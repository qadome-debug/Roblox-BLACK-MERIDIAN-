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

local LegacyIds = require(script.Parent.LegacyIds)

local Migrations = {}

-- Cant IDs used before schema v3 (see Persistence/LegacyIds).
Migrations.LEGACY_CANT_IDS = LegacyIds.CANT
local renameKeys = LegacyIds.renameKeys

local function renameReceiptKeys(map: { [any]: any }): { [any]: any }
	local out: { [any]: any } = {}
	for key, value in map do
		out[if type(key) == "string" then LegacyIds.receipt(key) else key] = value
	end
	return out
end

-- The production chain.
Migrations.STEPS = table.freeze({
	-- v1 -> v2 (BM-047): receipts gain an append-only list of archive keys.
	{
		from = 1,
		to = 2,
		apply = function(raw: Raw): Raw
			if type(raw.receipts) == "table" and raw.receipts.archives == nil then
				raw.receipts.archives = {}
			end
			raw.schemaVersion = 2
			return raw
		end,
	},
	-- v2 -> v3: canonical IDs follow the design report's format
	-- (approved 2026-11-16). The one Cant ID that existed before the change
	-- is carried over explicitly, so a profile saved under the old ID keeps
	-- its Cant instead of failing validation. IDs that did not change are
	-- untouched, and nothing is dropped.
	{
		from = 2,
		to = 3,
		apply = function(raw: Raw): Raw
			local cants = raw.cants
			if type(cants) == "table" then
				if type(cants.unlocked) == "table" then
					cants.unlocked = renameKeys(cants.unlocked, LegacyIds.CANT)
				end
				if type(cants.verses) == "table" then
					cants.verses = renameKeys(cants.verses, LegacyIds.CANT)
				end
				if type(cants.equipped) == "string" then
					cants.equipped = Migrations.LEGACY_CANT_IDS[cants.equipped] or cants.equipped
				end
			end
			raw.schemaVersion = 3
			return raw
		end,
	},
	-- v3 -> v4: Waymark I is `waymark.branded` (approved 2026-11-16). The
	-- rename reaches Waymark progress and every receipt that names the
	-- Waymark as its source: permanent and seasonal receipts, and pending
	-- intents (key, grantId and sourceId). Archive records are not part of
	-- the profile; they are translated when read (LegacyIds.receipt).
	{
		from = 3,
		to = 4,
		apply = function(raw: Raw): Raw
			if type(raw.waymarks) == "table" then
				raw.waymarks = renameKeys(raw.waymarks, LegacyIds.WAYMARK)
			end
			local receipts = raw.receipts
			if type(receipts) == "table" then
				if type(receipts.permanent) == "table" then
					receipts.permanent = renameReceiptKeys(receipts.permanent)
				end
				if type(receipts.seasonal) == "table" then
					receipts.seasonal = renameReceiptKeys(receipts.seasonal)
				end
				if type(receipts.pending) == "table" then
					local pending = renameReceiptKeys(receipts.pending)
					for _, intent in pending do
						if type(intent) == "table" then
							if type(intent.grantId) == "string" then
								intent.grantId = LegacyIds.receipt(intent.grantId)
							end
							if type(intent.sourceId) == "string" then
								intent.sourceId = LegacyIds.WAYMARK[intent.sourceId]
									or intent.sourceId
							end
						end
					end
					receipts.pending = pending
				end
			end
			raw.schemaVersion = 4
			return raw
		end,
	},
} :: { Step })

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
