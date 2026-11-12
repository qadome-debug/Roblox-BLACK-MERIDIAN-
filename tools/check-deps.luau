--!strict
-- Module dependency checker (BM-003).
--
-- Scans every .luau file under <root>/src, resolves each `require(...)` to a
-- module in the tree, and fails on:
--   * requires that cannot be resolved to a file (string requires, unknown
--     roots, missing modules),
--   * requires that cross a forbidden layer boundary (see docs/architecture.md),
--   * dependency cycles anywhere in the graph.
--
-- Usage (run with Lune):
--   lune run tools/check-deps.luau              -- check the repository
--   lune run tools/check-deps.luau --root DIR   -- check another project root
--   lune run tools/check-deps.luau --self-test  -- verify the checker itself

local fs = require("@lune/fs")
local process = require("@lune/process")

type Module = {
	id: string,
	segments: { string },
	file: string,
	requires: { string },
}

type Report = {
	modules: number,
	edges: number,
	errors: { string },
	kinds: { [string]: number },
}

local ROOTS: { { path: { string }, layer: string } } = {
	{ path = { "ReplicatedStorage", "Shared" }, layer = "shared" },
	{ path = { "ServerScriptService", "Server" }, layer = "server" },
	{ path = { "StarterPlayer", "StarterPlayerScripts", "Client" }, layer = "client" },
}

local function joinPath(a: string, b: string): string
	if a == "" then
		return b
	end
	return a .. "/" .. b
end

local function listLuauFiles(dir: string, rel: string, out: { string })
	for _, name in fs.readDir(dir) do
		local full = dir .. "/" .. name
		local relName = joinPath(rel, name)
		if fs.isDir(full) then
			listLuauFiles(full, relName, out)
		elseif string.match(name, "%.luau$") then
			table.insert(out, relName)
		end
	end
end

