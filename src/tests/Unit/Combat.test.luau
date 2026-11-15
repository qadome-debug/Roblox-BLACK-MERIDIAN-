--!strict
-- BM-052 / BM-053: deterministic derived stats with caps; resources that
-- never go negative or over cap, with regeneration delays.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Attributes = require(ServerScriptService.Server.Combat.Attributes)
local Resources = require(ServerScriptService.Server.Combat.Resources)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Combat")

suite:case("derivation is deterministic and matches the formulas", function()
	local a = Attributes.derive(Attributes.DEFAULT_BASE)
	local b = Attributes.derive({ vigor = 10, might = 10, grace = 10, will = 10 })
	Assert.deepEqual(a, b, "same base, same derived")
	Assert.equal(a.maxHealth, 200, "100 + vigor*10")
	Assert.equal(a.maxStamina, 140, "100 + grace*4")
	Assert.equal(a.maxPosture, 80, "50 + will*3")
	Assert.equal(a.staminaRegen, 20, "15 + grace*0.5")
	Assert.equal(a.postureRegen, 8, "5 + will*0.3")
	Assert.equal(a.attackPower, 30, "10 + might*2")
	Assert.equal(a.defense, 10, "might*0.5 + vigor*0.5")
	Assert.equal(a.moveSpeed, 16.5, "16 + grace*0.05")
end)

suite:case("modifiers add, then multiply, in any order, then cap", function()
	local base = Attributes.DEFAULT_BASE
	local mods: { Attributes.Modifier } = {
		{ id = "m1", stat = "attackPower", add = 10 },
		{ id = "m2", stat = "attackPower", mul = 2 },
		{ id = "m3", stat = "attackPower", add = 5 },
	}
	local x = Attributes.derive(base, mods)
	Assert.equal(x.attackPower, 90, "(30 + 10 + 5) * 2")
	local reversed = Attributes.derive(base, { mods[3], mods[2], mods[1] })
	Assert.equal(reversed.attackPower, 90, "order independent")
	local capped = Attributes.derive(
		base,
		{
			{ id = "big", stat = "maxHealth", mul = 5 },
			{ id = "big2", stat = "maxHealth", add = 1000 },
		} :: { Attributes.Modifier }
	)
	Assert.equal(capped.maxHealth, 5000, "capped at the max")
	local floored = Attributes.derive(
		base,
		{ { id = "slow", stat = "moveSpeed", mul = 0.1 } } :: { Attributes.Modifier }
	)
	Assert.equal(floored.moveSpeed, 4, "floored at the min")
	Assert.equal(Attributes.derive(base, {}).attackPower, 30, "no modifiers")
end)

suite:case("invalid bases and modifiers are rejected", function()
	Assert.count(Attributes.validateBase(Attributes.DEFAULT_BASE), 0, "default valid")
	Assert.contains(
		table.concat(Attributes.validateBase({ vigor = 0, might = 10, grace = 10, will = 10 }), ";"),
		"vigor must be",
		"below min"
	)
	Assert.contains(
		table.concat(
			Attributes.validateBase({ vigor = 100, might = 10, grace = 10, will = 10 }),
			";"
		),
		"vigor must be",
		"above max"
	)
	Assert.contains(
		table.concat(
			Attributes.validateBase({ vigor = 10.5, might = 10, grace = 10, will = 10 }),
			";"
		),
		"vigor must be",
		"fraction"
	)
	Assert.contains(
		table.concat(
			Attributes.validateBase({ vigor = 10, might = 10, grace = 10, will = 10, luck = 5 }),
			";"
		),
		"unknown attribute luck",
		"extra"
	)
	Assert.contains(
		table.concat(Attributes.validateBase("x"), ";"),
		"must be a table",
		"not a table"
	)
	Assert.throws(function()
		Attributes.derive({ vigor = 0, might = 10, grace = 10, will = 10 })
	end, "vigor must be")

	local function bad(mod: any, needle: string)
		Assert.contains(table.concat(Attributes.validateModifier(mod), ";"), needle, needle)
		Assert.throws(function()
			Attributes.derive(Attributes.DEFAULT_BASE, { mod })
		end, needle)
	end
	bad({ id = "x", stat = "luck", add = 1 }, "not a derived statistic")
	bad({ id = "x", stat = "attackPower" }, "changes nothing")
	bad({ id = "x", stat = "attackPower", add = 1001 }, "add out of range")
	bad({ id = "x", stat = "attackPower", mul = 0 }, "mul out of range")
	bad({ id = "x", stat = "attackPower", mul = 6 }, "mul out of range")
	bad({ id = "x", stat = "attackPower", add = 0 / 0 }, "add out of range")
	bad({ id = "", stat = "attackPower", add = 1 }, "modifier id")
	bad({ id = "x", stat = "attackPower", add = 1, secret = true }, "unknown modifier field")
end)

