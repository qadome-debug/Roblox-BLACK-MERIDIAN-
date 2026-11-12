--!strict
-- Runs every check the repository requires, in order, and fails on the
-- first group that fails (BM-010). CI and developers run the same script,
-- so "passes locally" and "passes in CI" mean the same thing.
--
--   lune run tools/check-all.luau            -- everything
--   lune run tools/check-all.luau --quick    -- skip the Rojo build
--
-- Steps marked "expect failure" are negative fixtures: the check must fail
-- on them, which proves the check can fail at all.

local process = require("@lune/process")

type Step = {
	name: string,
	program: string,
	args: { string },
	-- When true the step passes only if the command exits non-zero.
	expectFailure: boolean?,
}

local quick = table.find(process.args, "--quick") ~= nil

local ANALYZE_SRC = {
	"analyze",
	"--platform",
	"roblox",
	"--sourcemap",
	"sourcemap.json",
	"--definitions",
	"@roblox=globalTypes.d.luau",
	"--base-luaurc",
	".luaurc",
	"src",
}

local ANALYZE_TOOLS = {
	"analyze",
	"--platform",
	"standard",
	"tools/check-all.luau",
	"tools/check-deps.luau",
	"tools/check-contracts.luau",
	"tools/check-tests.luau",
	"tools/run-tests.luau",
	"tools/host",
}

local steps: { Step } = {
	{ name = "format", program = "stylua", args = { "--check", "src", "tools" } },
	{ name = "lint", program = "selene", args = { "src", "tools" } },
	{
		name = "sourcemap",
		program = "rojo",
		args = { "sourcemap", "tests.project.json", "--output", "sourcemap.json" },
	},
	{ name = "typecheck src", program = "luau-lsp", args = ANALYZE_SRC },
	{ name = "typecheck tools", program = "luau-lsp", args = ANALYZE_TOOLS },
	{
		name = "deps self-test",
		program = "lune",
		args = { "run", "tools/check-deps.luau", "--self-test" },
	},
	{ name = "deps", program = "lune", args = { "run", "tools/check-deps.luau" } },
	{ name = "contracts", program = "lune", args = { "run", "tools/check-contracts.luau" } },
	{ name = "test isolation", program = "lune", args = { "run", "tools/check-tests.luau" } },
	{ name = "tests", program = "lune", args = { "run", "tools/run-tests.luau" } },
	{
		name = "failing fixture (expect failure)",
		program = "lune",
		args = { "run", "tools/run-tests.luau", "--root", "tools/fixtures/tests/failing" },
		expectFailure = true,
	},
}

if not quick then
	table.insert(steps, {
		name = "build",
		program = "rojo",
		args = { "build", "default.project.json", "--output", "BlackMeridian.rbxl" },
	})
end

local function run(step: Step): boolean
	local result = process.exec(step.program, step.args)
	local succeeded = if step.expectFailure then not result.ok else result.ok
	if not succeeded then
		print(string.format("\n==> %s: FAIL (exit %d)", step.name, result.code))
		if #result.stdout > 0 then
			print(result.stdout)
		end
		if #result.stderr > 0 then
			print(result.stderr)
		end
		return false
	end
	print(string.format("ok    %s", step.name))
	return true
end

local allOk = true
for _, step in steps do
	if not run(step) then
		allOk = false
		break
	end
end

print("")
if allOk then
	print(string.format("check-all: %d steps passed", #steps))
	process.exit(0)
else
	print("check-all: FAILED")
	process.exit(1)
end
