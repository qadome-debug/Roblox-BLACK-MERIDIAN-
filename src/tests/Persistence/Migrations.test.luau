--!strict
-- BM-023: upgrade fixtures, repeated migrations, future-schema refusal.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Migrations = require(ServerScriptService.Server.Persistence.Migrations)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local ReceiptCapacity = require(ServerScriptService.Server.Persistence.ReceiptCapacity)
local Receipts = require(ServerScriptService.Server.Persistence.Receipts)
local RewardCatalog = require(ServerScriptService.Server.Content.RewardCatalog)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("Migrations")

-- A fake chain: v1 adds `titles`, v2 renames `gold` to `coins`.
local function chain(): { Migrations.Step }
	return {
		{
			from = 1,
			to = 2,
			apply = function(raw)
				raw.titles = raw.titles or {}
				raw.schemaVersion = 2
				return raw
			end,
		},
		{
			from = 2,
			to = 3,
			apply = function(raw)
				raw.coins = raw.gold or 0
				raw.gold = nil
				raw.schemaVersion = 3
				return raw
			end,
		},
	}
end

suite:case("production migrator accepts a current profile unchanged", function()
	local migrator = Migrations.production()
	local profile = ProfileSchema.default()
	local result = migrator:migrate(profile)
	Assert.isNil(result.error, "no error")
	Assert.count(result.applied, 0, "no steps")
	Assert.deepEqual(result.profile, profile, "same content")
	Assert.isTrue(result.profile ~= profile, "but a copy, never the stored object")
	Assert.count(ProfileSchema.validate(result.profile), 0, "still valid")
end)

suite:case("steps run in order from the stored version to the current one", function()
	local migrator = Migrations.new(chain(), 3)
	local result = migrator:migrate({ schemaVersion = 1, gold = 7 })
	Assert.isNil(result.error, "no error")
	Assert.deepEqual(result.applied, { 2, 3 }, "both steps")
	Assert.deepEqual(result.profile, { schemaVersion = 3, titles = {}, coins = 7 }, "migrated")

	local partial = migrator:migrate({ schemaVersion = 2, titles = { "a" }, gold = 1 })
	Assert.deepEqual(partial.applied, { 3 }, "only the second step")
	Assert.deepEqual(
		partial.profile,
		{ schemaVersion = 3, titles = { "a" }, coins = 1 },
		"migrated from v2"
	)
end)

suite:case("migrating twice is a no-op the second time", function()
	local migrator = Migrations.new(chain(), 3)
	local first = migrator:migrate({ schemaVersion = 1, gold = 7 })
	local second = migrator:migrate(first.profile)
	Assert.count(second.applied, 0, "nothing applied")
	Assert.deepEqual(second.profile, first.profile, "unchanged")
end)

suite:case("the stored object is never mutated", function()
	local migrator = Migrations.new(chain(), 3)
	local stored = { schemaVersion = 1, gold = 7, nested = { a = 1 } }
	local result = migrator:migrate(stored)
	Assert.equal(stored.schemaVersion, 1, "stored version untouched")
	Assert.equal(stored.gold, 7, "stored field untouched")
	Assert.isTrue((result.profile :: any).nested ~= stored.nested, "nested tables copied")
end)

suite:case("future schemas are refused without rewriting", function()
	local migrator = Migrations.new(chain(), 3)
	local result = migrator:migrate({ schemaVersion = 4, coins = 1 })
	Assert.isNil(result.profile, "no profile")
	Assert.contains(result.error :: string, "schema 4 but this server supports up to 3", "reason")
	local prod = Migrations.production():migrate({ schemaVersion = 5 })
	Assert.isNil(prod.profile, "production refuses v5 while current is v4")
end)

suite:case("gaps, failures and bad output are refused", function()
	local steps = chain()
	table.remove(steps, 1)
	local migrator = Migrations.new(steps, 3)
	local gap = migrator:migrate({ schemaVersion = 1 })
	Assert.contains(gap.error :: string, "no migration from schema 1", "gap")

	local failing = Migrations.new({
		{
			from = 1,
			to = 2,
			apply = function()
				error("boom")
			end,
		},
	}, 2)
	Assert.contains(
		failing:migrate({ schemaVersion = 1 }).error :: string,
		"migration 1 -> 2 failed: ",
		"failure"
	)

	local wrongVersion = Migrations.new({
		{
			from = 1,
			to = 2,
			apply = function(raw)
				return raw -- forgot to bump the version
			end,
		},
	}, 2)
	Assert.contains(
		wrongVersion:migrate({ schemaVersion = 1 }).error :: string,
		"did not produce schema 2",
		"bad output"
	)
end)

