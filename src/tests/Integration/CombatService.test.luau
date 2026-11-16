--!strict
-- BM-060: CombatService owns the simulation, maps players to combatants,
-- feeds server-sampled poses, steps on the heartbeat and replicates only
-- what each client may see.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("CombatService")

type Vec3 = { x: number, y: number, z: number }

type Sent = { userId: number, remote: string, payload: any }

type Harness = {
	service: CombatService.Service,
	sent: { Sent },
	poses: { [number]: CombatService.Pose },
	failSend: { value: boolean },
}

local function pos(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

local function harness(env: Suite.Env): Harness
	local sent: { Sent } = {}
	local poses: { [number]: CombatService.Pose } = {}
	local failSend = { value = false }
	local service = CombatService.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		send = function(userId, remote, payload)
			if failSend.value then
				error("remote down")
			end
			local entry: Sent = { userId = userId, remote = remote, payload = payload }
			table.insert(sent, entry)
		end,
		poseOf = function(userId)
			return poses[userId]
		end,
		replicateInterval = 1 / 30,
	})
	return { service = service, sent = sent, poses = poses, failSend = failSend }
end

local function sentTo(h: Harness, userId: number, remote: string): { any }
	local out = {}
	for _, s in h.sent do
		if s.userId == userId and s.remote == remote then
			table.insert(out, s.payload)
		end
	end
	return out
end

suite:case(
	"players become combatants at their server-sampled pose and receive a full delta first",
	function(env)
		local h = harness(env)
		h.poses[1] = { position = pos(10, 0, 0), facing = pos(0, 0, -1) }
		h.service:addPlayer(1)
		h.service:addPlayer(1) -- idempotent
		Assert.isTrue(h.service:hasPlayer(1), "tracked")
		Assert.equal(h.service:combatantId(1), "p-1", "stable id")
		local c = h.service.sim:get("p-1")
		Assert.notNil(c, "combatant exists")
		Assert.equal((c :: any).position.x, 10, "spawned at the sampled pose")
		Assert.equal(h.service:tick(1 / 30), 1, "one step")
		local deltas = sentTo(h, 1, "StateDelta")
		Assert.count(deltas, 1, "one delta")
		Assert.isTrue(deltas[1].full, "full first")
		Assert.equal(deltas[1].own.id, "p-1", "own view attached")
		Assert.equal(deltas[1].own.health, 200, "exact own health")
		h.poses[1] = { position = pos(12, 0, 0), facing = pos(1, 0, 0) }
		h.service:tick(1 / 30)
		Assert.equal((c :: any).position.x, 12, "pose applied each tick from the server sample")
		Assert.equal((c :: any).facing.x, 1, "facing applied")
		Assert.isFalse(sentTo(h, 1, "StateDelta")[2].full, "then incremental")
	end
)

