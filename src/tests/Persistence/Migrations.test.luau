--!strict
-- BM-023: upgrade fixtures, repeated migrations, future-schema refusal.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Migrations = require(ServerScriptService.Server.Persistence.Migrations)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local Suite = require(ServerStorage.Tests.Support.Suite)

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
	local prod = Migrations.production():migrate({ schemaVersion = 2 })
	Assert.isNil(prod.profile, "production refuses v2 while current is v1")
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

return suite:cases()
