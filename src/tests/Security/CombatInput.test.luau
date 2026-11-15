--!strict
-- BM-061: CombatInput goes through the dispatcher and nothing else.
-- Input spam is rate limited, forged targets prove nothing, stale
-- sequences are refused, and malformed payloads never reach the service.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local ClientHello = require(ServerScriptService.Server.Network.Adapters.ClientHello)
local CombatInput = require(ServerScriptService.Server.Network.Adapters.CombatInput)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local Dispatcher = require(ServerScriptService.Server.Network.Dispatcher)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local RateLimiter = require(ServerScriptService.Server.Network.RateLimiter)
local Session = require(ServerScriptService.Server.Network.Session)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("CombatInput")

type Vec3 = { x: number, y: number, z: number }

type Harness = {
	dispatcher: Dispatcher.Dispatcher,
	combat: CombatService.Service,
	sessions: Session.Service,
	sent: { any },
	-- Sends a CombatInput for `userId` with the given payload.
	send: (userId: number, payload: { [string]: unknown }) -> { [string]: any },
	-- Joins a player: session, handshake, profile loaded, combatant.
	join: (userId: number, position: Vec3) -> (),
	tick: (steps: number) -> (),
}

local function pos(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

-- The dispatcher answers every rejection with a fixed client-safe message
-- (BM-019); the adapter.s reason is logged. Read the last one.
local function lastReason(env: Suite.Env): string
	local events = env.logged("gameplay", "request_rejected")
	local last = events[#events]
	return if last ~= nil then tostring(last.fields.reason) else ""
end

local function harness(env: Suite.Env): Harness
	local epochs: { [number]: string } = {}
	local sessions = Session.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		sendEpoch = function(player, epoch)
			epochs[player.UserId] = epoch
		end,
	})
	local poses: { [number]: CombatService.Pose } = {}
	local sent: { any } = {}
	local combat = CombatService.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		send = function(userId, remote, payload)
			table.insert(sent, { userId = userId, remote = remote, payload = payload })
		end,
		poseOf = function(userId)
			return poses[userId]
		end,
		replicateInterval = 1 / 30,
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
	dispatcher:register(CombatInput.new({ combat = combat }))

	local players: { [number]: Session.PlayerLike } = {}
	local seqs: { [number]: number } = {}
	local h = {} :: Harness
	h.dispatcher = dispatcher
	h.combat = combat
	h.sessions = sessions
	h.sent = sent

	local function request(userId: number, action: string, payload: unknown): { [string]: any }
		seqs[userId] = (seqs[userId] or 0) + 1
		return dispatcher:handle(players[userId], {
			v = 1,
			requestId = "req-" .. userId .. "-" .. seqs[userId],
			sessionEpoch = epochs[userId],
			seq = seqs[userId],
			action = action,
			payload = payload,
		}) :: any
	end

	h.join = function(userId: number, position: Vec3)
		local player: Session.PlayerLike = { UserId = userId, Name = "player" .. userId }
		players[userId] = player
		sessions:onPlayerAdded(player)
		local result = request(userId, "ClientHello", { protocolVersion = 1 })
		Assert.equal(result.status, "OK", "hello")
		epochs[userId] = result.data.sessionEpoch
		sessions:markProfileLoaded(player, true)
		poses[userId] = { position = position, facing = pos(0, 0, -1) }
		combat:addPlayer(userId)
	end

	h.send = function(userId: number, payload: { [string]: unknown }): { [string]: any }
		return request(userId, "CombatInput", payload)
	end

	h.tick = function(steps: number)
		for _ = 1, steps do
			combat:tick(1 / 30)
		end
	end
	return h
end

