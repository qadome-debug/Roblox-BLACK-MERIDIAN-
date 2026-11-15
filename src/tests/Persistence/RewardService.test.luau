--!strict
-- BM-040..046 (facade): every grant source goes through RewardService;
-- compensation is idempotent and audited; run results are recorded
-- durably; pending grants recover after a crash; reconciliation
-- converges without duplicates.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local ProfileStore = require(ServerScriptService.Server.Persistence.ProfileStore)
local ReceiptCapacity = require(ServerScriptService.Server.Persistence.ReceiptCapacity)
local RewardCatalog = require(ServerScriptService.Server.Content.RewardCatalog)
local RewardService = require(ServerScriptService.Server.Services.RewardService)
local SaveQueue = require(ServerScriptService.Server.Persistence.SaveQueue)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("RewardService")

local STORE = "Profiles"
local RUNS = RewardService.RUN_STORE_NAME

local CATALOG = RewardCatalog.build({
	{
		id = "reward-gold",
		kind = "repeatable",
		sources = { "descent" },
		grants = { currencies = { ["currency-test"] = 25 } },
	},
	{
		id = "reward-waymark",
		kind = "permanent",
		sources = { "waymark" },
		grants = { waymarks = { "waymark-i" }, currencies = { ["currency-test"] = 5 } },
	},
	{
		id = "reward-quest",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = 10 } },
	},
	{
		id = "reward-overcap",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = 100000 } },
	},
})

local SEASONS = { currentSeason = 3, retainedSeasons = 2 }

type World = {
	service: RewardService.Service,
	queue: SaveQueue.Queue,
	leases: Lease.Manager,
	profiles: ProfileStore.Store,
	own: (userId: number) -> RewardService.Target,
}

local function world(env: Suite.Env, jobId: string): World
	local raw = env.dataStores:GetDataStore(STORE) :: any
	local runStore = env.dataStores:GetDataStore(RUNS) :: any
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
		archiveStore = env.dataStores:GetDataStore(ReceiptCapacity.ARCHIVE_STORE_NAME) :: any,
	})
	local service = RewardService.new({
		clock = env.clock,
		logger = env.logger,
		telemetry = telemetry,
		catalog = CATALOG,
		queue = queue,
		profiles = profiles,
		capacity = capacity,
		runStore = runStore,
		seasons = SEASONS,
		retryAfterSeconds = 30,
		escalateAfterSeconds = 300,
	})
	local w = {} :: World
	w.service = service
	w.queue = queue
	w.leases = leases
	w.profiles = profiles
	w.own = function(userId: number): RewardService.Target
		local key = "player-" .. userId
		local _, handle = leases:acquire(key)
		if handle ~= nil then
			queue:track(key, handle)
		end
		return { userId = userId, key = key }
	end
	return w
end

local function stored(env: Suite.Env, key: string): any
	return env.dataStores:peek(STORE, key)
end

suite:case(
	"a permanent grant pays once, writes intent then receipt, and emits telemetry",
	function(env)
		local w = world(env, "job-a")
		local t = w.own(1)
		local result =
			w.service:grantPermanent(t, { kind = "waymark", id = "waymark-i" }, "reward-waymark")
		Assert.equal(result.outcome, "granted", "granted: " .. tostring(result.reason))
		Assert.equal(result.receiptId, "p:waymark:waymark-i:reward-waymark", "receipt id")
		local p = stored(env, t.key)
		Assert.equal(p.balances["currency-test"], 5, "currency")
		Assert.equal(p.waymarks["waymark-i"].activated, true, "unlock")
		Assert.equal(p.revision, 2, "intent write then grant write")
		Assert.isNil(p.receipts.pending[result.receiptId :: string], "intent cleared")

		local again =
			w.service:grantPermanent(t, { kind = "waymark", id = "waymark-i" }, "reward-waymark")
		Assert.equal(again.outcome, "duplicate", "duplicate detected before any write")
		Assert.equal(stored(env, t.key).revision, 2, "no extra writes")

		local granted = env.logged("telemetry", "reward_granted")
		Assert.count(granted, 1, "one grant event")
		Assert.equal(granted[1].fields.receiptId, result.receiptId, "receipt in telemetry")
		Assert.equal(granted[1].fields.userId, 1, "player in telemetry")
		Assert.count(env.logged("telemetry", "reward_duplicate"), 1, "duplicate counted")
		Assert.count(env.logged("reward", "reward_granted"), 1, "grant logged with correlation")
	end
)

