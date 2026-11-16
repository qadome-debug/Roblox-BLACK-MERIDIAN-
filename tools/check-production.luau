--!strict
-- Production isolation audit.
--
-- The Studio play-test harness (src/tests/Playtest) can grant Cants, set
-- resources and read server state. It must never ship. This check fails
-- the build if any of the following stops being true:
--
--   1. The production project (default.project.json) mounts nothing from
--      src/tests, creates no remotes, sets no play-test attributes, and its
--      instance tree holds no test or play-test instance.
--   2. Production source mentions the play-test harness only in the two
--      Bootstrap scripts.
--   3. The server Bootstrap looks the harness up only inside its
--      `config.environment == "studio"` block, and "studio" is only ever
--      returned behind `RunService:IsStudio()`.
--   4. The client Bootstrap looks its driver up only behind `IsStudio()`.
--   5. The harness itself refuses to run outside Studio.
--
--   lune run tools/check-production.luau
--   lune run tools/check-production.luau --project playtest.project.json
--
-- The second form audits another project file; check-all runs it against
-- the play-test project and expects it to FAIL, which proves the audit can
-- tell the two builds apart.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local project = "default.project.json"
do
	local at = table.find(process.args, "--project")
	if at ~= nil and process.args[at + 1] ~= nil then
		project = process.args[at + 1]
	end
end

local SERVER_BOOTSTRAP = "src/server/Bootstrap.server.luau"
local CLIENT_BOOTSTRAP = "src/client/Bootstrap.client.luau"
local HARNESS = "src/tests/Playtest/Server.luau"

local FORBIDDEN_NAMES: { [string]: boolean } = {
	Tests = true,
	Playtest = true,
	PlaytestClient = true,
	PlaytestControl = true,
	RunnerPlugin = true,
	FakeDataStoreService = true,
	ContentFixtures = true,
}
local FORBIDDEN_CLASSES: { [string]: boolean } = {
	RemoteEvent = true,
	RemoteFunction = true,
	UnreliableRemoteEvent = true,
	BindableEvent = true,
	BindableFunction = true,
}

local problems: { string } = {}
local function problem(message: string)
	table.insert(problems, message)
end

local function normalize(path: string): string
	return (string.gsub(path, "\\", "/"))
end

-- 1a. The project file itself.
local function auditProjectNode(name: string, node: any, where: string)
	if type(node) ~= "table" then
		return
	end
	if FORBIDDEN_NAMES[name] or string.find(string.lower(name), "playtest", 1, true) then
		problem(string.format("%s: node %s must not be in a production build", project, where))
	end
	local path = node["$path"]
	if type(path) == "string" then
		local lowered = string.lower(normalize(path))
		if
			string.find(lowered, "src/tests", 1, true) or string.find(lowered, "playtest", 1, true)
		then
			problem(string.format("%s: %s mounts %s", project, where, path))
		end
	end
	local className = node["$className"]
	if type(className) == "string" and FORBIDDEN_CLASSES[className] then
		problem(string.format("%s: %s creates a %s", project, where, className))
	end
	local attributes = node["$attributes"]
	if type(attributes) == "table" then
		for key in attributes do
			if string.find(string.lower(tostring(key)), "playtest", 1, true) then
				problem(string.format("%s: %s sets attribute %s", project, where, tostring(key)))
			end
		end
	end
	for key, child in node do
		if type(key) == "string" and string.sub(key, 1, 1) ~= "$" then
			auditProjectNode(key, child, where .. "." .. key)
		end
	end
end

local projectData = serde.decode("json", fs.readFile(project))
auditProjectNode("game", projectData.tree, "game")

-- 1b. The instance tree Rojo actually builds from it.
local instances = 0
local function auditInstance(node: any, where: string)
	instances += 1
	local name = tostring(node.name)
	local here = where .. "." .. name
	if FORBIDDEN_NAMES[name] or string.find(name, "%.test$") then
		problem(string.format("built tree: %s must not be in a production build", here))
	end
	if FORBIDDEN_CLASSES[tostring(node.className)] then
		problem(string.format("built tree: %s is a %s", here, tostring(node.className)))
	end
	if type(node.filePaths) == "table" then
		for _, path in node.filePaths do
			if string.find(string.lower(normalize(tostring(path))), "src/tests", 1, true) then
				problem(string.format("built tree: %s comes from %s", here, tostring(path)))
			end
		end
	end
	if type(node.children) == "table" then
		for _, child in node.children do
			auditInstance(child, here)
		end
	end
end

local sourcemap = process.exec("rojo", { "sourcemap", project })
if not sourcemap.ok then
	problem("rojo sourcemap " .. project .. " failed: " .. sourcemap.stderr)
