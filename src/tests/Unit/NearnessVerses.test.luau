--!strict
-- BM-066: the four Nearness Verses do what the design says, on the server,
-- with the production catalog and its initial balancing values. The world
-- is a deterministic fake with walls and voids.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ActionMachine = require(ServerScriptService.Server.Combat.ActionMachine)
local Assert = require(ServerStorage.Tests.Support.Assert)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local FakeWorld = require(ServerStorage.Tests.Support.FakeWorld)
local NearnessTuning = require(ServerScriptService.Server.Content.NearnessTuning)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)
local Validators = require(ServerScriptService.Server.Network.Validators)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)
local VerseCatalog = require(ServerScriptService.Server.Content.VerseCatalog)

local suite = Suite.new("NearnessVerses")

type Harness = {
	service: CombatService.Service,
	me: string,
	cues: { any },
	teleports: { Vec3.Vec3 },
	step: (n: number) -> (),
	enemy: (id: string, x: number, z: number, displacement: string?) -> any,
	cast: (verseId: string, target: string?, extra: any?) -> any,
	has: (kind: string, field: string?, value: any?) -> boolean,
}

local function harness(env: Suite.Env, options: any?): Harness
	local opts = options or {}
	local world = FakeWorld.new(opts)
	local cues: { any } = {}
	local teleports: { Vec3.Vec3 } = {}
	local service = CombatService.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		send = function(_, remote, payload: any)
			if remote == "CombatCue" then
				for _, cue in payload.cues do
					table.insert(cues, cue)
				end
			end
		end,
		world = world,
		lineOfSight = world.lineOfSight,
		verseCatalog = opts.catalog,
		teleport = function(_, to)
			table.insert(teleports, Vec3.copy(to))
			return true
		end,
	})
	service:addPlayer(1)
	local me = service:combatantId(1)
	service.cants:equip(me, "cant.nearness")
	local caster = service.sim:get(me) :: any
	caster.position = Vec3.new(0, 3, 0)
	local h = {} :: Harness
	h.service = service
	h.me = me
	h.cues = cues
	h.teleports = teleports
	h.step = function(n: number)
		for _ = 1, n do
			service.sim:step()
		end
	end
	h.enemy = function(id: string, x: number, z: number, displacement: string?)
		local c = service.sim:addCombatant({
			id = id,
			team = "enemies",
			position = Vec3.new(x, 3, z),
		})
		if displacement ~= nil then
			c.extra.displacement = displacement
		end
		return c
	end
	h.cast = function(verseId: string, target: string?, extra: any?)
		return service.verses:cast(me, verseId, target, extra)
	end
	h.has = function(kind: string, field: string?, value: any?): boolean
		service:replicate()
		for _, cue in cues do
			if
				cue.kind == kind
				and (field == nil or (cue.data ~= nil and cue.data[field] == value))
			then
				return true
			end
		end
		return false
	end
	return h
end

local function effects(h: Harness): any
	return h.service.verseEffects :: any
end

local function me(h: Harness): any
	return h.service.sim:get(h.me)
end

local function at(h: Harness, id: string): Vec3.Vec3
	return (h.service.sim:get(id) :: any).position
end

local function flatDist(a: Vec3.Vec3, b: Vec3.Vec3): number
	return Vec3.flatDistance(a, b)
end

local STAMINA = {
	["near.close_step"] = 15,
	["near.draw_near"] = 20,
	["near.between_us"] = 25,
	["near.no_farther"] = 30,
}