suite:case("resources start full, spend exactly, and never go negative", function()
	local derived = Attributes.derive(Attributes.DEFAULT_BASE)
	local state = Resources.new(derived)
	Assert.equal(state.stamina, 140, "full stamina")
	Assert.isTrue(Resources.spend(state, "stamina", 100, 0), "first spend")
	Assert.isFalse(Resources.spend(state, "stamina", 50, 0), "second spend in the same step fails")
	Assert.equal(state.stamina, 40, "only the first spent")
	Assert.isTrue(Resources.spend(state, "stamina", 40, 0), "exact remainder ok")
	Assert.equal(state.stamina, 0, "zero, not negative")
	Assert.isFalse(Resources.spend(state, "stamina", 0.01, 0), "nothing left")
	Assert.isFalse(Resources.spend(state, "stamina", -5, 0), "negative cost refused")
	Assert.isFalse(Resources.spend(state, "stamina", 0 / 0, 0), "NaN cost refused")
	Assert.isTrue(Resources.spend(state, "stamina", 0, 0), "zero cost always ok")
end)

suite:case("regeneration waits for the delay, then refills to the cap and no further", function()
	local derived = Attributes.derive(Attributes.DEFAULT_BASE)
	local state = Resources.new(derived)
	Resources.spend(state, "stamina", 140, 10)
	Resources.regen(state, derived, 10.5, 0.5)
	Assert.equal(state.stamina, 0, "no regen inside the delay")
	Resources.regen(state, derived, 11, 0.5)
	Assert.equal(state.stamina, 10, "20/s * 0.5s after the delay")
	for _ = 1, 100 do
		Resources.regen(state, derived, 12, 1)
	end
	Assert.equal(state.stamina, 140, "capped at max")
	Resources.regen(state, derived, 13, -1)
	Assert.equal(state.stamina, 140, "negative dt ignored")
	Assert.equal(state.health, 200, "health does not auto-regenerate")
end)

suite:case("posture breaks at zero and recovers past half", function()
	local derived = Attributes.derive(Attributes.DEFAULT_BASE)
	local state = Resources.new(derived)
	Assert.isTrue(Resources.spend(state, "posture", 80, 0), "drain")
	Assert.isTrue(state.postureBroken, "broken at zero")
	Resources.regen(state, derived, 2, 1) -- delay is 2s: regen starts now
	Assert.equal(state.posture, 8, "8/s")
	Assert.isTrue(state.postureBroken, "still broken below half")
	Resources.restore(state, "posture", 40, derived)
	Assert.isFalse(state.postureBroken, "recovered past half")
end)

suite:case("damage, death and clamping", function()
	local derived = Attributes.derive(Attributes.DEFAULT_BASE)
	local state = Resources.new(derived)
	Assert.equal(Resources.damage(state, 150), 150, "applied")
	Assert.equal(Resources.damage(state, 100), 50, "only what was left")
	Assert.equal(state.health, 0, "zero")
	Assert.isTrue(Resources.isDead(state), "dead")
	Assert.equal(Resources.damage(state, -10), 0, "negative damage ignored")
	Assert.equal(Resources.restore(state, "health", 5000, derived), 200, "restore caps")
	state.stamina = 999
	Resources.clamp(state, derived)
	Assert.equal(state.stamina, 140, "clamped down after a cap change")
	Assert.count(Resources.validate(state, derived), 0, "valid")
	state.posture = -1
	Assert.contains(
		table.concat(Resources.validate(state, derived), ";"),
		"posture out of range",
		"detects bad state"
	)
end)

return suite:cases()
