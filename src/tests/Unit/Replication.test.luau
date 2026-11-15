--!strict
-- BM-060: replication carries only public state, incremental deltas
-- become full snapshots after a long gap (packet delay), private cues
-- reach only their owner, and the acknowledgement corrects predictions.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Damage = require(ServerScriptService.Server.Combat.Damage)
local Hitboxes = require(ServerScriptService.Server.Combat.Hitboxes)
local Replication = require(ServerScriptService.Server.Combat.Replication)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Targeting = require(ServerScriptService.Server.Combat.Targeting)

local suite = Suite.new("Replication")

type Vec3 = { x: number, y: number, z: number }

type World = {
	sim: Simulation.Simulation,
	replication: Replication.Replication,
	targeting: Targeting.Targeting,
	tick: (steps: number) -> (),
}

local function pos(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

local function world(env: Suite.Env, deps: Replication.Deps?): World
	local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork("combat") })
	local hitboxes = Hitboxes.attach(sim)
	local damage = Damage.attach(sim, hitboxes)
	local targeting = Targeting.attach(sim, { damage = damage })
	local options: Replication.Deps = deps or {}
	options.targeting = targeting
	local replication = Replication.new(sim, options)
	sim:onStep(function()
		targeting:tick()
		replication:collect()
	end)
	return {
		sim = sim,
		replication = replication,
		targeting = targeting,
		tick = function(steps: number)
			for _ = 1, steps do
				sim:step()
			end
		end,
	}
end

local function ids(list: { Replication.PublicCombatant }): { string }
	local out = {}
	for _, view in list do
		table.insert(out, view.id)
	end
	return out
end

suite:case("public views hide exact numbers; own views carry resources and the ack", function(env)
	local w = world(env)
	w.sim:addCombatant({ id = "p:1", team = "players", position = pos(0, 0, 0) })
	w.sim:addCombatant({
		id = "e",
		team = "enemies",
		position = pos(0, 0, -3),
		base = { vigor = 50, might = 10, grace = 10, will = 10 },
	})
	w.sim:damage("e", 123.4)
	w.tick(1)
	local view = w.replication:publicView("e") :: Replication.PublicCombatant
	Assert.equal(view.health, 0.79, "fraction of 600, rounded")
	Assert.deepEqual(
		view,
		{ id = "e", team = "enemies", state = "Idle", phase = "None", actionId = 0, health = 0.79 },
		"nothing else"
	)
	Assert.isTrue(w.sim:submit("p:1", { kind = "Attack", sequence = 1 }).ok, "attack")
	w.tick(1)
	Assert.isTrue(w.targeting:request("p:1", "e").ok, "lock")
	local own = w.replication:ownView("p:1") :: Replication.OwnCombatant
	Assert.equal(own.health, 200, "exact own health")
	Assert.equal(own.stamina, 120, "exact own stamina")
	Assert.equal(own.ackSequence, 1, "the server judged sequence 1")
	Assert.equal(own.state, "Attacking", "state")
	Assert.equal(own.target, "e", "lock target")
	Assert.isTrue(own.engaged, "engaged by the lock")
	Assert.isNil(w.replication:ownView("nobody"), "unknown")
end)

suite:case("deltas are incremental, list removals, and become full after a long gap", function(env)
	local w = world(env, { historySteps = 20 })
	w.sim:addCombatant({ id = "p:1", team = "players", position = pos(0, 0, 0) })
	w.sim:addCombatant({ id = "e1", team = "enemies", position = pos(0, 0, -3) })
	w.sim:addCombatant({ id = "e2", team = "enemies", position = pos(10, 0, 0) })
	w.tick(1)
	local first = w.replication:delta("p:1", nil)
	Assert.isTrue(first.full, "first delta is full")
	Assert.deepEqual(ids(first.combatants), { "e1", "e2", "p:1" }, "everyone, sorted")
	Assert.equal(first.revision, 1, "revision is the step")
	Assert.notNil(first.own, "own view for the viewer")

	w.tick(3)
	local quiet = w.replication:delta("p:1", first.revision)
	Assert.isFalse(quiet.full, "incremental")
	Assert.deepEqual(ids(quiet.combatants), {}, "nothing changed")
	Assert.equal(quiet.revision, 4, "revision advanced")

	Assert.isTrue(w.sim:submit("e1", { kind = "Attack", sequence = 1 }).ok, "e1 attacks")
	w.tick(1)
	local changed = w.replication:delta("p:1", quiet.revision)
	Assert.deepEqual(ids(changed.combatants), { "e1" }, "only the changed combatant")
	Assert.equal(changed.combatants[1].state, "Attacking", "new state")

	w.sim:removeCombatant("e2")
	w.tick(1)
	local removed = w.replication:delta("p:1", changed.revision)
	Assert.deepEqual(removed.removed, { "e2" }, "removal listed")
	Assert.deepEqual(ids(removed.combatants), {}, "no public change otherwise")
	Assert.isNil(w.replication:delta(nil, removed.revision).own, "no viewer, no own view")

	-- Packet delay: a client that last applied an old revision gets a
	-- full snapshot instead of an unreconstructable diff.
	w.tick(25)
	local late = w.replication:delta("p:1", removed.revision)
	Assert.isTrue(late.full, "full after the history window")
	Assert.deepEqual(ids(late.combatants), { "e1", "p:1" }, "current population")
	Assert.deepEqual(late.removed, {}, "a full delta lists no removals")
	Assert.isTrue(
		w.replication:delta("p:1", 9999).full,
		"a revision from the future forces a full resync"
	)
end)

