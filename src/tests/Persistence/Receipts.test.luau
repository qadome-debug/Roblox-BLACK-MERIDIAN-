--!strict
-- BM-036..039: one-time grants cannot duplicate across sessions, seasonal
-- grants respect retention, intents survive a crash, and grant + receipt
-- commit atomically.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local Limits = require(game:GetService("ReplicatedStorage").Shared.Constants.Limits)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local ProfileStore = require(ServerScriptService.Server.Persistence.ProfileStore)
local Receipts = require(ServerScriptService.Server.Persistence.Receipts)
local RewardCatalog = require(ServerScriptService.Server.Content.RewardCatalog)
local SaveQueue = require(ServerScriptService.Server.Persistence.SaveQueue)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Receipts")

local STORE = "Profiles"
local KEY = "player-1"
local P = Limits.PROFILE

local CATALOG = RewardCatalog.build({
	{
		id = "reward-gold",
		kind = "repeatable",
		sources = { "descent" },
		grants = { currencies = { ["currency-test"] = 25 } },
	},
	{
		id = "reward-nearness",
		kind = "permanent",
		sources = { "waymark" },
		grants = {
			cants = { "cant.nearness" },
			waymarks = { "waymark-i" },
			instances = { "item-test-blade" },
		},
	},
	{
		id = "reward-overcap",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = 100000 } },
	},
})

local POLICY: Receipts.SeasonPolicy = { currentSeason = 5, retainedSeasons = 2 }

-- A "server": its own lease manager, store and queue over the shared fake.
local function server(env: Suite.Env, jobId: string)
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
	local _, handle = leases:acquire(KEY)
	if handle ~= nil then
		queue:track(KEY, handle)
	end
	return { leases = leases, queue = queue, handle = handle }
end

local function def(id: string): RewardCatalog.Definition
	return CATALOG:get(id) :: RewardCatalog.Definition
end

local function stored(env: Suite.Env): any
	return env.dataStores:peek(STORE, KEY)
end

suite:case("a permanent grant applies once and writes its receipt atomically", function(env)
	local s = server(env, "job-a")
	local receiptId =
		RewardCatalog.permanentReceiptId("waymark", "waymark-i", "reward-nearness") :: string
	local mutation =
		Receipts.permanentGrant(receiptId, def("reward-nearness")) :: SaveQueue.Mutation
	s.queue:enqueue(KEY, mutation)
	Assert.equal(s.queue:flush(KEY), "committed", "committed")
	local p = stored(env)
	Assert.equal(p.receipts.permanent[receiptId], true, "receipt")
	Assert.equal(p.cants.unlocked["cant.nearness"], true, "cant unlocked")
	Assert.equal(p.waymarks["waymark-i"].activated, true, "waymark activated")
	Assert.count(p.inventory, 1, "instance granted")
	Assert.isTrue(
		string.match(p.inventory[1].instanceId, "^i%-%x+%-1$") ~= nil,
		"deterministic instance id"
	)
	Assert.count(ProfileSchema.validate(p), 0, "valid")

	-- Same receipt again, same session: nothing changes.
	s.queue:enqueue(
		KEY,
		Receipts.permanentGrant(receiptId, def("reward-nearness")) :: SaveQueue.Mutation
	)
	Assert.equal(s.queue:flush(KEY), "committed", "treated as already applied")
	Assert.count(stored(env).inventory, 1, "no second instance")
	Assert.equal(stored(env).revision, 1, "no second write")
end)

suite:case("a duplicate permanent grant from another session is also a no-op", function(env)
	local a = server(env, "job-a")
	local receiptId = RewardCatalog.permanentReceiptId("quest", "quest-x", "reward-gold") :: string
	a.queue:enqueue(
		KEY,
		Receipts.permanentGrant(receiptId, def("reward-gold")) :: SaveQueue.Mutation
	)
	a.queue:flush(KEY)
	a.leases:release(a.handle :: Lease.Handle)

	local b = server(env, "job-b")
	Assert.notNil(b.handle, "second server owns the profile now")
	b.queue:enqueue(
		KEY,
		Receipts.permanentGrant(receiptId, def("reward-gold")) :: SaveQueue.Mutation
	)
	Assert.equal(b.queue:flush(KEY), "committed", "no-op success")
	Assert.equal(stored(env).balances["currency-test"], 25, "paid exactly once across sessions")
end)

