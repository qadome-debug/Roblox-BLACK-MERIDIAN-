--!strict
-- BM-068: Dissonance threshold crossings, decay, repeated actions,
-- determinism, and the client path (an action name only, never a value).

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local ContentFixtures = require(ServerStorage.Tests.Support.ContentFixtures)
local Dissonance = require(ServerScriptService.Server.Combat.Dissonance)
local DissonanceAction = require(ServerScriptService.Server.Network.Adapters.DissonanceAction)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)
local Validators = require(ServerScriptService.Server.Network.Validators)

local suite = Suite.new("Dissonance")

local TUNING: Dissonance.Tuning = {
	max = 100,
	thresholds = { 30, 60, 90 },
	decayPerStep = 1,
	decayDelaySteps = 5,
	provisional = false,
}

type Setup = { sim: Simulation.Simulation, layer: Dissonance.Layer, effects: { string } }

local function setup(env: Suite.Env): Setup
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("d") })
	local effects: { string } = {}
	local layer = Dissonance.attach(sim, {
		tuning = TUNING,
		actions = {
			vent = {
				minLevel = 1,
				consume = 30,
				cooldownSteps = 10,
				effect = function(ctx)
					table.insert(effects, ctx.actionId .. "@" .. ctx.level)
				end,
			},
			stoke = { minLevel = 0, consume = -20, cooldownSteps = 0, effect = function() end },
		},
	})
	sim:addCombatant({ id = "a", team = "players" })
	return { sim = sim, layer = layer, effects = effects }
end

local function levelEvents(sim: Simulation.Simulation): { string }
	local out: { string } = {}
	for _, e in sim:drainEvents() do
		if e.kind == "dissonance_level_changed" then
			local data = e.data :: any
			table.insert(out, data.previous .. ">" .. data.level)
		end
	end
	return out
end

suite:case("threshold crossings change level exactly at the boundary", function(env)
	local s = setup(env)
	Assert.equal(s.layer:add("a", 29.5, "test"), 29.5, "below")
	Assert.equal(s.layer:level("a"), 0, "level 0")
	s.layer:add("a", 0.5, "test")
	Assert.equal(s.layer:level("a"), 1, "exactly 30 is level 1")
	s.layer:add("a", 200, "test")
	Assert.equal(s.layer:value("a"), 100, "clamped to max")
	Assert.equal(s.layer:level("a"), 3, "top level")
	Assert.deepEqual(levelEvents(s.sim), { "0>1", "1>3" }, "one event per change")
	for _, bad in { -5, 0, 0 / 0, math.huge } do
		s.layer:add("a", bad, "test")
	end
	Assert.equal(s.layer:value("a"), 100, "invalid amounts ignored")
	Assert.equal(s.layer:add("ghost", 10, "test"), 0, "unknown combatant ignored")
end)

suite:case("decay waits for the quiet period and walks levels down", function(env)
	local s = setup(env)
	s.layer:add("a", 62, "test")
	levelEvents(s.sim)
	for _ = 1, 4 do
		s.sim:step()
	end
	Assert.equal(s.layer:value("a"), 62, "no decay inside the delay")
	for _ = 1, 3 do
		s.sim:step()
	end
	Assert.equal(s.layer:value("a"), 59, "decaying after the delay")
	Assert.deepEqual(levelEvents(s.sim), { "2>1" }, "crossed down once")
	for _ = 1, 100 do
		s.sim:step()
	end
	Assert.equal(s.layer:value("a"), 0, "floors at zero")
	Assert.equal(s.layer:level("a"), 0, "level 0")
end)