-- "server/Network/init.luau" -> {"server", "Network"}
-- "server/Bootstrap.server.luau" -> {"server", "Bootstrap"}
local function segmentsForFile(rel: string): { string }
	local segments = {}
	for part in string.gmatch(rel, "[^/]+") do
		table.insert(segments, part)
	end
	local last = segments[#segments]
	last = string.gsub(last, "%.luau$", "")
	last = string.gsub(last, "%.server$", "")
	last = string.gsub(last, "%.client$", "")
	if last == "init" then
		table.remove(segments)
	else
		segments[#segments] = last
	end
	return segments
end

local function stripComments(source: string): string
	source = string.gsub(source, "%-%-%[%[.-%]%]", "")
	source = string.gsub(source, "%-%-[^\n]*", "")
	return source
end

local function normalize(source: string): string
	source = string.gsub(source, "game:GetService%(%s*[\"']([%w_]+)[\"']%s*%)", "%1")
	source = string.gsub(source, ":WaitForChild%(%s*[\"']([%w_]+)[\"'][^%)]*%)", ".%1")
	source = string.gsub(source, ":FindFirstChild%(%s*[\"']([%w_]+)[\"'][^%)]*%)", ".%1")
	source = string.gsub(source, "%[%s*[\"']([%w_]+)[\"']%s*%]", ".%1")
	return source
end

local function extractRequires(source: string): { string }
	local found = {}
	source = normalize(stripComments(source))
	for arg in string.gmatch(source, "require%s*%(%s*([^%)]*)%)") do
		arg = string.gsub(arg, "%s+", "")
		table.insert(found, arg)
	end
	return found
end

local function startsWith(segments: { string }, prefix: { string }): boolean
	if #segments < #prefix then
		return false
	end
	for i, part in prefix do
		if segments[i] ~= part then
			return false
		end
	end
	return true
end

local function resolve(from: Module, arg: string): ({ string }?, string?)
	if string.match(arg, "^[\"']") then
		return nil, "string require is not allowed; use an instance path"
	end
	if string.find(arg, "(", 1, true) then
		return nil, "unsupported require expression"
	end

	local parts = {}
	for part in string.gmatch(arg, "[^%.]+") do
		table.insert(parts, part)
	end
	if #parts == 0 then
		return nil, "empty require"
	end

	local target: { string }
	local index: number

	if parts[1] == "script" then
		target = table.clone(from.segments)
		index = 2
	else
		local matched = nil
		for _, root in ROOTS do
			if startsWith(parts, root.path) then
				matched = root
				break
			end
		end
		if matched == nil then
			return nil, "unknown require root '" .. parts[1] .. "'"
		end
		target = { matched.layer }
		index = #matched.path + 1
	end

	for i = index, #parts do
		local part = parts[i]
		if part == "Parent" then
			if #target == 0 then
				return nil, "walked above the project root"
			end
			table.remove(target)
		else
			table.insert(target, part)
		end
	end

	return target, nil
end

local function layerViolation(from: { string }, to: { string }): string?
	local fromLayer, toLayer = from[1], to[1]

	if fromLayer == "tests" then
		return nil
	end
	if toLayer == "tests" then
		return "production code must not depend on tests"
	end
	if toLayer == "shared" then
		return nil
	end
	if toLayer ~= fromLayer then
		return fromLayer .. " code must not depend on " .. toLayer .. " code"
	end
	if fromLayer ~= "server" then
		return nil
	end

	local fromArea, toArea = from[2], to[2]
	if fromArea == "Services" and toArea == "Network" then
		return "Services must not depend on Network"
	end
	if fromArea == "Config" then
		if toArea ~= "Config" then
			return "Config must not depend on " .. tostring(toArea)
		end
		return nil
	end
	if fromArea == "Logging" then
		if toArea ~= "Logging" then
			return "Logging must not depend on " .. tostring(toArea)
		end
		return nil
	end
	if
		(fromArea == "Persistence" or fromArea == "Content")
		and (toArea == "Services" or toArea == "Network")
	then
		return fromArea .. " must not depend on " .. toArea
	end
	return nil
end

local function run(root: string): Report
	local report: Report = { modules = 0, edges = 0, errors = {}, kinds = {} }
	local function fail(kind: string, message: string)
		table.insert(report.errors, "[" .. kind .. "] " .. message)
		report.kinds[kind] = (report.kinds[kind] or 0) + 1
	end

	local srcDir = root .. "/src"
	if not fs.isDir(srcDir) then
		fail("setup", "no src directory under " .. root)
		return report
	end

	local files = {}
	listLuauFiles(srcDir, "", files)
	table.sort(files)

	local modules: { [string]: Module } = {}
	local ordered: { Module } = {}
	for _, rel in files do
		local segments = segmentsForFile(rel)
		local id = table.concat(segments, "/")
		if modules[id] ~= nil then
			fail("duplicate", id .. " is defined by both " .. modules[id].file .. " and " .. rel)
		else
			local module: Module = {
				id = id,
				segments = segments,
				file = rel,
				requires = extractRequires(fs.readFile(srcDir .. "/" .. rel)),
			}
			modules[id] = module
			table.insert(ordered, module)
		end
	end
	report.modules = #ordered

	local graph: { [string]: { string } } = {}
	for _, module in ordered do
		graph[module.id] = {}
		for _, arg in module.requires do
			local target, err = resolve(module, arg)
			if target == nil then
				fail("unresolved", module.file .. ": require(" .. arg .. "): " .. (err or "?"))
			else
				local targetId = table.concat(target, "/")
				if modules[targetId] == nil then
					fail(
						"unresolved",
						module.file .. ": require(" .. arg .. ") -> no module at " .. targetId
					)
				else
					local violation = layerViolation(module.segments, target)
					if violation then
						fail("layer", module.file .. " -> " .. targetId .. ": " .. violation)
					end
					table.insert(graph[module.id], targetId)
					report.edges += 1
				end
			end
		end
	end

	-- Cycle detection: depth-first search with white/grey/black colouring.
	local state: { [string]: string } = {}
	local stack: { string } = {}
	local reported: { [string]: boolean } = {}

	local function visit(id: string)
		state[id] = "grey"
		table.insert(stack, id)
		for _, dep in graph[id] do
			if state[dep] == "grey" then
				local cycle = {}
				local started = false
				for _, entry in stack do
					if entry == dep then
						started = true
					end
					if started then
						table.insert(cycle, entry)
					end
				end
				table.insert(cycle, dep)
				local key = table.concat(cycle, " -> ")
				if not reported[key] then
					reported[key] = true
					fail("cycle", key)
				end
			elseif state[dep] == nil then
				visit(dep)
			end
		end
		table.remove(stack)
		state[id] = "black"
	end

	for _, module in ordered do
		if state[module.id] == nil then
			visit(module.id)
		end
	end

	return report
end

local function printReport(root: string, report: Report)
	print(string.format("check-deps: %s", root))
	print(
		string.format(
			"  modules: %d, edges: %d, errors: %d",
			report.modules,
			report.edges,
			#report.errors
		)
	)
	for _, err in report.errors do
		print("  " .. err)
	end
end

local function selfTest(): boolean
	local fixtures = "tools/fixtures/deps"
	local expectations: { { name: string, kinds: { [string]: number } } } = {
		{ name = "clean", kinds = {} },
		{ name = "cycle", kinds = { cycle = 1 } },
		{ name = "layer", kinds = { layer = 5 } },
		{ name = "unresolved", kinds = { unresolved = 3 } },
	}
	local passed = true
	for _, case in expectations do
		local report = run(fixtures .. "/" .. case.name)
		local ok = true
		for kind, count in case.kinds do
			if (report.kinds[kind] or 0) ~= count then
				ok = false
			end
		end
		for kind in report.kinds do
			if case.kinds[kind] == nil then
				ok = false
			end
		end
		print(string.format("self-test %-10s %s", case.name, if ok then "pass" else "FAIL"))
		if not ok then
			passed = false
			printReport(fixtures .. "/" .. case.name, report)
		end
	end
	return passed
end

local args = process.args
if args[1] == "--self-test" then
	process.exit(if selfTest() then 0 else 1)
end

local root = "."
if args[1] == "--root" and args[2] ~= nil then
	root = args[2]
end

local report = run(root)
printReport(root, report)
process.exit(if #report.errors == 0 then 0 else 1)
