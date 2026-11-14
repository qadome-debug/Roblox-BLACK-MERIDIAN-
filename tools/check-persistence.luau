--!strict
-- Persistence write audit (BM-030).
--
-- Only Persistence/Lease.luau and Persistence/ProfileStore.luau may call
-- the DataStore write methods. Everything else enqueues mutations through
-- SaveQueue. This scans src/ (excluding the test fakes) for UpdateAsync,
-- SetAsync, RemoveAsync, IncrementAsync and GetDataStore and fails on a
-- hit anywhere else.
--
--   lune run tools/check-persistence.luau

local fs = require("@lune/fs")
local process = require("@lune/process")

local ALLOWED = {
	["src/server/Persistence/Lease.luau"] = true,
	["src/server/Persistence/ProfileStore.luau"] = true,
	-- Bootstrap wires the real DataStoreService to the persistence layer.
	["src/server/Bootstrap.server.luau"] = { GetDataStore = true },
	-- The test fake implements the API.
	["src/tests/Support/FakeDataStoreService.luau"] = true,
}

local PATTERNS: { [string]: string } = {
	UpdateAsync = ":UpdateAsync%s*%(",
	SetAsync = ":SetAsync%s*%(",
	RemoveAsync = ":RemoveAsync%s*%(",
	IncrementAsync = ":IncrementAsync%s*%(",
	GetDataStore = ":GetDataStore%s*%(",
}

local function stripComments(source: string): string
	source = string.gsub(source, "%-%-%[%[.-%]%]", "")
	source = string.gsub(source, "%-%-[^\n]*", "")
	return source
end

local problems: { string } = {}
local scanned = 0

local function allowed(path: string, name: string): boolean
	local rule = ALLOWED[path]
	if rule == true then
		return true
	end
	if type(rule) == "table" then
		return rule[name] == true
	end
	return false
end

local function scan(dir: string)
	-- Tests drive the fake store directly; the rule is for production code.
	if dir == "src/tests" then
		return
	end
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			scan(path)
		elseif string.match(entry, "%.luau$") then
			scanned += 1
			local source = stripComments(fs.readFile(path))
			local lineNumber = 0
			for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
				lineNumber += 1
				for name, pattern in PATTERNS do
					if string.find(line, pattern) and not allowed(path, name) then
						table.insert(
							problems,
							string.format(
								"%s:%d: %s outside the persistence layer",
								path,
								lineNumber,
								name
							)
						)
					end
				end
			end
		end
	end
end

scan("src")

print(string.format("check-persistence: %d files scanned, %d problems", scanned, #problems))
table.sort(problems)
for _, problem in problems do
	print("  " .. problem)
end
process.exit(if #problems == 0 then 0 else 1)
