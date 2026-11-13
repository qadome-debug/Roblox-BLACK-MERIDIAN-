--!strict
-- BM-025..027: two-server acquisition, renewal and stale-owner fencing,
-- release, disconnect and teleport handoff races.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Lease")

local STORE = "Profiles"
local KEY = "player-1"

local function server(env: Suite.Env, jobId: string): Lease.Manager
	return Lease.new({
		clock = env.clock,
		rng = env.rng:fork(jobId),
		logger = env.logger,
		store = env.dataStores:GetDataStore(STORE) :: any,
		jobId = jobId,
	})
end

suite:case("first acquire creates a default profile with fence 1", function(env)
	local a = server(env, "job-a")
	local outcome, handle = a:acquire(KEY)
	Assert.equal(outcome, "acquired", "outcome")
	Assert.notNil(handle, "handle")
	local h = handle :: Lease.Handle
	Assert.equal(h.lease.fence, 1, "fence")
	Assert.equal(h.lease.sessionId, a.sessionId, "owner")
	Assert.equal(h.lease.expiresAt, env.clock:wallTime() + Lease.LIFETIME_SECONDS, "expiry")
	local stored = env.dataStores:peek(STORE, KEY)
	Assert.equal(stored.schemaVersion, 1, "default profile written")
	Assert.equal(stored.lease.fence, 1, "lease stored with the profile")
	Assert.isTrue(a:isValid(h), "valid")
	Assert.count(env.logged("persistence", "lease_acquired"), 1, "logged")
end)

suite:case("two servers cannot both own a live lease", function(env)
	local a = server(env, "job-a")
	local b = server(env, "job-b")
	Assert.equal((a:acquire(KEY)), "acquired", "a wins")
	local outcome, handle, heldUntil = b:acquire(KEY)
	Assert.equal(outcome, "held", "b is refused")
	Assert.isNil(handle, "no handle for b")
	Assert.equal(heldUntil, env.clock:wallTime() + Lease.LIFETIME_SECONDS, "told when to retry")
	Assert.count(b:held(), 0, "b holds nothing")
end)

suite:case(
	"an expired lease can be taken over with a higher fence, and the old owner is fenced out",
	function(env)
		local a = server(env, "job-a")
		local b = server(env, "job-b")
		local _, ha = a:acquire(KEY)
		env.clock:advance(Lease.LIFETIME_SECONDS + 1)

		local outcome, hb = b:acquire(KEY)
		Assert.equal(outcome, "acquired", "takeover")
		Assert.equal((hb :: Lease.Handle).lease.fence, 2, "fence advanced")

		-- The stale server still has its in-memory handle; every path must fail.
		Assert.equal(a:renew(ha :: Lease.Handle), "lost", "stale renew rejected")
		Assert.isTrue((ha :: Lease.Handle).lost, "handle marked lost")
		Assert.isFalse(a:isValid(ha :: Lease.Handle), "no longer valid")
		Assert.isFalse(
			Lease.guard(
				env.dataStores:peek(STORE, KEY),
				(ha :: Lease.Handle).lease,
				env.clock:wallTime()
			),
			"guard rejects the stale fence"
		)
		Assert.isTrue(
			Lease.guard(
				env.dataStores:peek(STORE, KEY),
				(hb :: Lease.Handle).lease,
				env.clock:wallTime()
			),
			"guard accepts the new owner"
		)
		Assert.count(env.logged("persistence", "lease_lost"), 1, "loss logged")
		Assert.equal(env.dataStores:peek(STORE, KEY).lease.sessionId, b.sessionId, "store shows b")
	end
)

suite:case("renewal extends the lease for the owner only", function(env)
	local a = server(env, "job-a")
	local _, handle = a:acquire(KEY)
	local h = handle :: Lease.Handle
	env.clock:advance(Lease.RENEWAL_INTERVAL_SECONDS)
	Assert.equal(a:renew(h), "renewed", "renewed")
	Assert.equal(h.lease.expiresAt, env.clock:wallTime() + Lease.LIFETIME_SECONDS, "extended")
	Assert.equal(h.lease.fence, 1, "fence unchanged by renewal")
	Assert.equal(env.dataStores:peek(STORE, KEY).lease.expiresAt, h.lease.expiresAt, "stored")
end)

suite:case("tick renews only handles that are due", function(env)
	local a = server(env, "job-a")
	local _, h1 = a:acquire("k1")
	a:acquire("k2")
	Assert.count(a:dueForRenewal(env.clock:wallTime()), 0, "nothing due yet")
	env.clock:advance(Lease.RENEWAL_INTERVAL_SECONDS)
	Assert.count(a:dueForRenewal(env.clock:wallTime()), 2, "both due")
	local before = env.dataStores:callCount("UpdateAsync")
	a:tick()
	Assert.equal(env.dataStores:callCount("UpdateAsync") - before, 2, "two renewals")
	Assert.equal(
		(h1 :: Lease.Handle).lease.expiresAt,
		env.clock:wallTime() + Lease.LIFETIME_SECONDS,
		"renewed"
	)
	Assert.count(a:dueForRenewal(env.clock:wallTime()), 0, "none due after tick")
end)

