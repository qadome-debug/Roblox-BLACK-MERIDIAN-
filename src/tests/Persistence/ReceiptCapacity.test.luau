--!strict
-- BM-047: capacity gauges, archive migration that preserves every claim,
-- and duplicate detection across archives.

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
local SaveQueue = require(ServerScriptService.Server.Persistence.SaveQueue)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("ReceiptCapacity")

local STORE = "Profiles"
local KEY = "player-1"
local P = Limits.PROFILE

local GOLD: RewardCatalog.Definition = RewardCatalog.build({
	{
		id = "reward-gold",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = 1 } },
	},
}):get("reward-gold") :: RewardCatalog.Definition

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
	local queue = SaveQueue.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		leases = leases,
		profiles = profiles,
	})
	local monitor = ReceiptCapacity.new({
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		profiles = profiles,
		archiveStore = env.dataStores:GetDataStore(ReceiptCapacity.ARCHIVE_STORE_NAME) :: any,
	})
	local _, handle = leases:acquire(KEY)
	queue:track(KEY, handle :: Lease.Handle)
	return monitor, queue, handle :: Lease.Handle
end

local function withReceipts(env: Suite.Env, count: number, handle: Lease.Handle): any
	local p: any = ProfileSchema.default()
	for i = 1, count do
		p.receipts.permanent[string.format("p:quest:q%04d:reward-gold", i)] = true
	end
	p.lease = handle.lease
	env.dataStores:seed(STORE, KEY, p)
	return p
end

suite:case("gauges report ok, warn and critical, and observe emits telemetry", function(env)
	local monitor, _, handle = make(env)
	local p = withReceipts(env, 10, handle)
	local report = monitor.observe(KEY, 1, p)
	Assert.equal(report.permanent.level, "ok", "ok")
	Assert.count(env.logged("telemetry", "receipt_capacity"), 0, "quiet when ok")

	p = withReceipts(env, math.ceil(P.MAX_PERMANENT_RECEIPTS * 0.8), handle)
	Assert.equal(monitor.observe(KEY, 1, p).permanent.level, "warn", "warn at 80%")
	p = withReceipts(env, math.ceil(P.MAX_PERMANENT_RECEIPTS * 0.95), handle)
	local critical = monitor.observe(KEY, 1, p)
	Assert.equal(critical.permanent.level, "critical", "critical at 95%")
	Assert.count(env.logged("telemetry", "receipt_capacity"), 2, "warn and critical counted")
	Assert.count(env.logged("persistence", "receipt_capacity_critical"), 1, "critical logged")
	Assert.equal(critical.archives, 0, "no archives yet")
end)

suite:case(
	"archiving moves the oldest half out, preserves every claim, and is idempotent",
	function(env)
		local monitor, queue, handle = make(env)
		local total = math.floor(P.MAX_PERMANENT_RECEIPTS * 0.9)
		local p = withReceipts(env, total, handle)
		Assert.isTrue(ReceiptCapacity.needsArchive(p), "needs archive at 90%")

		local mutation, reason = monitor.buildArchive(KEY, p)
		Assert.notNil(mutation, "mutation built: " .. tostring(reason))
		local archiveKey = ReceiptCapacity.archiveKey(KEY, 1)
		local record = env.dataStores:peek(ReceiptCapacity.ARCHIVE_STORE_NAME, archiveKey)
		Assert.notNil(record, "archive written before the profile changes")
		Assert.equal(record.count, math.floor(total / 2), "half moved")

		queue:enqueue(KEY, mutation :: SaveQueue.Mutation)
		Assert.equal(queue:flush(KEY), "committed", "profile updated")
		local after = env.dataStores:peek(STORE, KEY)
		local remaining = 0
		for _ in after.receipts.permanent do
			remaining += 1
		end
		Assert.equal(remaining, total - math.floor(total / 2), "remaining half")
		Assert.deepEqual(after.receipts.archives, { archiveKey }, "archive key recorded")
		Assert.count(ProfileSchema.validate(after), 0, "still valid")

		-- Every receipt is in exactly one place.
		local archived = monitor.loadArchived(after) :: { [string]: boolean }
		for i = 1, total do
			local id = string.format("p:quest:q%04d:reward-gold", i)
			local inProfile = after.receipts.permanent[id] == true
			local inArchive = archived[id] == true
			Assert.isTrue(inProfile ~= inArchive, id .. " must be in exactly one place")
		end
		Assert.isNil(after.receipts.permanent["p:quest:q0001:reward-gold"], "oldest id archived")
		Assert.equal(
			after.receipts.permanent[string.format("p:quest:q%04d:reward-gold", total)],
			true,
			"newest kept"
		)

		-- Re-applying the same archive mutation is a no-op.
		queue:enqueue(KEY, mutation :: SaveQueue.Mutation)
		Assert.equal(queue:flush(KEY), "committed", "no-op")
		Assert.equal(env.dataStores:peek(STORE, KEY).revision, after.revision, "no extra write")
		Assert.count(env.logged("telemetry", "receipts_archived"), 1, "counted once")
	end
)

