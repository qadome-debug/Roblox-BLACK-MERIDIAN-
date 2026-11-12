--!strict
-- Remote creation audit, static half (BM-011).
--
-- Only src/server/Network/Remotes.luau may create remote instances. This
-- scans every other file under src/ for Instance.new of a remote class and
-- fails on a hit. The runtime half, Remotes.audit, inspects the live place.
--
--   lune run tools/check-remotes.luau

local fs = require("@lune/fs")
local process = require("@lune/process")

local ALLOWED_FILE = "src/server/Network/Remotes.luau"

local PATTERNS = {
	"%f[%w_]Instance%.new%(%s*[\"']RemoteEvent[\"']",
	"%f[%w_]Instance%.new%(%s*[\"']RemoteFunction[\"']",
	"%f[%w_]Instance%.new%(%s*[\"']UnreliableRemoteEvent[\"']",
	"%f[%w_]Instance%.new%(%s*[\"']BindableFunction[\"']",
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
		elseif string.match(name, "%.luau$") and path ~= ALLOWED_FILE then
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

scan("src")

print(string.format("check-remotes: %d files scanned, %d problems", scanned, #problems))
for _, problem in problems do
	print("  " .. problem)
end
process.exit(if #problems == 0 then 0 else 1)
