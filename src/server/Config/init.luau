--!strict
-- Server configuration and feature flags (BM-006).
--
-- Configuration is built once at server start (construction stage 1) from
-- the environment the server detects plus the checked-in defaults, then
-- frozen and injected into services. Nothing reads flags from a client,
-- nothing can flip one at runtime, and every experimental feature defaults
-- to off in every environment. The client learns which features are on only
-- through server-to-client state and cannot change them.
--
-- This module is pure: it does not touch `game` so it can be built and
-- tested under Lune. Bootstrap detects the environment and passes it in.

local Flags = require(script.Flags)

export type Environment = "test" | "studio" | "development" | "production"

export type FlagName = Flags.FlagName
export type FlagValues = Flags.FlagValues

export type Config = {
	environment: Environment,
	-- True when nothing durable may be written (test runs, read-only
	-- recovery). ProfileService refuses to acquire leases when set.
	readOnly: boolean,
	-- DataStore name prefix; keeps Studio and tests away from production keys.
	dataStoreScope: string,
	flags: FlagValues,
	isEnabled: (self: Config, flag: FlagName) -> boolean,
}

-- Overrides a caller may supply for an environment. Anything not listed
-- keeps the default for that environment. Unknown keys are an error.
export type Overrides = {
	readOnly: boolean?,
	dataStoreScope: string?,
	flags: { [string]: boolean }?,
}

local ENVIRONMENTS: { Environment } = { "test", "studio", "development", "production" }

local DEFAULTS: { [Environment]: { readOnly: boolean, dataStoreScope: string } } = {
	test = { readOnly = true, dataStoreScope = "test" },
	studio = { readOnly = false, dataStoreScope = "studio" },
	development = { readOnly = false, dataStoreScope = "dev" },
	production = { readOnly = false, dataStoreScope = "prod" },
}

local function describe(value: unknown): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return typeof(value)
end

local Config = {}

Config.ENVIRONMENTS = table.freeze(table.clone(ENVIRONMENTS))

function Config.isEnvironment(value: unknown): boolean
	return type(value) == "string" and table.find(ENVIRONMENTS, value :: Environment) ~= nil
end

-- Returns every problem with `overrides` for the given environment, or an
-- empty list. Production may not enable experimental flags through
-- overrides; a flag reaches production only by changing its definition in
-- Flags.luau through a reviewed commit.
function Config.validate(environment: unknown, overrides: unknown): { string }
	local errors: { string } = {}
	local function fail(message: string)
		table.insert(errors, message)
	end

	if not Config.isEnvironment(environment) then
		fail(
			"environment must be one of "
				.. table.concat(ENVIRONMENTS, ", ")
				.. ", got "
				.. describe(environment)
		)
	end

	if overrides == nil then
		return errors
	end
	if type(overrides) ~= "table" then
		fail("overrides must be a table, got " .. typeof(overrides))
		return errors
	end
	local raw = overrides :: { [any]: unknown }

	for key, value in raw do
		if key == "readOnly" then
			if type(value) ~= "boolean" then
				fail("readOnly must be a boolean")
			end
		elseif key == "dataStoreScope" then
			if
				type(value) ~= "string"
				or not string.match(value, "^[a-z][a-z0-9%-]*$")
				or #value > 32
			then
				fail("dataStoreScope must be a short lowercase identifier")
			end
		elseif key == "flags" then
			if type(value) ~= "table" then
				fail("flags must be a table")
			else
				for flag, enabled in value :: { [any]: unknown } do
					if type(flag) ~= "string" or not Flags.isFlag(flag) then
						fail("unknown flag " .. describe(flag))
					elseif type(enabled) ~= "boolean" then
						fail("flag " .. flag .. " must be a boolean")
					elseif
						environment == "production"
						and enabled
						and Flags.DEFINITIONS[flag :: FlagName].experimental
					then
						fail(
							"flag "
								.. flag
								.. " is experimental and cannot be enabled in production by override"
						)
					end
				end
			end
		else
			fail("unknown override " .. describe(key))
		end
	end

	return errors
end

-- Builds a frozen Config. Errors on invalid input so a server never runs on
-- a half-applied configuration.
function Config.build(environment: Environment, overrides: Overrides?): Config
	local problems = Config.validate(environment, overrides)
	if #problems > 0 then
		error("Config: invalid configuration:\n  " .. table.concat(problems, "\n  "), 2)
	end

	local defaults = DEFAULTS[environment]
	local flags = Flags.defaultsFor(environment)

	local readOnly = defaults.readOnly
	local dataStoreScope = defaults.dataStoreScope
	if overrides ~= nil then
		if overrides.readOnly ~= nil then
			readOnly = overrides.readOnly
		end
		if overrides.dataStoreScope ~= nil then
			dataStoreScope = overrides.dataStoreScope
		end
		if overrides.flags ~= nil then
			for flag, enabled in overrides.flags do
				flags[flag :: FlagName] = enabled
			end
		end
	end

	local config = {} :: Config
	config.environment = environment
	config.readOnly = readOnly
	config.dataStoreScope = dataStoreScope
	config.flags = table.freeze(flags)
	function config:isEnabled(flag: FlagName): boolean
		return self.flags[flag] == true
	end

	return table.freeze(config)
end

return table.freeze(Config)
