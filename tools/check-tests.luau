--!strict
-- Test isolation check (BM-009).
--
-- Tests must never be able to reach a real DataStore or other live
-- service. This scans src/tests for the engine calls that would do so and
-- fails if any appear. Production code gets these through injection, and
-- tests inject the fakes from src/tests/Support.
--
--   lune run tools/check-tests.luau

local fs = require("@lune/fs")
local process = require("@lune/process")

local FORBIDDEN = {
	"GetService%(%s*[\"']DataStoreService[\"']%s*%)",
	"GetService%(%s*[\"']MemoryStoreService[\"']%s*%)",
	"GetService%(%s*[\"']HttpService[\"']%s*%)",
	"GetService%(%s*[\"']MessagingService[\"']%s*%)",
	"GetService%(%s*[\"']TeleportService[\"']%s*%)",
	"%f[%w_]DataStoreService%f[^%w_]",
	"%f[%w_]MemoryStoreService%f[^%w_]",
	"%f[%w_]HttpService%f[^%w_]",
	"%f[%w_]MessagingService%f[^%w_]",
	"%f[%w_]TeleportService%f[^%w_]",
	"%f[%w_]os%.time%s*%(",
	"%f[%w_]os%.clock%s*%(",
	"%f[%w_]math%.random%s*%(",
	"%f[%w_]Random%.new%s*%(",
}

local function stripComments(source: string): string
	source = string.gsub(source, "%-%-%[%[.-%]%]", "")
	source = string.gsub(source, "%-%-[^\n]*", "")
	return source
end

local problems: { string } = {}
local scanned = 0

local function scan(dir: string)
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
				for _, pattern in FORBIDDEN do
					if string.find(line, pattern) then
						table.insert(problems, string.format("%s:%d: %s", path, lineNumber, line))
						break
					end
				end
			end
		end
	end
end

if fs.isDir("src/tests") then
	scan("src/tests")
end

print(string.format("check-tests: %d files scanned, %d problems", scanned, #problems))
for _, problem in problems do
	print("  " .. problem)
end
process.exit(if #problems == 0 then 0 else 1)
