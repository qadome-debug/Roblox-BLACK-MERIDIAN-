--!strict
-- BM-034: overflow, insufficient funds, caps, and no client-authored
-- amounts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Balances = require(ServerScriptService.Server.Persistence.Balances)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Balances")

suite:case("add and spend keep integers and never go negative", function()
	local p = ProfileSchema.default()
	local a = Balances.add(p, "currency-gold", 100) :: any
	Assert.equal(Balances.get(a, "currency-gold"), 100, "added")
	Assert.equal(Balances.get(p, "currency-gold"), 0, "input untouched")
	local b = Balances.spend(a, "currency-gold", 40) :: any
	Assert.equal(Balances.get(b, "currency-gold"), 60, "spent")
	local _, reason = Balances.spend(b, "currency-gold", 61)
	Assert.equal(reason, "insufficient", "cannot overspend")
	local zero = Balances.spend(b, "currency-gold", 60) :: any
	Assert.isNil(zero.balances["currency-gold"], "zero balances are removed")
	Assert.count(ProfileSchema.validate(zero), 0, "valid")
end)

suite:case("malformed amounts and currencies are refused", function()
	local p = ProfileSchema.default()
	for _, bad in { 0, -1, 1.5, 0 / 0, math.huge, Balances.MAX_SINGLE_AMOUNT + 1 } do
		local _, reason = Balances.add(p, "currency-gold", bad)
		Assert.equal(reason, "badAmount", "add " .. tostring(bad))
		local _, reason2 = Balances.spend(p, "currency-gold", bad)
		Assert.equal(reason2, "badAmount", "spend " .. tostring(bad))
	end
	local _, r = Balances.add(p, "Gold!", 1)
	Assert.equal(r, "badCurrency", "bad currency id")
	local _, r2 = Balances.spend(p, "", 1)
	Assert.equal(r2, "badCurrency", "empty currency id")
end)

suite:case("caps are enforced per currency", function()
	local p = Balances.add(ProfileSchema.default(), "currency-gold", 90, 100) :: any
	local _, reason = Balances.add(p, "currency-gold", 11, 100)
	Assert.equal(reason, "overCap", "over the cap")
	Assert.notNil(Balances.add(p, "currency-gold", 10, 100), "exactly the cap is fine")
	-- Default cap applies when none is given.
	local big: any = ProfileSchema.default()
	big.balances["currency-gold"] = Balances.DEFAULT_CAP
	local _, r2 = Balances.add(big, "currency-gold", 1)
	Assert.equal(r2, "overCap", "default cap")
end)

suite:case("the number of currencies is bounded", function()
	local p: any = ProfileSchema.default()
	for i = 1, Limits.PROFILE.MAX_BALANCE_TYPES do
		p = Balances.add(p, "currency-" .. i, 1)
	end
	local _, reason = Balances.add(p, "currency-new", 1)
	Assert.equal(reason, "tooManyCurrencies", "refused")
	Assert.notNil(Balances.add(p, "currency-1", 1), "existing currency still works")
	Assert.count(ProfileSchema.validate(p), 0, "valid at the bound")
end)

suite:case("canAfford checks every cost without mutating", function()
	local p = Balances.add(
		Balances.add(ProfileSchema.default(), "currency-gold", 10) :: any,
		"currency-gem",
		2
	) :: any
	Assert.isTrue(Balances.canAfford(p, { ["currency-gold"] = 10, ["currency-gem"] = 2 }), "exact")
	Assert.isFalse(Balances.canAfford(p, { ["currency-gold"] = 11 }), "short")
	Assert.isFalse(Balances.canAfford(p, { ["currency-gold"] = 0 }), "zero cost is malformed")
	Assert.isFalse(Balances.canAfford(p, { ["currency-missing"] = 1 }), "unknown currency")
	Assert.equal(Balances.get(p, "currency-gold"), 10, "unchanged")
end)

return suite:cases()
