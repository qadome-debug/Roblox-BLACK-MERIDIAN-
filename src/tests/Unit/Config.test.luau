--!strict
-- BM-006: configuration validation and feature-flag defaults.

local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ServerScriptService.Server.Config)
local Flags = require(ServerScriptService.Server.Config.Flags)

local cases = {}
local function case(name: string, run: () -> ())
	table.insert(cases, { name = name, run = run })
end

local function expectInvalid(environment: unknown, overrides: unknown, needle: string)
	local errors = Config.validate(environment, overrides)
	for _, err in errors do
		if string.find(err, needle, 1, true) then
			return
		end
	end
	error(
		string.format(
			"expected an error containing %q, got:\n  %s",
			needle,
			table.concat(errors, "\n  ")
		)
	)
end

case("every environment builds with defaults", function()
	for _, environment: Config.Environment in Config.ENVIRONMENTS do
		local config = Config.build(environment)
		assert(config.environment == environment, "environment")
		assert(type(config.dataStoreScope) == "string", "scope")
		assert(table.isfrozen(config :: any), "config frozen")
		assert(table.isfrozen(config.flags), "flags frozen")
	end
end)

case("test environment is read-only and scoped away from production", function()
	local config = Config.build("test")
	assert(config.readOnly == true, "test must be read-only")
	assert(config.dataStoreScope ~= "prod", "test must not use the production scope")
	assert(Config.build("production").readOnly == false, "production writes")
end)

case("every experimental flag defaults to disabled in every environment", function()
	for _, environment: Config.Environment in Config.ENVIRONMENTS do
		local config = Config.build(environment)
		for _, name: Flags.FlagName in Flags.NAMES do
			if Flags.DEFINITIONS[name].experimental then
				assert(config:isEnabled(name) == false, name .. " must be off in " .. environment)
			end
		end
	end
end)

case("every flag has an owning task", function()
	assert(#Flags.NAMES > 0, "at least one flag registered")
	for _, name: Flags.FlagName in Flags.NAMES do
		assert(
			string.match(Flags.DEFINITIONS[name].owningTask, "^BM%-%d%d%d$"),
			name .. " owning task"
		)
	end
end)

case("overrides apply outside production", function()
	local config =
		Config.build("studio", { flags = { alternateStarterCants = true }, readOnly = true })
	assert(config:isEnabled("alternateStarterCants"), "override applied")
	assert(config.readOnly == true, "readOnly override")
	assert(config:isEnabled("contentCoverageGate") == false, "untouched flag keeps default")
end)

case("experimental flags cannot be enabled in production by override", function()
	expectInvalid(
		"production",
		{ flags = { alternateStarterCants = true } },
		"cannot be enabled in production"
	)
	-- Explicitly disabling is fine.
	assert(
		#Config.validate("production", { flags = { alternateStarterCants = false } }) == 0,
		"disable ok"
	)
end)

case("invalid configuration is rejected", function()
	expectInvalid("staging", nil, "environment must be one of")
	expectInvalid(nil, nil, "environment must be one of")
	expectInvalid("studio", "fast", "overrides must be a table")
	expectInvalid("studio", { flags = { notAFlag = true } }, "unknown flag")
	expectInvalid("studio", { flags = { alternateStarterCants = "yes" } }, "must be a boolean")
	expectInvalid("studio", { flags = "all" }, "flags must be a table")
	expectInvalid("studio", { readOnly = 1 }, "readOnly must be a boolean")
	expectInvalid("studio", { dataStoreScope = "Prod Data" }, "dataStoreScope must be")
	expectInvalid("studio", { dataStoreScope = string.rep("a", 40) }, "dataStoreScope must be")
	expectInvalid("studio", { speedHack = true }, "unknown override")

	local ok = pcall(function()
		Config.build("studio", { flags = { notAFlag = true } } :: any)
	end)
	assert(not ok, "build must error on invalid overrides")
end)

case("flags cannot be changed after build", function()
	local config = Config.build("studio")
	local ok = pcall(function()
		(config.flags :: any).alternateStarterCants = true
	end)
	assert(not ok, "flags table must be frozen")
	assert(config:isEnabled("alternateStarterCants") == false, "value unchanged")
end)

case("isFlag only accepts registered names", function()
	assert(Flags.isFlag("alternateStarterCants"), "known")
	assert(not Flags.isFlag("AlternateStarterCants"), "case sensitive")
	assert(not Flags.isFlag(""), "empty")
	assert(not Flags.isFlag(nil), "nil")
	assert(not Flags.isFlag(true), "boolean")
end)

return cases
