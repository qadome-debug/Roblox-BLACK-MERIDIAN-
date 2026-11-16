--!strict
-- BM-050 wiring: the player lifecycle from join to leave through the real
-- persistence stack, with the session gate.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Config = require(ServerScriptService.Server.Config)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local ProfileService = require(ServerScriptService.Server.Services.ProfileService)
local RewardCatalog = require(ServerScriptService.Server.Content.RewardCatalog)
local Session = require(ServerScriptService.Server.Network.Session)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("ProfileService")

local SCOPE = Config.build("studio").dataStoreScope

local CATALOG = RewardCatalog.build({
	{
		id = "reward-quest",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = 10 } },
	},
})

local function make(env: Suite.Env, jobId: string, environment: Config.Environment?)
	local sessions = Session.new({
		clock = env.clock,
		rng = env.rng:fork(jobId .. "-s"),
		logger = env.logger,
		sendEpoch = function() end,
	})
	local service = ProfileService.new({
		config = Config.build(environment or "studio"),
		clock = env.clock,
		rng = env.rng:fork(jobId),
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		markProfileLoaded = function(p, loaded)
			sessions:markProfileLoaded(p, loaded)
		end,
		stores = {
			profiles = env.dataStores:GetDataStore(ProfileService.STORE_NAME, SCOPE) :: any,
			runs = env.dataStores:GetDataStore("DescentRuns", SCOPE) :: any,
			archives = env.dataStores:GetDataStore("ProfileReceiptArchive", SCOPE) :: any,
		},
		jobId = jobId,
		catalog = CATALOG,
		wait = function(seconds)
			env.clock:advance(seconds)
		end,
	})
	return service, sessions
end

local function player(id: number): Session.PlayerLike
	return { UserId = id, Name = "p" .. id }
end

local function storeName(): string
	return ProfileService.STORE_NAME .. "/" .. Config.build("studio").dataStoreScope
end

suite:case(
	"join loads a profile, marks the session ready, and leave releases cleanly",
	function(env)
		local service, sessions = make(env, "job-a")
		local p = player(1)
		local session = sessions:onPlayerAdded(p)
		local entry = service:onPlayerAdded(p)
		Assert.equal(entry.state, "ready", "ready")
		Assert.isTrue(session.profileLoaded, "session knows the profile is loaded")
		Assert.notNil(env.dataStores:peek(storeName(), "p:1"), "stored under the scoped store")
		Assert.count(env.logged("persistence", "player_profile_ready"), 1, "logged")

		local result = service.rewards:grantPermanent(
			entry.target,
			{ kind = "quest", id = "quest-x" },
			"reward-quest"
		)
		Assert.equal(result.outcome, "granted", "rewards work through the service")

		service:onPlayerRemoving(p)
		Assert.isNil(service:get(p), "entry dropped")
		Assert.isFalse(session.profileLoaded, "session no longer loaded")
		local stored = env.dataStores:peek(storeName(), "p:1")
		Assert.equal(stored.lease.expiresAt, 0, "lease released")
		Assert.equal(stored.balances["currency-test"], 10, "data persisted")
		Assert.count(ProfileSchema.validate(stored), 0, "valid on disk")
	end
)

suite:case("a player whose profile is held elsewhere is read-only and gated", function(env)
	local other, otherSessions = make(env, "job-b")
	local pb = player(1)
	otherSessions:onPlayerAdded(pb)
	Assert.equal(other:onPlayerAdded(pb).state, "ready", "server b owns it")

	local service, sessions = make(env, "job-a")
	local p = player(1)
	local session = sessions:onPlayerAdded(p)
	local entry = service:onPlayerAdded(p)
	Assert.equal(entry.state, "readOnly", "read-only")
	Assert.equal(entry.reason, "leaseHeld", "reason")
	Assert.isFalse(session.profileLoaded, "gameplay stays gated")
	Assert.count(env.logged("persistence", "player_profile_readonly"), 1, "logged")
	service:onPlayerRemoving(p) -- must not touch the other server's lease
	Assert.notEqual(
		env.dataStores:peek(storeName(), "p:1").lease.expiresAt,
		0,
		"other server's lease intact"
	)
end)

suite:case(
	"a store outage yields failed, never a fabricated profile, and the session stays gated",
	function(env)
		local service, sessions = make(env, "job-a")
		local p = player(1)
		local session = sessions:onPlayerAdded(p)
		env.dataStores:injectFault({ kind = "timeout", times = 100 })
		local entry = service:onPlayerAdded(p)
		Assert.equal(entry.state, "failed", "failed")
		Assert.isFalse(session.profileLoaded, "gated")
		Assert.isNil(env.dataStores:peek(storeName(), "p:1"), "nothing written")
	end
)

