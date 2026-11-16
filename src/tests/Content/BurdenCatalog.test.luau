--!strict
-- BM-069: Burden catalog integrity, invalid combinations and modifier
-- bounds. Test IDs only; not canon.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Attributes = require(ServerScriptService.Server.Combat.Attributes)
local BurdenCatalog = require(ServerScriptService.Server.Content.BurdenCatalog)
local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentFixtures = require(ServerStorage.Tests.Support.ContentFixtures)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("BurdenCatalog")

local function defs(): { any }
	return {
		{
			id = "burden-ta",
			sources = { "descent", "boss" },
			incompatibleWith = { "burden-tb" },
			maxStacks = 1,
			modifiers = { { stat = "maxHealth", mul = 0.8 } },
			mechanics = "provisional",
		},
		{
			id = "burden-tb",
			sources = { "quest" },
			incompatibleWith = { "burden-ta" },
			maxStacks = 3,
			modifiers = { { stat = "attackPower", add = 5 }, { stat = "defense", mul = 0.9 } } :: { any },
			mechanics = "provisional",
		},
		{
			id = "burden-tc",
			sources = { "waymark" },
			incompatibleWith = {},
			maxStacks = 5,
			modifiers = { { stat = "moveSpeed", mul = 1.5 } },
			mechanics = "canonical",
		},
	}
end

local function expectProblem(data: unknown, needle: string)
	local problems = BurdenCatalog.validate(data, ContentFixtures.registry())
	for _, p in problems do
		if string.find(p, needle, 1, true) then
			return
		end
	end
	error("expected a problem containing '" .. needle .. "', got: " .. table.concat(problems, "; "))
end

local function build(): BurdenCatalog.Catalog
	return BurdenCatalog.build(defs() :: any, ContentFixtures.registry())
end

suite:case("the fixture catalog validates and the production one matches canon", function()
	Assert.deepEqual(BurdenCatalog.validate(defs(), ContentFixtures.registry()), {}, "valid")
	Assert.deepEqual(build():ids(), { "burden-ta", "burden-tb", "burden-tc" }, "ids")
	Assert.equal(
		#BurdenCatalog.production():ids(),
		#Canon:ids("burden"),
		"one per canonical Burden"
	)
end)

suite:case("only canonical Burden IDs are accepted", function()
	local catalog = build()
	for _, value: any in { "burden-fake", "", 1, {} } :: { any } do
		Assert.isNil(catalog:resolve(value), "rejected")
	end
	local data = defs()
	data[1].id = "burden-invented"
	expectProblem(data, "burden-invented: not a canonical Burden ID")
	local missing = defs()
	table.remove(missing, 3)
	expectProblem(missing, "burden-tc: canonical Burden has no definition")
	local dup = defs()
	table.insert(dup, table.clone(dup[3]))
	expectProblem(dup, "defined more than once")
end)

suite:case("invalid combinations are problems and are refused at runtime", function()
	local selfRef = defs()
	selfRef[3].incompatibleWith = { "burden-tc" }
	expectProblem(selfRef, "cannot be incompatible with itself")
	local oneWay = defs()
	oneWay[2].incompatibleWith = {}
	expectProblem(oneWay, "incompatible with burden-tb but not the other way round")
	local unknown = defs()
	unknown[3].incompatibleWith = { "burden-nope" }
	expectProblem(unknown, "is not a canonical Burden")
	local catalog = build()
	Assert.isTrue((catalog:compatible({}, "burden-ta")), "alone")
	local ok, reason = catalog:compatible({ "burden-tb" }, "burden-ta")
	Assert.isFalse(ok, "conflict")
	Assert.equal(reason, "incompatible burden", "reason")
	Assert.isTrue((catalog:compatible({ "burden-tc" }, "burden-ta")), "unrelated")
	Assert.isFalse((catalog:compatible({}, "burden-fake")), "unknown")
end)

suite:case("modifier bounds are enforced", function()
	local cases: { { mod: any, needle: string } } = {
		{ mod = { stat = "luck", add = 1 }, needle = "must target a derived stat" },
		{ mod = { stat = "maxHealth" }, needle = "needs add or mul" },
		{ mod = { stat = "maxHealth", mul = 0.1 }, needle = "mul must be within" },
		{ mod = { stat = "maxHealth", mul = 2 }, needle = "mul must be within" },
		{ mod = { stat = "maxHealth", mul = 0 / 0 }, needle = "mul must be within" },
		{
			mod = { stat = "maxHealth", add = (Attributes.CAPS :: any).maxHealth.max },
			needle = "add must be finite and within",
		},
		{ mod = { stat = "maxHealth", add = math.huge }, needle = "add must be finite" },
		{ mod = { stat = "maxHealth", add = 1, set = 0 }, needle = "unknown field set" },
	}
	for _, c in cases do
		local data = defs()
		data[1].modifiers = { c.mod }
		expectProblem(data, c.needle)
	end
	local stacks = defs()
	stacks[1].maxStacks = 0
	expectProblem(stacks, "maxStacks must be an integer")
	local sources = defs()
	sources[1].sources = { "shop" }
	expectProblem(sources, "unknown source shop")
end)

suite:case("stacked modifiers are clamped to maxStacks and attribute limits", function()
	local catalog = build()
	local mods =
		catalog:modifiersFor({ ["burden-tb"] = 10, ["burden-tc"] = 5, ["burden-fake"] = 1 })
	local byId: { [string]: Attributes.Modifier } = {}
	for _, m in mods do
		byId[m.id] = m
		Assert.deepEqual(Attributes.validateModifier(m), {}, m.id .. " valid for derive")
	end
	Assert.equal(byId["burden-tb:1"].add, 15, "three stacks at most")
	Assert.equal(
		byId["burden-tc:1"].mul,
		Attributes.MAX_MODIFIER_MUL,
		"clamped to the attribute cap"
	)
	Assert.isNil(byId["burden-fake:1"], "unknown ignored")
	local derived = Attributes.derive(Attributes.DEFAULT_BASE, mods)
	Assert.isTrue(
		derived.moveSpeed <= (Attributes.CAPS :: any).moveSpeed.max,
		"derived stays in caps"
	)
end)

return suite:cases()
