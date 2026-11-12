--!strict
-- Test runner (minimal form; BM-009 extends it).
--
-- Discovers every `*.test.luau` under src/tests, loads it through the virtual
-- tree so it can require production modules by instance path, and runs the
-- cases it returns. A test module returns an array of { name, run } records.
--
--   lune run tools/run-tests.luau              -- run everything
--   lune run tools/run-tests.luau --filter X   -- only cases whose file or
--                                                 name contains X

local process = require("@lune/process")

local Loader = require("./host/Loader")

type Case = { name: string, run: () -> () }

local args = process.args
local filter: string? = nil
for i, arg in args do
	if arg == "--filter" then
		filter = args[i + 1]
	end
end

local loader = Loader.forProject(".")

local testFiles = {}
for rel, node in loader.tree.byFile do
	if string.match(rel, "^tests/.*%.test%.luau$") then
		table.insert(testFiles, { rel = rel, node = node })
	end
end
table.sort(testFiles, function(a, b)
	return a.rel < b.rel
end)

local passed, failed, skipped = 0, 0, 0
local failures: { string } = {}

for _, file in testFiles do
	local okLoad, cases = pcall(loader.require, file.node)
	if not okLoad then
		failed += 1
		table.insert(failures, string.format("%s: failed to load: %s", file.rel, tostring(cases)))
		print(string.format("LOAD FAIL  %s", file.rel))
		continue
	end
	if type(cases) ~= "table" then
		failed += 1
		table.insert(
			failures,
			string.format("%s: test module must return an array of cases", file.rel)
		)
		continue
	end

	for _, case in cases :: { Case } do
		local label = file.rel .. " :: " .. case.name
		if filter ~= nil and not string.find(label, filter, 1, true) then
			skipped += 1
			continue
		end
		local ok, err = pcall(case.run :: () -> ...any)
		if ok then
			passed += 1
			print(string.format("pass  %s", label))
		else
			failed += 1
			table.insert(failures, string.format("%s\n    %s", label, tostring(err)))
			print(string.format("FAIL  %s", label))
		end
	end
end

print("")
if #failures > 0 then
	print("Failures:")
	for _, failure in failures do
		print("  " .. failure)
	end
	print("")
end
print(
	string.format("%d passed, %d failed, %d skipped, %d files", passed, failed, skipped, #testFiles)
)

if #testFiles == 0 then
	print("no test files found under src/tests")
	process.exit(1)
end
process.exit(if failed == 0 then 0 else 1)