suite:case(
	"cues are public, bounded, filtered, and private rejections reach only their owner",
	function(env)
		local w = world(env, { maxCuesPerBatch = 5 })
		w.sim:addCombatant({ id = "p:1", team = "players", position = pos(0, 0, 0) })
		w.sim:addCombatant({ id = "p:2", team = "players", position = pos(5, 0, 0) })
		w.sim:addCombatant({ id = "e", team = "enemies", position = pos(0, 0, -3) })
		w.tick(1)
		w.replication:cues("p:1")
		w.replication:cues("p:2")
		Assert.isTrue(w.sim:submit("p:1", { kind = "Release", sequence = 1 }).ok, "queued") -- rejected at the step
		Assert.isTrue(w.sim:submit("p:1", { kind = "Attack", sequence = 2 }).ok, "queued")
		w.tick(7) -- attack lands on e
		local mine = w.replication:cues("p:1")
		local theirs = w.replication:cues("p:2")
		local kinds = {}
		for _, cue in mine do
			table.insert(kinds, cue.kind)
		end
		Assert.deepEqual(
			kinds,
			{ "intent_rejected", "action_started", "phase_entered", "hit", "interrupted" },
			"own cues, bounded to five"
		)
		Assert.equal(
			(mine[1].data :: any).reason,
			"nothing to release",
			"private reason visible to the owner"
		)
		Assert.equal((mine[1].data :: any).sequence, 1, "which sequence")
		Assert.equal((mine[4].data :: any).target, "e", "public hit target")
		local theirKinds = {}
		for _, cue in theirs do
			table.insert(theirKinds, cue.kind)
		end
		Assert.deepEqual(
			theirKinds,
			{ "action_started", "phase_entered", "hit", "interrupted", "damage" },
			"no private cue for others"
		)
		local rest = w.replication:cues("p:1")
		Assert.isTrue(#rest >= 1, "the remaining cues arrive on the next call")
		Assert.count(w.replication:cues("p:1"), 0, "then nothing")
		w.replication:forgetViewer("p:1")
		Assert.isTrue(
			#w.replication:cues("p:1") > 0,
			"a forgotten viewer starts over from the retained history"
		)
	end
)

suite:case("prediction correction: the ack settles a mispredicted action", function(env)
	local w = world(env)
	local p = w.sim:addCombatant({ id = "p:1", team = "players", position = pos(0, 0, 0) })
	w.tick(1)
	p.resources.stamina = 5
	-- The client predicts an attack for sequence 1 and plays its animation.
	Assert.isTrue(
		w.sim:submit("p:1", { kind = "Attack", sequence = 1 }).ok,
		"accepted into the queue"
	)
	local before = w.replication:ownView("p:1") :: Replication.OwnCombatant
	Assert.equal(before.ackSequence, 0, "not judged yet")
	w.tick(1)
	local after = w.replication:ownView("p:1") :: Replication.OwnCombatant
	Assert.equal(after.ackSequence, 1, "judged")
	Assert.equal(after.state, "Idle", "the server never started it")
	local cues = w.replication:cues("p:1")
	Assert.equal(cues[#cues].kind, "intent_rejected", "the client learns why")
	Assert.equal((cues[#cues].data :: any).reason, "cannot afford stamina", "reason")
end)

return suite:cases()
