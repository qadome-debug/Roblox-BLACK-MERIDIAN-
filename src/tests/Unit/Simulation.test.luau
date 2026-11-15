--!strict
-- BM-054: fixed-step authoritative combat simulation and action state
-- machine. Deterministic sequences; impossible transitions and
-- manipulated timing are rejected.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ActionMachine = require(ServerScriptService.Server.Combat.ActionMachine)
local Assert = require(ServerStorage.Tests.Support.Assert)
local Simulation = require(ServerScriptService.Server.Combat.Simulation)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Simulation")

local function make(env: Suite.Env): Simulation.Simulation
	return Simulation.new({ logger = env.logger, rng = env.rng:fork("combat") })
end

local function run(sim: Simulation.Simulation, steps: number)
	for _ = 1, steps do
		sim:step()
	end
end

local function kinds(events: { Simulation.Event }, id: string?): { string }
	local out = {}
	for _, event in events do
		if id == nil or event.id == id then
			local data = event.data
			local detail = if data ~= nil and data.phase ~= nil
				then tostring(data.phase)
				elseif data ~= nil and data.reason ~= nil then tostring(data.reason)
				else ""
			table.insert(
				out,
				event.step .. ":" .. event.kind .. (if detail ~= "" then "/" .. detail else "")
			)
		end
	end
	return out
end

local function submitOk(
	sim: Simulation.Simulation,
	id: string,
	kind: ActionMachine.ActionKind,
	sequence: number
)
	local outcome = sim:submit(id, { kind = kind, sequence = sequence })
	Assert.isTrue(
		outcome.ok,
		"submit " .. kind .. " #" .. sequence .. ": " .. tostring((outcome :: any).reason)
	)
end

suite:case("an attack moves through windup, active and recovery in whole steps", function(env)
	local sim = make(env)
	sim:addCombatant({ id = "a", team = "players" })
	sim:drainEvents()
	submitOk(sim, "a", "Attack", 1)
	run(sim, 1)
	local snap = sim:snapshot("a") :: Simulation.Snapshot
	Assert.equal(snap.state, "Attacking", "started")
	Assert.equal(snap.phase, "Windup", "windup first")
	Assert.equal(snap.stamina, 120, "cost spent on start")
	run(sim, 5)
	Assert.equal(
		(sim:snapshot("a") :: Simulation.Snapshot).phase,
		"Windup",
		"still winding up at step 6"
	)
	run(sim, 1)
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).phase, "Active", "active at step 7")
	run(sim, 4)
	Assert.equal(
		(sim:snapshot("a") :: Simulation.Snapshot).phase,
		"Recovery",
		"recovery at step 11"
	)
	run(sim, 10)
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).state, "Idle", "idle at step 21")
	Assert.deepEqual(kinds(sim:drainEvents()), {
		"1:action_started/Windup",
		"7:phase_entered/Active",
		"11:phase_entered/Recovery",
		"21:action_ended",
	}, "event timeline")
	-- Stamina regenerates after the delay: 1s = 30 steps after the spend.
	Assert.isTrue(
		(sim:snapshot("a") :: Simulation.Snapshot).stamina < 125,
		"no regen inside the delay"
	)
	run(sim, 60)
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).stamina, 140, "refilled")
end)

suite:case("impossible transitions are rejected with a reason", function(env)
	local sim = make(env)
	sim:addCombatant({ id = "a", team = "players" })
	sim:drainEvents()
	submitOk(sim, "a", "Release", 1)
	run(sim, 1)
	Assert.deepEqual(
		kinds(sim:drainEvents(), "a"),
		{ "1:intent_rejected/nothing to release" },
		"release while idle"
	)

	submitOk(sim, "a", "Attack", 2)
	run(sim, 1) -- step 2: attack starts, windup until 8
	submitOk(sim, "a", "Attack", 3)
	submitOk(sim, "a", "Dodge", 4)
	run(sim, 1) -- step 3
	Assert.deepEqual(kinds(sim:drainEvents(), "a"), {
		"2:action_started/Windup",
		"3:intent_rejected/cannot interrupt Attacking",
		"3:intent_rejected/committed to windup",
	}, "nothing interrupts a windup")

	run(sim, 5) -- step 8: active
	submitOk(sim, "a", "Dodge", 5)
	run(sim, 1) -- step 9
	Assert.deepEqual(kinds(sim:drainEvents(), "a"), {
		"8:phase_entered/Active",
		"9:intent_rejected/committed to active frames",
	}, "nothing interrupts active frames")

	run(sim, 6) -- step 15: recovery started at 12, frame 3
	submitOk(sim, "a", "Dodge", 6)
	run(sim, 1) -- step 16: frame 4, too early (cancel from frame 5)
	submitOk(sim, "a", "Dodge", 7)
	run(sim, 1) -- step 17: frame 5, cancel allowed
	Assert.deepEqual(kinds(sim:drainEvents(), "a"), {
		"12:phase_entered/Recovery",
		"16:intent_rejected/too early to cancel recovery",
		"17:action_started/Active",
		"17:phase_entered/Active",
	}, "recovery cancels into a dodge only after the cancel frame")
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).state, "Dodging", "dodging")

	-- Guard is held until released, then recovers.
	run(sim, 20)
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).state, "Idle", "dodge finished")
	sim:drainEvents()
	submitOk(sim, "a", "Guard", 8)
	run(sim, 3) -- starts at 38, windup 2 -> active at 40
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).phase, "Active", "guard held")
	run(sim, 100)
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).phase, "Active", "still held")
	submitOk(sim, "a", "Release", 9)
	run(sim, 1)
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).phase, "Recovery", "released")
	run(sim, 4)
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).state, "Idle", "recovered")
end)

