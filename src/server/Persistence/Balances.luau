--!strict
-- Currency balances, caps and legal arithmetic (BM-034).
--
-- Pure functions over `profile.balances`. Amounts are nonnegative
-- integers; a balance never goes negative, never exceeds its cap, and
-- never comes from a client. Every function returns a new profile or nil
-- with a reason.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)

type PlayerProfile = Profile.PlayerProfile

export type Reason = "badCurrency" | "badAmount" | "insufficient" | "overCap" | "tooManyCurrencies"

local Balances = {}

-- Default cap per currency until the economy catalog (BM-108) sets one.
Balances.DEFAULT_CAP = 1_000_000_000
-- Single-grant ceiling; larger grants are a catalog error, not a payout.
Balances.MAX_SINGLE_AMOUNT = 100_000

local function isAmount(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and value >= 1
		and value % 1 == 0
		and value <= Balances.MAX_SINGLE_AMOUNT
end

local function copy(profile: PlayerProfile): PlayerProfile
	local next = table.clone(profile)
	next.balances = table.clone(profile.balances)
	return next
end

function Balances.get(profile: PlayerProfile, currencyId: string): number
	return profile.balances[currencyId] or 0
end

function Balances.add(
	profile: PlayerProfile,
	currencyId: string,
	amount: number,
	cap: number?
): (PlayerProfile?, Reason?)
	if not ContentRegistry.isValidId(currencyId) then
		return nil, "badCurrency"
	end
	if not isAmount(amount) then
		return nil, "badAmount"
	end
	local limit = cap or Balances.DEFAULT_CAP
	local current = profile.balances[currencyId]
	if current == nil then
		local count = 0
		for _ in profile.balances do
			count += 1
		end
		if count >= Limits.PROFILE.MAX_BALANCE_TYPES then
			return nil, "tooManyCurrencies"
		end
		current = 0
	end
	if current + amount > limit then
		return nil, "overCap"
	end
	local next = copy(profile)
	next.balances[currencyId] = current + amount
	return next, nil
end

function Balances.spend(
	profile: PlayerProfile,
	currencyId: string,
	amount: number
): (PlayerProfile?, Reason?)
	if not ContentRegistry.isValidId(currencyId) then
		return nil, "badCurrency"
	end
	if not isAmount(amount) then
		return nil, "badAmount"
	end
	local current = profile.balances[currencyId] or 0
	if current < amount then
		return nil, "insufficient"
	end
	local next = copy(profile)
	if current - amount == 0 then
		next.balances[currencyId] = nil
	else
		next.balances[currencyId] = current - amount
	end
	return next, nil
end

function Balances.canAfford(profile: PlayerProfile, costs: { [string]: number }): boolean
	for currencyId, amount in costs do
		if not isAmount(amount) or (profile.balances[currencyId] or 0) < amount then
			return false
		end
	end
	return true
end

return table.freeze(Balances)