suite:case(
	"intents reach the simulation only for players in combat, and enemies fight back",
	function(env)
		local h = harness(env)
		h.poses[1] = { position = pos(0, 0, 0), facing = pos(0, 0, -1) }
		h.poses[2] = { position = pos(40, 0, 0), facing = pos(0, 0, -1) }
		h.service:addPlayer(1)
		h.service:addPlayer(2)
		h.service:spawnEnemy({ id = "e", position = pos(0, 0, -3), facing = pos(0, 0, 1) })
		Assert.isFalse(h.service:submit(9, { kind = "Attack", sequence = 1 }).ok, "not in combat")
		Assert.isTrue(h.service:submit(1, { kind = "Attack", sequence = 1 }).ok, "queued")
		Assert.isFalse(h.service:submit(1, { kind = "Attack", sequence = 1 }).ok, "stale")
		for _ = 1, 60 do
			h.service:tick(1 / 30)
		end
		local e = h.service.sim:get("e") :: any
		Assert.isTrue(e.resources.health < 200, "the player's swing landed")
		local p1 = h.service.sim:get("p-1") :: any
		Assert.isTrue(p1.resources.health < 200, "the enemy fought back without any client input")
		Assert.isTrue(h.service:engaged(1), "player 1 engaged")
		Assert.isFalse(h.service:engaged(2), "player 2 is a bystander")
		Assert.equal(h.service.ai:lootOwner("e"), "p-1", "loot owner tallied")

		-- Both viewers saw the public cues; only player 1 has an own view of p:1.
		local cues1 = sentTo(h, 1, "CombatCue")
		local cues2 = sentTo(h, 2, "CombatCue")
		Assert.isTrue(#cues1 > 0 and #cues2 > 0, "cues delivered to both")
		local sawDamage = false
		for _, batch in cues2 do
			for _, cue in batch.cues do
				if cue.kind == "damage" and cue.id == "e" then
					sawDamage = true
					Assert.isNil(cue.data.amount, "no amounts")
				end
			end
		end
		Assert.isTrue(sawDamage, "bystander saw the public outcome")
		local last2 = sentTo(h, 2, "StateDelta")
		Assert.equal(last2[#last2].own.id, "p-2", "own view is the viewer's")
		Assert.isTrue(h.service:requestTarget(1, "e").ok, "lock")
		Assert.equal((h.service:ownView(1) :: any).target, "e", "target in own view")
		Assert.isFalse(h.service:requestTarget(2, "p-1").ok, "cannot target an ally")
		Assert.isTrue(h.service:cycleTarget(2).ok == false, "nothing in range for the far player")
	end
)

suite:case(
	"leaving removes the combatant and stops replication; send failures are contained",
	function(env)
		local h = harness(env)
		h.poses[1] = { position = pos(0, 0, 0), facing = pos(0, 0, -1) }
		h.service:addPlayer(1)
		h.service:tick(1 / 30)
		h.service:removePlayer(1)
		h.service:removePlayer(1)
		Assert.isNil(h.service.sim:get("p-1"), "gone")
		local before = #h.sent
		h.service:tick(1 / 30)
		Assert.equal(#h.sent, before, "nothing sent to a player who left")
		Assert.isFalse(
			h.service:submit(1, { kind = "Attack", sequence = 1 }).ok,
			"no longer in combat"
		)

		h.service:addPlayer(2)
		h.failSend.value = true
		h.service:tick(1 / 30)
		Assert.isTrue(#env.logged("gameplay", "combat_send_failed") >= 1, "logged, not crashed")
		Assert.equal(h.service:tick(0 / 0), 0, "bad elapsed ignored")
		Assert.isTrue(h.service:despawnEnemy("nope") == false, "unknown enemy")
	end
)

suite:case("an equipped Cant activates on the server and its cue reaches everyone", function(env)
	local h = harness(env)
	h.poses[1] = { position = pos(0, 0, 0), facing = pos(0, 0, -1) }
	h.poses[2] = { position = pos(4, 0, 0), facing = pos(0, 0, -1) }
	h.service:addPlayer(1)
	h.service:addPlayer(2)
	local id = h.service:combatantId(1)
	Assert.isTrue(h.service.cants:equip(id, "cant-nearness").ok, "equip Nearness")
	Assert.isFalse(h.service.cants:equip(id, "cant-invented").ok, "fabricated Cant refused")
	Assert.isTrue(h.service.cants:activate(id).ok, "activate")
	Assert.isFalse(h.service.cants:activate(id).ok, "cooldown")
	for _ = 1, 3 do
		h.service:tick(1 / 30)
	end
	local seen = false
	for _, batch in sentTo(h, 2, "CombatCue") do
		for _, cue in batch.cues do
			if cue.kind == "cant_activated" and cue.id == id then
				Assert.equal(cue.data.cantId, "cant-nearness", "cant id replicated")
				Assert.isNil(cue.data.provisional, "internal flags are not replicated")
				seen = true
			end
		end
	end
	Assert.isTrue(seen, "the other player saw the activation")
	h.service:removePlayer(1)
	Assert.isNil(h.service.cants:equipped(id), "forgotten on leave")
end)

return suite:cases()