suite:case("manipulated timing and malformed intents are refused before queueing", function(env)
	local sim = make(env)
	sim:addCombatant({ id = "a", team = "players" })
	local function refused(intent: unknown, reason: string)
		local outcome = sim:submit("a", intent)
		Assert.isFalse(outcome.ok, reason)
		Assert.contains((outcome :: any).reason, reason, reason)
	end
	refused("Attack", "intent must be a table")
	refused({ kind = "Fireball", sequence = 1 }, "unknown action kind")
	refused({ kind = "Attack", sequence = 0 }, "sequence must be a positive integer")
	refused({ kind = "Attack", sequence = 1.5 }, "sequence must be a positive integer")
	refused({ kind = "Attack", sequence = "1" }, "sequence must be a positive integer")
	refused({ kind = "Attack", sequence = 1, clientTime = 0 }, "unknown intent field")
	refused({ kind = "Attack", sequence = 1, target = "" }, "invalid target")
	submitOk(sim, "a", "Attack", 5)
	refused({ kind = "Attack", sequence = 5 }, "stale sequence")
	refused({ kind = "Attack", sequence = 4 }, "stale sequence")
	run(sim, 1)
	refused({ kind = "Attack", sequence = 5 }, "stale sequence")
	Assert.isFalse(sim:submit("ghost", { kind = "Attack", sequence = 1 }).ok, "unknown combatant")

	-- Flooding: only a bounded number of intents per step are kept.
	for i = 6, 6 + Simulation.MAX_INTENTS_PER_STEP - 1 do
		submitOk(sim, "a", "Dodge", i)
	end
	refused({ kind = "Dodge", sequence = 50 }, "too many intents this step")
	run(sim, 1)
	local rejected = 0
	for _, event in sim:drainEvents() do
		if event.kind == "intent_rejected" then
			rejected += 1
		end
	end
	Assert.equal(
		rejected,
		Simulation.MAX_INTENTS_PER_STEP,
		"every queued intent was judged at the step"
	)
	Assert.equal(
		(sim:get("a") :: Simulation.Combatant).lastSequence,
		6 + Simulation.MAX_INTENTS_PER_STEP - 1,
		"sequence advanced"
	)
end)

