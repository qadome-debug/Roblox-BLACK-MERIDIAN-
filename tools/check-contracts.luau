--!strict
-- Contract hygiene check (BM-005).
--
-- Persistent and protocol types must not contain unrestricted `any`. This
-- scans src/shared/Types and src/shared/Contracts for `any` used as a type
-- and fails if it finds one. `unknown` is allowed: it forces a check before
-- use, which is the point.
--
--   lune run tools/check-contracts.luau

local fs = require("@lune/fs")
local process = require("@lune/process")

local DIRS = { "src/shared/Types", "src/shared/Contracts" }

local PATTERNS = {
	":%s*any%f[^%w_]", -- `: any`
	"{%s*any%s*}", -- `{ any }`
	"%[[^%]]*%]%s*:%s*any%f[^%w_]", -- `[string]: any`
	"<%s*any%s*>", -- `Foo<any>`
	"::%s*any%f[^%w_]", -- `:: any`
	"%->%s*any%f[^%w_]", -- `-> any`
	"|%s*any%f[^%w_]", -- `| any`
}

local function stripComments(source: string): string
	source = string.gsub(source, "%-%-%[%[.-%]%]", "")
	source = string.gsub(source, "%-%-[^\n]*", "")
	return source
end

local problems: { string } = {}
local scanned = 0

local function scan(dir: string)
	if not fs.isDir(dir) then
		return
	end
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			scan(path)
		elseif string.match(name, "%.luau$") then
			scanned += 1
			local source = stripComments(fs.readFile(path))
			local lineNumber = 0
			for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
				lineNumber += 1
				for _, pattern in PATTERNS do
					if string.find(line, pattern) then
						table.insert(problems, string.format("%s:%d: %s", path, lineNumber, line))
						break
					end
				end
			end
		end
	end
end

for _, dir in DIRS do
	scan(dir)
end

print(string.format("check-contracts: %d files scanned, %d problems", scanned, #problems))
for _, problem in problems do
	print("  " .. problem)
end
process.exit(if #problems == 0 then 0 else 1)
