--!strict
-- Non-destructive profile repair (BM-032).
--
-- When a loaded profile fails validation, the loader quarantines it (the
-- player gets a read-only session and the record is left untouched).
-- `Repair.attempt` is the conservative, auditable step an operator or the
-- recovery workflow (BM-049) may run afterwards. It only ever:
--   * fills in a missing container with its empty default,
--   * resets the lease (ownership metadata, never progression),
--   * coerces `chapterId` to "" when it names an unknown chapter,
-- and returns a report of every change. It never removes a receipt, a
-- quest record, a balance, an inventory stack, an unlock or an unknown
-- ID: anything it cannot fix stays, and the profile stays quarantined.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local Migrations = require(script.Parent.Migrations)
local ProfileSchema = require(script.Parent.ProfileSchema)

export type Report = {
	-- True when the repaired copy validates.
	repaired: boolean,
	changes: { string },
	remaining: { string },
	profile: any?,
}

local Repair = {}

local CONTAINERS: { { path: { string }, default: () -> any } } = {
	{
		path = { "quests" },
		default = function()
			return { active = {}, completed = {} }
		end,
	},
	{
		path = { "quests", "active" },
		default = function()
			return {}
		end,
	},
	{
		path = { "quests", "completed" },
		default = function()
			return {}
		end,
	},
	{
		path = { "cants" },
		default = function()
			return { unlocked = {}, verses = {} }
		end,
	},
	{
		path = { "cants", "unlocked" },
		default = function()
			return {}
		end,
	},
	{
		path = { "cants", "verses" },
		default = function()
			return {}
		end,
	},
	{
		path = { "burdens" },
		default = function()
			return { discovered = {}, active = {}, dissonance = 0 }
		end,
	},
	{
		path = { "burdens", "discovered" },
		default = function()
			return {}
		end,
	},
	{
		path = { "burdens", "active" },
		default = function()
			return {}
		end,
	},
	{
		path = { "waymarks" },
		default = function()
			return {}
		end,
	},
	{
		path = { "inventory" },
		default = function()
			return {}
		end,
	},
	{
		path = { "balances" },
		default = function()
			return {}
		end,
	},
	{
		path = { "descents" },
		default = function()
			return { unlockedTiers = {}, bestClears = {} }
		end,
	},
	{
		path = { "descents", "unlockedTiers" },
		default = function()
			return {}
		end,
	},
	{
		path = { "descents", "bestClears" },
		default = function()
			return {}
		end,
	},
	{
		path = { "receipts" },
		default = function()
			return { permanent = {}, seasonal = {}, pending = {} }
		end,
	},
	{
		path = { "receipts", "permanent" },
		default = function()
			return {}
		end,
	},
	{
		path = { "receipts", "seasonal" },
		default = function()
			return {}
		end,
	},
	{
		path = { "receipts", "pending" },
		default = function()
			return {}
		end,
	},
}

-- Attempts a conservative repair of `raw` (a stored record). Works on a
-- deep copy; the input is never mutated.
function Repair.attempt(raw: unknown): Report
	if type(raw) ~= "table" then
		return {
			repaired = false,
			changes = {},
			remaining = { "record is not a table" },
			profile = nil,
		}
	end
	local profile: any = Migrations.deepCopy(raw)
	local changes: { string } = {}

	for _, container in CONTAINERS do
		local parent = profile
		for i = 1, #container.path - 1 do
			parent = parent[container.path[i]]
			if type(parent) ~= "table" then
				parent = nil
				break
			end
		end
		if parent ~= nil then
			local leaf = container.path[#container.path]
			if parent[leaf] == nil then
				parent[leaf] = container.default()
				table.insert(changes, "added missing " .. table.concat(container.path, "."))
			end
		end
	end

	if
		profile.burdens ~= nil
		and type(profile.burdens) == "table"
		and profile.burdens.dissonance == nil
	then
		profile.burdens.dissonance = 0
		table.insert(changes, "added missing burdens.dissonance")
	end

	if profile.lease ~= nil then
		local problems = ProfileSchema.validate(profile)
		for _, problem in problems do
			if string.sub(problem, 1, 6) == "lease:" then
				profile.lease = nil
				table.insert(changes, "reset invalid lease")
				break
			end
		end
	end

	if
		profile.chapterId ~= nil
		and profile.chapterId ~= ""
		and Canon:resolve("chapter", profile.chapterId) == nil
	then
		profile.chapterId = ""
		table.insert(changes, "cleared unknown chapterId " .. tostring(profile.chapterId))
	end

	if type(profile.revision) ~= "number" then
		-- Revision is bookkeeping, not progression; a missing one restarts
		-- at zero so optimistic checks still work.
		if profile.revision == nil then
			profile.revision = 0
			table.insert(changes, "added missing revision")
		end
	end

	local remaining = ProfileSchema.validate(profile)
	return {
		repaired = #remaining == 0,
		changes = changes,
		remaining = remaining,
		profile = profile,
	}
end

return table.freeze(Repair)