suite:case("two simulations fed the same intents produce identical results", function(env)
	local script = {
		{ step = 0, id = "b", kind = "Attack", sequence = 1 },
		{ step = 0, id = "a", kind = "Guard", sequence = 1 },
		{ step = 4, id = "a", kind = "Release", sequence = 2 },
		{ step = 9, id = "a", kind = "Attack", sequence = 3 },
		{ step = 9, id = "b", kind = "Dodge", sequence = 2 },
		{ step = 30, id = "b", kind = "Parry", sequence = 3 },
	}
	local function play(seed: string, chunk: number): ({ string }, { Simulation.Snapshot })
		local sim = Simulation.new({ logger = env.logger, rng = env.rng:fork(seed) })
		sim:addCombatant({
			id = "b",
			team = "enemies",
			base = { vigor = 20, might = 12, grace = 8, will = 10 },
		})
		sim:addCombatant({ id = "a", team = "players" })
		local guard = 0
		while sim:stepNumber() < 60 do
			for _, line in script do
				if line.step == sim:stepNumber() then
					sim:submit(line.id, { kind = line.kind, sequence = line.sequence })
				end
			end
			-- Advance by uneven wall-clock chunks; steps are what matter.
			local before = sim:stepNumber()
			while sim:stepNumber() == before do
				sim:advance(chunk)
			end
			guard += 1
			if guard > 1000 then
				error("runaway")
			end
		end
		local snaps = {}
		for _, id in sim:ids() do
			table.insert(snaps, sim:snapshot(id) :: Simulation.Snapshot)
		end
		return kinds(sim:drainEvents()), snaps
	end
	local events1, snaps1 = play("seed7", 1 / 30)
	local events2, snaps2 = play("seed7", 1 / 90)
	Assert.deepEqual(events1, events2, "same events regardless of frame chunking")
	Assert.deepEqual(snaps1, snaps2, "same snapshots")
	Assert.isTrue(#events1 > 8, "the script produced a real sequence")
end)

suite:case(
	"costs are checked before an action starts and two intents compete for one pool",
	function(env)
		local sim = make(env)
		local c = sim:addCombatant({ id = "a", team = "players" })
		c.resources.stamina = 30
		sim:drainEvents()
		submitOk(sim, "a", "Attack", 1) -- 20
		submitOk(sim, "a", "Dodge", 2) -- 25: cannot interrupt anyway, but would also be unaffordable
		run(sim, 1)
		Assert.deepEqual(kinds(sim:drainEvents(), "a"), {
			"1:action_started/Windup",
			"1:intent_rejected/committed to windup",
		}, "first spends, second is judged against the new state")
		Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).stamina, 10, "one cost taken")
		run(sim, 25)
		Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).state, "Idle", "idle again")
		sim:drainEvents()
		c.resources.stamina = 10
		c.resources.lastSpent.stamina = sim:now()
		submitOk(sim, "a", "Attack", 3)
		run(sim, 1)
		Assert.deepEqual(
			kinds(sim:drainEvents(), "a"),
			{ "27:intent_rejected/cannot afford stamina" },
			"unaffordable"
		)
		Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).state, "Idle", "nothing started")
	end
)

suite:case("death is final: no actions, no regeneration, no further damage", function(env)
	local sim = make(env)
	sim:addCombatant({ id = "a", team = "players" })
	submitOk(sim, "a", "Attack", 1)
	run(sim, 1)
	sim:drainEvents()
	Assert.equal(sim:damage("a", 150), 150, "first hit")
	Assert.equal(sim:damage("a", 0 / 0), 0, "NaN ignored")
	Assert.equal(sim:damage("a", 500), 50, "only the remaining health")
	Assert.equal((sim:snapshot("a") :: Simulation.Snapshot).state, "Dead", "dead")
	Assert.equal(sim:damage("a", 5), 0, "no damage to the dead")
	submitOk(sim, "a", "Dodge", 2)
	run(sim, 40)
	Assert.deepEqual(kinds(sim:drainEvents(), "a"), {
		"1:health_changed",
		"1:health_changed",
		"1:died",
	}, "the queued intent was dropped silently and nothing else happened")
	Assert.equal(
		(sim:snapshot("a") :: Simulation.Snapshot).stamina,
		120,
		"no regeneration after death"
	)
	Assert.isTrue(sim:removeCombatant("a"), "removed")
	Assert.isNil(sim:snapshot("a"), "gone")
	Assert.isFalse(sim:removeCombatant("a"), "already gone")
end)

suite:case("combatant specs are validated", function(env)
	local sim = make(env)
	Assert.throws(function()
		sim:addCombatant({ id = "", team = "players" })
	end, "invalid id")
	sim:addCombatant({ id = "a", team = "players" })
	Assert.throws(function()
		sim:addCombatant({ id = "a", team = "players" })
	end, "duplicate id")
	Assert.throws(function()
		sim:addCombatant({
			id = "b",
			team = "players",
			base = { vigor = 0, might = 1, grace = 1, will = 1 },
		})
	end, "vigor must be")
	Assert.throws(function()
		sim:addCombatant({ id = "b", team = "players", position = { x = 0 / 0, y = 0, z = 0 } })
	end, "finite")
	local badActions: { [string]: ActionMachine.ActionDef } = {
		Attack = {
			kind = "Attack",
			windup = -1,
			active = 1,
			recovery = 1,
			cancelInto = {},
			cancelFromRecoveryFrame = 0,
		},
	}
	Assert.throws(function()
		sim:addCombatant({ id = "b", team = "players", actions = badActions })
	end, "windup must be")
	Assert.count(
		ActionMachine.validateDef(ActionMachine.DEFAULT_ACTIONS.Guard),
		0,
		"defaults valid"
	)
end)

return suite:cases()