suite:case(
	"a renewal with a lost response is uncertain, not lost, and settles on retry",
	function(env)
		local a = server(env, "job-a")
		local _, handle = a:acquire(KEY)
		local h = handle :: Lease.Handle
		local expiryBefore = h.lease.expiresAt
		env.clock:advance(10)
		env.dataStores:injectFault({ kind = "lostResponse", operation = "UpdateAsync" })
		Assert.equal(a:renew(h), "uncertain", "uncertain")
		Assert.isTrue(h.uncertain and not h.lost, "flags")
		Assert.isTrue(a:isValid(h), "still valid until the old expiry")
		Assert.equal(h.lease.expiresAt, expiryBefore, "local expiry not advanced on uncertainty")
		Assert.count(
			a:dueForRenewal(env.clock:wallTime()),
			1,
			"uncertain handles are due immediately"
		)
		Assert.equal(a:renew(h), "renewed", "retry settles it")
		Assert.isFalse(h.uncertain, "cleared")
	end
)

suite:case(
	"a timed-out renewal is retried, and the lease is lost once it truly expires",
	function(env)
		local a = server(env, "job-a")
		local b = server(env, "job-b")
		local _, handle = a:acquire(KEY)
		local h = handle :: Lease.Handle
		env.dataStores:injectFault({ kind = "timeout", operation = "UpdateAsync" })
		env.clock:advance(Lease.RENEWAL_INTERVAL_SECONDS)
		Assert.equal(a:renew(h), "uncertain", "first timeout")
		env.clock:advance(Lease.LIFETIME_SECONDS)
		Assert.isFalse(a:isValid(h), "expired locally: no more writes")
		Assert.equal((b:acquire(KEY)), "acquired", "another server takes over")
		env.dataStores:clearFaults()
		Assert.equal(a:renew(h), "lost", "a learns it lost")
	end
)

suite:case("release clears the lease, but only for the owner", function(env)
	local a = server(env, "job-a")
	local b = server(env, "job-b")
	local _, ha = a:acquire(KEY)
	local h = ha :: Lease.Handle

	-- A stale copy of the handle from another session cannot release it.
	local forged: Lease.Handle =
		{ key = KEY, lease = table.clone(h.lease), lost = false, uncertain = false }
	forged.lease.sessionId = "someone-else"
	Assert.equal(b:release(forged), "lost", "non-owner cannot release")
	Assert.notNil(env.dataStores:peek(STORE, KEY).lease, "lease still present")

	Assert.equal(a:release(h), "released", "owner releases")
	Assert.equal(
		env.dataStores:peek(STORE, KEY).lease.expiresAt,
		0,
		"lease expired in place, fence kept"
	)
	Assert.isTrue(h.lost, "handle unusable after release")
	Assert.count(a:held(), 0, "not held")
	Assert.equal((b:acquire(KEY)), "acquired", "another server acquires immediately")
	Assert.equal(
		env.dataStores:peek(STORE, KEY).lease.fence,
		2,
		"fence still increases after release"
	)
end)

suite:case("teleport handoff: the arriving server waits for release or expiry", function(env)
	local departing = server(env, "job-a")
	local arriving = server(env, "job-b")
	local _, h = departing:acquire(KEY)

	-- Arrival races the release: refused with the expiry time.
	local outcome, _, heldUntil = arriving:acquire(KEY)
	Assert.equal(outcome, "held", "refused while held")
	Assert.notNil(heldUntil, "knows when to retry")

	-- Departing server's release fails to reach the store.
	env.dataStores:injectFault({ kind = "error", operation = "UpdateAsync" })
	Assert.equal(departing:release(h :: Lease.Handle), "uncertain", "release uncertain")
	Assert.isTrue((h :: Lease.Handle).lost, "departing server stops writing regardless")

	-- Still held until the lease expires; then the arrival succeeds.
	Assert.equal((arriving:acquire(KEY)), "held", "still held")
	env.clock:advance(Lease.LIFETIME_SECONDS + 1)
	local final, hb = arriving:acquire(KEY)
	Assert.equal(final, "acquired", "acquired after expiry")
	Assert.equal((hb :: Lease.Handle).lease.fence, 2, "new fence")
end)

suite:case("a non-profile value under the key is never overwritten", function(env)
	env.dataStores:seed(STORE, KEY, "corrupt-string")
	local a = server(env, "job-a")
	local outcome = a:acquire(KEY)
	Assert.equal(outcome, "held", "refused")
	Assert.equal(env.dataStores:peek(STORE, KEY), "corrupt-string", "untouched")
end)

suite:case("DataStore errors on acquire are reported, not treated as ownership", function(env)
	local a = server(env, "job-a")
	env.dataStores:injectFault({ kind = "budget" })
	local outcome, handle = a:acquire(KEY)
	Assert.equal(outcome, "error", "error")
	Assert.isNil(handle, "no handle")
	Assert.count(a:held(), 0, "nothing held")
	Assert.count(env.logged("persistence", "lease_acquire_error"), 1, "logged")
end)

return suite:cases()
