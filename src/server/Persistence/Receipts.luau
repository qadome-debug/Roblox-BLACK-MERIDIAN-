--!strict
-- Receipts, pending intents and atomic grants (BM-036, BM-037, BM-038,
-- BM-039).
--
-- Builders for SaveQueue mutations that make rewards exactly-once:
--
--   permanentGrant   writes `receipts.permanent[id] = true` and applies the
--                    grant in the same transform; a second application is
--                    a no-op. Permanent receipts are never pruned; when the
--                    catalog is full the grant fails closed (BM-047 adds
--                    the compact migration).
--   seasonalGrant    writes `receipts.seasonal[id] = season`. Grants for a
--                    closed season are refused before enqueue. When the
--                    seasonal ledger is full, receipts from seasons older
--                    than the retention window are pruned to make room;
--                    if none can be, the grant fails closed.
--   recordIntent     durably records that a grant is owed (BM-038) before
--                    the grant itself is attempted, so a crash in between
--                    leaves something to recover. Bounded; fails closed.
--   clearIntent      removes an intent that will never be fulfilled
--                    (operator action, BM-049).
--
-- Every builder's `apply` is idempotent on stored state and reports
-- `isApplied`, so uncertain writes reconcile by reading.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Grant = require(script.Parent.Grant)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileStore = require(script.Parent.ProfileStore)
local RewardCatalog = require(script.Parent.Parent.Content.RewardCatalog)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

type PlayerProfile = Profile.PlayerProfile
export type Mutation = ProfileStore.Mutation

export type SeasonPolicy = {
	currentSeason: number,
	-- Seasons older than currentSeason - retainedSeasons are closed: their
	-- grants are refused and their receipts may be pruned under pressure.
	retainedSeasons: number,
}

export type Refusal = "capacityExhausted" | "seasonClosed" | "intentLimit" | "badId"

local P = Limits.PROFILE

local Receipts = {}

