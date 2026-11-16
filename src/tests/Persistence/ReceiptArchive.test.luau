--!strict
-- BM-047 through the RewardService facade: a permanent reward is paid
-- exactly once across archive migration, whatever fails around it.
--
--   * crash after the archive record is written (orphan record)
--   * lost response on the archive write
--   * archive record unreadable while a grant is requested
--   * reconnect through another server that archived in between
--   * grants queued in the same write as the archive, and twice at once
--   * a leftover intent for a receipt that was archived

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local ProfileStore = require(ServerScriptService.Server.Persistence.ProfileStore)
local ReceiptCapacity = require(ServerScriptService.Server.Persistence.ReceiptCapacity)
local Receipts = require(ServerScriptService.Server.Persistence.Receipts)
local RewardCatalog = require(ServerScriptService.Server.Content.RewardCatalog)
local RewardService = require(ServerScriptService.Server.Services.RewardService)
local SaveQueue = require(ServerScriptService.Server.Persistence.SaveQueue)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("ReceiptArchive")

local STORE = "Profiles"
local ARCHIVES = ReceiptCapacity.ARCHIVE_STORE_NAME
local KEY = "player-1"
local ARCHIVE_1 = ReceiptCapacity.archiveKey(KEY, 1)
local AMOUNT = 10
-- Enough receipts to cross the archive threshold.
local SEEDED = math.floor(Limits.PROFILE.MAX_PERMANENT_RECEIPTS * ReceiptCapacity.ARCHIVE_FRACTION)
	+ 1

local CATALOG = RewardCatalog.build({
	{
		id = "reward-quest",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = AMOUNT } },
	},
})
local QUEST = CATALOG:get("reward-quest") :: RewardCatalog.Definition

type World = {
	service: RewardService.Service,
	queue: SaveQueue.Queue,
	leases: Lease.Manager,
	capacity: ReceiptCapacity.Monitor,
	target: RewardService.Target,
	own: () -> Lease.Handle?,
	leave: (handle: Lease.Handle) -> (),
	grant: (questId: string) -> RewardService.GrantResult,
}

local function world(env: Suite.Env, jobId: string): World
	local raw = env.dataStores:GetDataStore(STORE) :: any
	local leases = Lease.new({
		clock = env.clock,
		rng = env.rng:fork(jobId),
		logger = env.logger,
		store = raw,
		jobId = jobId,
	})
	local profiles = ProfileStore.new({
		store = raw,
		logger = env.logger,
		now = function()
			return env.clock:wallTime()
		end,
	})
	local queue = SaveQueue.new({
		clock = env.clock,
		rng = env.rng:fork(jobId .. "-queue"),
		logger = env.logger,
		leases = leases,
		profiles = profiles,
	})
	local telemetry = Telemetry.new(env.logger)
	local capacity = ReceiptCapacity.new({
		logger = env.logger,
		telemetry = telemetry,
		profiles = profiles,
		archiveStore = env.dataStores:GetDataStore(ARCHIVES) :: any,
	})
	local service = RewardService.new({
		clock = env.clock,
		logger = env.logger,
		telemetry = telemetry,
		catalog = CATALOG,
		queue = queue,
		profiles = profiles,
		capacity = capacity,
		runStore = env.dataStores:GetDataStore(RewardService.RUN_STORE_NAME) :: any,
		seasons = { currentSeason = 1, retainedSeasons = 1 },
		retryAfterSeconds = 30,
		escalateAfterSeconds = 3600,
	})
	local w = {} :: World
	w.service = service
	w.queue = queue
	w.leases = leases
	w.capacity = capacity
	w.target = { userId = 1, key = KEY }
	w.own = function(): Lease.Handle?
		local _, handle = leases:acquire(KEY)
		if handle ~= nil then
			queue:track(KEY, handle)
		end
		return handle
	end
	w.leave = function(handle: Lease.Handle)
		queue:flush(KEY)
		queue:untrack(KEY)
		leases:release(handle)
	end
	w.grant = function(questId: string): RewardService.GrantResult
		return service:grantPermanent(w.target, { kind = "quest", id = questId }, "reward-quest")
	end
	return w
end

local function receiptFor(questId: string): string
	return RewardCatalog.permanentReceiptId("quest", questId, "reward-quest") :: string
end

local function seededId(index: number): string
	return string.format("q%04d", index)
end