suite:case("pending grants are recovered on join and reconciled on tick", function(env)
	local a = make(env, "job-a")
	local p = player(1)
	local entry = a:onPlayerAdded(p)
	-- Leave an intent behind: fault the grant write, then crash server a.
	env.dataStores:injectFault({ kind = "delay", operation = "UpdateAsync", seconds = 0 })
	env.dataStores:injectFault({ kind = "timeout", operation = "UpdateAsync" })
	local result =
		a.rewards:grantPermanent(entry.target, { kind = "quest", id = "quest-x" }, "reward-quest")
	Assert.equal(result.outcome, "pending", "owed")
	env.clock:advance(Lease.LIFETIME_SECONDS + 1)

	local b, sessionsB = make(env, "job-b")
	sessionsB:onPlayerAdded(p)
	local entryB = b:onPlayerAdded(p)
	Assert.equal(entryB.state, "ready", "taken over")
	local stored = env.dataStores:peek(storeName(), "p:1")
	Assert.equal(stored.balances["currency-test"], 10, "recovered on join")
	Assert.isNil(next(stored.receipts.pending), "no pending left")
	Assert.count(env.logged("telemetry", "reward_recovered"), 1, "recovery counted")

	-- Tick renews the lease and reconciles periodically.
	local before = stored.lease.expiresAt
	env.clock:advance(Lease.RENEWAL_INTERVAL_SECONDS + 1)
	b:tick()
	Assert.isTrue(
		env.dataStores:peek(storeName(), "p:1").lease.expiresAt > before,
		"lease renewed by tick"
	)
end)

suite:case("shutdown flushes and releases every player", function(env)
	local service, sessions = make(env, "job-a")
	for i = 1, 3 do
		sessions:onPlayerAdded(player(i))
		service:onPlayerAdded(player(i))
	end
	service:shutdown()
	for i = 1, 3 do
		Assert.equal(
			env.dataStores:peek(storeName(), "p:" .. i).lease.expiresAt,
			0,
			"player " .. i .. " released"
		)
		Assert.isNil(service:get(player(i)), "player " .. i .. " dropped")
	end
	Assert.count(env.logged("lifecycle", "profile_service_shutdown"), 1, "logged")
end)

suite:case("the test environment is read-only end to end", function(env)
	local service, sessions = make(env, "job-a", "test")
	local p = player(1)
	local session = sessions:onPlayerAdded(p)
	local entry = service:onPlayerAdded(p)
	Assert.equal(entry.state, "readOnly", "read-only mode")
	Assert.isFalse(session.profileLoaded, "gated")
	Assert.equal(env.dataStores:callCount("UpdateAsync"), 0, "no writes at all")
end)

suite:case("mutate changes the live profile, saves it, and refuses invalid results", function(env)
	local service, sessions = make(env, "job-a")
	local p = player(1)
	sessions:onPlayerAdded(p)
	service:onPlayerAdded(p)
	local function setEquipped(id: string?): any
		return {
			id = "test-equip:" .. tostring(id),
			apply = function(profile: any): any
				local nextProfile = table.clone(profile)
				nextProfile.cants = table.clone(profile.cants)
				nextProfile.cants.equipped = id
				return nextProfile
			end,
		}
	end
	local ok, reason = service:mutate(1, setEquipped("cant-nearness"))
	Assert.isFalse(ok, "equipping an unowned Cant fails the schema")
	Assert.equal(reason, "invalid profile", "reason")
	Assert.isNil((service:profileFor(1) :: any).cants.equipped, "live profile unchanged")

	local unlock = {
		id = "test-unlock",
		apply = function(profile: any): any
			local nextProfile = table.clone(profile)
			nextProfile.cants = table.clone(profile.cants)
			nextProfile.cants.unlocked = { ["cant-nearness"] = true }
			nextProfile.cants.verses = { ["cant-nearness"] = {} }
			return nextProfile
		end,
	}
	Assert.isTrue((service:mutate(1, unlock :: any)), "unlock")
	Assert.isTrue((service:mutate(1, setEquipped("cant-nearness"))), "equip")
	Assert.equal((service:profileFor(1) :: any).cants.equipped, "cant-nearness", "live")
	service:tick()
	Assert.equal(
		env.dataStores:peek(storeName(), "p:1").cants.equipped,
		"cant-nearness",
		"saved by the queue"
	)
	Assert.isFalse((service:mutate(2, unlock :: any)), "unknown player refused")
	service:onPlayerRemoving(p)
	Assert.isNil(service:profileFor(1), "gone after leave")
	local okAfter, why = service:mutate(1, unlock :: any)
	Assert.isFalse(okAfter, "refused after leave")
	Assert.equal(why, "profile not ready", "reason")
end)

return suite:cases()
