--!strict
-- Applying a reward definition to a profile (BM-039).
--
-- All-or-nothing: every currency, item, instance and unlock in the
-- definition is applied to a working copy; if any single part fails
-- (cap, capacity, unknown content) the whole grant fails and the original
-- profile is returned untouched. Receipts are written by the caller in the
-- same mutation (Receipts.luau), so a receipt never exists without its
-- grant and a grant never lands without its receipt.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Balances = require(script.Parent.Balances)
local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local Inventory = require(script.Parent.Inventory)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local RewardCatalog = require(script.Parent.Parent.Content.RewardCatalog)

type PlayerProfile = Profile.PlayerProfile

export type Reason = string

export type Options = {
	-- Issues instance IDs for instanced items; must be deterministic for
	-- the grant (derived from the receipt ID) so a retry produces the same
	-- instances and the duplicate check holds.
	instanceId: (itemId: string, index: number) -> string,
}

local Grant = {}

local function copyUnlocks(profile: PlayerProfile): PlayerProfile
	local next = table.clone(profile)
	next.cants = table.clone(profile.cants)
	next.cants.unlocked = table.clone(profile.cants.unlocked)
	next.cants.verses = table.clone(profile.cants.verses)
	next.waymarks = table.clone(profile.waymarks)
	return next
end

function Grant.apply(
	profile: PlayerProfile,
	definition: RewardCatalog.Definition,
	options: Options
): (PlayerProfile?, Reason?)
	local working: PlayerProfile = profile
	local grants = definition.grants

	if grants.currencies ~= nil then
		local currencies = {}
		for currency in grants.currencies do
			table.insert(currencies, currency)
		end
		table.sort(currencies)
		for _, currency in currencies do
			local next, reason = Balances.add(working, currency, grants.currencies[currency])
			if next == nil then
				return nil, "currency " .. currency .. ": " .. tostring(reason)
			end
			working = next
		end
	end

	if grants.items ~= nil then
		for _, item in grants.items do
			local next, reason = Inventory.addStackable(working, item.itemId, item.quantity)
			if next == nil then
				return nil, "item " .. item.itemId .. ": " .. tostring(reason)
			end
			working = next
		end
	end

	if grants.instances ~= nil then
		for index, itemId in grants.instances do
			local instanceId = options.instanceId(itemId, index)
			if Inventory.findInstance(working, instanceId) ~= nil then
				-- Already granted by an earlier attempt of this same grant.
				continue
			end
			local next, reason = Inventory.addInstance(working, itemId, instanceId)
			if next == nil then
				return nil, "instance " .. itemId .. ": " .. tostring(reason)
			end
			working = next
		end
	end

	if grants.cants ~= nil or grants.verses ~= nil or grants.waymarks ~= nil then
		working = copyUnlocks(working)
		local cantIds: { string } = grants.cants or {}
		for _, cantId in cantIds do
			if Canon:getCant(cantId) == nil then
				return nil, "unknown cant " .. cantId
			end
			working.cants.unlocked[cantId] = true
			if working.cants.verses[cantId] == nil then
				working.cants.verses[cantId] = {}
			end
		end
		local verseIds: { string } = grants.verses or {}
		for _, verseId in verseIds do
			local verse = Canon:getVerse(verseId)
			if verse == nil then
				return nil, "unknown verse " .. verseId
			end
			if working.cants.unlocked[verse.cantId] ~= true then
				return nil, "verse " .. verseId .. " requires cant " .. verse.cantId
			end
			local list = table.clone(working.cants.verses[verse.cantId] or {})
			list[verseId] = true
			working.cants.verses[verse.cantId] = list
		end
		local waymarkIds: { string } = grants.waymarks or {}
		for _, waymarkId in waymarkIds do
			local waymark = Canon:getWaymark(waymarkId)
			if waymark == nil then
				return nil, "unknown waymark " .. waymarkId
			end
			local existing = working.waymarks[waymarkId]
			working.waymarks[waymarkId] = {
				activated = true,
				rank = math.max(waymark.rank, if existing ~= nil then existing.rank else 0),
			}
		end
	end

	return working, nil
end

return table.freeze(Grant)
