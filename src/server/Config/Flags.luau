--!strict
-- Feature flag definitions (BM-006).
--
-- Every flag is listed here with a default per environment. A flag marked
-- `experimental` defaults to off everywhere and cannot be switched on in
-- production by an override; it goes live only by editing this file in a
-- reviewed commit. Flags are server-owned: clients never send or set them.
--
-- Later tasks register their flags here, in the same change that adds the
-- feature, and remove them when the feature is permanent.

export type FlagName = "alternateStarterCants" | "contentCoverageGate"

export type FlagDefinition = {
	-- Which backlog task owns the flag.
	owningTask: string,
	experimental: boolean,
	-- Default when on; environments not listed get `false`.
	enabledIn: { [string]: boolean },
}

export type FlagValues = { [FlagName]: boolean }

local DEFINITIONS: { [FlagName]: FlagDefinition } = {
	-- BM-107: offer established Cants other than Nearness as a first Cant.
	-- Off until each alternate starter passes its gate.
	alternateStarterCants = {
		owningTask = "BM-107",
		experimental = true,
		enabledIn = {},
	},
	-- BM-120: refuse to start a server whose launch-required content is
	-- incomplete. Off until the content manifest is populated.
	contentCoverageGate = {
		owningTask = "BM-120",
		experimental = true,
		enabledIn = {},
	},
}

local NAMES: { FlagName } = {}
for name in DEFINITIONS do
	table.insert(NAMES, name)
end
table.sort(NAMES)

local Flags = {}

Flags.DEFINITIONS = table.freeze(DEFINITIONS)
Flags.NAMES = table.freeze(NAMES)

function Flags.isFlag(value: unknown): boolean
	return type(value) == "string" and DEFINITIONS[value :: FlagName] ~= nil
end

-- A fresh, mutable table of defaults for an environment.
function Flags.defaultsFor(environment: string): FlagValues
	local values: FlagValues = {}
	for _, name: FlagName in NAMES do
		local definition = DEFINITIONS[name]
		values[name] = definition.enabledIn[environment] == true
	end
	return values
end

return table.freeze(Flags)
