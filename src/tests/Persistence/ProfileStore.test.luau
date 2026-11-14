--!strict
-- BM-030 / BM-031: every write is guarded, revision-checked, validated and
-- classified; uncertain writes are inspectable.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local ProfileStore = require(ServerScriptService.Server.Persistence.ProfileStore)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("ProfileStore")

local STORE = "Profiles"
local KEY = "player-1"

local function make(env: Suite.Env)
	local raw = env.dataStores:GetDataStore(STORE) :: any
	local leases = Lease.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		store = raw,
		jobId = "job-a",
	})
	local profiles = ProfileStore.new({
		store = raw,
		logger = env.logger,
		now = function()
			return env.clock:wallTime()
		end,
	})
	local _, handle = leases:acquire(KEY)
	return profiles, leases, handle :: Lease.Handle
end

local function grant(id: string, amount: number): ProfileStore.Mutation
	return {
		id = id,
		apply = function(profile)
			if profile.receipts.permanent[id] then
				return nil
			end
			profile.receipts.permanent[id] = true
			profile.balances["currency-test"] = (profile.balances["currency-test"] or 0) + amount
			return profile
		end,
		isApplied = function(profile)
			return profile.receipts.permanent[id] == true
		end,
	}
end

suite:case("a committed mutation bumps the revision and keeps the lease", function(env)
	local profiles, _, handle = make(env)
	local result = profiles:mutate(KEY, handle, { grant("g1", 5), grant("g2", 2) })
	Assert.equal(result.outcome, "committed", "outcome")
	Assert.equal(result.revision, 1, "revision")
	Assert.equal(result.sizeVerdict, "ok", "size")
	local stored = env.dataStores:peek(STORE, KEY)
	Assert.equal(stored.balances["currency-test"], 7, "both applied in order")
	Assert.equal(stored.lease.fence, handle.lease.fence, "lease untouched")
	Assert.equal(stored.revision, 1, "stored revision")
end)

suite:case("a stale or foreign lease is rejected inside the transform", function(env)
	local profiles, _, handle = make(env)
	local forged: Lease.Handle =
		{ key = KEY, lease = table.clone(handle.lease), lost = false, uncertain = false }
	forged.lease.fence = handle.lease.fence + 1
	local result = profiles:mutate(KEY, forged, { grant("g1", 5) })
	Assert.equal(result.outcome, "rejected", "rejected")
	Assert.equal(result.reason, "lease", "reason")
	Assert.isNil(env.dataStores:peek(STORE, KEY).balances["currency-test"], "nothing written")
	env.clock:advance(Lease.LIFETIME_SECONDS + 1)
	Assert.equal(
		profiles:mutate(KEY, handle, { grant("g1", 5) }).reason,
		"lease",
		"expired lease rejected too"
	)
end)

suite:case("expected revision gives optimistic concurrency", function(env)
	local profiles, _, handle = make(env)
	Assert.equal(
		profiles:mutate(KEY, handle, { grant("g1", 1) }, { expectedRevision = 0 }).outcome,
		"committed",
		"matches"
	)
	local stale = profiles:mutate(KEY, handle, { grant("g2", 1) }, { expectedRevision = 0 })
	Assert.equal(stale.outcome, "rejected", "stale")
	Assert.equal(stale.reason, "revision", "reason")
	Assert.contains(stale.detail :: string, "expected revision 0, stored 1", "detail")
	Assert.equal(
		profiles:mutate(KEY, handle, { grant("g2", 1) }, { expectedRevision = 1 }).outcome,
		"committed",
		"current"
	)
end)

suite:case(
	"no-op batches, invalid results and oversized results are rejected without writing",
	function(env)
		local profiles, _, handle = make(env)
		profiles:mutate(KEY, handle, { grant("g1", 1) })
		local again = profiles:mutate(KEY, handle, { grant("g1", 1) })
		Assert.equal(again.reason, "noop", "already applied is a noop")
		Assert.equal(env.dataStores:peek(STORE, KEY).revision, 1, "revision not bumped by a noop")

		local bad = profiles:mutate(KEY, handle, {
			{
				id = "bad",
				apply = function(profile)
					(profile.balances :: any)["currency-test"] = -5
					return profile
				end,
			},
		})
		Assert.equal(bad.reason, "schema", "schema rejection")
		Assert.equal(env.dataStores:peek(STORE, KEY).balances["currency-test"], 1, "untouched")

		local huge = profiles:mutate(KEY, handle, {
			{
				id = "huge",
				apply = function(profile)
					for i = 1, 40 do
						profile.receipts.permanent["r" .. i .. string.rep("x", 40)] = true
					end
					return profile
				end,
			},
		}, { softBytes = 500, hardBytes = 1000 })
		Assert.equal(huge.reason, "size", "size rejection")
		Assert.equal(env.dataStores:peek(STORE, KEY).revision, 1, "untouched")
		Assert.count(
			env.logged("persistence", "profile_write_rejected"),
			3,
			"each rejection logged"
		)
	end
)

suite:case("a thrown write is uncertain, never assumed rolled back, and inspectable", function(env)
	local profiles, _, handle = make(env)
	env.dataStores:injectFault({ kind = "lostResponse", operation = "UpdateAsync" })
	local batch = { grant("g1", 5) }
	local result = profiles:mutate(KEY, handle, batch)
	Assert.equal(result.outcome, "uncertain", "uncertain")
	Assert.contains(result.detail :: string, "response lost", "detail")
	Assert.equal(env.dataStores:peek(STORE, KEY).balances["currency-test"], 5, "it did commit")
	Assert.equal(profiles:inspect(KEY, batch), "applied", "inspection finds it applied")

	env.dataStores:injectFault({ kind = "timeout", operation = "UpdateAsync" })
	local batch2 = { grant("g2", 1) }
	Assert.equal(
		profiles:mutate(KEY, handle, batch2).outcome,
		"uncertain",
		"timeout is uncertain too"
	)
	Assert.equal(profiles:inspect(KEY, batch2), "notApplied", "inspection finds it not applied")

	local mixed = { grant("g1", 5), grant("g3", 1) }
	local verdict, detail = profiles:inspect(KEY, mixed)
	Assert.equal(verdict, "unknown", "mixed")
	Assert.contains(detail :: string, "1 applied, 1 not applied", "detail")

	local opaque = { {
		id = "x",
		apply = function()
			return nil
		end,
	} }
	Assert.equal(
		profiles:inspect(KEY, opaque),
		"unknown",
		"mutation without isApplied cannot be inspected"
	)
	Assert.count(env.logged("persistence", "profile_write_uncertain"), 2, "uncertain writes logged")
end)

suite:case("read reports store failures instead of throwing", function(env)
	local profiles = make(env)
	env.dataStores:injectFault({ kind = "budget", operation = "GetAsync", times = 2 })
	local value, err = profiles:read(KEY)
	Assert.isNil(value, "no value")
	Assert.contains(err :: string, "budget", "error text")
	Assert.equal(
		profiles:inspect(KEY, { grant("g1", 1) }),
		"unknown",
		"inspection without a read is unknown"
	)
end)

return suite:cases()