suite:case("grants are refused for unknown rewards, wrong sources and wrong kinds", function(env)
	local w = world(env, "job-a")
	local t = w.own(1)
	Assert.equal(
		w.service:grantPermanent(t, { kind = "quest", id = "q" }, "reward-made-up").outcome,
		"refused",
		"unknown"
	)
	local wrongSource = w.service:grantPermanent(t, { kind = "boss", id = "b" }, "reward-quest")
	Assert.equal(wrongSource.outcome, "refused", "source not allowed")
	Assert.contains(wrongSource.reason :: string, "cannot come from boss", "reason")
	Assert.equal(
		w.service:grantPermanent(t, { kind = "quest", id = "q" }, "reward-gold").outcome,
		"refused",
		"repeatable via permanent"
	)
	Assert.equal(
		w.service:grantSeasonal(t, "run-1", 1, "reward-quest", 3).outcome,
		"refused",
		"permanent via seasonal"
	)
	Assert.equal(
		w.service:grantSeasonal(t, "run-1", 1, "reward-gold", 1).outcome,
		"refused",
		"closed season"
	)
	Assert.equal(
		w.service:grantPermanent(t, { kind = "quest", id = "bad id" }, "reward-quest").outcome,
		"refused",
		"bad source id"
	)
	Assert.equal(stored(env, t.key).revision, 0, "nothing written")
	Assert.isTrue(#env.logged("telemetry", "reward_refused") >= 4, "refusals counted")
end)

suite:case(
	"a deterministic grant failure leaves a durable intent, and recovery fulfils it later",
	function(env)
		local w = world(env, "job-a")
		local t = w.own(1)
		-- Push the balance near the cap so reward-overcap cannot apply.
		local p: any = stored(env, t.key)
		p.balances["currency-test"] = 1_000_000_000 - 1
		env.dataStores:seed(STORE, t.key, p)

		local result =
			w.service:grantPermanent(t, { kind = "quest", id = "quest-x" }, "reward-overcap")
		Assert.equal(result.outcome, "pending", "owed, not lost")
		local after = stored(env, t.key)
		Assert.notNil(after.receipts.pending[result.receiptId :: string], "intent on disk")
		Assert.isNil(after.receipts.permanent[result.receiptId :: string], "no receipt")
		Assert.count(env.logged("reward", "reward_grant_rejected"), 1, "rejection logged")

		-- An operator spends the balance down; reconciliation then succeeds.
		after.balances["currency-test"] = 0
		after.lease = stored(env, t.key).lease
		env.dataStores:seed(STORE, t.key, after)
		env.clock:advance(31)
		local report = w.service:reconcile(t)
		Assert.equal(report.retried, 1, "retried")
		local final = stored(env, t.key)
		Assert.equal(final.receipts.permanent[result.receiptId :: string], true, "receipt now")
		Assert.equal(final.balances["currency-test"], 100000, "paid once")
		Assert.isNil(final.receipts.pending[result.receiptId :: string], "intent cleared")
	end
)

suite:case(
	"a crash after the intent is recovered by the next server without duplication",
	function(env)
		local a = world(env, "job-a")
		local t = a.own(1)
		-- Simulate the crash: intent written, grant never attempted.
		local intentOnly = a.service -- same service; write the intent by hand through the queue
		local receiptId =
			RewardCatalog.permanentReceiptId("quest", "quest-x", "reward-quest") :: string
		local Receipts = require(ServerScriptService.Server.Persistence.Receipts)
		a.queue:enqueue(
			t.key,
			Receipts.recordIntent(receiptId, "quest-x", "reward-quest", env.clock:wallTime()) :: any
		)
		a.queue:flush(t.key)
		Assert.notNil(intentOnly, "service exists")
		env.clock:advance(Lease.LIFETIME_SECONDS + 1)

		local b = world(env, "job-b")
		local t2 = b.own(1)
		local loaded = stored(env, t2.key)
		local recovered = b.service:recoverPending(t2, loaded)
		Assert.equal(recovered, 1, "one grant recovered")
		local p = stored(env, t2.key)
		Assert.equal(p.balances["currency-test"], 10, "paid")
		Assert.equal(p.receipts.permanent[receiptId], true, "receipt")
		Assert.isNil(p.receipts.pending[receiptId], "intent cleared")
		Assert.count(env.logged("telemetry", "reward_recovered"), 1, "recovery counted")

		-- Running recovery again changes nothing.
		Assert.equal(b.service:recoverPending(t2, stored(env, t2.key)), 0, "nothing left")
		Assert.equal(stored(env, t2.key).balances["currency-test"], 10, "still once")
	end
)

suite:case("compensation is operator-attributed, idempotent per case, and audited", function(env)
	local w = world(env, "job-a")
	local t = w.own(1)
	local op = { operatorId = "op-42", caseId = "case-7", reason = "lost reward during outage" }
	local first = w.service:compensate(t, op, "reward-quest")
	Assert.equal(first.outcome, "granted", "granted")
	Assert.equal(first.receiptId, "p:event:comp-case-7:reward-quest", "receipt from case id")
	local second = w.service:compensate(t, op, "reward-quest")
	Assert.equal(second.outcome, "duplicate", "same case is a no-op")
	Assert.equal(stored(env, t.key).balances["currency-test"], 10, "paid once")
	local audit = env.logged("reward", "reward_compensation")
	Assert.count(audit, 2, "every attempt audited")
	Assert.equal(audit[1].fields.operator, "op-42", "operator recorded")
	Assert.equal(audit[1].fields.reason, "lost reward during outage", "reason recorded")
	Assert.equal(
		w.service:compensate(t, { operatorId = "", caseId = "x", reason = "r" }, "reward-quest").outcome,
		"refused",
		"no operator"
	)
	Assert.equal(
		w.service:compensate(t, { operatorId = "op", caseId = "x", reason = "" }, "reward-quest").outcome,
		"refused",
		"no reason"
	)
	Assert.count(env.logged("telemetry", "reward_compensation_duplicate"), 1, "duplicate counted")
end)

suite:case("run results are recorded once and pay every eligible player's slots once", function(env)
	local w = world(env, "job-a")
	local t1 = w.own(1)
	local t2 = w.own(2)
	local run: RewardService.RunResult = {
		runId = "run-abc",
		descentId = "descent-test",
		season = 3,
		completedAt = env.clock:wallTime(),
		players = {
			{
				target = t1,
				slots = {
					{ slot = 1, rewardId = "reward-gold" },
					{ slot = 2, rewardId = "reward-gold" },
				},
			},
			{ target = t2, slots = { { slot = 1, rewardId = "reward-gold" } } },
		},
	}
	local results = w.service:recordRunResult(run)
	local granted = 0
	for _, result in results do
		if result.outcome == "granted" then
			granted += 1
		end
	end
	Assert.equal(granted, 3, "three slot grants")
	Assert.equal(stored(env, t1.key).balances["currency-test"], 50, "player 1: two slots")
	Assert.equal(stored(env, t2.key).balances["currency-test"], 25, "player 2: one slot")

	local record = env.dataStores:peek(RUNS, "run-abc")
	Assert.notNil(record, "run record written")
	Assert.equal(
		record.players[1].slots[2].receiptId,
		"s:3:run-abc:2:reward-gold",
		"traceable receipt ids"
	)

	-- Replaying the same result (a retried completion) changes nothing.
	local replay = w.service:recordRunResult(run)
	local duplicates = 0
	for _, result in replay do
		if result.outcome == "duplicate" then
			duplicates += 1
		end
	end
	Assert.equal(duplicates, 3, "all duplicates")
	Assert.equal(stored(env, t1.key).balances["currency-test"], 50, "unchanged")
	Assert.equal(
		env.dataStores:peek(RUNS, "run-abc").completedAt,
		run.completedAt,
		"record not rewritten"
	)
	Assert.count(env.logged("telemetry", "descent_run_recorded"), 2, "recording counted each time")
end)

suite:case("reconcile settles uncertain writes and escalates intents past the window", function(env)
	local w = world(env, "job-a")
	local t = w.own(1)
	env.dataStores:injectFault({ kind = "lostResponse", operation = "UpdateAsync", times = 1 })
	local result = w.service:grantPermanent(t, { kind = "quest", id = "quest-x" }, "reward-quest")
	-- The intent write lost its response: the service reports pending.
	Assert.equal(result.outcome, "pending", "pending")
	Assert.notNil(
		stored(env, t.key).receipts.pending[result.receiptId :: string],
		"intent actually committed"
	)

	env.clock:advance(31)
	local report = w.service:reconcile(t)
	Assert.isTrue(report.settled, "uncertain intent write settled by reading")
	Assert.equal(report.retried, 1, "grant retried")
	Assert.equal(stored(env, t.key).balances["currency-test"], 10, "paid once")

	-- An intent for a reward that vanished from the catalog is escalated.
	local p: any = stored(env, t.key)
	p.receipts.pending["p:quest:old:reward-gone"] = {
		grantId = "p:quest:old:reward-gone",
		sourceId = "old",
		createdAt = env.clock:wallTime() - 1000,
		rewardCatalogId = "reward-gone",
	}
	env.dataStores:seed(STORE, t.key, p)
	local report2 = w.service:reconcile(t)
	Assert.equal(report2.escalated, 1, "escalated")
	Assert.equal(report2.retried, 0, "not retried")
	Assert.notNil(
		stored(env, t.key).receipts.pending["p:quest:old:reward-gone"],
		"left for an operator"
	)
	Assert.isTrue(#env.logged("reward", "reward_recovery_escalated") >= 2, "escalations logged")
end)

return suite:cases()