suite:case("repeated actions respect level, cost and cooldown", function(env)
	local s = setup(env)
	local function reason(o: any): string?
		return if o.ok then nil else o.reason
	end
	Assert.equal(reason(s.layer:perform("a", "vent")), "dissonance too low", "level 0")
	s.layer:add("a", 95, "test")
	Assert.equal(reason(s.layer:perform("a", "vent")), nil, "vent at level 3")
	Assert.equal(s.layer:value("a"), 65, "consumed 30")
	Assert.equal(reason(s.layer:perform("a", "vent")), "cooldown", "again at once")
	for _ = 1, 10 do
		s.sim:step()
	end
	Assert.equal(s.layer:value("a"), 59, "consuming is not a rise, so decay ran")
	Assert.equal(reason(s.layer:perform("a", "vent")), nil, "after cooldown")
	Assert.equal(s.layer:value("a"), 29, "consumed again")
	Assert.deepEqual(s.effects, { "vent@3", "vent@1" }, "effects ran with the level at use")
	Assert.equal(reason(s.layer:perform("a", "nonsense")), "unknown action", "unknown")
	Assert.equal(reason(s.layer:perform("a", "stoke")), nil, "stoke adds")
	Assert.equal(s.layer:value("a"), 49, "added 20")
end)

suite:case("the same inputs give the same transitions", function(env)
	local function run(): { string }
		local s = setup(env)
		local trace: { string } = {}
		for step = 1, 60 do
			if step % 7 == 0 then
				s.layer:add("a", 18, "test")
			end
			if step % 11 == 0 then
				s.layer:perform("a", "vent")
			end
			s.sim:step()
			table.insert(trace, s.layer:value("a") .. "/" .. s.layer:level("a"))
		end
		return trace
	end
	Assert.deepEqual(run(), run(), "deterministic")
end)

suite:case("invalid tuning and actions are refused at attach", function(env)
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("x") })
	Assert.isTrue(#Dissonance.validateTuning(Dissonance.PROVISIONAL_TUNING) == 0, "provisional ok")
	Assert.isTrue(#Dissonance.validateTuning({
		max = 100,
		thresholds = { 50, 40 },
		decayPerStep = 1,
		decayDelaySteps = 1,
		provisional = true,
	}) > 0, "descending thresholds")
	Assert.isTrue(#Dissonance.validateTuning({
		max = 10,
		thresholds = { 50 },
		decayPerStep = 1,
		decayDelaySteps = 1,
		provisional = true,
	}) > 0, "threshold above max")
	Assert.throws(function()
		Dissonance.attach(sim, {
			tuning = TUNING,
			actions = {
				bad = { minLevel = 9, consume = 1, cooldownSteps = 0, effect = function() end },
			},
		})
	end, "invalid configuration")
end)

suite:case("resolved Verses raise Dissonance and the client can only name an action", function(env)
	local cantCatalog, verseCatalog = ContentFixtures.catalogs()
	local combat = CombatService.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		send = function() end,
		cantCatalog = cantCatalog,
		cantKits = {
			["cant-tc"] = {
				cooldownSteps = 0,
				usableIn = { "Idle" },
				effect = function() end,
				provisional = true,
			},
		},
		verseCatalog = verseCatalog,
		dissonanceTuning = TUNING,
		dissonancePerVerse = 12,
	})
	combat:addPlayer(1)
	local id = combat:combatantId(1)
	combat.cants:equip(id, "cant-tc")
	Assert.isTrue(combat.verses:cast(id, "verse-tc1", nil).ok, "cast")
	combat.sim:step()
	Assert.equal(combat.dissonance:value(id), 12, "raised by the resolved Verse")

	local validate = Validators.forAction("DissonanceAction") :: any
	Assert.notNil(validate({ actionId = "vent" }), "an action name is accepted")
	Assert.isNil(validate({ actionId = "vent", value = 0 }), "a meter value is refused")
	Assert.isNil(validate({ level = 3 }), "a level is refused")
	Assert.isNil(validate({ actionId = "" }), "empty refused")

	local adapter = DissonanceAction.new({ combat = combat } :: any)
	local ctx: any =
		{ userId = 1, requestId = "r1", action = "DissonanceAction", logger = env.logger }
	local result: any = adapter.handle(ctx, { actionId = "anything" })
	Assert.equal(result.status, "REJECTED", "production has no canonical actions yet")
	ctx.userId = 2
	Assert.equal(
		(adapter.handle(ctx, { actionId = "x" }) :: any).status,
		"NOT_READY",
		"no combatant"
	)
	combat:removePlayer(1)
	Assert.equal(combat.dissonance:value(id), 0, "forgotten on leave")
end)

return suite:cases()
