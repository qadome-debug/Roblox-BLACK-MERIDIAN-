--!strict
-- BM-015: burst, sustained flood, refill and fairness.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local RateLimiter = require(ServerScriptService.Server.Network.RateLimiter)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("RateLimiter")

local function drain(
	limiter: RateLimiter.Limiter,
	userId: number,
	class: RateLimiter.Class,
	attempts: number
): number
	local admitted = 0
	for _ = 1, attempts do
		if limiter:tryConsume(userId, class) then
			admitted += 1
		end
	end
	return admitted
end

suite:case("a burst admits exactly the class burst, then rejects", function(env)
	local limiter = RateLimiter.new({ clock = env.clock })
	local admitted = drain(limiter, 1, "choice", 50)
	Assert.equal(admitted, Limits.RATE.choice.burst, "burst size")
	local ok, retryAfter = limiter:tryConsume(1, "choice")
	Assert.isFalse(ok, "rejected after burst")
	Assert.isTrue(
		retryAfter > 0 and retryAfter <= 1 / Limits.RATE.choice.perSecond + 1e-9,
		"retry hint"
	)
end)

suite:case("tokens refill at the class rate", function(env)
	local limiter = RateLimiter.new({ clock = env.clock })
	drain(limiter, 1, "combat", 100)
	Assert.isFalse((limiter:tryConsume(1, "combat")), "empty")
	env.clock:advance(1 / Limits.RATE.combat.perSecond)
	Assert.isTrue((limiter:tryConsume(1, "combat")), "one token after one interval")
	Assert.isFalse((limiter:tryConsume(1, "combat")), "only one")
	env.clock:advance(60)
	Assert.equal(
		limiter:peek(1, "combat"),
		Limits.RATE.combat.burst,
		"never refills past the burst"
	)
end)

suite:case("a sustained flood is capped at the class rate", function(env)
	local limiter = RateLimiter.new({ clock = env.clock })
	local admitted = 0
	-- 10 seconds of 100 requests per second against the combat class.
	for _ = 1, 1000 do
		env.clock:advance(0.01)
		if limiter:tryConsume(1, "combat") then
			admitted += 1
		end
	end
	local expected = Limits.RATE.combat.burst + 10 * Limits.RATE.combat.perSecond
	Assert.isTrue(
		admitted <= expected and admitted >= expected - 2,
		"admitted " .. admitted .. " vs " .. expected
	)
end)

suite:case("the envelope budget caps all classes together", function(env)
	local limiter = RateLimiter.new({ clock = env.clock })
	local total = 0
	for _, class in { "combat", "cant", "choice", "waymark", "party", "economy", "session" } do
		total += drain(limiter, 1, class :: RateLimiter.Class, 100)
	end
	Assert.equal(total, Limits.RATE.envelope.burst, "envelope burst bounds the sum")
	local ok, retryAfter = limiter:tryConsume(1, "party")
	Assert.isFalse(ok, "envelope exhausted")
	Assert.isTrue(retryAfter > 0, "retry hint")
	Assert.isTrue(limiter:peek(1, "party") >= 1, "class tokens were not consumed by the rejection")
end)

suite:case("rejections consume nothing", function(env)
	local limiter = RateLimiter.new({ clock = env.clock })
	drain(limiter, 1, "choice", 100)
	local envelopeBefore = limiter:peek(1, "envelope")
	for _ = 1, 100 do
		limiter:tryConsume(1, "choice")
	end
	Assert.equal(
		limiter:peek(1, "envelope"),
		envelopeBefore,
		"envelope untouched by rejected calls"
	)
end)

suite:case("one player's flood never affects another player", function(env)
	local limiter = RateLimiter.new({ clock = env.clock })
	drain(limiter, 1, "combat", 10000)
	for _ = 1, 100 do
		limiter:tryConsume(1, "combat")
	end
	Assert.equal(
		drain(limiter, 2, "combat", 100),
		Limits.RATE.combat.burst,
		"player 2 has a full burst"
	)
	Assert.equal(
		limiter:peek(2, "envelope"),
		Limits.RATE.envelope.burst - Limits.RATE.combat.burst,
		"player 2 envelope"
	)
end)

suite:case("forget resets a player's buckets", function(env)
	local limiter = RateLimiter.new({ clock = env.clock })
	drain(limiter, 1, "choice", 100)
	limiter:forget(1)
	Assert.equal(limiter:peek(1, "choice"), Limits.RATE.choice.burst, "fresh buckets")
end)

return suite:cases()