local function stored(env: Suite.Env): any
	return env.dataStores:peek(STORE, KEY)
end

-- Rewrites the stored profile (keeping its lease) with SEEDED old receipts,
-- as if the player had earned them long ago.
local function seedReceipts(env: Suite.Env)
	local profile = stored(env)
	for index = 1, SEEDED do
		profile.receipts.permanent[receiptFor(seededId(index))] = true
	end
	env.dataStores:seed(STORE, KEY, profile)
end

local function balance(env: Suite.Env): number
	return stored(env).balances["currency-test"] or 0
end

local function count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- Every seeded receipt, plus `extra`, is in the profile or in the archive
-- record, never both and never neither.
local function assertEveryClaimKept(env: Suite.Env, extra: { string })
	local profile = stored(env)
	local record = env.dataStores:peek(ARCHIVES, ARCHIVE_1)
	local ids: { string } = table.clone(extra)
	for index = 1, SEEDED do
		table.insert(ids, receiptFor(seededId(index)))
	end
	for _, id in ids do
		local inProfile = profile.receipts.permanent[id] == true
		local inArchive = record ~= nil and record.receipts[id] == true
		Assert.isTrue(inProfile ~= inArchive, id .. " must be in exactly one place")
	end
	Assert.count(ProfileSchema.validate(profile), 0, "profile still valid")
end

suite:case("an archived receipt is a duplicate through the service", function(env)
	local w = world(env, "job-a")
	Assert.notNil(w.own(), "owned")
	seedReceipts(env)
	w.service:maintain(w.target, stored(env))
	Assert.deepEqual(stored(env).receipts.archives, { ARCHIVE_1 }, "archived")
	Assert.isNil(stored(env).receipts.permanent[receiptFor(seededId(1))], "oldest moved out")

	Assert.equal(w.grant(seededId(1)).outcome, "duplicate", "archived receipt refused")
	Assert.equal(w.grant(seededId(SEEDED)).outcome, "duplicate", "kept receipt refused")
	Assert.equal(balance(env), 0, "nothing paid again")
	Assert.equal(w.grant("new-quest").outcome, "granted", "a new reward still pays")
	Assert.equal(balance(env), AMOUNT, "paid once")
	Assert.equal(w.grant("new-quest").outcome, "duplicate", "and only once")
	assertEveryClaimKept(env, { receiptFor("new-quest") })
end)

suite:case(
	"a crash after the archive record is written loses nothing and never blocks archiving",
	function(env)
		local a = world(env, "job-a")
		Assert.notNil(a.own(), "a owns")
		seedReceipts(env)
		-- The record is written, then the profile write fails and server a dies.
		env.dataStores:injectFault({ kind = "error", operation = "UpdateAsync", key = KEY })
		a.service:maintain(a.target, stored(env))
		Assert.notNil(env.dataStores:peek(ARCHIVES, ARCHIVE_1), "orphan record exists")
		Assert.deepEqual(stored(env).receipts.archives, {}, "profile not updated")
		Assert.equal(count(stored(env).receipts.permanent), SEEDED, "every receipt still held")
		env.clock:advance(Lease.LIFETIME_SECONDS + 1)

		local b = world(env, "job-b")
		Assert.notNil(b.own(), "b takes over")
		-- With the orphan in place nothing can be paid twice.
		Assert.equal(b.grant(seededId(1)).outcome, "duplicate", "orphaned receipt still refused")
		-- A new receipt that sorts before every old one changes what "the
		-- oldest half" is, so the orphan no longer matches a fresh selection.
		Assert.equal(b.grant("a-new-quest").outcome, "granted", "new reward")
		Assert.equal(balance(env), AMOUNT, "paid once")

		-- The stale owner cannot finish its archive.
		local revision = stored(env).revision
		Assert.equal(a.queue:flush(KEY), "noLease", "stale owner fenced out")
		Assert.equal(stored(env).revision, revision, "no write from the stale owner")

		b.service:maintain(b.target, stored(env))
		Assert.count(env.logged("persistence", "receipt_archive_adopted"), 1, "orphan adopted")
		Assert.deepEqual(stored(env).receipts.archives, { ARCHIVE_1 }, "archive recorded")
		local record = env.dataStores:peek(ARCHIVES, ARCHIVE_1)
		Assert.equal(
			count(stored(env).receipts.permanent),
			SEEDED + 1 - record.count,
			"exactly the adopted receipts left the profile"
		)
		Assert.equal(
			stored(env).receipts.permanent[receiptFor("a-new-quest")],
			true,
			"the new receipt stays in the profile"
		)
		assertEveryClaimKept(env, { receiptFor("a-new-quest") })

		Assert.equal(b.grant(seededId(1)).outcome, "duplicate", "archived receipt refused")
		Assert.equal(b.grant("a-new-quest").outcome, "duplicate", "new receipt refused")
		Assert.equal(balance(env), AMOUNT, "still paid once")
	end
)

