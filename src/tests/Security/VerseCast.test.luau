--!strict
-- BM-067: VerseCast through the dispatcher. Cast spam, forged targets,
-- incompatible Cants, locked Verses, costs and interruption. Invalid casts
-- produce no effects. Uses the shared fixture catalogs (test IDs only).

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local ClientHello = require(ServerScriptService.Server.Network.Adapters.ClientHello)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local ContentFixtures = require(ServerStorage.Tests.Support.ContentFixtures)
local Dispatcher = require(ServerScriptService.Server.Network.Dispatcher)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local RateLimiter = require(ServerScriptService.Server.Network.RateLimiter)
local Session = require(ServerScriptService.Server.Network.Session)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)
local VerseCast = require(ServerScriptService.Server.Network.Adapters.VerseCast)

local suite = Suite.new("VerseCast")

type Harness = {
	send: (payload: unknown, spaced: boolean?) -> { [string]: any },
	combat: CombatService.Service,
	effects: { string },
	cues: { any },
	me: string,
	profile: any,
}

local function pos(x: number, y: number, z: number)
	return { x = x, y = y, z = z }
end

local function lastReason(env: Suite.Env, category: string?): string
	local events = env.logged((category or "gameplay") :: any, "request_rejected")
	local last = events[#events]
	return if last ~= nil then tostring(last.fields.reason) else ""
end

-- Player 1 owns cant.ta (with ta.v1) and cant.tc (with tc.v1),
-- has cant.ta equipped, and stands at the origin.
local function harness(env: Suite.Env): Harness
	local cantCatalog, verseCatalog = ContentFixtures.catalogs()
	local effects: { string } = {}
	local cues: { any } = {}
	local function record(ctx: any)
		table.insert(
			effects,
			ctx.verseId .. ">" .. (if ctx.target ~= nil then ctx.target.id else "none")
		)
	end
	local combat = CombatService.new({
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
		cantCatalog = cantCatalog,
		verseCatalog = verseCatalog,
		verseEffects = { ["ta.v1"] = record, ["tc.v1"] = record },
	})
	local profile: any = ProfileSchema.default()
	profile.cants.unlocked = { ["cant.ta"] = true, ["cant.tc"] = true }
	profile.cants.verses =
		{ ["cant.ta"] = { ["ta.v1"] = true }, ["cant.tc"] = { ["tc.v1"] = true } }
	local profiles = {
		profileFor = function(_, userId: number)
			return if userId == 1 then profile else nil
		end,
	}
	local epoch: string? = nil
	local sessions = Session.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		sendEpoch = function(_, e)
			epoch = e
		end,
	})
	local dispatcher = Dispatcher.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		sessions = sessions,
		limiter = RateLimiter.new({ clock = env.clock }),
	})
	dispatcher:register(ClientHello.new({ sessions = sessions, clock = env.clock }))
	dispatcher:register(VerseCast.new({ profiles = profiles, combat = combat } :: any))
	local player: Session.PlayerLike = { UserId = 1, Name = "player1" }
	local seq = 0
	local function request(action: string, payload: unknown): { [string]: any }
		seq += 1
		return dispatcher:handle(player, {
			v = 1,
			requestId = "req-" .. seq,
			sessionEpoch = epoch,
			seq = seq,
			action = action,
			payload = payload,
		}) :: any
	end
	sessions:onPlayerAdded(player)
	epoch = request("ClientHello", { protocolVersion = 1 }).data.sessionEpoch
	sessions:markProfileLoaded(player, true)
	combat:addPlayer(1)
	local me = combat:combatantId(1)
	Assert.isTrue(combat.cants:equip(me, "cant.ta").ok, "equip cant.ta")
	return {
		send = function(payload: unknown, spaced: boolean?)
			if spaced ~= false then
				env.clock:advance(1)
			end
			return request("VerseCast", payload)
		end,
		combat = combat,
		effects = effects,
		cues = cues,
		me = me,
		profile = profile,
	}
end

local function steps(h: Harness, n: number)
	for _ = 1, n do
		h.combat.sim:step()
	end
end

local function enemy(h: Harness, id: string, at: { x: number, y: number, z: number })
	h.combat:spawnEnemy({
		id = id,
		position = at,
		profile = {
			aggroRange = 1,
			attackRange = 1,
			leashRange = 40,
			maxPathFailures = 3,
			attackCooldownSteps = 3000,
			attackJitterSteps = 0,
			repathSteps = 10,
		},
	})
end

