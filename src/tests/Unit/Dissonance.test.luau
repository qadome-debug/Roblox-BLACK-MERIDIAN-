--!strict
-- BM-068: the Dissonance meter follows the design's five bands, rises and
-- recovers only through the design's sources, is never saved, and can
-- never be set by a client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local ContentFixtures = require(ServerStorage.Tests.Support.ContentFixtures)
local Dissonance = require(ServerScriptService.Server.Combat.Dissonance)
local DissonanceAction = require(ServerScriptService.Server.Network.Adapters.DissonanceAction)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)
local Validators = require(ServerScriptService.Server.Network.Validators)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

local suite = Suite.new("Dissonance")

local BASE = { vigor = 10, might = 10, grace = 10, will = 10 }

type Setup = {
	sim: Simulation.Simulation,
	layer: Dissonance.Layer,
	events: (kind: string) -> { any },
}

local function setup(env: Suite.Env, deps: Dissonance.Deps?): Setup
	local sim = Simulation.new({ logger = env.logger, rng = env.rng })
	sim:addCombatant({ id = "a", team = "players", base = BASE, position = Vec3.new(0, 0, 0) })
	local layer = Dissonance.attach(sim, deps)
	local seen: { any } = {}
	local function events(kind: string): { any }
		for _, event in sim:drainEvents() do
			table.insert(seen, event)
		end
		local out = {}
		for _, event in seen do
			if event.kind == kind then
				table.insert(out, event)
			end
		end
		return out
	end
	return { sim = sim, layer = layer, events = events }
end

suite:case("the five bands are the design's, with exact boundaries", function(env)
	Assert.equal(Dissonance.MAX, 100, "0 to 100")
	local names = {}
	local mins = {}
	for _, band in Dissonance.BANDS do
		table.insert(names, band.name)
		table.insert(mins, band.min)
	end
	Assert.deepEqual(mins, { 0, 40, 65, 85, 100 }, "band starts")
	Assert.deepEqual(names, {
		"Stable",
		"Noticeable instability",
		"Enemy and environmental reactions",
		"Fractured event risk",
		"Controlled rupture",
	}, "band names")
	local expected: { [number]: number } = {
		[0] = 0,
		[39] = 0,
		[39.99] = 0,
		[40] = 1,
		[64] = 1,
		[65] = 2,
		[84] = 2,
		[85] = 3,
		[99] = 3,
		[99.99] = 3,
		[100] = 4,
	}
	for value, level in expected do
		Assert.equal(Dissonance.levelFor(value), level, "band of " .. value)
	end

	local s = setup(env)
	Assert.equal(s.layer:band("a").key, "stable", "starts stable")
	s.layer:add("a", 39, "verse")
	Assert.equal(s.layer:level("a"), 0, "39 is still Stable")
	Assert.count(s.events("dissonance_band_changed"), 0, "no event below 40")
	s.layer:add("a", 1, "verse")
	Assert.equal(s.layer:level("a"), 1, "40 crosses")
	local changes = s.events("dissonance_band_changed")
	Assert.count(changes, 1, "one event per crossing")
	Assert.equal(changes[1].data.band, "instability", "band key")
	Assert.equal(changes[1].data.previous, 0, "previous band")
	Assert.equal(changes[1].data.source, "verse", "source")
	s.layer:add("a", 5, "enemyAttack")
	Assert.count(s.events("dissonance_band_changed"), 1, "no event inside a band")
end)

suite:case("the meter is clamped, and a jump across bands is one event", function(env)
	local s = setup(env)
	Assert.equal(s.layer:add("a", 90, "unstableArea"), 90, "raised")
	local changes = s.events("dissonance_band_changed")
	Assert.count(changes, 1, "one event for the jump")
	Assert.equal(changes[1].data.level, 3, "landed in the fourth band")
	Assert.equal(s.layer:add("a", 500, "relic"), 100, "clamped at 100")
	Assert.equal(s.layer:recover("a", 5000, "camp"), 0, "clamped at 0")
	Assert.equal(s.layer:level("a"), 0, "stable again")
	-- Bad amounts change nothing.
	for _, amount: any in { 0, -5, 0 / 0, math.huge, "10" } :: { any } do
		Assert.equal(s.layer:add("a", amount, "verse"), 0, "ignored " .. tostring(amount))
		Assert.equal(s.layer:recover("a", amount, "anchor"), 0, "ignored " .. tostring(amount))
	end
	Assert.equal(s.layer:add("ghost", 10, "verse"), 0, "unknown combatant")
end)