suite:case("invalid stored values are refused", function()
	local migrator = Migrations.new(chain(), 3)
	Assert.contains(migrator:migrate(nil).error :: string, "not a table", "nil")
	Assert.contains(migrator:migrate("x").error :: string, "not a table", "string")
	Assert.contains(
		migrator:migrate({}).error :: string,
		"no valid schemaVersion",
		"missing version"
	)
	Assert.contains(
		migrator:migrate({ schemaVersion = 0 }).error :: string,
		"no valid schemaVersion",
		"zero"
	)
	Assert.contains(
		migrator:migrate({ schemaVersion = 1.5 }).error :: string,
		"no valid schemaVersion",
		"fraction"
	)
end)

suite:case("chains are validated at construction", function()
	Assert.throws(function()
		Migrations.new(
			{ {
				from = 1,
				to = 3,
				apply = function(r)
					return r
				end,
			} },
			3
		)
	end, "must advance exactly one version")
	Assert.throws(function()
		Migrations.new({
			{
				from = 1,
				to = 2,
				apply = function(r)
					return r
				end,
			},
			{
				from = 1,
				to = 2,
				apply = function(r)
					return r
				end,
			},
		}, 2)
	end, "duplicate step")
	Assert.throws(function()
		Migrations.new(
			{ {
				from = 1,
				to = 2,
				apply = function(r)
					return r
				end,
			} },
			1
		)
	end, "past the current version")
end)

suite:case("v2 to v3 carries the old Nearness ID over and touches nothing else", function()
	local old: any = ProfileSchema.default()
	old.schemaVersion = 2
	old.revision = 41
	old.cants.unlocked = { ["cant-nearness"] = true }
	old.cants.verses = { ["cant-nearness"] = {} }
	old.cants.equipped = "cant-nearness"
	old.balances = { ["currency-test"] = 7 }
	old.receipts.permanent["p:quest:q1:reward-x"] = true
	old.receipts.archives = { "p:1:archive:1" }

	local result = Migrations.production():migrate(old)
	Assert.notNil(result.profile, "migrated: " .. tostring(result.error))
	local now: any = result.profile
	Assert.deepEqual(result.applied, { 3, 4 }, "both steps applied")
	Assert.equal(now.schemaVersion, 4, "version")
	Assert.deepEqual(now.cants.unlocked, { ["cant.nearness"] = true }, "ownership kept")
	Assert.deepEqual(now.cants.verses, { ["cant.nearness"] = {} }, "Verse map kept")
	Assert.equal(now.cants.equipped, "cant.nearness", "equipped Cant kept")
	Assert.equal(now.revision, 41, "revision untouched")
	Assert.equal(now.balances["currency-test"], 7, "balances untouched")
	Assert.equal(now.receipts.permanent["p:quest:q1:reward-x"], true, "receipts untouched")
	Assert.deepEqual(now.receipts.archives, { "p:1:archive:1" }, "archives untouched")
	Assert.count(ProfileSchema.validate(now), 0, "valid under the current schema")
	Assert.equal(old.cants.equipped, "cant-nearness", "the input is not modified")

	-- From v1 both steps run in order.
	local v1: any = ProfileSchema.default()
	v1.schemaVersion = 1
	v1.receipts.archives = nil
	v1.cants.unlocked = { ["cant-nearness"] = true }
	v1.cants.verses = { ["cant-nearness"] = {} }
	local fromV1 = Migrations.production():migrate(v1)
	Assert.deepEqual(fromV1.applied, { 2, 3, 4 }, "three steps")
	Assert.count(ProfileSchema.validate(fromV1.profile :: any), 0, "valid")

	-- A profile already on v4 is returned as it is.
	local current: any = ProfileSchema.default()
	current.cants.unlocked = { ["cant.nearness"] = true }
	current.cants.verses = { ["cant.nearness"] = {} }
	local same = Migrations.production():migrate(current)
	Assert.deepEqual(same.applied, {}, "nothing to do")
	Assert.deepEqual(same.profile, current, "unchanged")
end)

