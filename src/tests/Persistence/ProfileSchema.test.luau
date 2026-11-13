--!strict
-- BM-021 / BM-022: valid and invalid profile fixtures, every bound and
-- overflow, unknown IDs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("ProfileSchema")
local P = Limits.PROFILE

local function set(target: any, key: any, value: any)
	target[key] = value
end

-- A rich but valid profile using only canonical IDs that exist today.
local function rich(): any
	local profile: any = ProfileSchema.default()
	profile.revision = 12
	profile.lease = { sessionId = "sess-1", jobId = "job-1", fence = 3, expiresAt = 1_700_000_090 }
	profile.cants.unlocked["cant-nearness"] = true
	profile.cants.equipped = "cant-nearness"
	profile.cants.verses["cant-nearness"] = {}
	profile.waymarks["waymark-i"] = { activated = true, rank = 1 }
	profile.inventory = {
		{ itemId = "item-test-ore", quantity = 5 },
		{ itemId = "item-test-blade", quantity = 1, instanceId = "inst-1" },
	}
	profile.balances = { ["currency-test"] = 120 }
	profile.receipts.permanent["waymark-i:first"] = true
	profile.receipts.seasonal["descent-run-1:slot-1"] = 1
	profile.receipts.pending["grant-1"] = {
		grantId = "grant-1",
		sourceId = "quest-complete:quest-x",
		createdAt = 1_700_000_000,
		rewardCatalogId = "reward-test",
	}
	return profile
end

local function expectClean(profile: unknown)
	local errors = ProfileSchema.validate(profile)
	Assert.count(errors, 0, "expected a valid profile, got:\n  " .. table.concat(errors, "\n  "))
end

local function expectError(profile: unknown, needle: string)
	local errors = ProfileSchema.validate(profile)
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

suite:case("default and rich profiles are valid", function()
	expectClean(ProfileSchema.default())
	expectClean(rich())
	Assert.isTrue(ProfileSchema.isValid(rich()), "isValid")
	Assert.isFalse(ProfileSchema.isValid(nil), "nil is not a profile")
end)

suite:case("top-level shape and version", function()
	expectError("x", "profile: must be a table")
	local p = rich()
	set(p, "extra", 1)
	expectError(p, "unexpected field extra")
	p = rich()
	p.schemaVersion = 99
	expectError(p, "schemaVersion: expected 1")
	p = rich()
	p.revision = -1
	expectError(p, "revision: must be a nonnegative integer")
	p = rich()
	p.chapterId = "chapter-unknown"
	expectError(p, "unknown chapter id")
	p = rich()
	p.quests = nil
	expectError(p, "quests: must be a table")
end)

suite:case("lease fields are checked when present", function()
	local p = rich()
	p.lease.fence = -1
	expectError(p, "fence must be a nonnegative integer")
	p = rich()
	p.lease.sessionId = "has space"
	expectError(p, "sessionId is not a valid opaque id")
	p = rich()
	set(p.lease, "owner", "x")
	expectError(p, "lease: unexpected field owner")
	p = rich()
	p.lease = nil
	expectClean(p)
end)

suite:case("unknown canonical ids are rejected everywhere", function()
	local p = rich()
	p.cants.unlocked["cant-invented"] = true
	expectError(p, "unknown cant id cant-invented")
	p = rich()
	p.waymarks["waymark-ix"] = { activated = false, rank = 0 }
	expectError(p, "unknown waymark id waymark-ix")
	p = rich()
	p.quests.completed["quest-nope"] = true
	expectError(p, "unknown quest id quest-nope")
	p = rich()
	p.burdens.discovered["burden-nope"] = true
	expectError(p, "unknown burden id burden-nope")
	p = rich()
	p.cants.verses["cant-nearness"]["verse-nope"] = true
	expectError(p, "unknown verse id verse-nope")
	p = rich()
	p.descents.bestClears["descent-nope"] = 1
	expectError(p, "unknown descent id descent-nope")
end)

suite:case("cant consistency", function()
	local p = rich()
	p.cants.equipped = "cant-nearness"
	p.cants.unlocked = {}
	expectError(p, "equipped cant is not unlocked")
	p = rich()
	p.cants.equipped = "waymark-i"
	expectError(p, "cants.equipped: unknown cant id")
	p = rich()
	p.cants.unlocked["cant-nearness"] = false
	expectError(p, "must be true")
end)

suite:case("burden rules", function()
	local p = rich()
	p.burdens.dissonance = -1
	expectError(p, "dissonance: must be a number")
	p = rich()
	p.burdens.dissonance = 0 / 0
	expectError(p, "dissonance: must be a number")
	p = rich()
	p.burdens.active = { "burden-nope" }
	expectError(p, "unknown burden id")
	p = rich()
	p.burdens.active = { a = 1 }
	expectError(p, "burdens.active: must be an array")
end)

