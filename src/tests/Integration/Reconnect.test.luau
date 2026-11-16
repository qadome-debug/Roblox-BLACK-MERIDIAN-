--!strict
-- Full-stack reconnect: profile, sessions, dispatcher, CantEquip, combat
-- and loadout restore wired as Bootstrap wires them. A player equips a
-- Cant, leaves, and rejoins on the same store: the saved Cant is restored
-- into combat, the old session proves nothing, and the server view stays
-- the only truth.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local CantEquip = require(ServerScriptService.Server.Network.Adapters.CantEquip)
local ClientHello = require(ServerScriptService.Server.Network.Adapters.ClientHello)
local CombatService = require(ServerScriptService.Server.Services.CombatService)
local Config = require(ServerScriptService.Server.Config)
local Dispatcher = require(ServerScriptService.Server.Network.Dispatcher)
local Loadout = require(ServerScriptService.Server.Services.Loadout)
local ProfileService = require(ServerScriptService.Server.Services.ProfileService)
local RateLimiter = require(ServerScriptService.Server.Network.RateLimiter)
local Session = require(ServerScriptService.Server.Network.Session)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("Reconnect")

local SCOPE = Config.build("studio").dataStoreScope

type Server = {
	join: (userId: number) -> Session.PlayerLike,
	leave: (player: Session.PlayerLike) -> (),
	hello: (player: Session.PlayerLike) -> string,
	send: (player: Session.PlayerLike, epoch: string?, action: string, payload: unknown) -> any,
	combat: CombatService.Service,
	profiles: ProfileService.Service,
	epochs: { [number]: string },
}

-- One server process over the shared fake store, wired like Bootstrap.
local function server(env: Suite.Env, jobId: string): Server
	local epochs: { [number]: string } = {}
	local sessions = Session.new({
		clock = env.clock,
		rng = env.rng:fork(jobId .. "-s"),
		logger = env.logger,
		sendEpoch = function(player, epoch)
			epochs[player.UserId] = epoch
		end,
	})
	local restore: ((userId: number) -> ())? = nil
	local profiles = ProfileService.new({
		config = Config.build("studio"),
		clock = env.clock,
		rng = env.rng:fork(jobId),
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		markProfileLoaded = function(player, loaded)
			sessions:markProfileLoaded(player, loaded)
			if loaded and restore ~= nil then
				restore(player.UserId)
			end
		end,
		stores = {
			profiles = env.dataStores:GetDataStore(ProfileService.STORE_NAME, SCOPE) :: any,
			runs = env.dataStores:GetDataStore("DescentRuns", SCOPE) :: any,
			archives = env.dataStores:GetDataStore("ProfileReceiptArchive", SCOPE) :: any,
		},
		jobId = jobId,
		wait = function(seconds)
			env.clock:advance(seconds)
		end,
	})
	local combat = CombatService.new({
		clock = env.clock,
		rng = env.rng:fork(jobId .. "-c"),
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		send = function() end,
	})
	local function restoreNow(userId: number)
		Loadout.restore({ profiles = profiles, combat = combat, logger = env.logger }, userId)
	end
	restore = restoreNow
	local limiter = RateLimiter.new({ clock = env.clock })
	local dispatcher = Dispatcher.new({
		clock = env.clock,
		rng = env.rng:fork(jobId .. "-d"),
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		sessions = sessions,
		limiter = limiter,
	})
	dispatcher:register(ClientHello.new({ sessions = sessions, clock = env.clock }))
	dispatcher:register(CantEquip.new({ profiles = profiles, combat = combat } :: any))

	local seqs: { [Session.PlayerLike]: number } = {}
	local s = {} :: Server
	s.combat = combat
	s.profiles = profiles
	s.epochs = epochs

	s.send = function(player, epoch, action, payload)
		seqs[player] = (seqs[player] or 0) + 1
		env.clock:advance(1)
		return dispatcher:handle(player, {
			v = 1,
			requestId = jobId .. "-" .. player.UserId .. "-" .. seqs[player],
			sessionEpoch = epoch,
			seq = seqs[player],
			action = action,
			payload = payload,
		}) :: any
	end

	s.hello = function(player)
		local result = s.send(player, epochs[player.UserId], "ClientHello", { protocolVersion = 1 })
		Assert.equal(result.status, "OK", "hello")
		epochs[player.UserId] = result.data.sessionEpoch
		return result.data.sessionEpoch
	end

	-- Bootstrap order: session, character (combatant), then the profile
	-- finishes loading.
	s.join = function(userId)
		local player: Session.PlayerLike = { UserId = userId, Name = "p" .. userId }
		sessions:onPlayerAdded(player)
		combat:addPlayer(userId)
		restoreNow(userId)
		profiles:onPlayerAdded(player)
		return player
	end

	s.leave = function(player)
		profiles:onPlayerRemoving(player)
		combat:removePlayer(player.UserId)
		sessions:onPlayerRemoving(player)
		limiter:forget(player.UserId)
	end
	return s
