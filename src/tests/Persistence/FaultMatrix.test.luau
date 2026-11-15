--!strict
-- BM-044: the persistence and reward fault matrix. Every fault kind is
-- injected at every write boundary of a grant; afterwards reconciliation
-- must converge to exactly one payment, one receipt and no pending intent.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local ProfileStore = require(ServerScriptService.Server.Persistence.ProfileStore)
local ReceiptCapacity = require(ServerScriptService.Server.Persistence.ReceiptCapacity)
local RewardCatalog = require(ServerScriptService.Server.Content.RewardCatalog)
local RewardService = require(ServerScriptService.Server.Services.RewardService)
local SaveQueue = require(ServerScriptService.Server.Persistence.SaveQueue)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("FaultMatrix")

local STORE = "Profiles"

local CATALOG = RewardCatalog.build({
	{
		id = "reward-quest",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = 10 } },
	},
})

local FAULTS = { "error", "timeout", "lostResponse", "budget" }

type World = { service: RewardService.Service, queue: SaveQueue.Queue, leases: Lease.Manager }

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
		rng = env.rng:fork(jobId .. "-q"),
		logger = env.logger,
		leases = leases,
		profiles = profiles,
		backoff = { 1 },
	})
	local telemetry = Telemetry.new(env.logger)
	local service = RewardService.new({
		clock = env.clock,
		logger = env.logger,
		telemetry = telemetry,
		catalog = CATALOG,
		queue = queue,
		profiles = profiles,
		capacity = ReceiptCapacity.new({
			logger = env.logger,
			telemetry = telemetry,
			profiles = profiles,
			archiveStore = env.dataStores:GetDataStore(ReceiptCapacity.ARCHIVE_STORE_NAME) :: any,
		}),
		runStore = env.dataStores:GetDataStore(RewardService.RUN_STORE_NAME) :: any,
		seasons = { currentSeason = 1, retainedSeasons = 1 },
		retryAfterSeconds = 0,
		escalateAfterSeconds = 99999,
	})
	return { service = service, queue = queue, leases = leases }
end

local function own(w: World, key: string): RewardService.Target
	local _, handle = w.leases:acquire(key)
	Assert.notNil(handle, "lease for " .. key)
	w.queue:track(key, handle :: Lease.Handle)
	return { userId = 1, key = key }
end

local function converge(env: Suite.Env, w: World, target: RewardService.Target)
	for _ = 1, 12 do
		env.clock:advance(2)
		w.service:reconcile(target)
		local stored = env.dataStores:peek(STORE, target.key)
		if
			stored ~= nil
			and next(stored.receipts.pending) == nil
			and w.queue:pendingCount(target.key) == 0
		then
			return
		end
	end
end

local function assertPaidOnce(env: Suite.Env, key: string, receiptId: string, label: string)
	local stored = env.dataStores:peek(STORE, key)
	Assert.equal(stored.balances["currency-test"], 10, label .. ": paid exactly once")
	Assert.equal(stored.receipts.permanent[receiptId], true, label .. ": receipt present")
	Assert.isNil(stored.receipts.pending[receiptId], label .. ": no pending intent")
	Assert.count(ProfileSchema.validate(stored), 0, label .. ": profile valid")
end

-- Fault on the Nth UpdateAsync of the grant flow (1 = intent, 2 = grant).
for _, fault in FAULTS do
	for _, boundary in { 1, 2 } do
		suite:case(
			string.format("%s at write %d of a grant converges to one payment", fault, boundary),
			function(env)
				local w = world(env, "job-a")
				local key = "player-1"
				local target = own(w, key)
				-- Let `boundary - 1` writes through, then fault the next one.
				for _ = 1, boundary - 1 do
					env.dataStores:injectFault({
						kind = "delay",
						operation = "UpdateAsync",
						seconds = 0,
					})
				end
				env.dataStores:injectFault({ kind = fault :: any, operation = "UpdateAsync" })

				local result = w.service:grantPermanent(
					target,
					{ kind = "quest", id = "quest-x" },
					"reward-quest"
				)
				Assert.isTrue(
					result.outcome == "pending" or result.outcome == "granted",
					"pending or granted, got " .. result.outcome
				)
				converge(env, w, target)
				assertPaidOnce(env, key, result.receiptId :: string, fault .. "@" .. boundary)
			end
		)
	end
end

suite:case(
	"a crash after the intent is recovered by another server under every fault kind",
	function(env)
		for index, fault in FAULTS do
			local key = "player-" .. index
			local a = world(env, "job-a" .. index)
			local target = own(a, key)
			env.dataStores:injectFault({ kind = "delay", operation = "UpdateAsync", seconds = 0 }) -- intent lands
			env.dataStores:injectFault({ kind = fault :: any, operation = "UpdateAsync" }) -- grant write faults
			local result =
				a.service:grantPermanent(target, { kind = "quest", id = "quest-x" }, "reward-quest")
			-- Server a now "crashes": no reconcile; its lease expires.
			env.clock:advance(Lease.LIFETIME_SECONDS + 1)
			local b = world(env, "job-b" .. index)
			local target2 = own(b, key)
			converge(env, b, target2)
			assertPaidOnce(env, key, result.receiptId :: string, fault .. " crash")
		end
	end
)

suite:case("lease faults: acquire and renew under every fault keep single ownership", function(env)
	local raw = env.dataStores:GetDataStore(STORE) :: any
	local a = Lease.new({
		clock = env.clock,
		rng = env.rng:fork("a"),
		logger = env.logger,
		store = raw,
		jobId = "job-a",
	})
	local b = Lease.new({
		clock = env.clock,
		rng = env.rng:fork("b"),
		logger = env.logger,
		store = raw,
		jobId = "job-b",
	})
	for _, fault in FAULTS do
		local key = "player-" .. fault
		env.dataStores:injectFault({ kind = fault :: any, operation = "UpdateAsync" })
		local outcome, handle = a:acquire(key)
		Assert.equal(outcome, "error", fault .. ": acquire reports an error")
		Assert.isNil(handle, fault .. ": no handle")
		if fault == "lostResponse" then
			-- The lease actually committed; b must be refused until expiry.
			Assert.equal(
				(b:acquire(key)),
				"held",
				fault .. ": committed lease still protects the key"
			)
			env.clock:advance(Lease.LIFETIME_SECONDS + 1)
		end
		local retry, h2 = a:acquire(key)
		Assert.equal(retry, "acquired", fault .. ": retry acquires")
		env.dataStores:injectFault({ kind = fault :: any, operation = "UpdateAsync" })
		Assert.equal(
			a:renew(h2 :: Lease.Handle),
			"uncertain",
			fault .. ": renew under fault is uncertain"
		)
		Assert.equal(a:renew(h2 :: Lease.Handle), "renewed", fault .. ": renew settles")
		Assert.equal((b:acquire(key)), "held", fault .. ": still single owner")
	end
end)

suite:case("a corrupt profile stays quarantined through every read fault", function(env)
	local key = "player-corrupt"
	env.dataStores:seed(STORE, key, { schemaVersion = 2, revision = "bad" })
	local raw = env.dataStores:GetDataStore(STORE) :: any
	for _, fault in FAULTS do
		env.dataStores:injectFault({ kind = fault :: any, operation = "GetAsync" })
		local okRead = pcall(function()
			return raw:GetAsync(key)
		end)
		Assert.isFalse(okRead, fault .. ": read failed")
		Assert.equal(env.dataStores:peek(STORE, key).revision, "bad", fault .. ": untouched")
	end
end)

return suite:cases()