suite:case("a valid cast spends its cost, waits its cast time and resolves once", function(env)
	local h = harness(env)
	enemy(h, "e", pos(0, 0, -10))
	local me = h.combat.sim:get(h.me) :: any
	local stamina = me.resources.stamina
	local result = h.send({ verseId = "ta.v1", target = "e" })
	Assert.equal(result.status, "OK", tostring(result.message))
	Assert.equal(result.data.resolveStep, h.combat.sim:stepNumber() + 6, "cast time")
	Assert.equal(me.resources.stamina, stamina - 20, "cost spent at cast")
	steps(h, 5)
	Assert.equal(#h.effects, 0, "not yet")
	steps(h, 1)
	Assert.deepEqual(h.effects, { "ta.v1>e" }, "resolved on the server with the verified target")
	steps(h, 10)
	Assert.equal(#h.effects, 1, "exactly once")
end)

suite:case("cast spam: already casting, cooldown and the rate class", function(env)
	local h = harness(env)
	Assert.equal(h.send({ verseId = "ta.v1" }).status, "OK", "first")
	Assert.equal(h.send({ verseId = "ta.v1" }).status, "REJECTED", "second")
	Assert.equal(lastReason(env), "already casting", "reason")
	steps(h, 6)
	Assert.equal(#h.effects, 1, "resolved")
	Assert.equal(h.send({ verseId = "ta.v1" }).status, "REJECTED", "cooldown")
	Assert.equal(lastReason(env), "cooldown", "reason")
	Assert.equal(#h.effects, 1, "no extra effect")
	local limited = 0
	for _ = 1, 20 do
		if h.send({ verseId = "ta.v1" }, false).status == "RATE_LIMITED" then
			limited += 1
		end
	end
	Assert.isTrue(limited > 0, "burst spam is rate limited")
	steps(h, 40)
	Assert.equal(#h.effects, 1, "spam produced no effects")
end)

suite:case("forged targets are verified and refused", function(env)
	local h = harness(env)
	enemy(h, "far", pos(0, 0, -100))
	enemy(h, "dead", pos(0, 0, -5))
	h.combat.sim:damage("dead", 100000)
	local cases = {
		{ target = "nobody", reason = "unknown target" },
		{ target = h.me, reason = "cannot target yourself" },
		{ target = "far", reason = "target out of range" },
		{ target = "dead", reason = "target is dead" },
	}
	local me = h.combat.sim:get(h.me) :: any
	local stamina = me.resources.stamina
	for _, c in cases do
		Assert.equal(h.send({ verseId = "ta.v1", target = c.target }).status, "REJECTED", c.target)
		Assert.equal(lastReason(env), c.reason, c.target)
	end
	Assert.equal(me.resources.stamina, stamina, "nothing spent")
	steps(h, 10)
	Assert.equal(#h.effects, 0, "no effects")
end)

suite:case("an incompatible equipped Cant refuses the Verse", function(env)
	local h = harness(env)
	Assert.equal(h.send({ verseId = "tc.v1" }).status, "REJECTED", "cant.ta equipped")
	Assert.equal(lastReason(env), "incompatible cant", "reason")
	h.combat.cants:equip(h.me, nil)
	Assert.equal(h.send({ verseId = "tc.v1" }).status, "REJECTED", "nothing equipped")
	Assert.equal(lastReason(env), "no cant equipped", "reason")
	h.combat.cants:equip(h.me, "cant.tc")
	Assert.equal(h.send({ verseId = "tc.v1" }).status, "OK", "compatible now")
	steps(h, 1)
	Assert.deepEqual(h.effects, { "tc.v1>none" }, "instant cast resolves next step")
end)

suite:case("locked, unknown and malformed Verses never cast", function(env)
	local h = harness(env)
	Assert.equal(h.send({ verseId = "ta.v2" }).status, "UNAUTHORIZED", "not unlocked")
	Assert.equal(lastReason(env, "security"), "verse not unlocked", "security log")
	Assert.equal(h.send({ verseId = "none.invented" }).status, "REJECTED", "undefined")
	Assert.equal(lastReason(env), "unknown verse", "reason")
	for _, payload in
		{
			{ verseId = "cant.ta" },
			{ verseId = "Verse TA1" },
			{ verseId = 5 },
			{},
			{ verseId = "ta.v1", target = "" },
			{ verseId = "ta.v1", damage = 999 },
		} :: { any }
	do
		Assert.equal(h.send(payload).status, "BAD_PAYLOAD", "shape")
	end
	h.profile.cants.unlocked["cant.ta"] = nil
	Assert.equal(h.send({ verseId = "ta.v1" }).status, "UNAUTHORIZED", "Cant revoked")
	steps(h, 20)
	Assert.equal(#h.effects, 0, "no effects")
end)

suite:case("an unaffordable cast spends nothing and starts no cooldown", function(env)
	local h = harness(env)
	local me = h.combat.sim:get(h.me) :: any
	me.resources.stamina = 19
	Assert.equal(h.send({ verseId = "ta.v1" }).status, "REJECTED", "poor")
	Assert.equal(lastReason(env), "cannot afford", "reason")
	Assert.equal(me.resources.stamina, 19, "unchanged")
	Assert.equal(h.combat.verses:cooldownRemaining(h.me, "ta.v1"), 0, "no cooldown")
end)

suite:case("being hit interrupts a cast: no effect, costs and cooldown stay", function(env)
	local h = harness(env)
	local me = h.combat.sim:get(h.me) :: any
	local stamina = me.resources.stamina
	Assert.equal(h.send({ verseId = "ta.v1" }).status, "OK", "cast")
	steps(h, 2)
	-- A hit interrupts through the damage layer's hit stun.
	local ActionMachine = require(ServerScriptService.Server.Combat.ActionMachine)
	ActionMachine.interrupt(me.action, "Hit", 6, h.combat.sim:stepNumber())
	steps(h, 10)
	Assert.equal(#h.effects, 0, "fizzled")
	Assert.equal(me.resources.stamina < stamina, true, "cost stays spent")
	Assert.isTrue(h.combat.verses:cooldownRemaining(h.me, "ta.v1") > 0, "cooldown runs")
	Assert.isNil(h.combat.verses:casting(h.me), "no cast pending")
	h.combat:replicate()
	local interrupted = false
	for _, cue in h.cues do
		if cue.kind == "verse_interrupted" and cue.data.verseId == "ta.v1" then
			interrupted = true
		end
	end
	Assert.isTrue(interrupted, "interruption announced")
end)

return suite:cases()