suite:case("a grant that fails leaves no receipt and no partial change", function(env)
	local s = server(env, "job-a")
	local full: any = ProfileSchema.default()
	full.balances["currency-test"] = 1_000_000_000 - 10 -- 10 below the default cap
	full.lease = stored(env).lease
	env.dataStores:seed(STORE, KEY, full)
	local receiptId =
		RewardCatalog.permanentReceiptId("quest", "quest-x", "reward-overcap") :: string
	s.queue:enqueue(
		KEY,
		Receipts.permanentGrant(receiptId, def("reward-overcap")) :: SaveQueue.Mutation
	)
	local outcome, reason = s.queue:flush(KEY)
	Assert.equal(outcome, "rejected", "the mutation failed deterministically")
	Assert.contains(reason :: string, "overCap", "reason")
	local p = stored(env)
	Assert.isNil(p.receipts.permanent[receiptId], "no receipt")
	Assert.equal(p.balances["currency-test"], 1_000_000_000 - 10, "balance untouched")
end)

suite:case("permanent receipts fail closed at capacity and are never pruned", function(env)
	local s = server(env, "job-a")
	local p: any = ProfileSchema.default()
	for i = 1, P.MAX_PERMANENT_RECEIPTS do
		p.receipts.permanent["p:quest:q" .. i .. ":reward-gold"] = true
	end
	p.lease = stored(env).lease
	env.dataStores:seed(STORE, KEY, p)
	local receiptId =
		RewardCatalog.permanentReceiptId("quest", "quest-new", "reward-gold") :: string
	s.queue:enqueue(
		KEY,
		Receipts.permanentGrant(receiptId, def("reward-gold")) :: SaveQueue.Mutation
	)
	local outcome, reason = s.queue:flush(KEY)
	Assert.equal(outcome, "rejected", "failed closed")
	Assert.contains(reason :: string, "capacity exhausted", "reason")
	local after = stored(env)
	local count = 0
	for _ in after.receipts.permanent do
		count += 1
	end
	Assert.equal(count, P.MAX_PERMANENT_RECEIPTS, "nothing pruned")
	Assert.isNil(after.balances["currency-test"], "nothing granted")
end)

suite:case("seasonal grants: duplicate, late and cross-season", function(env)
	local s = server(env, "job-a")
	local id = RewardCatalog.seasonalReceiptId(5, "run-1", 1, "reward-gold") :: string
	s.queue:enqueue(
		KEY,
		Receipts.seasonalGrant(id, 5, def("reward-gold"), POLICY) :: SaveQueue.Mutation
	)
	s.queue:flush(KEY)
	s.queue:enqueue(
		KEY,
		Receipts.seasonalGrant(id, 5, def("reward-gold"), POLICY) :: SaveQueue.Mutation
	)
	s.queue:flush(KEY)
	Assert.equal(stored(env).balances["currency-test"], 25, "duplicate run grant paid once")
	Assert.equal(stored(env).receipts.seasonal[id], 5, "season recorded")

	local late = RewardCatalog.seasonalReceiptId(2, "run-old", 1, "reward-gold") :: string
	local mutation, refusal = Receipts.seasonalGrant(late, 2, def("reward-gold"), POLICY)
	Assert.isNil(mutation, "closed season refused before enqueue")
	Assert.equal(refusal, "seasonClosed", "refusal")

	local prev = RewardCatalog.seasonalReceiptId(4, "run-prev", 1, "reward-gold") :: string
	Assert.notNil(
		Receipts.seasonalGrant(prev, 4, def("reward-gold"), POLICY),
		"previous season still open"
	)
	local future = RewardCatalog.seasonalReceiptId(6, "run-next", 1, "reward-gold") :: string
	local m2, r2 = Receipts.seasonalGrant(future, 6, def("reward-gold"), POLICY)
	Assert.isNil(m2, "future season refused")
	Assert.equal(r2, "seasonClosed", "refusal")
	Assert.isTrue(
		Receipts.isSeasonOpen(POLICY, 4) and not Receipts.isSeasonOpen(POLICY, 3),
		"retention window"
	)
end)