suite:case("v3 to v4 renames Waymark I everywhere it is saved", function()
	local old: any = ProfileSchema.default()
	old.schemaVersion = 3
	old.revision = 9
	old.waymarks = { ["waymark-i"] = { activated = true, rank = 1 } }
	old.receipts.permanent = {
		["p:waymark:waymark-i:reward-waymark"] = true,
		["p:quest:q1:reward-x"] = true,
		["p:quest:waymark-i-notes:reward-y"] = true,
	}
	old.receipts.seasonal = { ["s:1:run-1:1:reward-gold"] = 1 }
	old.receipts.pending = {
		["p:waymark:waymark-i:reward-pending"] = {
			grantId = "p:waymark:waymark-i:reward-pending",
			sourceId = "waymark-i",
			createdAt = 5,
			rewardCatalogId = "reward-pending",
		},
	}
	old.balances = { ["currency-test"] = 5 }

	local result = Migrations.production():migrate(old)
	Assert.notNil(result.profile, "migrated: " .. tostring(result.error))
	local now: any = result.profile
	Assert.deepEqual(result.applied, { 4 }, "one step")
	Assert.deepEqual(
		now.waymarks,
		{ ["waymark.branded"] = { activated = true, rank = 1 } },
		"progress moved to the new ID"
	)
	Assert.isNil(now.waymarks["waymark-i"], "old key gone")
	Assert.equal(
		now.receipts.permanent["p:waymark:waymark.branded:reward-waymark"],
		true,
		"receipt"
	)
	Assert.isNil(now.receipts.permanent["p:waymark:waymark-i:reward-waymark"], "old receipt gone")
	Assert.equal(now.receipts.permanent["p:quest:q1:reward-x"], true, "unrelated receipt kept")
	Assert.equal(
		now.receipts.permanent["p:quest:waymark-i-notes:reward-y"],
		true,
		"an ID that only contains the old text is left alone"
	)
	Assert.equal(now.receipts.seasonal["s:1:run-1:1:reward-gold"], 1, "seasonal kept")
	local intent = now.receipts.pending["p:waymark:waymark.branded:reward-pending"]
	Assert.notNil(intent, "pending intent re-keyed")
	Assert.equal(
		intent.grantId,
		"p:waymark:waymark.branded:reward-pending",
		"grantId follows the key"
	)
	Assert.equal(intent.sourceId, "waymark.branded", "source follows")
	Assert.equal(now.balances["currency-test"], 5, "balances untouched")
	Assert.equal(now.revision, 9, "revision untouched")
	Assert.count(ProfileSchema.validate(now), 0, "valid under the current schema")
	Assert.equal(old.waymarks["waymark-i"].rank, 1, "the input is not modified")

	-- Running the whole chain from v1 reaches the same place, and a profile
	-- that already has the new ID is not disturbed.
	local current: any = ProfileSchema.default()
	current.waymarks = { ["waymark.branded"] = { activated = true, rank = 1 } }
	Assert.deepEqual(Migrations.production():migrate(current).applied, {}, "nothing to do")
end)

suite:case("an old receipt in an archive record still blocks the renamed grant", function(env)
	local archiveKey = "p:1:archive:1"
	local oldId = "p:waymark:waymark-i:reward-waymark"
	env.dataStores:seed(
		ReceiptCapacity.ARCHIVE_STORE_NAME,
		archiveKey,
		{ profileKey = "p:1", index = 1, receipts = { [oldId] = true }, count = 1 }
	)
	local monitor = ReceiptCapacity.new({
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		profiles = nil :: any,
		archiveStore = env.dataStores:GetDataStore(ReceiptCapacity.ARCHIVE_STORE_NAME) :: any,
	})
	local profile: any = ProfileSchema.default()
	profile.receipts.archives = { archiveKey }
	local view = monitor.loadArchived(profile) :: ReceiptCapacity.ArchivedView
	Assert.notNil(view, "archive readable")
	Assert.equal(
		view.receipts["p:waymark:waymark.branded:reward-waymark"],
		true,
		"the archived receipt is recognised under the new ID"
	)
	Assert.isNil(view.receipts[oldId], "the old spelling is not kept")
	Assert.equal(
		env.dataStores:peek(ReceiptCapacity.ARCHIVE_STORE_NAME, archiveKey).receipts[oldId],
		true,
		"the archive record itself is never rewritten"
	)

	-- A grant built with the view refuses to pay again.
	local def = RewardCatalog.build({
		{
			id = "reward-waymark",
			kind = "permanent",
			sources = { "waymark" },
			grants = { currencies = { ["currency-test"] = 5 } },
		},
	}):get("reward-waymark") :: RewardCatalog.Definition
	local grant =
		Receipts.permanentGrant("p:waymark:waymark.branded:reward-waymark", def, view) :: Receipts.Mutation
	Assert.isNil(grant.apply(profile), "already paid, so no change")
	Assert.isTrue((grant.isApplied :: any)(profile), "reported as applied")
end)

return suite:cases()
