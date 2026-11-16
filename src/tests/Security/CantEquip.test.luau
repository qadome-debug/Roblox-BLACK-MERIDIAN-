--!strict
-- BM-064: forged Cant, duplicate equip, invalid slot, ownership, busy
-- combatant, and refused saves. Equipment is server-owned profile state.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CantEquip = require(ServerScriptService.Server.Network.Adapters.CantEquip)
local ClientHello = require(ServerScriptService.Server.Network.Adapters.ClientHello)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local Dispatcher = require(ServerScriptService.Server.Network.Dispatcher)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local RateLimiter = require(ServerScriptService.Server.Network.RateLimiter)
local SaveQueue = require(ServerScriptService.Server.Persistence.SaveQueue)
local Session = require(ServerScriptService.Server.Network.Session)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("CantEquip")

type Harness = {
	send: (payload: unknown) -> { [string]: any },
	profile: () -> any,
	mutations: { string },
	refuseSaves: { value: boolean },
	combat: CombatService.Service,
}

local function lastReason(env: Suite.Env, category: string?): string
	local events = env.logged((category or "gameplay") :: any, "request_rejected")
	local last = events[#events]
	return if last ~= nil then tostring(last.fields.reason) else ""
end

local function harness(env: Suite.Env, owned: { string }): Harness
	local profile: any = ProfileSchema.default()
	for _, id in owned do
		profile.cants.unlocked[id] = true
		profile.cants.verses[id] = {}
	end
	local mutations: { string } = {}
	local refuseSaves = { value = false }
	local profiles = {
		profileFor = function(_, userId: number)
			return if userId == 1 then profile else nil
		end,
		mutate = function(_, _userId: number, mutation: SaveQueue.Mutation): (boolean, string?)
			if refuseSaves.value then
				return false, "save queue full"
			end
			local nextProfile = mutation.apply(profile)
			if nextProfile ~= nil then
				profile = nextProfile
			end
			table.insert(mutations, mutation.id)
			return true, nil
		end,
	}
	local combat = CombatService.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		send = function() end,
	})
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
	dispatcher:register(CantEquip.new({ profiles = profiles, combat = combat } :: any))

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
	local hello = request("ClientHello", { protocolVersion = 1 })
	epoch = hello.data.sessionEpoch
	sessions:markProfileLoaded(player, true)
	combat:addPlayer(1)

	return {
		send = function(payload: unknown)
			-- Space requests out so the cant rate class never interferes.
			env.clock:advance(1)
			return request("CantEquip", payload)
		end,
		profile = function()
			return profile
		end,
		mutations = mutations,
		refuseSaves = refuseSaves,
		combat = combat,
	}
end

suite:case("an owned Cant equips, saves and reaches the combat layer", function(env)
	local h = harness(env, { "cant-nearness" })
	local result = h.send({ slot = "primary", cantId = "cant-nearness" })
	Assert.equal(result.status, "OK", tostring(result.message))
	Assert.isTrue(result.data.changed, "changed")
	Assert.equal(h.profile().cants.equipped, "cant-nearness", "saved on the profile")
	Assert.deepEqual(h.mutations, { "cant-equip:cant-nearness" }, "one save queued")
	Assert.equal(h.combat.cants:equipped(h.combat:combatantId(1)), "cant-nearness", "mirrored")
	Assert.isTrue(ProfileSchema.isValid(h.profile()), "profile still valid")
	local off = h.send({ slot = "primary" })
	Assert.equal(off.status, "OK", "unequip")
	Assert.isNil(h.profile().cants.equipped, "cleared")
	Assert.isNil(h.combat.cants:equipped(h.combat:combatantId(1)), "cleared in combat")
end)

suite:case("forged and malformed Cant IDs never reach the adapter", function(env)
	local h = harness(env, { "cant-nearness" })
	for _, payload in
		{
			{ slot = "primary", cantId = "cant-invented" },
			{ slot = "primary", cantId = "Nearness" },
			{ slot = "primary", cantId = 7 },
			{ slot = "tertiary", cantId = "cant-nearness" },
			{ cantId = "cant-nearness" },
			{ slot = "primary", cantId = "cant-nearness", force = true },
		} :: { any }
	do
		Assert.equal(h.send(payload).status, "BAD_PAYLOAD", "refused at the validator")
	end
	Assert.equal(#h.mutations, 0, "nothing saved")
end)

suite:case("a Cant the player does not own is UNAUTHORIZED", function(env)
	local h = harness(env, {})
	local result = h.send({ slot = "primary", cantId = "cant-nearness" })
	Assert.equal(result.status, "UNAUTHORIZED", "not owned")
	Assert.equal(lastReason(env, "security"), "cant not owned", "logged as a security event")
	Assert.isNil(h.profile().cants.equipped, "nothing equipped")
	Assert.isNil(h.combat.cants:equipped(h.combat:combatantId(1)), "combat untouched")
end)

suite:case("duplicate equips and empty unequips are refused", function(env)
	local h = harness(env, { "cant-nearness" })
	Assert.equal(h.send({ slot = "primary", cantId = "cant-nearness" }).status, "OK", "first")
	Assert.equal(h.send({ slot = "primary", cantId = "cant-nearness" }).status, "REJECTED", "dup")
	Assert.equal(lastReason(env), "already equipped", "reason")
	Assert.equal(#h.mutations, 1, "only one save")
	Assert.equal(h.send({ slot = "primary" }).status, "OK", "unequip")
	Assert.equal(h.send({ slot = "primary" }).status, "REJECTED", "again")
	Assert.equal(lastReason(env), "nothing equipped", "reason")
end)

suite:case("a slot without saved state is refused", function(env)
	local h = harness(env, { "cant-nearness" })
	Assert.equal(
		h.send({ slot = "secondary", cantId = "cant-nearness" }).status,
		"REJECTED",
		"secondary"
	)
	Assert.equal(lastReason(env), "slot unavailable", "reason")
end)

suite:case("a combatant mid-action cannot swap Cants", function(env)
	local h = harness(env, { "cant-nearness" })
	local id = h.combat:combatantId(1)
	Assert.isTrue(h.combat.sim:submit(id, { kind = "Attack", sequence = 1 }).ok, "attack")
	h.combat.sim:step()
	Assert.equal(h.send({ slot = "primary", cantId = "cant-nearness" }).status, "REJECTED", "busy")
	Assert.equal(lastReason(env), "busy", "reason")
	Assert.isNil(h.profile().cants.equipped, "profile untouched")
end)

suite:case("a refused save rolls the combat layer back and commits nothing", function(env)
	local h = harness(env, { "cant-nearness" })
	h.refuseSaves.value = true
	local result = h.send({ slot = "primary", cantId = "cant-nearness" })
	Assert.equal(result.status, "INTERNAL", "save refused")
	Assert.isNil(h.profile().cants.equipped, "profile untouched")
	Assert.isNil(h.combat.cants:equipped(h.combat:combatantId(1)), "combat rolled back")
end)

return suite:cases()