suite:case("only the design's sources raise or recover Dissonance", function(env)
	local s = setup(env)
	for _, source: any in
		{ "verse", "relic", "unstableArea", "enemyAttack", "failedContainment" } :: { any }
	do
		s.layer:add("a", 1, source)
	end
	Assert.equal(s.layer:value("a"), 5, "five gain sources")
	for _, source: any in
		{ "stableEnvironment", "anchor", "camp", "consumable", "encounterComplete", "cooperative" } :: { any }
	do
		s.layer:recover("a", 0.5, source)
	end
	Assert.equal(s.layer:value("a"), 2, "six recovery sources")
	Assert.throws(function()
		s.layer:add("a", 1, "decay" :: any)
	end, "unknown gain source", "an invented source is a programming error")
	Assert.throws(function()
		s.layer:recover("a", 1, "time" :: any)
	end, "unknown recovery source", "time alone is not a recovery source")
end)

suite:case("nothing recovers by itself until a rate is approved", function(env)
	-- Production: no tuning and no stable-environment check.
	local s = setup(env)
	s.layer:add("a", 50, "verse")
	for _ = 1, 600 do
		s.sim:step()
	end
	Assert.equal(s.layer:value("a"), 50, "no decay over time")
	Assert.isNil(Dissonance.PRODUCTION_TUNING.stableRecoveryPerSecond, "no approved rate")

	-- A rate without a stable environment still recovers nothing.
	local outside = setup(env, { tuning = { stableRecoveryPerSecond = 6 } })
	outside.layer:add("a", 50, "verse")
	for _ = 1, 60 do
		outside.sim:step()
	end
	Assert.equal(outside.layer:value("a"), 50, "not in a stable environment")
end)

