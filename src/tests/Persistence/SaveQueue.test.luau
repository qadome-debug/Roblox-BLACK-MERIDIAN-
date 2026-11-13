--!strict
-- BM-029: budget exhaustion and queue saturation never drop a committed
-- change; ordering of irreversible mutations is preserved.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local SaveQueue = require(ServerScriptService.Server.Persistence.SaveQueue)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("SaveQueue")

local STORE = "Profiles"
local KEY = "player-1"

local function make(env: Suite.Env)
	local store = env.dataStores:GetDataStore(STORE) :: any
	local leases = Lease.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		store = store,
		jobId = "job-a",
	})
	local queue = SaveQueue.new({
		clock = env.clock,
		logger = env.logger,
		leases = leases,
		store = store,
		maxPending = 4,
		backoff = { 1, 2, 4 },
		softBytes = 1500,
		hardBytes = 2500,
	})
	local _, handle = leases:acquire(KEY)
	queue:track(KEY, handle :: Lease.Handle)
	return queue, leases, handle :: Lease.Handle
end

-- A mutation that adds `amount` to a test currency; idempotent via a
-- receipt so re-applying after an uncertain write does not double it.
local function grant(id: string, amount: number): SaveQueue.Mutation
	return {
		id = id,
		irreversible = true,
		apply = function(profile)
			if profile.receipts.permanent[id] then
				return nil
			end
			profile.receipts.permanent[id] = true
			profile.balances["currency-test"] = (profile.balances["currency-test"] or 0) + amount
			return profile
		end,
	}
end

local function balance(env: Suite.Env): number
	return env.dataStores:peek(STORE, KEY).balances["currency-test"] or 0
end

suite:case("queued mutations coalesce into one write, in order", function(env)
	local queue = make(env)
	Assert.isTrue(queue:enqueue(KEY, grant("g1", 5)), "enqueue 1")
	Assert.isTrue(queue:enqueue(KEY, grant("g2", 7)), "enqueue 2")
	Assert.isTrue(
		queue:enqueue(KEY, {
			id = "double",
			apply = function(profile)
				profile.balances["currency-test"] = profile.balances["currency-test"] * 2
				return profile
			end,
		}),
		"enqueue 3"
	)
	local before = env.dataStores:callCount("UpdateAsync")
	local outcome = queue:flush(KEY)
	Assert.equal(outcome, "committed", "committed")
	Assert.equal(
		env.dataStores:callCount("UpdateAsync") - before,
		1,
		"one write for three mutations"
	)
	Assert.equal(balance(env), 24, "(5 + 7) * 2: order preserved")
	Assert.equal(queue:pendingCount(KEY), 0, "queue drained")
	Assert.equal(env.dataStores:peek(STORE, KEY).revision, 1, "revision advanced once")
	Assert.notNil(env.dataStores:peek(STORE, KEY).lease, "lease carried through")
	Assert.equal(queue:flush(KEY), "nothingToDo", "empty flush")
end)

suite:case("the queue is bounded and refuses rather than drops", function(env)
	local queue = make(env)
	for i = 1, 4 do
		Assert.isTrue(queue:enqueue(KEY, grant("g" .. i, 1)), "enqueue " .. i)
	end
	Assert.isFalse(queue:enqueue(KEY, grant("g5", 1)), "fifth refused")
	Assert.equal(queue:pendingCount(KEY), 4, "first four kept")
	Assert.count(env.logged("persistence", "save_queue_full"), 1, "logged")
	Assert.isFalse(queue:enqueue("untracked", grant("x", 1)), "untracked key refused")
end)

suite:case("a failed write keeps everything queued and backs off", function(env)
	local queue = make(env)
	queue:enqueue(KEY, grant("g1", 5))
	env.dataStores:injectFault({ kind = "timeout", operation = "UpdateAsync" })
	local outcome = queue:flush(KEY)
	Assert.equal(outcome, "uncertain", "uncertain")
	Assert.equal(queue:pendingCount(KEY), 1, "still queued")
	Assert.equal(balance(env), 0, "nothing written")
	Assert.equal(queue:flush(KEY), "backoff", "in backoff")
	env.clock:advance(1)
	Assert.equal(queue:flush(KEY), "committed", "retried after backoff")
	Assert.equal(balance(env), 5, "written once")
end)

