--!strict
-- BM-024: size measurement is deterministic and the soft/hard budgets
-- reject oversized mutations without touching existing data.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local ProfileSize = require(ServerScriptService.Server.Persistence.ProfileSize)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("ProfileSize")

suite:case("encoding is canonical JSON with sorted keys", function()
	Assert.equal(ProfileSize.encode({ b = 1, a = "x" }), '{"a":"x","b":1}', "sorted object")
	Assert.equal(ProfileSize.encode({ 1, 2, 3 }), "[1,2,3]", "array")
	Assert.equal(ProfileSize.encode({}), "{}", "empty table is an object")
	Assert.equal(
		ProfileSize.encode({ n = 1.5, t = true, f = false }),
		'{"f":false,"n":1.5,"t":true}',
		"scalars"
	)
	Assert.equal(ProfileSize.encode('a"b\\c\n'), '"a\\"b\\\\c\\n"', "escapes")
	Assert.equal(ProfileSize.encode({ x = { y = { 1 } } }), '{"x":{"y":[1]}}', "nested")
	Assert.equal(ProfileSize.encode(2 ^ 40), "1099511627776", "large integer stays integral")
	Assert.equal(
		ProfileSize.encode({ b = 1, a = 2 }),
		ProfileSize.encode({ a = 2, b = 1 }),
		"order independent"
	)
end)

suite:case("unencodable values are refused rather than silently dropped", function()
	Assert.throws(function()
		ProfileSize.encode({ n = 0 / 0 })
	end, "non-finite")
	Assert.throws(function()
		ProfileSize.encode({ [1] = "a", x = "b" })
	end, "keys must be strings")
	Assert.throws(function()
		ProfileSize.encode({ f = function() end })
	end, "cannot encode a function")
end)

suite:case("a default profile is tiny and classified ok", function()
	local verdict, bytes = ProfileSize.check(ProfileSchema.default())
	Assert.equal(verdict, "ok", "verdict")
	Assert.isTrue(bytes > 100 and bytes < 1024, "default profile is " .. bytes .. " bytes")
end)

suite:case("soft and hard thresholds", function()
	Assert.equal(ProfileSize.classify(ProfileSize.SOFT_BYTES), "ok", "at soft is ok")
	Assert.equal(ProfileSize.classify(ProfileSize.SOFT_BYTES + 1), "soft", "above soft")
	Assert.equal(ProfileSize.classify(ProfileSize.HARD_BYTES), "soft", "at hard is still soft")
	Assert.equal(ProfileSize.classify(ProfileSize.HARD_BYTES + 1), "hard", "above hard")
	Assert.equal(ProfileSize.SOFT_BYTES, 128 * 1024, "soft budget")
	Assert.equal(ProfileSize.HARD_BYTES, 192 * 1024, "hard budget")
end)

suite:case("a large profile crosses soft then hard, and the original is untouched", function()
	local profile: any = ProfileSchema.default()
	local filler = string.rep("x", 1000)
	local i = 0
	-- Grow the permanent receipts until the soft limit trips.
	while ProfileSize.check(profile) == "ok" do
		i += 1
		profile.receipts.permanent["r" .. i .. filler] = true
	end
	local verdict, bytes = ProfileSize.check(profile)
	Assert.equal(verdict, "soft", "soft reached first")
	Assert.isTrue(
		bytes > ProfileSize.SOFT_BYTES and bytes <= ProfileSize.HARD_BYTES,
		"between budgets"
	)

	local snapshot = ProfileSize.encode(profile)
	local candidate = table.clone(profile)
	candidate.receipts = table.clone(profile.receipts)
	candidate.receipts.permanent = table.clone(profile.receipts.permanent)
	while ProfileSize.check(candidate) ~= "hard" do
		i += 1
		candidate.receipts.permanent["r" .. i .. filler] = true
	end
	Assert.equal(ProfileSize.check(candidate), "hard", "candidate rejected")
	Assert.equal(
		ProfileSize.encode(profile),
		snapshot,
		"existing profile unchanged by the rejected candidate"
	)
end)

return suite:cases()