suite:case("passive recovery runs only in a stable environment", function(env)
	local stable = false
	local s = setup(env, {
		tuning = { stableRecoveryPerSecond = 6 },
		inStableEnvironment = function(_id: string): boolean
			return stable
		end,
	})
	s.layer:add("a", 45, "verse")
	for _ = 1, 30 do
		s.sim:step()
	end
	Assert.equal(s.layer:value("a"), 45, "unstable ground: no recovery")
	stable = true
	-- One second of steps at the default step length removes 6.
	local stepsPerSecond = math.floor(1 / s.sim.stepSeconds + 0.5)
	for _ = 1, stepsPerSecond do
		s.sim:step()
	end
	Assert.isTrue(
		math.abs(s.layer:value("a") - 39) < 1e-6,
		"6 per second, whatever the step length"
	)
	Assert.equal(s.layer:level("a"), 0, "walked down a band")
	local last = s.events("dissonance_band_changed")
	Assert.equal(last[#last].data.source, "stableEnvironment", "recovery source reported")
end)

suite:case("reaching 100 is a rupture handed to the region or encounter", function(env)
	local ruptured: { string } = {}
	local s = setup(env, {
		onRupture = function(id: string)
			table.insert(ruptured, id)
		end,
	})
	s.layer:add("a", 99, "verse")
	Assert.count(ruptured, 0, "99 is not a rupture")
	s.layer:add("a", 1, "failedContainment")
	Assert.deepEqual(ruptured, { "a" }, "handler called once")
	Assert.count(s.events("dissonance_rupture"), 1, "announced once")
	s.layer:add("a", 10, "verse")
	Assert.count(ruptured, 1, "staying at 100 does not rupture again")
	-- The layer itself takes nothing from the combatant.
	Assert.notNil(s.sim:get("a"), "the combatant is untouched by the meter itself")
end)

suite:case("there are no player-triggered actions until a design is approved", function(env)
	local s = setup(env)
	Assert.equal(next(Dissonance.PRODUCTION_ACTIONS), nil, "production action list is empty")
	Assert.isFalse(s.layer:hasAction("vent"), "no action")
	Assert.equal((s.layer:perform("a", "vent") :: any).reason, "unknown action", "refused")

	-- The mechanism still validates what it is given.
	Assert.throws(function()
		setup(env, { tuning = { stableRecoveryPerSecond = -1 } })
	end, "stableRecoveryPerSecond", "bad rate")
	Assert.throws(function()
		setup(env, { tuning = { decayPerStep = 1 } :: any })
	end, "unknown tuning field", "the old decay tuning is gone")
	Assert.throws(function()
		setup(env, {
			actions = {
				bad = { minLevel = 9, consume = 0, cooldownSteps = 0, effect = function() end },
			},
		})
	end, "minLevel", "bad action")
end)

suite:case("the same inputs give the same transitions", function(env)
	local function run(): { string }
		local s = setup(env, {
			tuning = { stableRecoveryPerSecond = 3 },
			inStableEnvironment = function(_id: string): boolean
				return true
			end,
		})
		local trace: { string } = {}
		for step = 1, 240 do
			if step % 40 == 1 then
				s.layer:add("a", 22, "verse")
			end
			s.sim:step()
			table.insert(trace, string.format("%.4f:%d", s.layer:value("a"), s.layer:level("a")))
		end
		return trace
	end
	Assert.deepEqual(run(), run(), "identical traces")
end)

suite:case(
	"a resolved Verse adds its own Dissonance; a client can only name an action",
	function(env)
		local cantCatalog, verseCatalog = ContentFixtures.catalogs()
		local combat = CombatService.new({
			clock = env.clock,
			rng = env.rng,
			logger = env.logger,
			telemetry = Telemetry.new(env.logger),
			send = function() end,
			cantCatalog = cantCatalog,
			verseCatalog = verseCatalog,
		})
		combat:addPlayer(1)
		local id = combat:combatantId(1)
		combat.cants:equip(id, "cant.ta")
		-- ta.v1 states 10 Dissonance; tc.v1 states none.
		Assert.isTrue(combat.verses:cast(id, "ta.v1", nil).ok, "cast")
		Assert.equal(combat.dissonance:value(id), 0, "nothing until the Verse resolves")
		for _ = 1, 8 do
			combat.sim:step()
		end
		Assert.equal(combat.dissonance:value(id), 10, "raised by the resolved Verse's own value")

		local validate = Validators.forAction("DissonanceAction") :: any
		Assert.notNil(validate({ actionId = "vent" }), "an action name is accepted")
		Assert.isNil(validate({ actionId = "vent", value = 0 }), "a meter value is refused")
		Assert.isNil(validate({ level = 3 }), "a level is refused")
		Assert.isNil(validate({ actionId = "" }), "empty refused")

		local adapter = DissonanceAction.new({ combat = combat } :: any)
		local ctx: any =
			{ userId = 1, requestId = "r1", action = "DissonanceAction", logger = env.logger }
		local result: any = adapter.handle(ctx, { actionId = "anything" })
		Assert.equal(result.status, "REJECTED", "no player-triggered actions exist")
		Assert.equal(combat.dissonance:value(id), 10, "a request never moves the meter")
		ctx.userId = 2
		Assert.equal(
			(adapter.handle(ctx, { actionId = "x" }) :: any).status,
			"NOT_READY",
			"no combatant"
		)

		-- Not saved: the profile schema's field stays at zero and a combatant
		-- that leaves and returns starts from zero.
		Assert.equal((ProfileSchema.default() :: any).burdens.dissonance, 0, "nothing saved")
		combat:removePlayer(1)
		Assert.equal(combat.dissonance:value(id), 0, "forgotten on leave")
		combat:addPlayer(1)
		Assert.equal(
			combat.dissonance:value(combat:combatantId(1)),
			0,
			"a new session starts at zero"
		)
		Assert.equal(combat.dissonance:band(combat:combatantId(1)).name, "Stable", "and Stable")
	end
)

return suite:cases()