suite:case("a lost response on the archive write is retried without a second record", function(env)
	local w = world(env, "job-a")
	Assert.notNil(w.own(), "owned")
	seedReceipts(env)
	env.dataStores:injectFault({
		kind = "lostResponse",
		operation = "UpdateAsync",
		key = ARCHIVE_1,
	})
	w.service:maintain(w.target, stored(env))
	Assert.count(env.logged("reward", "receipt_archive_failed"), 1, "first attempt reported")
	Assert.deepEqual(stored(env).receipts.archives, {}, "profile untouched")
	local first = env.dataStores:peek(ARCHIVES, ARCHIVE_1)
	Assert.notNil(first, "the record did land")

	w.service:maintain(w.target, stored(env))
	Assert.deepEqual(stored(env).receipts.archives, { ARCHIVE_1 }, "second attempt finished")
	Assert.deepEqual(env.dataStores:peek(ARCHIVES, ARCHIVE_1), first, "record never rewritten")
	Assert.isNil(
		env.dataStores:peek(ARCHIVES, ReceiptCapacity.archiveKey(KEY, 2)),
		"no second record"
	)
	assertEveryClaimKept(env, {})
	Assert.equal(w.grant(seededId(1)).outcome, "duplicate", "archived receipt refused")
	Assert.equal(balance(env), 0, "nothing paid")
end)

