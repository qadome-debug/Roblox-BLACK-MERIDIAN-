--!strict
-- BM-033: capacity, malformed stacks, duplicate instances, and invariants
-- after a save/load round trip.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Inventory = require(ServerScriptService.Server.Persistence.Inventory)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local ProfileSize = require(ServerScriptService.Server.Persistence.ProfileSize)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Inventory")

local function fresh()
	return ProfileSchema.default()
end

suite:case("stackables merge and instances stay separate", function()
	local p = fresh()
	local a = Inventory.addStackable(p, "item-ore", 3) :: any
	local b = Inventory.addStackable(a, "item-ore", 4) :: any
	Assert.count(b.inventory, 1, "one stack")
	Assert.equal(b.inventory[1].quantity, 7, "merged")
	Assert.count(p.inventory, 0, "input untouched")
	local c = Inventory.addInstance(b, "item-blade", "inst-1") :: any
	local d = Inventory.addInstance(c, "item-blade", "inst-2") :: any
	Assert.count(d.inventory, 3, "two instances plus the stack")
	Assert.equal(Inventory.count(d, "item-blade"), 2, "count sums instances")
	Assert.notNil(Inventory.findInstance(d, "inst-2"), "find instance")
	Assert.count(Inventory.check(d), 0, "invariants hold")
	Assert.count(ProfileSchema.validate(d), 0, "schema agrees")
end)

suite:case("malformed inputs are refused with a reason", function()
	local p = fresh()
	local _, r1 = Inventory.addStackable(p, "Not Valid", 1)
	Assert.equal(r1, "badItem", "bad item")
	local _, r2 = Inventory.addStackable(p, "item-ore", 0)
	Assert.equal(r2, "badQuantity", "zero")
	local _, r3 = Inventory.addStackable(p, "item-ore", 1.5)
	Assert.equal(r3, "badQuantity", "fraction")
	local _, r4 = Inventory.addStackable(p, "item-ore", -2)
	Assert.equal(r4, "badQuantity", "negative")
	local _, r5 = Inventory.addStackable(p, "item-ore", Inventory.MAX_STACK + 1)
	Assert.equal(r5, "badQuantity", "over max stack")
	local _, r6 = Inventory.addInstance(p, "item-blade", "bad id!")
	Assert.equal(r6, "badInstance", "bad instance id")
	local withBlade = Inventory.addInstance(p, "item-blade", "inst-1") :: any
	local _, r7 = Inventory.addInstance(withBlade, "item-blade", "inst-1")
	Assert.equal(r7, "duplicateInstance", "duplicate instance")
end)

suite:case("stack and capacity limits", function()
	local p = fresh()
	local near = Inventory.addStackable(p, "item-ore", Inventory.MAX_STACK - 1) :: any
	Assert.notNil(Inventory.addStackable(near, "item-ore", 1), "exactly max ok")
	local _, reason = Inventory.addStackable(near, "item-ore", 2)
	Assert.equal(reason, "stackLimit", "over the stack limit")

	local full: any = fresh()
	for i = 1, Inventory.MAX_STACKS do
		full = Inventory.addStackable(full, "item-" .. i, 1)
	end
	Assert.count(full.inventory, Inventory.MAX_STACKS, "at capacity")
	local _, r2 = Inventory.addStackable(full, "item-new", 1)
	Assert.equal(r2, "full", "new stack refused")
	local _, r3 = Inventory.addInstance(full, "item-blade", "inst-x")
	Assert.equal(r3, "full", "new instance refused")
	Assert.notNil(Inventory.addStackable(full, "item-1", 5), "existing stack still grows")
	Assert.count(ProfileSchema.validate(full), 0, "full inventory is still valid")
end)

suite:case("removal is exact and never goes negative", function()
	local p = Inventory.addStackable(fresh(), "item-ore", 5) :: any
	local _, r1 = Inventory.removeStackable(p, "item-ore", 6)
	Assert.equal(r1, "missing", "not enough")
	local less = Inventory.removeStackable(p, "item-ore", 2) :: any
	Assert.equal(Inventory.count(less, "item-ore"), 3, "subtracted")
	local none = Inventory.removeStackable(less, "item-ore", 3) :: any
	Assert.count(none.inventory, 0, "empty stack removed")
	local _, r2 = Inventory.removeStackable(none, "item-ore", 1)
	Assert.equal(r2, "missing", "nothing left")
	local withBlade = Inventory.addInstance(none, "item-blade", "inst-1") :: any
	local _, r3 = Inventory.removeInstance(withBlade, "inst-9")
	Assert.equal(r3, "missing", "unknown instance")
	local gone = Inventory.removeInstance(withBlade, "inst-1") :: any
	Assert.isNil(Inventory.findInstance(gone, "inst-1"), "instance removed")
end)

suite:case("invariants hold after an encode/decode round trip", function()
	local p: any = fresh()
	p = Inventory.addStackable(p, "item-ore", 12)
	p = Inventory.addInstance(p, "item-blade", "inst-1")
	p = Inventory.addStackable(p, "item-herb", 1)
	local encoded = ProfileSize.encode(p)
	-- Re-encoding a structurally equal copy is byte-identical, which is
	-- what a reload through the DataStore relies on.
	local reloaded = ProfileSchema.default() :: any
	reloaded.inventory = {
		{ itemId = "item-ore", quantity = 12 },
		{ itemId = "item-blade", quantity = 1, instanceId = "inst-1" },
		{ itemId = "item-herb", quantity = 1 },
	}
	Assert.equal(ProfileSize.encode(reloaded), encoded, "same bytes")
	Assert.count(Inventory.check(reloaded), 0, "invariants after reload")
	Assert.count(ProfileSchema.validate(reloaded), 0, "schema after reload")
end)

suite:case("check reports every broken invariant", function()
	local p: any = fresh()
	p.inventory = {
		{ itemId = "item-ore", quantity = 2 },
		{ itemId = "item-ore", quantity = 3 }, -- split stackable
		{ itemId = "item-blade", quantity = 2, instanceId = "i" }, -- instance qty
		{ itemId = "item-axe", quantity = 1, instanceId = "i" }, -- duplicate instance
		{ itemId = "BAD", quantity = 0 },
	}
	local problems = Inventory.check(p)
	local joined = table.concat(problems, "\n")
	Assert.contains(joined, "splits stackable item-ore", "split")
	Assert.contains(joined, "instance with quantity 2", "instance quantity")
	Assert.contains(joined, "duplicates instance i", "duplicate")
	Assert.contains(joined, "bad itemId", "bad id")
	Assert.contains(joined, "bad quantity", "bad quantity")
end)

return suite:cases()