suite:case("a committed-but-lost-response write is not applied twice", function(env)
	local queue = make(env)
	queue:enqueue(KEY, grant("g1", 5))
	env.dataStores:injectFault({ kind = "lostResponse", operation = "UpdateAsync" })
	Assert.equal(queue:flush(KEY), "uncertain", "uncertain")
	Assert.equal(balance(env), 5, "actually committed")
	Assert.equal(queue:pendingCount(KEY), 1, "still queued because we cannot know")
	env.clock:advance(1)
	Assert.equal(queue:flush(KEY), "committed", "re-applied")
	Assert.equal(balance(env), 5, "receipt made the re-apply a no-op")
	Assert.equal(env.dataStores:peek(STORE, KEY).revision, 2, "revision counts both writes")
end)

suite:case("budget exhaustion escalates the backoff and never loses order", function(env)
	local queue = make(env)
	queue:enqueue(KEY, grant("g1", 1))
	queue:enqueue(KEY, grant("g2", 10))
	env.dataStores:injectFault({ kind = "budget", operation = "UpdateAsync", times = 3 })
	local waits = {}
	for _ = 1, 3 do
		queue:flush(KEY)
		local state = queue:state(KEY) :: SaveQueue.KeyState
		table.insert(waits, state.nextAttemptAt - env.clock:wallTime())
		env.clock:advance(state.nextAttemptAt - env.clock:wallTime())
	end
	Assert.deepEqual(waits, { 1, 2, 4 }, "exponential backoff")
	Assert.equal(queue:flush(KEY), "committed", "fourth attempt succeeds")
	Assert.equal(balance(env), 11, "both applied, once each")
	Assert.equal((queue:state(KEY) :: SaveQueue.KeyState).failures, 0, "failure count reset")
end)

suite:case("no lease, no write", function(env)
	local queue, leases, handle = make(env)
	queue:enqueue(KEY, grant("g1", 5))
	env.clock:advance(Lease.LIFETIME_SECONDS + 1) -- lease expired locally
	Assert.equal(queue:flush(KEY), "noLease", "refused")
	Assert.equal(balance(env), 0, "nothing written")
	Assert.equal(queue:pendingCount(KEY), 1, "kept for recovery")

	-- A fresh owner takes the key; our stale handle is fenced out inside
	-- the transform even if local validity were wrong.
	local other = Lease.new({
		clock = env.clock,
		rng = env.rng:fork("b"),
		logger = env.logger,
		store = env.dataStores:GetDataStore(STORE) :: any,
		jobId = "job-b",
	})
	Assert.equal((other:acquire(KEY)), "acquired", "taken over")
	handle.lease.expiresAt = env.clock:wallTime() + 100 -- lie locally
	Assert.equal(queue:flush(KEY), "noLease", "fenced out by the store")
	Assert.isTrue(handle.lost, "handle marked lost")
	Assert.equal(balance(env), 0, "still nothing written")
	Assert.count(leases:held(), 1, "manager still lists it until release") -- bookkeeping only
end)

suite:case(
	"a mutation that breaks the schema or the size budget is rejected without partial writes",
	function(env)
		local queue = make(env)
		queue:enqueue(KEY, grant("g1", 5))
		queue:enqueue(KEY, {
			id = "bad",
			apply = function(profile)
				(profile.balances :: any)["currency-test"] = -1
				return profile
			end,
		})
		local outcome, reason = queue:flush(KEY)
		Assert.equal(outcome, "rejected", "rejected")
		Assert.contains(reason :: string, "invalid profile", "reason")
		Assert.equal(balance(env), 0, "the valid first mutation was not written alone")
		Assert.equal(queue:pendingCount(KEY), 0, "batch dropped and reported")
		Assert.count(env.logged("persistence", "save_queue_rejected"), 1, "logged")

		queue:enqueue(KEY, {
			id = "huge",
			apply = function(profile)
				for i = 1, 60 do
					profile.receipts.permanent["r" .. i .. string.rep("x", 40)] = true
				end
				return profile
			end,
		})
		local outcome2, reason2 = queue:flush(KEY)
		Assert.equal(outcome2, "rejected", "size rejected")
		Assert.contains(reason2 :: string, "hard limit", "reason")
		Assert.equal(env.dataStores:peek(STORE, KEY).revision, 0, "nothing committed")
	end
)

suite:case("flushAll respects per-key backoff and the soft size warning is logged", function(env)
	local queue = make(env)
	queue:enqueue(KEY, {
		id = "big-but-ok",
		apply = function(profile)
			for i = 1, 30 do
				profile.receipts.permanent["r" .. i .. string.rep("x", 40)] = true
			end
			return profile
		end,
	})
	queue:flushAll()
	Assert.equal(queue:pendingCount(KEY), 0, "flushed")
	Assert.count(env.logged("persistence", "profile_size_soft_limit"), 1, "soft limit logged")
	Assert.isTrue(
		env.logged("persistence", "profile_size_soft_limit")[1].fields.bytes > 1500,
		"bytes reported"
	)
end)

return suite:cases()