suite:case(
	"an unreadable archive delays grants; it never pays twice and never forgets one",
	function(env)
		local a = world(env, "job-a")
		local handle = a.own() :: Lease.Handle
		seedReceipts(env)
		a.service:maintain(a.target, stored(env))
		Assert.deepEqual(stored(env).receipts.archives, { ARCHIVE_1 }, "archived")
		a.leave(handle)

		-- A fresh server (nothing cached) while the archive store is failing.
		local b = world(env, "job-b")
		Assert.notNil(b.own(), "b owns")
		env.dataStores:injectFault({
			kind = "error",
			operation = "GetAsync",
			key = ARCHIVE_1,
			times = 1000,
		})
		local old = b.grant(seededId(1))
		Assert.equal(old.outcome, "pending", "archived receipt cannot be verified: not paid")
		local new = b.grant("new-quest")
		Assert.equal(new.outcome, "pending", "new reward waits too")
		Assert.equal(balance(env), 0, "nothing paid while the archive is unreadable")
		Assert.notNil(stored(env).receipts.pending[receiptFor("new-quest")], "new reward is owed")
		Assert.isTrue(
			#env.logged("reward", "reward_receipts_unverifiable") >= 2,
			"both attempts reported"
		)

		-- Recovery also waits rather than guessing.
		env.clock:advance(31)
		b.service:reconcile(b.target)
		Assert.equal(balance(env), 0, "still nothing paid")
		Assert.isTrue(#env.logged("reward", "reward_recovery_deferred") >= 1, "deferral reported")

		-- The archive store comes back: the new reward is paid once and the
		-- old one is recognised as already paid.
		env.dataStores:clearFaults()
		env.clock:advance(31)
		b.service:reconcile(b.target)
		Assert.equal(balance(env), AMOUNT, "only the new reward is paid")
		Assert.equal(count(stored(env).receipts.pending), 0, "no intent left behind")
		Assert.equal(b.grant(seededId(1)).outcome, "duplicate", "old receipt refused")
		Assert.equal(b.grant("new-quest").outcome, "duplicate", "new receipt refused")
		Assert.equal(balance(env), AMOUNT, "paid exactly once")
	end
)

suite:case(
	"rejoining a server that cached the archives before another server archived",
	function(env)
		local a = world(env, "job-a")
		local first = a.own() :: Lease.Handle
		seedReceipts(env)
		-- Server a serves a grant, so it now holds a view with no archives.
		Assert.equal(a.grant("z-first").outcome, "granted", "first reward on a")
		a.leave(first)

		-- The player plays on server b, which archives.
		local b = world(env, "job-b")
		local second = b.own() :: Lease.Handle
		b.service:maintain(b.target, stored(env))
		Assert.deepEqual(stored(env).receipts.archives, { ARCHIVE_1 }, "b archived")
		b.leave(second)

		-- Back on server a: its cached view is stale.
		Assert.notNil(a.own(), "a owns again")
		Assert.equal(a.grant(seededId(1)).outcome, "duplicate", "archived elsewhere: refused")
		Assert.equal(balance(env), AMOUNT, "not paid again")
		Assert.equal(a.grant("z-second").outcome, "granted", "new rewards still pay")
		Assert.equal(balance(env), 2 * AMOUNT, "paid once each")
		assertEveryClaimKept(env, { receiptFor("z-first"), receiptFor("z-second") })
	end
)

suite:case("grants written together with the archive, or twice at once, pay once", function(env)
	local w = world(env, "job-a")
	Assert.notNil(w.own(), "owned")
	seedReceipts(env)

	-- The same new receipt queued twice lands in one write and pays once.
	local none: ReceiptCapacity.ArchivedView = { receipts = {}, covers = {} }
	local twin = receiptFor("twin")
	w.queue:enqueue(KEY, Receipts.permanentGrant(twin, QUEST, none) :: SaveQueue.Mutation)
	w.queue:enqueue(KEY, Receipts.permanentGrant(twin, QUEST, none) :: SaveQueue.Mutation)
	Assert.equal(w.queue:flush(KEY), "committed", "one write")
	Assert.equal(balance(env), AMOUNT, "twin paid once")

	-- Grants built before the archive, written in the same batch after it:
	-- their view does not cover the new archive, so the write refuses them.
	local stale: ReceiptCapacity.ArchivedView = { receipts = {}, covers = {} }
	local archive, reason = w.capacity.buildArchive(KEY, stored(env))
	Assert.notNil(archive, "archive built: " .. tostring(reason))
	local oldId = receiptFor(seededId(1))
	local newId = receiptFor("raced")
	w.queue:enqueue(KEY, archive :: SaveQueue.Mutation)
	w.queue:enqueue(KEY, Receipts.permanentGrant(oldId, QUEST, stale) :: SaveQueue.Mutation)
	w.queue:enqueue(KEY, Receipts.permanentGrant(newId, QUEST, stale) :: SaveQueue.Mutation)
	local outcome, _, dropped = w.queue:flush(KEY)
	Assert.equal(outcome, "rejected", "the stale grants were refused")
	Assert.deepEqual(dropped, { oldId, newId }, "only the grants were dropped")
	Assert.deepEqual(stored(env).receipts.archives, { ARCHIVE_1 }, "the archive still landed")
	Assert.equal(balance(env), AMOUNT, "neither stale grant paid")

	-- Through the service, with a fresh view, the outcome is exact.
	Assert.equal(w.grant(seededId(1)).outcome, "duplicate", "archived receipt refused")
	Assert.equal(w.grant("raced").outcome, "granted", "the new reward pays")
	Assert.equal(w.grant("raced").outcome, "duplicate", "once")
	Assert.equal(balance(env), 2 * AMOUNT, "twin and raced, once each")
	assertEveryClaimKept(env, { twin, newId })
end)

suite:case("a leftover intent for an archived receipt is cleared, not paid", function(env)
	local a = world(env, "job-a")
	local handle = a.own() :: Lease.Handle
	seedReceipts(env)
	a.service:maintain(a.target, stored(env))
	a.leave(handle)

	local archivedId = receiptFor(seededId(1))
	local profile = stored(env)
	profile.receipts.pending[archivedId] = {
		grantId = archivedId,
		sourceId = seededId(1),
		createdAt = 0,
		rewardCatalogId = "reward-quest",
	}
	env.dataStores:seed(STORE, KEY, profile)

	local b = world(env, "job-b")
	Assert.notNil(b.own(), "b owns")
	b.service:recoverPending(b.target, stored(env))
	Assert.equal(balance(env), 0, "not paid again")
	Assert.isNil(stored(env).receipts.pending[archivedId], "intent cleared")
	Assert.isNil(stored(env).receipts.permanent[archivedId], "receipt stays archived only")
end)

return suite:cases()