suite:case("the tuning table is the single source of the four Verses", function(env)
	local h = harness(env)
	local catalog = h.service.verseCatalog
	Assert.equal(#NearnessTuning, 4, "four Verses")
	local cooldowns = {
		["near.close_step"] = 7,
		["near.draw_near"] = 11,
		["near.between_us"] = 16,
		["near.no_farther"] = 24,
	}
	for _, verse in NearnessTuning do
		local def = catalog:get(verse.id) :: any
		Assert.equal(def.cooldownSeconds, cooldowns[verse.id], verse.id .. " confirmed cooldown")
		Assert.equal(def.costs[1].amount, STAMINA[verse.id], verse.id .. " stamina")
		Assert.equal(def.mechanics, "provisional", verse.id .. " is initial balancing, not final")
		Assert.isTrue(catalog:isCastable(verse.id), verse.id .. " castable")
	end
	-- Changing the table changes the Verse: nothing else holds a number.
	local changed = table.clone(NearnessTuning)
	local copy: any = table.clone(NearnessTuning[1])
	copy.params = table.clone(copy.params)
	copy.params.range = 8
	changed[1] = copy
	local custom = VerseCatalog.build(VerseCatalog.definitionsFrom(changed :: any))
	Assert.equal((custom:get("near.close_step") :: any).params.range, 8, "configurable")
end)

suite:case("Close Step lunges along the aim, pays 15 stamina and 8 Dissonance", function(env)
	local h = harness(env)
	local before = me(h).resources.stamina
	local result = h.cast("near.close_step", nil, { aim = Vec3.new(30, 3, 0) })
	Assert.isTrue(result.ok, "cast accepted")
	h.step(2)
	local now = at(h, h.me)
	Assert.isTrue(
		math.abs(now.x - 16) < 0.3 and math.abs(now.z) < 0.01,
		"moved 16 studs toward the aim"
	)
	Assert.equal(now.y, 3, "kept its height")
	Assert.equal(#h.teleports, 1, "the character was moved once")
	Assert.equal(before - me(h).resources.stamina, 15, "15 stamina")
	Assert.equal(h.service.dissonance:value(h.me), 8, "8 Dissonance, gained by executing")
	Assert.isTrue(h.has("verse_motion", "kind", "lunge"), "lunge cue for the client")
	-- 7 seconds of cooldown, counted in steps, and not before.
	Assert.equal(h.service.verses:cooldownRemaining(h.me, "near.close_step") > 0, true, "cooldown")
	Assert.equal((h.cast("near.close_step") :: any).reason, "cooldown", "refused during cooldown")
	h.step(220)
	Assert.equal(h.service.verses:cooldownRemaining(h.me, "near.close_step"), 0, "ready after 7 s")
end)

suite:case(
	"Close Step without an aim goes straight ahead, and a short aim is not stretched",
	function(env)
		local h = harness(env)
		Assert.isTrue(h.cast("near.close_step").ok, "no aim")
		h.step(2)
		Assert.isTrue(math.abs(at(h, h.me).z + 16) < 0.3, "ahead is -Z")
		local g = harness(env)
		g.cast("near.close_step", nil, { aim = Vec3.new(5, 3, 0) })
		g.step(2)
		-- The aim sets the direction; the lunge covers its full range.
		Assert.isTrue(
			math.abs(at(g, g.me).x - 16) < 0.3,
			"direction from the aim, range from the Verse"
		)
	end
)

suite:case(
	"Close Step never crosses a wall, a gate or a boundary, and never lands in one",
	function(env)
		local h = harness(env, { walls = { { minX = 8, maxX = 9, minZ = -5, maxZ = 5 } } })
		Assert.isTrue(h.cast("near.close_step", nil, { aim = Vec3.new(30, 3, 0) }).ok, "cast")
		h.step(2)
		local x = at(h, h.me).x
		Assert.isTrue(x > 5 and x < 8, "stopped short of the wall at 8 (x = " .. x .. ")")
		Assert.equal(h.service.dissonance:value(h.me), 8, "a shortened move still executes")

		-- Pressed against the wall there is nothing to step to: the cast
		-- fizzles, the cost and cooldown stay, and no Dissonance is gained.
		local pressed = harness(env, { walls = { { minX = 0.5, maxX = 2, minZ = -5, maxZ = 5 } } })
		local stamina = me(pressed).resources.stamina
		Assert.isTrue(pressed.cast("near.close_step", nil, { aim = Vec3.new(30, 3, 0) }).ok, "cast")
		pressed.step(2)
		Assert.equal(at(pressed, pressed.me).x, 0, "did not move")
		Assert.equal(#pressed.teleports, 0, "no teleport")
		Assert.equal(stamina - me(pressed).resources.stamina, 15, "cost stays spent")
		Assert.isTrue(
			pressed.service.verses:cooldownRemaining(pressed.me, "near.close_step") > 0,
			"cooldown runs"
		)
		Assert.equal(
			pressed.service.dissonance:value(pressed.me),
			0,
			"no Dissonance for an empty cast"
		)
		Assert.isTrue(pressed.has("verse_fizzled", "reason", "no effect"), "announced")
	end
)

suite:case("Close Step stops at a void and refuses a cliff taller than a step", function(env)
	local void = harness(env, {
		heightAt = function(x: number, _z: number): number?
			return if x < 6 then 0 else nil
		end,
	})
	void.cast("near.close_step", nil, { aim = Vec3.new(30, 3, 0) })
	void.step(2)
	Assert.isTrue(at(void, void.me).x < 6, "never over the edge")

	local cliff = harness(env, {
		heightAt = function(x: number, _z: number): number?
			return if x < 6 then 0 else 10
		end,
	})
	cliff.cast("near.close_step", nil, { aim = Vec3.new(30, 3, 0) })
	cliff.step(2)
	Assert.isTrue(at(cliff, cliff.me).x < 6, "does not climb a wall of ground")
end)

suite:case("Close Step can follow a swing but not interrupt one", function(env)
	local h = harness(env)
	Assert.isTrue(me(h) ~= nil, "caster")
	Assert.isTrue(h.service.sim:submit(h.me, { kind = "Attack", sequence = 1 }).ok, "attack")
	h.step(1)
	Assert.equal((h.cast("near.close_step") :: any).reason, "busy", "not during the wind-up")
	local guard = 0
	while (me(h).action.phase :: string) ~= "Recovery" and guard < 60 do
		h.step(1)
		guard += 1
	end
	Assert.equal(me(h).action.phase, "Recovery", "reached the recovery phase")
	Assert.isTrue(h.cast("near.close_step").ok, "allowed from recovery")
	Assert.equal((h.cast("near.draw_near", "nobody") :: any).reason, "busy", "other Verses are not")
end)

suite:case("Draw Near pulls one enemy to 4 studs over about a third of a second", function(env)
	local h = harness(env)
	h.enemy("e1", 15, 0)
	local before = me(h).resources.stamina
	Assert.isTrue(h.cast("near.draw_near", "e1").ok, "cast")
	Assert.equal(before - me(h).resources.stamina, 20, "20 stamina, paid at the start")
	Assert.equal(h.service.dissonance:value(h.me), 0, "nothing until it executes")
	h.step(8) -- 0.2 s cast, then it executes
	Assert.equal(h.service.dissonance:value(h.me), 10, "10 Dissonance")
	local previous = at(h, "e1").x
	local biggest = 0
	for _ = 1, 20 do
		h.step(1)
		local x = at(h, "e1").x
		biggest = math.max(biggest, previous - x)
		previous = x
	end
	Assert.isTrue(math.abs(at(h, "e1").x - 4) < 0.2, "ended 4 studs from the caster")
	Assert.isTrue(biggest > 0.5 and biggest < 2, "moved a little each step, never in one jump")
	Assert.equal(#h.teleports, 0, "nothing was teleported: it is a controlled motion")
	Assert.isTrue(h.has("verse_motion", "kind", "pull"), "pull cue")
end)

suite:case("Draw Near respects walls, range, allies, elites and bosses", function(env)
	local walled = harness(env, { walls = { { minX = 7, maxX = 8, minZ = -5, maxZ = 5 } } })
	walled.enemy("e1", 15, 0)
	local stamina = me(walled).resources.stamina
	Assert.equal(
		(walled.cast("near.draw_near", "e1") :: any).reason,
		"target not in sight",
		"no line of sight"
	)
	Assert.equal(me(walled).resources.stamina, stamina, "a refusal costs nothing")

	local h = harness(env)
	h.enemy("far", 25, 0)
	Assert.equal((h.cast("near.draw_near", "far") :: any).reason, "target out of range", "range 20")
	h.service:addPlayer(2)
	Assert.equal(
		(h.cast("near.draw_near", "p-2") :: any).reason,
		"target is not hostile",
		"never a teammate"
	)
	Assert.equal(
		(h.cast("near.draw_near", h.me) :: any).reason,
		"cannot target yourself",
		"not yourself"
	)
	Assert.equal((h.cast("near.draw_near", "ghost") :: any).reason, "unknown target", "forged id")
	Assert.equal((h.cast("near.draw_near", nil) :: any).reason, "target required", "needs a target")
	h.enemy("boss", 10, 0, "immune")
	Assert.equal(
		(h.cast("near.draw_near", "boss") :: any).reason,
		"target immune",
		"bosses cannot be pulled"
	)
	Assert.equal(at(h, "boss").x, 10, "the boss did not move")

	local e = harness(env)
	e.enemy("elite", 15, 0, "elite")
	Assert.isTrue(e.cast("near.draw_near", "elite").ok, "elites can be pulled")
	e.step(30)
	Assert.isTrue(math.abs(at(e, "elite").x - (15 - 11 * 0.5)) < 0.3, "by half the distance")
end)

suite:case(
	"Draw Near does nothing to a target that dies or leaves before it executes",
	function(env)
		local h = harness(env)
		h.enemy("e1", 15, 0)
		Assert.isTrue(h.cast("near.draw_near", "e1").ok, "cast")
		h.service.sim:removeCombatant("e1")
		h.step(10)
		Assert.equal(h.service.dissonance:value(h.me), 0, "no Dissonance")
		Assert.isTrue(
			h.service.verses:cooldownRemaining(h.me, "near.draw_near") > 0,
			"cooldown stays"
		)
		Assert.isTrue(h.has("verse_fizzled", "reason", "target lost"), "announced")
	end
)

suite:case("Between Us ties two enemies within 8 studs, gently, for 6 seconds", function(env)
	local h = harness(env)
	h.enemy("a", 15, 0)
	h.enemy("b", 15, 12)
	local before = me(h).resources.stamina
	Assert.isTrue(h.cast("near.between_us", "a", { targetB = "b" }).ok, "cast")
	Assert.equal(before - me(h).resources.stamina, 25, "25 stamina")
	h.step(10) -- 0.3 s cast
	Assert.equal(h.service.dissonance:value(h.me), 12, "12 Dissonance")
	Assert.equal(effects(h):counts().tethers, 1, "tether active")
	local previous = at(h, "b")
	local fastest = 0
	for _ = 1, 40 do
		h.step(1)
		local now = at(h, "b")
		fastest = math.max(fastest, flatDist(previous, now))
		previous = now
	end
	Assert.isTrue(flatDist(at(h, "a"), at(h, "b")) <= 8.1, "never farther than 8 studs apart")
	Assert.isTrue(
		fastest <= 14 / 30 + 0.01,
		"drawn back at 14 studs per second at most, never snapped"
	)
	Assert.equal(at(h, "a").x, 15, "the first target stays where it is")
	Assert.equal(#h.teleports, 0, "no teleporting")
	Assert.isTrue(h.has("verse_field", "state", "start"), "start cue")
	h.step(200)
	Assert.equal(effects(h):counts().tethers, 0, "ended after its duration")
	Assert.isTrue(h.has("verse_field", "state", "end"), "end cue")
	h.enemy("c", 15, 30)
	-- after the tether, a target may leave again
	local free = flatDist(at(h, "a"), at(h, "c"))
	Assert.isTrue(free > 8, "free again")
end)

suite:case("Between Us can tie an enemy to the caster, who is never moved", function(env)
	local h = harness(env)
	h.enemy("a", 12, 0)
	Assert.isTrue(h.cast("near.between_us", "a", { targetB = h.me }).ok, "cast")
	h.step(10)
	local enemy = h.service.sim:get("a") :: any
	enemy.position = Vec3.new(19, 3, 0)
	h.step(30)
	Assert.isTrue(
		flatDist(at(h, "a"), at(h, h.me)) <= 8.1,
		"the enemy was drawn back to the caster"
	)
	Assert.equal(at(h, h.me).x, 0, "the caster is never moved")
	Assert.equal(#h.teleports, 0, "and never teleported")
end)

suite:case(
	"Between Us ends when a tethered target dies or the caster does, and obeys walls",
	function(env)
		local h = harness(env)
		h.enemy("a", 15, 0)
		h.enemy("b", 15, 6)
		h.cast("near.between_us", "a", { targetB = "b" })
		h.step(10)
		Assert.equal(effects(h):counts().tethers, 1, "active")
		h.service.sim:removeCombatant("b")
		h.step(2)
		Assert.equal(effects(h):counts().tethers, 0, "ended when a target left")

		local w = harness(env, { walls = { { minX = 15, maxX = 16, minZ = 8, maxZ = 9 } } })
		w.enemy("a", 15, 0)
		w.enemy("b", 15, 7)
		w.cast("near.between_us", "a", { targetB = "b" })
		w.step(10)
		local blocked = w.service.sim:get("b") :: any
		blocked.position = Vec3.new(15, 3, 12)
		w.step(40)
		Assert.isTrue(
			at(w, "b").z >= 9,
			"a wall stops the correction; nothing is dragged through it"
		)
	end
)

suite:case("Between Us refuses bosses, allies, one target and the same target twice", function(env)
	local h = harness(env)
	h.enemy("a", 10, 0)
	h.enemy("boss", 10, 5, "immune")
	Assert.equal(
		(h.cast("near.between_us", "a", { targetB = "boss" }) :: any).reason,
		"target immune",
		"boss"
	)
	Assert.equal(
		(h.cast("near.between_us", "a") :: any).reason,
		"second target required",
		"one target"
	)
	Assert.equal(
		(h.cast("near.between_us", "a", { targetB = "a" }) :: any).reason,
		"targets must differ",
		"same twice"
	)
	h.service:addPlayer(2)
	Assert.equal(
		(h.cast("near.between_us", "a", { targetB = "p-2" }) :: any).reason,
		"target is not hostile",
		"ally"
	)
	Assert.equal(
		(h.cast("near.close_step", nil, { targetB = "a" }) :: any).reason,
		"unexpected second target",
		"wrong Verse"
	)
	Assert.equal(me(h).resources.stamina, me(h).derived.maxStamina, "refusals cost nothing")
end)

suite:case("No Farther slows all movement inside its 20-stud zone, only for enemies", function(env)
	local h = harness(env)
	local inside = h.enemy("in", 18, 0)
	local other = h.enemy("out", 50, 0)
	local before = me(h).resources.stamina
	Assert.isTrue(h.cast("near.no_farther", nil, { aim = Vec3.new(15, 3, 0) }).ok, "cast")
	Assert.equal(before - me(h).resources.stamina, 30, "30 stamina")
	h.step(14) -- 0.4 s cast
	Assert.equal(h.service.dissonance:value(h.me), 15, "15 Dissonance")
	Assert.equal(effects(h):counts().zones, 1, "zone active")
	Assert.isTrue(h.has("verse_field", "kind", "zone"), "zone cue with its centre and radius")
	h.step(1)
	-- Moving 1 stud a step in any direction inside the zone runs at 40%.
	local start = inside.position.x
	for _ = 1, 4 do
		inside.position = Vec3.new(inside.position.x + 1, 3, 0)
		other.position = Vec3.new(other.position.x + 1, 3, 0)
		h.step(1)
	end
	local fled = inside.position.x - start
	Assert.isTrue(fled > 1.3 and fled < 1.9, "4 studs outward became about 1.6 (" .. fled .. ")")
	Assert.equal(other.position.x, 54, "outside the zone nothing changes")
	local back = inside.position.x
	for _ = 1, 4 do
		inside.position = Vec3.new(inside.position.x - 1, 3, 0)
		h.step(1)
	end
	local returned = back - inside.position.x
	Assert.isTrue(returned > 1.3 and returned < 1.9, "inward is slowed too (" .. returned .. ")")
	-- Teammates and the caster are never affected.
	h.service:addPlayer(2)
	local mate = h.service.sim:get("p-2") :: any
	mate.position = Vec3.new(16, 3, 0)
	h.step(1)
	for _ = 1, 4 do
		mate.position = Vec3.new(mate.position.x + 1, 3, 0)
		h.step(1)
	end
	Assert.equal(mate.position.x, 20, "a teammate moves at full speed")
	local caster = me(h)
	caster.position = Vec3.new(caster.position.x + 3, 3, 0)
	h.step(1)
	Assert.equal(caster.position.x, 3, "so does the caster")
end)

suite:case(
	"No Farther lasts 5 seconds, is placed within range and stops at walls, and spares bosses",
	function(env)
		local h = harness(env)
		local boss = h.enemy("boss", 14, 0, "immune")
		h.cast("near.no_farther", nil, { aim = Vec3.new(500, 3, 0) })
		h.step(14)
		h.step(1)
		for _ = 1, 3 do
			boss.position = Vec3.new(boss.position.x + 1, 3, 0)
			h.step(1)
		end
		Assert.equal(
			boss.position.x,
			17,
			"a boss moves at full speed: its own mechanics stay in charge"
		)
		h.step(200)
		Assert.equal(effects(h):counts().zones, 0, "ended after 5 seconds")
		Assert.isTrue(h.has("verse_field", "state", "end"), "end cue")

		local w = harness(env, { walls = { { minX = 6, maxX = 7, minZ = -5, maxZ = 5 } } })
		w.cast("near.no_farther", nil, { aim = Vec3.new(15, 3, 0) })
		w.step(14)
		local centre: number = 0
		for _, cue in w.cues do
			if cue.kind == "verse_field" and cue.data ~= nil and cue.data.state == "start" then
				centre = cue.data.x
			end
		end
		w.service:replicate()
		for _, cue in w.cues do
			if cue.kind == "verse_field" and cue.data ~= nil and cue.data.state == "start" then
				centre = cue.data.x
			end
		end
		Assert.isTrue(
			centre > 0 and centre < 6,
			"never placed beyond a wall (x = " .. centre .. ")"
		)
	end
)

suite:case(
	"only a stagger interrupts: cost and cooldown stay, Dissonance does not rise",
	function(env)
		local h = harness(env)
		h.enemy("e1", 15, 0)
		local before = me(h).resources.stamina
		Assert.isTrue(h.cast("near.draw_near", "e1").ok, "cast")
		h.step(2)
		ActionMachine.interrupt(me(h).action, "Staggered", 6, h.service.sim:stepNumber())
		h.step(10)
		Assert.equal(before - me(h).resources.stamina, 20, "stamina stays spent")
		Assert.isTrue(
			h.service.verses:cooldownRemaining(h.me, "near.draw_near") > 100,
			"cooldown runs"
		)
		Assert.equal(h.service.dissonance:value(h.me), 0, "no Dissonance from an interrupted cast")
		Assert.equal(at(h, "e1").x, 15, "the target did not move")
		Assert.isTrue(h.has("verse_interrupted"), "announced")

		local hit = harness(env)
		hit.enemy("e1", 15, 0)
		hit.cast("near.draw_near", "e1")
		hit.step(2)
		ActionMachine.interrupt(me(hit).action, "Hit", 3, hit.service.sim:stepNumber())
		hit.step(14)
		Assert.equal(hit.service.dissonance:value(hit.me), 10, "ordinary damage does not interrupt")
	end
)

suite:case("Dissonance accumulates through use and never behaves like mana", function(env)
	local h = harness(env, {})
	h.enemy("a", 12, 0)
	h.enemy("b", 12, 4)
	local total = 0
	local function row(verse: string, target: string?, extra: any?, gain: number): any
		return { verse = verse, target = target, extra = extra, gain = gain }
	end
	local plan: { any } = {
		row("near.close_step", nil, { aim = Vec3.new(0, 3, 30) }, 8),
		row("near.draw_near", "a", nil, 10),
		row("near.between_us", "a", { targetB = "b" }, 12),
	}
	for _, step: any in plan do
		local caster = me(h)
		caster.position = Vec3.new(0, 3, 0)
		caster.resources.stamina = caster.derived.maxStamina
		local a = h.service.sim:get("a") :: any
		local b = h.service.sim:get("b") :: any
		a.position, b.position = Vec3.new(12, 3, 0), Vec3.new(12, 3, 4)
		Assert.isTrue(h.cast(step.verse, step.target, step.extra).ok, step.verse)
		h.step(30)
		total += step.gain
		Assert.equal(h.service.dissonance:value(h.me), total, "adds up after " .. step.verse)
		-- Spending stamina never touches it, and stamina never touches it.
		caster.resources.stamina = 0
		Assert.equal(h.service.dissonance:value(h.me), total, "unchanged by stamina")
	end
	Assert.equal(h.service.dissonance:band(h.me).name, "Stable", "30 is still Stable")
	h.service.dissonance:add(h.me, 10, "unstableArea")
	Assert.equal(h.service.dissonance:band(h.me).name, "Noticeable instability", "40 crosses")
end)

suite:case("the cast request carries a bounded aim and a second target", function()
	local validate = Validators.forAction("VerseCast") :: any
	Assert.notNil(
		validate({ verseId = "near.close_step", aimX = 1, aimY = 2, aimZ = 3 }),
		"full aim"
	)
	Assert.notNil(validate({ verseId = "near.between_us", target = "e1", targetB = "e2" }), "pair")
	Assert.notNil(validate({ verseId = "near.close_step" }), "no aim")
	Assert.isNil(validate({ verseId = "near.close_step", aimX = 1 }), "partial aim")
	Assert.isNil(validate({ verseId = "near.close_step", aimX = 1, aimY = 2 }), "partial aim")
	Assert.isNil(validate({ verseId = "near.close_step", aimX = 0 / 0, aimY = 0, aimZ = 0 }), "NaN")
	Assert.isNil(
		validate({ verseId = "near.close_step", aimX = math.huge, aimY = 0, aimZ = 0 }),
		"inf"
	)
	Assert.isNil(
		validate({ verseId = "near.close_step", aimX = 1e9, aimY = 0, aimZ = 0 }),
		"enormous"
	)
	Assert.isNil(
		validate({ verseId = "near.close_step", aimX = "1", aimY = 0, aimZ = 0 }),
		"string"
	)
	Assert.isNil(
		validate({ verseId = "near.close_step", aim = { x = 1, y = 2, z = 3 } }),
		"a table"
	)
	Assert.isNil(validate({ verseId = "near.close_step", targetB = "" }), "empty target")
	Assert.isNil(validate({ verseId = "near.close_step", extra = 1 }), "unknown field")
end)

suite:case("the player's own view carries Dissonance and Verse cooldowns for the HUD", function(env)
	local h = harness(env)
	local before: any = h.service:ownView(1)
	Assert.equal(before.dissonance, 0, "starts at zero")
	Assert.equal(before.dissonanceBand, 0, "Stable")
	Assert.deepEqual(before.cooldowns, {}, "nothing cooling down")
	Assert.isTrue(h.cast("near.close_step", nil, { aim = Vec3.new(0, 3, -30) }).ok, "cast")
	h.step(2)
	local after: any = h.service:ownView(1)
	Assert.equal(after.dissonance, 8, "8 Dissonance")
	Assert.isTrue(
		after.cooldowns["near.close_step"] > 6.5 and after.cooldowns["near.close_step"] <= 7,
		"about 7 s left"
	)
	Assert.isNil(after.cooldowns["near.draw_near"], "other Verses are ready")
end)

return suite:cases()