else
	auditInstance(serde.decode("json", sourcemap.stdout), "")
end

-- 2. Production source mentions the harness only in the Bootstraps.
local scanned = 0
local function scan(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			scan(path)
		elseif string.match(name, "%.luau$") then
			scanned += 1
			if path ~= SERVER_BOOTSTRAP and path ~= CLIENT_BOOTSTRAP then
				local lowered = string.lower(fs.readFile(path))
				if string.find(lowered, "playtest", 1, true) then
					problem(path .. ": production source must not mention the play-test harness")
				end
				if string.find(lowered, "serverstorage.tests", 1, true) then
					problem(path .. ": production source must not reach into the test tree")
				end
			end
		end
	end
end
for _, dir in { "src/server", "src/client", "src/shared" } do
	scan(dir)
end

local function lines(path: string): { string }
	local out: { string } = {}
	local source = string.gsub(fs.readFile(path), "\r", "")
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		table.insert(out, line)
	end
	return out
end

local function stripComment(line: string): string
	return (string.gsub(line, "%-%-.*$", ""))
end

-- The line range of the top-level block opened by the first line equal to
-- `opener`: from that line to the next line that is exactly "end".
local function topLevelBlock(source: { string }, opener: string): (number?, number?)
	for index, line in source do
		if line == opener then
			for close = index + 1, #source do
				if source[close] == "end" then
					return index, close
				end
			end
		end
	end
	return nil, nil
end

-- 3. Server Bootstrap.
do
	local source = lines(SERVER_BOOTSTRAP)
	local first, last = topLevelBlock(source, 'if config.environment == "studio" then')
	if first == nil or last == nil then
		problem(SERVER_BOOTSTRAP .. ': the `config.environment == "studio"` block is missing')
	end
	local studioReturns = 0
	for index, raw in source do
		local line = stripComment(raw)
		local inside = first ~= nil and last ~= nil and index > first and index < last
		if string.find(line, '"Tests"', 1, true) or string.find(line, '"Playtest"', 1, true) then
			if not inside then
				problem(
					string.format(
						"%s:%d: the test tree is looked up outside the studio block",
						SERVER_BOOTSTRAP,
						index
					)
				)
			end
		end
		if string.find(line, "^%s*playtest%s*=") and not inside then
			problem(
				string.format(
					"%s:%d: the harness is assigned outside the studio block",
					SERVER_BOOTSTRAP,
					index
				)
			)
		end
		if string.find(line, 'return "studio"', 1, true) then
			studioReturns += 1
			local previous = stripComment(source[index - 1] or "")
			if not string.find(previous, "if RunService:IsStudio() then", 1, true) then
				problem(
					string.format(
						'%s:%d: "studio" must only be returned behind RunService:IsStudio()',
						SERVER_BOOTSTRAP,
						index
					)
				)
			end
		end
	end
	if studioReturns ~= 1 then
		problem(
			string.format(
				'%s: expected exactly one `return "studio"`, found %d',
				SERVER_BOOTSTRAP,
				studioReturns
			)
		)
	end
end

-- 4. Client Bootstrap.
do
	local source = lines(CLIENT_BOOTSTRAP)
	local first, last = topLevelBlock(source, 'if game:GetService("RunService"):IsStudio() then')
	for index, raw in source do
		local line = stripComment(raw)
		if string.find(line, "PlaytestClient", 1, true) then
			if first == nil or last == nil or index <= first or index >= last then
				problem(
					string.format(
						"%s:%d: the play-test driver is looked up outside the IsStudio block",
						CLIENT_BOOTSTRAP,
						index
					)
				)
			end
		end
	end
end

-- 5. The harness refuses to run outside Studio.
do
	local source = lines(HARNESS)
	for _, entry in { "function Playtest.stores", "function Playtest.start" } do
		local found = false
		for index, line in source do
			if string.sub(line, 1, #entry) == entry then
				found = true
				local guard = source[index + 1] or ""
				if not string.find(guard, "if not RunService:IsStudio() then", 1, true) then
					problem(
						string.format(
							"%s:%d: %s must start with the IsStudio guard",
							HARNESS,
							index,
							entry
						)
					)
				end
			end
		end
		if not found then
			problem(HARNESS .. ": " .. entry .. " not found")
		end
	end
end

print(
	string.format(
		"check-production: %s, %d instances, %d source files, %d problems",
		project,
		instances,
		scanned,
		#problems
	)
)
local SHOWN = 12
for index, message in problems do
	if index > SHOWN then
		print(string.format("  ... and %d more", #problems - SHOWN))
		break
	end
	print("  " .. message)
end
process.exit(if #problems == 0 then 0 else 1)
