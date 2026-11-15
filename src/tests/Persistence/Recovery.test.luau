--!strict
-- BM-049: unauthorized recovery is refused and logged; every operator
-- action is idempotent and goes through the persistence layer.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Lease = require(ServerScriptService.Server.Persistence.Lease)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local ProfileStore = require(ServerScriptService.Server.Persistence.ProfileStore)
local ReceiptCapacity = require(ServerScriptService.Server.Persistence.ReceiptCapacity)
local Recovery = require(ServerScriptService.Server.Operations.Recovery)
local RewardCatalog = require(ServerScriptService.Server.Content.RewardCatalog)
local RewardService = require(ServerScriptService.Server.Services.RewardService)
local SaveQueue = require(ServerScriptService.Server.Persistence.SaveQueue)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("Recovery")

local STORE = "Profiles"
local KEY = "player-1"
local TARGET: RewardService.Target = { userId = 1, key = KEY }

local CATALOG = RewardCatalog.build({
	{
		id = "reward-quest",
		kind = "permanent",
		sources = { "quest" },
		grants = { currencies = { ["currency-test"] = 10 } },
	},
})

local SUPPORT: Recovery.Operator =
	{ operatorId = "op-support", role = "support", caseId = "case-1" }
local ADMIN: Recovery.Operator = { operatorId = "op-admin", role = "admin", caseId = "case-2" }

local function make(env: Suite.Env)
	local raw = env.dataStores:GetDataStore(STORE) :: any
	local leases = Lease.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		store = raw,
		jobId = "ops",
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
	local telemetry = Telemetry.new(env.logger)
	local rewards = RewardService.new({
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
	})
	local workflow = Recovery.new({
		logger = env.logger,
		telemetry = telemetry,
		rewards = rewards,
		profiles = profiles,
		queue = queue,
		leases = leases,
	})
	return workflow, leases, queue
end

-- Seeds an offline profile with one pending intent.
local function seedPending(env: Suite.Env): string
	local p: any = ProfileSchema.default()
	local grantId = RewardCatalog.permanentReceiptId("quest", "quest-x", "reward-quest") :: string
	p.receipts.pending[grantId] =
		{ grantId = grantId, sourceId = "quest-x", createdAt = 1, rewardCatalogId = "reward-quest" }
	env.dataStores:seed(STORE, KEY, p)
	return grantId
end

suite:case("unauthorized roles and missing operators are refused and logged", function(env)
	local workflow = make(env)
	seedPending(env)
	Assert.equal(
		workflow:clearIntent(SUPPORT, TARGET, "x", "r").outcome,
		"unauthorized",
		"support cannot clear"
	)
	Assert.equal(
		workflow:compensate(SUPPORT, TARGET, "reward-quest", "r").outcome,
		"unauthorized",
		"support cannot compensate"
	)
	Assert.equal(workflow:repair(SUPPORT, TARGET).outcome, "unauthorized", "support cannot repair")
	local nobody: Recovery.Operator = { operatorId = "", role = "admin", caseId = "c" }
	Assert.equal(workflow:inspect(nobody, TARGET).outcome, "unauthorized", "no operator id")
	local noCase: Recovery.Operator = { operatorId = "op", role = "admin", caseId = "" }
	Assert.equal(workflow:inspect(noCase, TARGET).outcome, "unauthorized", "no case")
	local bogus: Recovery.Operator = { operatorId = "op", role = "root" :: any, caseId = "c" }
	Assert.equal(workflow:inspect(bogus, TARGET).outcome, "unauthorized", "unknown role")
	local denials = env.logged("security", "operator_action")
	Assert.count(denials, 6, "every denial logged")
	Assert.equal(denials[1].fields.outcome, "unauthorized", "outcome in log")
	Assert.equal(denials[1].fields.operator, "op-support", "operator in log")
	Assert.equal(env.dataStores:callCount("UpdateAsync"), 0, "nothing written")
end)

suite:case("inspect is read-only and summarizes validity, intents and capacity", function(env)
	local workflow = make(env)
	local grantId = seedPending(env)
	local result = workflow:inspect(SUPPORT, TARGET)
	Assert.equal(result.outcome, "ok", "ok")
	local data = result.data :: any
	Assert.isTrue(data.valid, "valid")
	Assert.count(data.pending, 1, "one intent")
	Assert.equal(data.pending[1].grantId, grantId, "intent id")
	Assert.equal(data.capacity.pending.count, 1, "capacity report")
	Assert.equal(env.dataStores:callCount("UpdateAsync"), 0, "no writes")
	Assert.equal(
		workflow:inspect(SUPPORT, { userId = 9, key = "player-9" }).outcome,
		"notFound",
		"unknown player"
	)
end)

