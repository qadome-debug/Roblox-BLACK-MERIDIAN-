--!strict
-- BM-048: adversarial reward and persistence stress. Hundreds of grants
-- across players with random store faults, server crashes and takeovers,
-- forged duplicate attempts and stale owners. Invariants afterwards:
-- every receipt paid exactly once, balances match receipts, no pending
-- intents, no writes from fenced-out owners, every profile valid.

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

local suite = Suite.new("Stress")

local STORE = "Profiles"
local PLAYERS = 3
local ATTEMPTS = 120 -- per player

local CATALOG = RewardCatalog.build({
	{
		id = "reward-quest",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = 10 } },
	},
	{
		id = "reward-run",
		kind = "repeatable",
		sources = { "descent" },
		grants = { currencies = { ["currency-test"] = 10 } },
	},
})

local FAULTS = { "error", "timeout", "lostResponse", "budget" }

type World = {
	service: RewardService.Service,
	queue: SaveQueue.Queue,
	leases: Lease.Manager,
	targets: { [number]: RewardService.Target },
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
	return { service = service, queue = queue, leases = leases, targets = {} }
end

-- Acquires every player for this world; a player still held by a crashed
-- server is skipped until its lease expires.
local function adopt(w: World)
	for i = 1, PLAYERS do
		local key = "player-" .. i
		if w.targets[i] == nil then
			local _, handle = w.leases:acquire(key)
			if handle ~= nil then
				w.queue:track(key, handle)
				w.targets[i] = { userId = i, key = key }
			end
		end
	end
end

suite:caseWithSeeds(
	"random faults, crashes and replays never duplicate or corrupt",
	{ 101, 202, 303 },
	function(env, seed)
		local rng = env.rng:fork("stress")
		local current = world(env, "job-1")
		adopt(current)
		local generation = 1
		local requested: { [number]: { [string]: boolean } } = {}
		for i = 1, PLAYERS do
			requested[i] = {}
		end
		local successes = 0

		for attempt = 1, ATTEMPTS do
			-- Random store trouble before some attempts.
			if rng:chance(0.3) then
				env.dataStores:injectFault({
					kind = rng:pick(FAULTS) :: any,
					operation = "UpdateAsync",
				})
			end
			if rng:chance(0.1) then
				env.dataStores:injectFault({
					kind = rng:pick(FAULTS) :: any,
					operation = "GetAsync",
				})
			end

			-- Occasionally the server crashes: its queue and caches vanish, its
			-- lease expires, and a new server adopts the players.
			if attempt % 25 == 0 then
				env.clock:advance(Lease.LIFETIME_SECONDS + 1)
				generation += 1
				local stale = current
				current = world(env, "job-" .. generation)
				adopt(current)
				-- The stale server tries to keep writing with its old handles.
				for i, target in stale.targets do
					local result = stale.service:grantPermanent(
						target,
						{ kind = "quest", id = "stale-" .. attempt .. "-" .. i },
						"reward-quest"
					)
					Assert.notEqual(result.outcome, "granted", "fenced-out server must not grant")
				end
			end

			for i, target in current.targets do
				local kind = if rng:chance(0.5) then "quest" else "descent"
				local id: string
				if rng:chance(0.2) and next(requested[i]) ~= nil then
					-- Replay an earlier source (a client retry or a duplicate event).
					local ids = {}
					for existing in requested[i] do
						table.insert(ids, existing)
					end
					table.sort(ids)
					id = rng:pick(ids)
				else
					id = string.format("src-%d-%d", attempt, i)
					requested[i][id] = true
				end
				local result
				if kind == "quest" then
					result = current.service:grantPermanent(
						target,
						{ kind = "quest", id = id },
						"reward-quest"
					)
				else
					result = current.service:grantSeasonal(target, id, 1, "reward-run", 1)
				end
				if result.outcome == "granted" then
					successes += 1
				end
			end
			env.clock:advance(1)
		end

		-- Let the final server converge.
		env.dataStores:clearFaults()
		adopt(current)
		for _ = 1, 20 do
			env.clock:advance(2)
			for _, target in current.targets do
				current.service:reconcile(target)
			end
		end

		for i = 1, PLAYERS do
			local stored = env.dataStores:peek(STORE, "player-" .. i)
			Assert.notNil(stored, "player " .. i .. " has a profile")
			Assert.count(
				ProfileSchema.validate(stored),
				0,
				"player " .. i .. " profile valid (seed " .. seed .. ")"
			)
			local receipts = 0
			for _ in stored.receipts.permanent do
				receipts += 1
			end
			for _ in stored.receipts.seasonal do
				receipts += 1
			end
			Assert.equal(
				stored.balances["currency-test"] or 0,
				receipts * 10,
				"player " .. i .. ": balance equals 10 per receipt"
			)
			local state = current.queue:state("player-" .. i)
			local diag = if state == nil
				then "untracked"
				else string.format(
					"pending=%d lost=%s failures=%d op=%s nextAt=%d now=%d valid=%s",
					#state.pending,
					tostring(state.handle.lost),
					state.failures,
					tostring(state.operation ~= nil),
					state.nextAttemptAt,
					env.clock:wallTime(),
					tostring(current.leases:isValid(state.handle))
				)
			Assert.isNil(
				next(stored.receipts.pending),
				"player " .. i .. ": no pending intents (" .. diag .. ")"
			)
			for receiptId in stored.receipts.permanent do
				local source = string.match(receiptId, "^p:quest:(.-):reward%-quest$")
				Assert.isTrue(
					source ~= nil and requested[i][source :: string] == true,
					"receipt " .. receiptId .. " traces to a real request"
				)
			end
		end
		Assert.isTrue(successes > ATTEMPTS, "the run exercised real grants: " .. successes)
	end
)

return suite:cases()