suite:case("an archived receipt still blocks a duplicate grant", function(env)
	local monitor, queue, handle = make(env)
	local p = withReceipts(env, 4, handle)
	local mutation = monitor.buildArchive(KEY, p) :: SaveQueue.Mutation
	queue:enqueue(KEY, mutation)
	queue:flush(KEY)
	local after = env.dataStores:peek(STORE, KEY)
	local archived = monitor.loadArchived(after) :: { [string]: boolean }
	Assert.equal(archived["p:quest:q0001:reward-gold"], true, "archived")

	local grant =
		Receipts.permanentGrant("p:quest:q0001:reward-gold", GOLD, archived) :: SaveQueue.Mutation
	queue:enqueue(KEY, grant)
	Assert.equal(queue:flush(KEY), "committed", "treated as already applied")
	Assert.isNil(env.dataStores:peek(STORE, KEY).balances["currency-test"], "not paid again")
	Assert.isTrue((grant.isApplied :: any)(after), "isApplied sees the archive")

	-- Without the archived set, the same grant would pay: the service must
	-- always pass it. This documents the contract.
	local naive = Receipts.permanentGrant("p:quest:q0001:reward-gold", GOLD) :: SaveQueue.Mutation
	Assert.isFalse((naive.isApplied :: any)(after), "naive builder cannot see archives")
end)

suite:case("archive failures never touch the profile", function(env)
	local monitor, _, handle = make(env)
	local p = withReceipts(env, 10, handle)
	env.dataStores:injectFault({ kind = "timeout", operation = "UpdateAsync" })
	local mutation, reason = monitor.buildArchive(KEY, p)
	Assert.isNil(mutation, "no mutation")
	Assert.contains(reason :: string, "uncertain", "reason")
	Assert.isNil(
		env.dataStores:peek(ReceiptCapacity.ARCHIVE_STORE_NAME, ReceiptCapacity.archiveKey(KEY, 1)),
		"no archive record"
	)
	Assert.equal(env.dataStores:peek(STORE, KEY).revision, 0, "profile untouched")

	local small: any = ProfileSchema.default()
	small.receipts.permanent["p:quest:only:reward-gold"] = true
	local none, why = monitor.buildArchive(KEY, small)
	Assert.isNil(none, "nothing to archive")
	Assert.contains(why :: string, "nothing to archive", "reason")

	local capped: any = ProfileSchema.default()
	for i = 1, ReceiptCapacity.MAX_ARCHIVES do
		table.insert(capped.receipts.archives, "k" .. i)
	end
	capped.receipts.permanent.a = true
	capped.receipts.permanent.b = true
	local limited, limitReason = monitor.buildArchive(KEY, capped)
	Assert.isNil(limited, "archive limit")
	Assert.contains(limitReason :: string, "archive limit", "reason")
end)

suite:case(
	"an unreadable archive makes loadArchived return nil, so grants are refused",
	function(env)
		local monitor = make(env)
		local p: any = ProfileSchema.default()
		p.receipts.archives = { "missing-archive" }
		Assert.isNil(monitor.loadArchived(p), "nil on missing archive")
		Assert.count(env.logged("persistence", "receipt_archive_unreadable"), 1, "logged")
	end
)

return suite:cases()