suite:case("retryIntent fulfils a stuck grant, then reports notFound", function(env)
	local workflow, leases = make(env)
	local grantId = seedPending(env)
	local result = workflow:retryIntent(SUPPORT, TARGET, grantId)
	Assert.equal(result.outcome, "ok", "fulfilled: " .. tostring(result.detail))
	local p = env.dataStores:peek(STORE, KEY)
	Assert.equal(p.balances["currency-test"], 10, "paid")
	Assert.isNil(p.receipts.pending[grantId], "intent cleared")
	Assert.count(leases:held(), 0, "lease given back")
	Assert.equal(
		workflow:retryIntent(SUPPORT, TARGET, grantId).outcome,
		"notFound",
		"second retry finds nothing"
	)
	Assert.equal(env.dataStores:peek(STORE, KEY).balances["currency-test"], 10, "still once")
end)

suite:case("clearIntent needs a reason, is idempotent, and is audited at warn", function(env)
	local workflow = make(env)
	local grantId = seedPending(env)
	Assert.equal(
		workflow:clearIntent(ADMIN, TARGET, grantId, "").outcome,
		"refused",
		"reason required"
	)
	Assert.equal(
		workflow:clearIntent(ADMIN, TARGET, grantId, "reward withdrawn").outcome,
		"ok",
		"cleared"
	)
	Assert.isNil(env.dataStores:peek(STORE, KEY).receipts.pending[grantId], "gone")
	Assert.equal(
		workflow:clearIntent(ADMIN, TARGET, grantId, "again").outcome,
		"noop",
		"idempotent"
	)
	local audits = env.logged("security", "operator_action")
	local last = audits[#audits]
	Assert.equal(last.level, "warn", "destructive actions audited at warn")
	Assert.equal(last.fields.reason, "again", "reason recorded")
end)

suite:case("compensate is idempotent per case and attributed", function(env)
	local workflow = make(env)
	env.dataStores:seed(STORE, KEY, ProfileSchema.default())
	local first = workflow:compensate(ADMIN, TARGET, "reward-quest", "lost in outage")
	Assert.equal(first.outcome, "ok", "granted: " .. tostring(first.detail))
	Assert.equal(
		workflow:compensate(ADMIN, TARGET, "reward-quest", "lost in outage").outcome,
		"noop",
		"same case no-op"
	)
	Assert.equal(env.dataStores:peek(STORE, KEY).balances["currency-test"], 10, "paid once")
	local other: Recovery.Operator = { operatorId = "op-admin", role = "admin", caseId = "case-3" }
	Assert.equal(
		workflow:compensate(other, TARGET, "reward-quest", "second case").outcome,
		"ok",
		"a new case pays again"
	)
	Assert.equal(
		workflow:compensate(ADMIN, TARGET, "reward-nope", "x").outcome,
		"refused",
		"unknown reward"
	)
end)

suite:case("repair writes back only a repaired profile, never an unfixable one", function(env)
	local workflow = make(env)
	local broken: any = ProfileSchema.default()
	broken.descents = nil
	env.dataStores:seed(STORE, KEY, broken)
	local result = workflow:repair(ADMIN, TARGET)
	Assert.equal(result.outcome, "ok", "repaired: " .. tostring(result.detail))
	Assert.deepEqual((result.data :: any).changes, { "added missing descents" }, "changes reported")
	Assert.count(
		ProfileSchema.validate(env.dataStores:peek(STORE, KEY)),
		0,
		"stored profile valid now"
	)
	Assert.equal(workflow:repair(ADMIN, TARGET).outcome, "noop", "already valid")

	local unfixable: any = ProfileSchema.default()
	unfixable.balances["currency-test"] = -1
	env.dataStores:seed(STORE, "player-2", unfixable)
	local refused = workflow:repair(ADMIN, { userId = 2, key = "player-2" })
	Assert.equal(refused.outcome, "refused", "not repaired")
	Assert.equal(
		env.dataStores:peek(STORE, "player-2").balances["currency-test"],
		-1,
		"left for a human"
	)
end)

suite:case("writes are refused while the player is online", function(env)
	local workflow = make(env)
	local grantId = seedPending(env)
	local raw = env.dataStores:GetDataStore(STORE) :: any
	local live = Lease.new({
		clock = env.clock,
		rng = env.rng:fork("live"),
		logger = env.logger,
		store = raw,
		jobId = "game",
	})
	Assert.equal((live:acquire(KEY)), "acquired", "game server owns it")
	local result = workflow:retryIntent(SUPPORT, TARGET, grantId)
	Assert.equal(result.outcome, "refused", "refused while held")
	Assert.contains(result.detail :: string, "offline", "reason")
	Assert.equal(workflow:inspect(SUPPORT, TARGET).outcome, "ok", "reads still work")
end)

return suite:cases()