local function countKeys(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function isOpaque(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= Limits.MAX_OPAQUE_ID_BYTES
		and string.match(value, "^[%w%-_:.]+$") ~= nil
end

local function copyReceipts(profile: PlayerProfile): PlayerProfile
	local next = table.clone(profile)
	next.receipts = table.clone(profile.receipts)
	next.receipts.permanent = table.clone(profile.receipts.permanent)
	next.receipts.seasonal = table.clone(profile.receipts.seasonal)
	next.receipts.pending = table.clone(profile.receipts.pending)
	return next
end

-- Deterministic instance IDs for instanced grants, derived from the
-- receipt so retries reproduce them.
local function instanceIssuer(receiptId: string): (itemId: string, index: number) -> string
	return function(itemId: string, index: number): string
		local seed = Rng.hashString(receiptId .. "|" .. itemId .. "|" .. index)
		return string.format("i-%08x-%d", seed, index)
	end
end

function Receipts.isSeasonOpen(policy: SeasonPolicy, season: number): boolean
	return season <= policy.currentSeason and season > policy.currentSeason - policy.retainedSeasons
end

-- One-time grant. Returns the mutation, or nil with a refusal when it can
-- be decided up front.
-- `archived` is the set of receipts moved to archive records for this
-- profile (BM-047); a receipt found there is already paid.
function Receipts.permanentGrant(
	receiptId: string,
	definition: RewardCatalog.Definition,
	archived: { [string]: boolean }?
): (Mutation?, Refusal?)
	if not isOpaque(receiptId) then
		return nil, "badId"
	end
	local issue = instanceIssuer(receiptId)
	return {
		id = receiptId,
		irreversible = true,
		apply = function(profile: PlayerProfile): PlayerProfile?
			if
				profile.receipts.permanent[receiptId] or (archived ~= nil and archived[receiptId])
			then
				return nil
			end
			if countKeys(profile.receipts.permanent) >= P.MAX_PERMANENT_RECEIPTS then
				-- Fail closed: no grant, no receipt, nothing pruned.
				error("permanent receipt capacity exhausted")
			end
			local granted, reason = Grant.apply(profile, definition, { instanceId = issue })
			if granted == nil then
				error("grant failed: " .. tostring(reason))
			end
			local next = copyReceipts(granted)
			next.receipts.permanent[receiptId] = true
			next.receipts.pending[receiptId] = nil
			return next
		end,
		isApplied = function(profile: PlayerProfile): boolean
			return profile.receipts.permanent[receiptId] == true
				or (archived ~= nil and archived[receiptId] == true)
		end,
	},
		nil
end

-- Repeatable grant inside a season.
function Receipts.seasonalGrant(
	receiptId: string,
	season: number,
	definition: RewardCatalog.Definition,
	policy: SeasonPolicy
): (Mutation?, Refusal?)
	if not isOpaque(receiptId) then
		return nil, "badId"
	end
	if not Receipts.isSeasonOpen(policy, season) then
		return nil, "seasonClosed"
	end
	local issue = instanceIssuer(receiptId)
	return {
		id = receiptId,
		irreversible = true,
		apply = function(profile: PlayerProfile): PlayerProfile?
			if profile.receipts.seasonal[receiptId] ~= nil then
				return nil
			end
			local next = copyReceipts(profile)
			if countKeys(next.receipts.seasonal) >= P.MAX_SEASONAL_RECEIPTS then
				-- Make room only from closed seasons.
				for id, s in profile.receipts.seasonal do
					if not Receipts.isSeasonOpen(policy, s) then
						next.receipts.seasonal[id] = nil
					end
				end
				if countKeys(next.receipts.seasonal) >= P.MAX_SEASONAL_RECEIPTS then
					error("seasonal receipt capacity exhausted")
				end
			end
			local granted, reason = Grant.apply(next, definition, { instanceId = issue })
			if granted == nil then
				error("grant failed: " .. tostring(reason))
			end
			local final = copyReceipts(granted)
			final.receipts.seasonal[receiptId] = season
			final.receipts.pending[receiptId] = nil
			return final
		end,
		isApplied = function(profile: PlayerProfile): boolean
			return profile.receipts.seasonal[receiptId] ~= nil
		end,
	},
		nil
end

-- Records that a grant is owed. The grantId doubles as the receipt ID the
-- fulfilling grant will use.
function Receipts.recordIntent(
	grantId: string,
	sourceId: string,
	rewardCatalogId: string,
	createdAt: number
): (Mutation?, Refusal?)
	if not isOpaque(grantId) or not isOpaque(sourceId) then
		return nil, "badId"
	end
	return {
		id = "intent:" .. grantId,
		irreversible = true,
		apply = function(profile: PlayerProfile): PlayerProfile?
			if profile.receipts.pending[grantId] ~= nil then
				return nil
			end
			if profile.receipts.permanent[grantId] or profile.receipts.seasonal[grantId] ~= nil then
				-- Already fulfilled; nothing is owed.
				return nil
			end
			if countKeys(profile.receipts.pending) >= P.MAX_PENDING_INTENTS then
				error("pending intent limit reached")
			end
			local next = copyReceipts(profile)
			next.receipts.pending[grantId] = {
				grantId = grantId,
				sourceId = sourceId,
				createdAt = createdAt,
				rewardCatalogId = rewardCatalogId,
			}
			return next
		end,
		isApplied = function(profile: PlayerProfile): boolean
			return profile.receipts.pending[grantId] ~= nil
				or profile.receipts.permanent[grantId] == true
				or profile.receipts.seasonal[grantId] ~= nil
		end,
	},
		nil
end

function Receipts.clearIntent(grantId: string): Mutation
	return {
		id = "clear-intent:" .. grantId,
		apply = function(profile: PlayerProfile): PlayerProfile?
			if profile.receipts.pending[grantId] == nil then
				return nil
			end
			local next = copyReceipts(profile)
			next.receipts.pending[grantId] = nil
			return next
		end,
		isApplied = function(profile: PlayerProfile): boolean
			return profile.receipts.pending[grantId] == nil
		end,
	}
end

-- Intents older than `maxAgeSeconds` that still have no receipt; these are
-- what the reconciliation worker (BM-046) retries or escalates.
function Receipts.stalePending(
	profile: PlayerProfile,
	now: number,
	maxAgeSeconds: number
): { Profile.RewardIntent }
	local out = {}
	for _, intent in profile.receipts.pending do
		if now - intent.createdAt >= maxAgeSeconds then
			table.insert(out, intent)
		end
	end
	table.sort(out, function(a, b)
		return a.createdAt < b.createdAt
	end)
	return out
end

return table.freeze(Receipts)
