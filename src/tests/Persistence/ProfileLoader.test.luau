--!strict
-- BM-028: outage and corrupt-profile cases never produce a fabricated
-- default; the player gets ready, read-only, or failed.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local Migrations = require(ServerScriptService.Server.Persistence.Migrations)
local ProfileLoader = require(ServerScriptService.Server.Persistence.ProfileLoader)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("ProfileLoader")

local STORE = "Profiles"
local KEY = "player-1"

local function make(env: Suite.Env, jobId: string, readOnly: boolean?)
	local store = env.dataStores:GetDataStore(STORE) :: any
	local leases = Lease.new({
		clock = env.clock,
		rng = env.rng:fork(jobId),
		logger = env.logger,
		store = store,
		jobId = jobId,
	})
	local waits: { number } = {}
	local loader = ProfileLoader.new({
		clock = env.clock,
		logger = env.logger,
		leases = leases,
		store = store,
		migrator = Migrations.production(),
		wait = function(seconds)
			table.insert(waits, seconds)
			env.clock:advance(seconds)
		end,
		backoff = { 1, 2, 4 },
		maxAttempts = 4,
		readOnly = readOnly,
	})
	return loader, leases, waits
end

suite:case("a new player gets a fresh default profile and the lease", function(env)
	local loader = make(env, "job-a")
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "ready", "state")
	Assert.equal(loaded.reason, "ok", "reason")
	Assert.notNil(loaded.handle, "handle")
	Assert.deepEqual(
		(loaded.profile :: any).receipts,
		{ permanent = {}, seasonal = {}, pending = {} },
		"default receipts"
	)
	Assert.equal(
		(loaded.profile :: any).lease.sessionId,
		(loaded.handle :: any).lease.sessionId,
		"profile carries our lease"
	)
	Assert.equal(loaded.attempts, 1, "first try")
end)

suite:case("an existing profile is loaded, not replaced", function(env)
	local existing: any = ProfileSchema.default()
	existing.balances["currency-test"] = 77
	existing.revision = 5
	env.dataStores:seed(STORE, KEY, existing)
	local loader = make(env, "job-a")
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "ready", "state")
	Assert.equal((loaded.profile :: any).balances["currency-test"], 77, "data preserved")
	Assert.equal((loaded.profile :: any).revision, 5, "revision preserved")
end)

suite:case("a DataStore outage retries with backoff and ends failed, never default", function(env)
	local loader, _, waits = make(env, "job-a")
	env.dataStores:injectFault({ kind = "timeout", times = 100 })
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "failed", "state")
	Assert.equal(loaded.reason, "storeError", "reason")
	Assert.isNil(loaded.profile, "no profile")
	Assert.isNil(loaded.handle, "no handle")
	Assert.equal(loaded.attempts, 4, "all attempts used")
	Assert.deepEqual(waits, { 1, 2, 4 }, "exponential backoff between attempts")
	Assert.isNil(env.dataStores:peek(STORE, KEY), "nothing was written")
	Assert.count(env.logged("persistence", "profile_load_failed"), 1, "logged")
end)

suite:case("a transient outage recovers on a later attempt", function(env)
	local loader = make(env, "job-a")
	env.dataStores:injectFault({ kind = "budget", times = 2 })
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "ready", "recovered")
	Assert.equal(loaded.attempts, 3, "third attempt")
end)

suite:case("a lease held by a live server yields read-only with the stored data", function(env)
	local existing: any = ProfileSchema.default()
	existing.balances["currency-test"] = 9
	env.dataStores:seed(STORE, KEY, existing)
	local other, otherLeases = make(env, "job-b")
	Assert.equal(other:load(KEY).state, "ready", "other server owns it")
	Assert.count(otherLeases:held(), 1, "held by b")

	local loader = make(env, "job-a")
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "readOnly", "state")
	Assert.equal(loaded.reason, "leaseHeld", "reason")
	Assert.equal((loaded.profile :: any).balances["currency-test"], 9, "can still read the data")
	Assert.isNil(loaded.handle, "no handle: no writes")
end)

suite:case("a lease about to expire (teleport handoff) is waited for", function(env)
	local other, otherLeases = make(env, "job-b")
	other:load(KEY)
	local handle = otherLeases:held()[1]
	-- Simulate the departing server releasing just after we first look.
	env.clock:advance(Lease.LIFETIME_SECONDS - 1)
	local loader, _, waits = make(env, "job-a")
	-- Release happens "during" our wait: schedule it by advancing time past expiry.
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "ready", "acquired after the short wait")
	Assert.isTrue(#waits >= 1 and waits[1] <= 2, "waited briefly rather than backing off")
	Assert.equal(otherLeases:renew(handle), "lost", "departing server is fenced out")
end)

suite:case("a corrupt record is quarantined read-only and never overwritten", function(env)
	env.dataStores:seed(STORE, KEY, { schemaVersion = 1, revision = "not a number" })
	local loader, leases = make(env, "job-a")
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "readOnly", "state")
	Assert.equal(loaded.reason, "invalidProfile", "reason")
	Assert.isNil(loaded.profile, "invalid data is not served")
	Assert.contains(loaded.detail :: string, "revision", "detail names the problem")
	Assert.count(leases:held(), 0, "lease released again")
	local stored = env.dataStores:peek(STORE, KEY)
	Assert.equal(stored.revision, "not a number", "original data preserved for recovery")
	Assert.count(env.logged("persistence", "profile_quarantined"), 1, "logged")
end)

suite:case("a profile from a newer schema is read-only, not migrated down", function(env)
	env.dataStores:seed(STORE, KEY, { schemaVersion = 7 })
	local loader = make(env, "job-a")
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "readOnly", "state")
	Assert.equal(loaded.reason, "unsupportedSchema", "reason")
	Assert.equal(env.dataStores:peek(STORE, KEY).schemaVersion, 7, "untouched")
end)

suite:case("a non-table record is never replaced", function(env)
	env.dataStores:seed(STORE, KEY, 12345)
	local loader = make(env, "job-a")
	local loaded = loader:load(KEY)
	Assert.notEqual(loaded.state, "ready", "not ready")
	Assert.equal(env.dataStores:peek(STORE, KEY), 12345, "untouched")
end)

suite:case("read-only mode never acquires or writes", function(env)
	local existing: any = ProfileSchema.default()
	existing.balances["currency-test"] = 3
	env.dataStores:seed(STORE, KEY, existing)
	local loader, leases = make(env, "job-a", true)
	local loaded = loader:load(KEY)
	Assert.equal(loaded.state, "readOnly", "state")
	Assert.equal((loaded.profile :: any).balances["currency-test"], 3, "readable")
	Assert.count(leases:held(), 0, "no lease")
	Assert.equal(env.dataStores:callCount("UpdateAsync"), 0, "no writes at all")
	Assert.isNil(env.dataStores:peek(STORE, KEY).lease, "no lease written")
end)

return suite:cases()