suite:case(
	"the seasonal ledger prunes only closed seasons under pressure, then fails closed",
	function(env)
		local s = server(env, "job-a")
		local p: any = ProfileSchema.default()
		for i = 1, P.MAX_SEASONAL_RECEIPTS - 1 do
			p.receipts.seasonal["s:5:run" .. i .. ":1:reward-gold"] = 5
		end
		p.receipts.seasonal["s:1:ancient:1:reward-gold"] = 1 -- closed season
		p.lease = stored(env).lease
		env.dataStores:seed(STORE, KEY, p)

		local id = RewardCatalog.seasonalReceiptId(5, "run-new", 1, "reward-gold") :: string
		s.queue:enqueue(
			KEY,
			Receipts.seasonalGrant(id, 5, def("reward-gold"), POLICY) :: SaveQueue.Mutation
		)
		Assert.equal(s.queue:flush(KEY), "committed", "room made by pruning the closed season")
		local after = stored(env)
		Assert.isNil(
			after.receipts.seasonal["s:1:ancient:1:reward-gold"],
			"closed-season receipt pruned"
		)
		Assert.equal(after.receipts.seasonal[id], 5, "new receipt")
		Assert.equal(
			after.receipts.seasonal["s:5:run1:1:reward-gold"],
			5,
			"open-season receipts kept"
		)

		local id2 = RewardCatalog.seasonalReceiptId(5, "run-new-2", 1, "reward-gold") :: string
		s.queue:enqueue(
			KEY,
			Receipts.seasonalGrant(id2, 5, def("reward-gold"), POLICY) :: SaveQueue.Mutation
		)
		local outcome, reason = s.queue:flush(KEY)
		Assert.equal(outcome, "rejected", "nothing left to prune: fail closed")
		Assert.contains(reason :: string, "capacity exhausted", "reason")
	end
)

suite:case(
	"intents are recorded durably, survive a crash, and are cleared by the grant",
	function(env)
		local a = server(env, "job-a")
		local grantId =
			RewardCatalog.permanentReceiptId("waymark", "waymark-i", "reward-nearness") :: string
		local intent = Receipts.recordIntent(
			grantId,
			"waymark-i",
			"reward-nearness",
			env.clock:wallTime()
		) :: SaveQueue.Mutation
		a.queue:enqueue(KEY, intent)
		Assert.equal(a.queue:flush(KEY), "committed", "intent written")
		Assert.notNil(stored(env).receipts.pending[grantId], "pending on disk")

		-- "Crash": server a vanishes without granting. Its lease expires.
		env.clock:advance(Lease.LIFETIME_SECONDS + 1)
		local b = server(env, "job-b")
		local loaded = stored(env)
		local stale = Receipts.stalePending(loaded, env.clock:wallTime(), 60)
		Assert.count(stale, 1, "recovery sees the owed grant")
		Assert.equal(stale[1].grantId, grantId, "same grant id")

		b.queue:enqueue(
			KEY,
			Receipts.permanentGrant(stale[1].grantId, def(stale[1].rewardCatalogId)) :: SaveQueue.Mutation
		)
		Assert.equal(b.queue:flush(KEY), "committed", "fulfilled by the new owner")
		local after = stored(env)
		Assert.isNil(after.receipts.pending[grantId], "intent cleared in the same write")
		Assert.equal(after.receipts.permanent[grantId], true, "receipt written")
		Assert.equal(after.revision, 2, "intent write + grant write")

		-- Recording the intent again after fulfilment is a no-op.
		b.queue:enqueue(
			KEY,
			Receipts.recordIntent(grantId, "waymark-i", "reward-nearness", 0) :: SaveQueue.Mutation
		)
		Assert.equal(b.queue:flush(KEY), "committed", "no-op")
		Assert.isNil(stored(env).receipts.pending[grantId], "not re-recorded")
	end
)

suite:case("pending intents are bounded and clearIntent removes one", function(env)
	local s = server(env, "job-a")
	for i = 1, P.MAX_PENDING_INTENTS do
		s.queue:enqueue(
			KEY,
			Receipts.recordIntent("g" .. i, "src", "reward-gold", i) :: SaveQueue.Mutation
		)
	end
	Assert.equal(s.queue:flush(KEY), "committed", "filled")
	s.queue:enqueue(
		KEY,
		Receipts.recordIntent("g-overflow", "src", "reward-gold", 99) :: SaveQueue.Mutation
	)
	local outcome, reason = s.queue:flush(KEY)
	Assert.equal(outcome, "rejected", "fails closed")
	Assert.contains(reason :: string, "intent limit", "reason")
	s.queue:enqueue(KEY, Receipts.clearIntent("g1"))
	Assert.equal(s.queue:flush(KEY), "committed", "cleared")
	Assert.isNil(stored(env).receipts.pending.g1, "gone")
	local _, bad = Receipts.recordIntent("bad id", "src", "reward-gold", 1)
	Assert.equal(bad, "badId", "bad ids refused up front")
end)

return suite:cases()