end

local function grantNearness(s: Server, userId: number)
	local ok = s.profiles:mutate(
		userId,
		{
			id = "test-grant-nearness",
			apply = function(profile: any): any
				local nextProfile = table.clone(profile)
				nextProfile.cants = table.clone(profile.cants)
				nextProfile.cants.unlocked = { ["cant-nearness"] = true }
				nextProfile.cants.verses = { ["cant-nearness"] = {} }
				return nextProfile
			end,
		} :: any
	)
	Assert.isTrue(ok, "granted")
end

local NEARNESS = { slot = "primary", cantId = "cant-nearness" }

suite:case("an equipped Cant survives leaving and rejoining the same server", function(env)
	local s = server(env, "job-a")
	local p = s.join(1)
	local epoch = s.hello(p)
	grantNearness(s, 1)
	Assert.equal(s.send(p, epoch, "CantEquip", NEARNESS).status, "OK", "equip")
	local id = s.combat:combatantId(1)
	Assert.equal(s.combat.cants:equipped(id), "cant-nearness", "mirrored")
	s.leave(p)
	Assert.isFalse(s.combat:hasPlayer(1), "combatant gone")

	local again = s.join(1)
	Assert.equal(s.combat.cants:equipped(id), "cant-nearness", "restored from the profile")
	Assert.count(env.logged("gameplay", "loadout_restored"), 1, "logged once")
	Assert.isTrue(s.combat.cants:activate(id).ok, "activation works without re-equipping")
	local newEpoch = s.hello(again)
	Assert.notEqual(newEpoch, epoch, "a new session epoch")
	Assert.equal(
		s.send(again, epoch, "CantEquip", NEARNESS).status,
		"STALE_EPOCH",
		"old epoch refused"
	)
	Assert.equal(
		s.send(again, newEpoch, "CantEquip", NEARNESS).status,
		"REJECTED",
		"already equipped"
	)
	Assert.equal(s.send(again, newEpoch, "CantEquip", { slot = "primary" }).status, "OK", "unequip")
	Assert.isNil(s.combat.cants:equipped(id), "cleared")
end)

suite:case("the saved Cant follows the player to another server", function(env)
	local a = server(env, "job-a")
	local p = a.join(1)
	local epoch = a.hello(p)
	grantNearness(a, 1)
	Assert.equal(a.send(p, epoch, "CantEquip", NEARNESS).status, "OK", "equip on server a")
	a.leave(p)

	local b = server(env, "job-b")
	b.join(1)
	Assert.equal(
		b.combat.cants:equipped(b.combat:combatantId(1)),
		"cant-nearness",
		"server b restored it from the store"
	)
end)

suite:case("restore waits for both sides and never invents a loadout", function(env)
	local s = server(env, "job-a")
	local deps: Loadout.Deps =
		{ profiles = s.profiles, combat = s.combat, logger = env.logger } :: any
	Assert.equal(Loadout.restore(deps, 1), "notReady", "nobody joined")
	s.combat:addPlayer(1)
	Assert.equal(Loadout.restore(deps, 1), "notReady", "no profile yet")
	s.combat:removePlayer(1)
	local p = s.join(1)
	Assert.equal(Loadout.restore(deps, 1), "nothingEquipped", "fresh profile")
	Assert.isNil(s.combat.cants:equipped(s.combat:combatantId(1)), "nothing equipped")
	-- A combatant that is mid-action is not interrupted; the refusal is logged.
	grantNearness(s, 1)
	local epoch = s.hello(p)
	Assert.equal(s.send(p, epoch, "CantEquip", NEARNESS).status, "OK", "equip")
	local id = s.combat:combatantId(1)
	s.combat.cants:equip(id, nil)
	Assert.isTrue(s.combat.sim:submit(id, { kind = "Attack", sequence = 1 }).ok, "attack")
	s.combat.sim:step()
	Assert.equal(Loadout.restore(deps, 1), "refused", "busy")
	Assert.count(env.logged("gameplay", "loadout_restore_refused"), 1, "logged")
end)

return suite:cases()