suite:case("inventory invariants", function()
	local p = rich()
	p.inventory[1].quantity = 0
	expectError(p, "quantity must be a positive integer")
	p = rich()
	p.inventory[1].quantity = 2.5
	expectError(p, "quantity must be a positive integer")
	p = rich()
	p.inventory[1].quantity = -3
	expectError(p, "quantity must be a positive integer")
	p = rich()
	table.insert(p.inventory, { itemId = "item-test-blade", quantity = 1, instanceId = "inst-1" })
	expectError(p, "duplicate instanceId inst-1")
	p = rich()
	p.inventory[2].quantity = 2
	expectError(p, "an item instance has quantity 1")
	p = rich()
	p.inventory[1].itemId = "Not An Id"
	expectError(p, "itemId is not a canonical id")
	p = rich()
	set(p.inventory[1], "durability", 3)
	expectError(p, "inventory[1]: unexpected field durability")
	p = rich()
	p.inventory = { x = 1 }
	expectError(p, "inventory: must be an array")
end)

suite:case("balances must be nonnegative integers under canonical ids", function()
	local p = rich()
	p.balances["currency-test"] = -1
	expectError(p, "must be a nonnegative integer")
	p = rich()
	p.balances["currency-test"] = 1.5
	expectError(p, "must be a nonnegative integer")
	p = rich()
	p.balances["currency-test"] = math.huge
	expectError(p, "must be a nonnegative integer")
	p = rich()
	p.balances["Gold!"] = 1
	expectError(p, "is not canonical")
end)

suite:case("receipt rules", function()
	local p = rich()
	p.receipts.permanent["r"] = false
	expectError(p, "receipts.permanent: must map receipt ids to true")
	p = rich()
	p.receipts.seasonal["r"] = "season-1"
	expectError(p, "must map receipt ids to season numbers")
	p = rich()
	p.receipts.pending["grant-1"].grantId = "other"
	expectError(p, "grantId does not match its key")
	p = rich()
	p.receipts.pending["grant-1"].rewardCatalogId = "Reward Test"
	expectError(p, "rewardCatalogId is not a canonical id")
	p = rich()
	set(p.receipts, "archived", {})
	expectError(p, "receipts: unexpected field archived")
end)

suite:case("quest progress rules", function()
	-- No canonical quests exist yet, so active quests can only be tested
	-- for the unknown-id path and shape checks on completed entries.
	local p = rich()
	p.quests.active["quest-x"] = {
		questId = "quest-x",
		nodeId = "n1",
		status = "Active",
		revision = 1,
		flags = {},
		choices = {},
	}
	expectError(p, "quests.active: unknown quest id quest-x")
	p = rich()
	set(p.quests, "abandoned", {})
	expectError(p, "quests: unexpected field abandoned")
end)

suite:case("every count bound is enforced at max+1 and allowed at max", function()
	-- Bounds that can be exercised with the IDs available today.
	local function fill(n: number, make: (i: number) -> (), check: () -> ())
		for i = 1, n do
			make(i)
		end
		check()
	end

	local p = rich()
	p.receipts.permanent = {}
	fill(P.MAX_PERMANENT_RECEIPTS, function(i)
		p.receipts.permanent["r" .. i] = true
	end, function()
		expectClean(p)
	end)
	p.receipts.permanent["overflow"] = true
	expectError(p, "receipts.permanent: more than " .. P.MAX_PERMANENT_RECEIPTS)

	p = rich()
	p.receipts.seasonal = {}
	fill(P.MAX_SEASONAL_RECEIPTS, function(i)
		p.receipts.seasonal["s" .. i] = 1
	end, function()
		expectClean(p)
	end)
	p.receipts.seasonal["overflow"] = 1
	expectError(p, "receipts.seasonal: more than " .. P.MAX_SEASONAL_RECEIPTS)

	p = rich()
	p.receipts.pending = {}
	fill(P.MAX_PENDING_INTENTS, function(i)
		p.receipts.pending["g" .. i] = {
			grantId = "g" .. i,
			sourceId = "src",
			createdAt = 1,
			rewardCatalogId = "reward-test",
		}
	end, function()
		expectClean(p)
	end)
	p.receipts.pending["overflow"] =
		{ grantId = "overflow", sourceId = "src", createdAt = 1, rewardCatalogId = "reward-test" }
	expectError(p, "receipts.pending: more than " .. P.MAX_PENDING_INTENTS)

	p = rich()
	p.inventory = {}
	fill(P.MAX_INVENTORY_STACKS, function(i)
		table.insert(p.inventory, { itemId = "item-test", quantity = i })
	end, function()
		expectClean(p)
	end)
	table.insert(p.inventory, { itemId = "item-test", quantity = 1 })
	expectError(p, "inventory: more than " .. P.MAX_INVENTORY_STACKS)

	p = rich()
	p.balances = {}
	fill(P.MAX_BALANCE_TYPES, function(i)
		p.balances["currency-" .. i] = i
	end, function()
		expectClean(p)
	end)
	p.balances["currency-overflow"] = 1
	expectError(p, "balances: more than " .. P.MAX_BALANCE_TYPES)
end)

return suite:cases()
