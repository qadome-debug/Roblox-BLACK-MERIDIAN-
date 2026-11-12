--!strict
-- Token-bucket rate limiting (BM-015).
--
-- Each player has one bucket per action class plus an overall envelope
-- bucket (Technical Plan 2.0, 3.7). A request is admitted only if both its
-- class bucket and the envelope bucket have a token; a rejected request
-- consumes nothing, so a flood cannot starve the player's legitimate
-- requests more than the budget already does, and one player's flood never
-- touches another player's buckets.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)

export type Class = "combat" | "cant" | "choice" | "waymark" | "party" | "economy" | "session"

type Bucket = { tokens: number, updatedAt: number, perSecond: number, burst: number }

export type Limiter = {
	-- Returns true and consumes one token from the class and envelope
	-- buckets, or false and the seconds until a token is available.
	tryConsume: (self: Limiter, userId: number, class: Class) -> (boolean, number),
	-- Drops a player's buckets on leave.
	forget: (self: Limiter, userId: number) -> (),
	-- Current tokens, for tests and telemetry.
	peek: (self: Limiter, userId: number, class: Class | "envelope") -> number,
}

export type Deps = { clock: Clock.Clock }

local RateLimiter = {}

local function newBucket(limit: Limits.RateLimit, now: number): Bucket
	return {
		tokens = limit.burst,
		updatedAt = now,
		perSecond = limit.perSecond,
		burst = limit.burst,
	}
end

local function refill(bucket: Bucket, now: number)
	local elapsed = now - bucket.updatedAt
	if elapsed > 0 then
		bucket.tokens = math.min(bucket.burst, bucket.tokens + elapsed * bucket.perSecond)
		bucket.updatedAt = now
	end
end

function RateLimiter.new(deps: Deps): Limiter
	local players: { [number]: { [string]: Bucket } } = {}

	local function bucketFor(userId: number, name: string): Bucket
		local buckets = players[userId]
		if buckets == nil then
			buckets = {}
			players[userId] = buckets
		end
		local bucket = buckets[name]
		if bucket == nil then
			local limit = (Limits.RATE :: any)[name] :: Limits.RateLimit
			bucket = newBucket(limit, deps.clock:now())
			buckets[name] = bucket
		end
		refill(bucket, deps.clock:now())
		return bucket
	end

	local limiter = {} :: Limiter

	function limiter:tryConsume(userId: number, class: Class): (boolean, number)
		local classBucket = bucketFor(userId, class)
		local envelopeBucket = bucketFor(userId, "envelope")
		if classBucket.tokens >= 1 and envelopeBucket.tokens >= 1 then
			classBucket.tokens -= 1
			envelopeBucket.tokens -= 1
			return true, 0
		end
		local waitClass = if classBucket.tokens >= 1
			then 0
			else (1 - classBucket.tokens) / classBucket.perSecond
		local waitEnvelope = if envelopeBucket.tokens >= 1
			then 0
			else (1 - envelopeBucket.tokens) / envelopeBucket.perSecond
		return false, math.max(waitClass, waitEnvelope)
	end

	function limiter:forget(userId: number)
		players[userId] = nil
	end

	function limiter:peek(userId: number, class: Class | "envelope"): number
		return bucketFor(userId, class).tokens
	end

	return table.freeze(limiter)
end

return table.freeze(RateLimiter)