suite:case(
	"a valid attack is queued through the dispatcher and resolves in the simulation",
	function(env)
		local h = harness(env)
		h.join(1, pos(0, 0, 0))
		h.combat:spawnEnemy({
			id = "e",
			position = pos(0, 0, -3),
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
		local result = h.send(1, { kind = "Attack", sequence = 1 })
		Assert.equal(result.status, "OK", "queued: " .. tostring(result.message))
		Assert.isTrue(result.data.queued, "queued")
		Assert.equal(result.data.sequence, 1, "sequence echoed")
		h.tick(10)
		local e = h.combat.sim:get("e") :: any
		Assert.isTrue(e.resources.health < 200, "the swing landed through the simulation")
		Assert.equal((h.combat:ownView(1) :: any).ackSequence, 1, "acknowledged")
	end
)

suite:case("malformed payloads are BAD_PAYLOAD and never reach the service", function(env)
	local h = harness(env)
	h.join(1, pos(0, 0, 0))
	local bad: { { [string]: unknown } } = {
		{ kind = "Fireball", sequence = 1 },
		{ kind = "Attack", sequence = 0 },
		{ kind = "Attack", sequence = 1.5 },
		{ kind = "Attack", sequence = "1" },
		{ kind = "Attack", sequence = 1, target = "" },
		{ kind = "Attack", sequence = 1, target = string.rep("x", 65) },
		{ kind = "Attack", sequence = 1, clientTime = 0.5 },
		{ kind = "Lock", sequence = 1 },
		{ sequence = 1 },
	}
	for i, payload in bad do
		local result = h.send(1, payload)
		Assert.equal(
			result.status,
			"BAD_PAYLOAD",
			"payload " .. i .. ": " .. tostring(result.message)
		)
	end
	Assert.equal((h.combat:ownView(1) :: any).ackSequence, 0, "nothing reached the simulation")
	h.tick(1)
	Assert.equal((h.combat:ownView(1) :: any).state, "Idle", "idle")
end)

suite:case("stale sequences and illegal transitions are REJECTED with a fixed reason", function(env)
	local h = harness(env)
	h.join(1, pos(0, 0, 0))
	Assert.equal(h.send(1, { kind = "Attack", sequence = 5 }).status, "OK", "first")
	local stale = h.send(1, { kind = "Attack", sequence = 5 })
	Assert.equal(stale.status, "REJECTED", "duplicate")
	Assert.equal(lastReason(env), "stale sequence", "reason logged")
	Assert.equal(h.send(1, { kind = "Attack", sequence = 4 }).status, "REJECTED", "older")
	Assert.equal(
		h.send(1, { kind = "Dodge", sequence = 6 }).status,
		"OK",
		"queued, judged at the step"
	)
	h.tick(1)
	local own = h.combat:ownView(1) :: any
	Assert.equal(own.state, "Attacking", "the attack started")
	Assert.equal(own.ackSequence, 6, "the dodge was judged (and refused) at the step")
	local sawRejection = false
	for _, s in h.sent do
		if s.remote == "CombatCue" then
			for _, cue in s.payload.cues do
				if cue.kind == "intent_rejected" and cue.data.sequence == 6 then
					sawRejection = true
				end
			end
		end
	end
	Assert.isTrue(sawRejection, "the client is told privately")
end)

suite:case("input spam is rate limited by the combat class before the adapter runs", function(env)
	local h = harness(env)
	h.join(1, pos(0, 0, 0))
	local limit = Limits.RATE.combat.burst
	local ok, limited = 0, 0
	for i = 1, limit + 10 do
		local result = h.send(1, { kind = "Attack", sequence = i })
		if result.status == "OK" or result.status == "REJECTED" then
			ok += 1
		elseif result.status == "RATE_LIMITED" then
			limited += 1
		else
			error("unexpected status " .. tostring(result.status))
		end
	end
	Assert.equal(ok, limit, "burst admitted")
	Assert.equal(limited, 10, "the rest refused")
	-- The simulation only ever saw the admitted ones, and only a bounded
	-- number per step at that.
	h.tick(1)
	Assert.isTrue(
		(h.combat:ownView(1) :: any).ackSequence <= limit,
		"no spam leaked past the budget"
	)
end)

suite:case(
	"forged targets prove nothing: lock requests are validated and hits are found by the server",
	function(env)
		local h = harness(env)
		h.join(1, pos(0, 0, 0))
		h.join(2, pos(60, 0, 0))
		h.combat:spawnEnemy({
			id = "far",
			position = pos(0, 0, -20),
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
		-- Attack "at" a far target: the intent is queued (target is a hint),
		-- but no hit exists because nothing is in reach.
		Assert.equal(
			h.send(1, { kind = "Attack", sequence = 1, target = "far" }).status,
			"OK",
			"queued"
		)
		h.tick(25)
		Assert.equal((h.combat.sim:get("far") :: any).resources.health, 200, "untouched")
		-- Lock requests: ally, self, unknown, out of range are refused.
		h.send(1, { kind = "Lock", sequence = 2, target = "p-2" })
		Assert.equal(lastReason(env), "cannot target an ally", "ally")
		h.send(1, { kind = "Lock", sequence = 3, target = "p-1" })
		Assert.equal(lastReason(env), "cannot target yourself", "self")
		h.send(1, { kind = "Lock", sequence = 4, target = "nobody" })
		Assert.equal(lastReason(env), "unknown target", "unknown")
		h.send(2, { kind = "Lock", sequence = 1, target = "far" })
		Assert.equal(lastReason(env), "target out of range", "range")
		local lock = h.send(1, { kind = "Lock", sequence = 5, target = "far" })
		Assert.equal(lock.status, "OK", "in range from the origin")
		Assert.equal(lock.data.target, "far", "lock confirmed")
		Assert.isFalse(lock.data.queued, "not an intent")
		Assert.equal(
			h.send(1, { kind = "CycleTarget", sequence = 6 }).data.target,
			"far",
			"cycle keeps the only target"
		)
		Assert.equal(h.send(1, { kind = "Unlock", sequence = 7 }).status, "OK", "unlock")
		Assert.isNil((h.combat:ownView(1) :: any).target, "cleared")
		h.send(2, { kind = "CycleTarget", sequence = 2 })
		Assert.equal(lastReason(env), "no eligible target", "nothing near player 2")
	end
)

suite:case("without a combatant the action is NOT_READY, and leaving removes access", function(env)
	local h = harness(env)
	h.join(1, pos(0, 0, 0))
	h.combat:removePlayer(1)
	local result = h.send(1, { kind = "Attack", sequence = 1 })
	Assert.equal(result.status, "NOT_READY", "no combatant")
end)

return suite:cases()
