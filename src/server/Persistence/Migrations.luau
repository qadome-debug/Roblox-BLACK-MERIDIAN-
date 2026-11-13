--!strict
-- Profile migrations (BM-023).
--
-- A stored profile carries `schemaVersion`. Loading runs the registered
-- steps from that version up to the current one, each step moving exactly
-- one version forward on a deep copy of the data. Rules:
--   * a profile from a newer schema than this server knows is rejected,
--     never rewritten or overwritten (a rollback must not destroy data),
--   * a version with no path to the current one is rejected,
--   * migrating a current profile is a no-op, and running the chain twice
--     gives the same result (steps are pure and each one is idempotent on
--     already-migrated data because it only runs for its own `from`).
--
-- Migration steps are added to STEPS by the task that changes the schema,
-- together with a fixture profile at the old version.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Profile = require(ReplicatedStorage.Shared.Types.Profile)

export type Raw = { [string]: any }

export type Step = {
	from: number,
	to: number,
	-- Receives a deep copy it may mutate; returns the migrated table with
	-- schemaVersion == to.
	apply: (raw: Raw) -> Raw,
}

export type Result = { profile: Raw?, applied: { number }, error: string? }

export type Migrator = {
	currentVersion: number,
	migrate: (self: Migrator, raw: unknown) -> Result,
}

local Migrations = {}

-- The production chain. Empty while schema version 1 is the only version.
Migrations.STEPS = table.freeze({} :: { Step })

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepCopy(item)
	end
	return copy
end

Migrations.deepCopy = deepCopy

function Migrations.new(steps: { Step }, currentVersion: number): Migrator
	local byFrom: { [number]: Step } = {}
	for _, step in steps do
		if step.to ~= step.from + 1 then
			error(
				string.format(
					"Migrations.new: step %d -> %d must advance exactly one version",
					step.from,
					step.to
				)
			)
		end
		if byFrom[step.from] ~= nil then
			error(string.format("Migrations.new: duplicate step from version %d", step.from))
		end
		if step.to > currentVersion then
			error(
				string.format(
					"Migrations.new: step %d -> %d goes past the current version %d",
					step.from,
					step.to,
					currentVersion
				)
			)
		end
		byFrom[step.from] = step
	end

	local migrator = {} :: Migrator
	migrator.currentVersion = currentVersion

	function migrator:migrate(raw: unknown): Result
		if type(raw) ~= "table" then
			return { profile = nil, applied = {}, error = "stored profile is not a table" }
		end
		local version = (raw :: Raw).schemaVersion
		if type(version) ~= "number" or version ~= version or version % 1 ~= 0 or version < 1 then
			return {
				profile = nil,
				applied = {},
				error = "stored profile has no valid schemaVersion",
			}
		end
		if version > currentVersion then
			return {
				profile = nil,
				applied = {},
				error = string.format(
					"stored profile is schema %d but this server supports up to %d",
					version,
					currentVersion
				),
			}
		end

		local working: Raw = deepCopy(raw)
		local applied: { number } = {}
		while working.schemaVersion < currentVersion do
			local step = byFrom[working.schemaVersion]
			if step == nil then
				return {
					profile = nil,
					applied = applied,
					error = string.format("no migration from schema %d", working.schemaVersion),
				}
			end
			local ok, migrated = pcall(step.apply, working)
			if not ok then
				return {
					profile = nil,
					applied = applied,
					error = string.format(
						"migration %d -> %d failed: %s",
						step.from,
						step.to,
						tostring(migrated)
					),
				}
			end
			if type(migrated) ~= "table" or migrated.schemaVersion ~= step.to then
				return {
					profile = nil,
					applied = applied,
					error = string.format(
						"migration %d -> %d did not produce schema %d",
						step.from,
						step.to,
						step.to
					),
				}
			end
			working = migrated
			table.insert(applied, step.to)
		end
		return { profile = working, applied = applied, error = nil }
	end

	return table.freeze(migrator)
end

-- The migrator for the production chain.
function Migrations.production(): Migrator
	return Migrations.new(Migrations.STEPS, Profile.SCHEMA_VERSION)
end

return table.freeze(Migrations)
