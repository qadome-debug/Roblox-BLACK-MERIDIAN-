--!strict
-- BM-035: receipt collisions, invalid sources, arbitrary reward
-- definitions.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local RewardCatalog = require(ServerScriptService.Server.Content.RewardCatalog)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("RewardCatalog")

local function good(): { RewardCatalog.Definition }
	return {
		{
			id = "reward-test-gold",
			kind = "repeatable",
			sources = { "descent", "boss" },
			grants = { currencies = { ["currency-test"] = 50 } },
		},
		{
			id = "reward-test-nearness",
			kind = "permanent",
			sources = { "quest" },
			grants = {
				cants = { "cant-nearness" },
				items = { { itemId = "item-test", quantity = 2 } },
			},
		},
	}
end

local function expectError(defs: unknown, needle: string)
	local errors = RewardCatalog.validate(defs)
	for _, err in errors do
		if string.find(err, needle, 1, true) then
			return
		end
	end
	error(
		string.format(
			"expected an error containing %q, got:\n  %s",
			needle,
			table.concat(errors, "\n  ")
		)
	)
end

suite:case("a valid catalog builds, freezes and looks up", function()
	local catalog = RewardCatalog.build(good())
	Assert.deepEqual(catalog:ids(), { "reward-test-gold", "reward-test-nearness" }, "ids sorted")
	local def = catalog:get("reward-test-gold") :: RewardCatalog.Definition
	Assert.equal(def.kind, "repeatable", "lookup")
	Assert.isTrue(table.isfrozen(def :: any) and table.isfrozen(def.grants :: any), "frozen")
	Assert.isNil(catalog:get("reward-made-up"), "unknown")
	Assert.count(
		RewardCatalog.production():ids(),
		0,
		"production catalog is empty until content lands"
	)
end)

suite:case("arbitrary and malformed definitions are rejected", function()
	expectError("x", "must be a table")
	local defs: any = good()
	defs[1].id = "gold"
	expectError(defs, "starting with 'reward-'")
	defs = good()
	defs[2].id = "reward-test-gold"
	expectError(defs, "duplicate id")
	defs = good()
	defs[1].kind = "forever"
	expectError(defs, "kind must be")
	defs = good()
	defs[1].sources = {}
	expectError(defs, "non-empty array")
	defs = good()
	defs[1].sources = { "admin" }
	expectError(defs, "unknown source kind")
	defs = good()
	defs[1].grants = {}
	expectError(defs, "grants nothing")
	defs = good()
	defs[1].grants.currencies["currency-test"] = 0
	expectError(defs, "currency amount must be an integer")
	defs = good()
	defs[1].grants.currencies["currency-test"] = 100001
	expectError(defs, "currency amount must be an integer")
	defs = good()
	defs[1].grants.currencies["Gold"] = 1
	expectError(defs, "bad currency id")
	defs = good()
	defs[2].grants.items[1].quantity = 1000
	expectError(defs, "item quantity must be an integer")
	defs = good()
	defs[2].grants.cants = { "cant-made-up" }
	expectError(defs, "unknown cant")
	defs = good()
	defs[2].grants.waymarks = { "cant-nearness" }
	expectError(defs, "unknown waymark")
	defs = good()
	defs[1].grants.robux = 5
	expectError(defs, "unknown grant field")
	defs = good()
	defs[1].secret = true
	expectError(defs, "unknown field")
	Assert.throws(function()
		RewardCatalog.build(defs)
	end, "invalid definitions")
end)

suite:case("receipt ids are deterministic, distinct and bounded", function()
	local a = RewardCatalog.permanentReceiptId("waymark", "waymark-i", "reward-test-nearness")
	local b = RewardCatalog.permanentReceiptId("waymark", "waymark-i", "reward-test-nearness")
	Assert.equal(a, b, "same inputs, same id")
	Assert.equal(a, "p:waymark:waymark-i:reward-test-nearness", "format")
	Assert.notEqual(
		a,
		RewardCatalog.permanentReceiptId("quest", "waymark-i", "reward-test-nearness"),
		"source kind matters"
	)
	Assert.notEqual(
		a,
		RewardCatalog.permanentReceiptId("waymark", "waymark-ii", "reward-test-nearness"),
		"source id matters"
	)
	Assert.isNil(
		RewardCatalog.permanentReceiptId("admin" :: any, "x", "reward-x"),
		"unknown source kind"
	)
	Assert.isNil(RewardCatalog.permanentReceiptId("quest", "has space", "reward-x"), "bad segment")
	Assert.isNil(
		RewardCatalog.permanentReceiptId("quest", string.rep("q", 60), "reward-x"),
		"too long"
	)

	local s = RewardCatalog.seasonalReceiptId(3, "run-abc", 2, "reward-test-gold")
	Assert.equal(s, "s:3:run-abc:2:reward-test-gold", "seasonal format")
	Assert.notEqual(
		s,
		RewardCatalog.seasonalReceiptId(4, "run-abc", 2, "reward-test-gold"),
		"season matters"
	)
	Assert.notEqual(
		s,
		RewardCatalog.seasonalReceiptId(3, "run-abc", 1, "reward-test-gold"),
		"slot matters"
	)
	Assert.isNil(
		RewardCatalog.seasonalReceiptId(0, "run", 1, "reward-x"),
		"season must be positive"
	)
	Assert.isNil(RewardCatalog.seasonalReceiptId(1, "run", 65, "reward-x"), "slot bounded")
	Assert.isNil(RewardCatalog.seasonalReceiptId(1.5, "run", 1, "reward-x"), "integer season")
end)

return suite:cases()
