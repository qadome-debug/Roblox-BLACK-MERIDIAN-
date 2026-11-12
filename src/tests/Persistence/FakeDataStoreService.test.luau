--!strict
-- BM-009: the fake DataStore behaves like the real one where it matters,
-- and its fault injection covers the plan's failure modes.

local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("FakeDataStoreService")

suite:case("get, set, update and remove round-trip with copies", function(env)
	local store = env.dataStores:GetDataStore("Profiles", "test")
	Assert.isNil(store:GetAsync("p1"), "missing key")

	local version = store:SetAsync("p1", { gold = 5, tags = { "a" } })
	Assert.isTrue(type(version) == "string" and #version > 0, "version string")

	local value, info = store:GetAsync("p1")
	Assert.deepEqual(value, { gold = 5, tags = { "a" } }, "stored value")
	Assert.notNil(info, "key info")
	value.gold = 999
	Assert.equal(store:GetAsync("p1").gold, 5, "caller mutation must not leak into the store")

	local updated = store:UpdateAsync("p1", function(old)
		old.gold += 1
		return old
	end)
	Assert.equal(updated.gold, 6, "update result")
	Assert.equal(env.dataStores:peek("Profiles/test", "p1").gold, 6, "peek sees commit")

	local removed = store:RemoveAsync("p1")
	Assert.equal(removed.gold, 6, "remove returns old value")
	Assert.isNil(store:GetAsync("p1"), "gone")
end)

suite:case("returning nil from an UpdateAsync transform cancels the write", function(env)
	local store = env.dataStores:GetDataStore("Profiles")
	store:SetAsync("k", { n = 1 })
	local result = store:UpdateAsync("k", function()
		return nil
	end)
	Assert.equal(result.n, 1, "old value returned")
	Assert.equal(env.dataStores:peek("Profiles", "k").n, 1, "unchanged")
end)

suite:case("stores are isolated by name and scope", function(env)
	local a = env.dataStores:GetDataStore("Profiles", "test")
	local b = env.dataStores:GetDataStore("Profiles", "studio")
	local c = env.dataStores:GetDataStore("Profiles")
	a:SetAsync("k", 1)
	Assert.isNil(b:GetAsync("k"), "other scope")
	Assert.isNil(c:GetAsync("k"), "no scope")
	Assert.equal(env.dataStores:GetDataStore("Profiles", "test"), a, "same object for same name")
end)

suite:case("error and timeout faults throw without writing", function(env)
	local store = env.dataStores:GetDataStore("Profiles")
	store:SetAsync("k", { n = 1 })
	env.dataStores:injectFault({ kind = "timeout", operation = "UpdateAsync" })
	Assert.throws(function()
		store:UpdateAsync("k", function(old)
			old.n = 2
			return old
		end)
	end, "timed out")
	Assert.equal(env.dataStores:peek("Profiles", "k").n, 1, "not written")

	env.dataStores:injectFault({ kind = "error", key = "other" })
	store:SetAsync("k", { n = 3 }) -- different key, unaffected
	Assert.throws(function()
		store:SetAsync("other", 1)
	end, "injected error")
	Assert.equal(env.dataStores:peek("Profiles", "k").n, 3, "other key written")
end)

suite:case("lostResponse commits the write and then throws", function(env)
	local store = env.dataStores:GetDataStore("Profiles")
	store:SetAsync("k", { n = 1 })
	env.dataStores:injectFault({ kind = "lostResponse", operation = "UpdateAsync" })
	Assert.throws(function()
		store:UpdateAsync("k", function(old)
			old.n = 2
			return old
		end)
	end, "response lost")
	Assert.equal(env.dataStores:peek("Profiles", "k").n, 2, "write committed despite the error")
	-- A retry of the same transform sees the committed state.
	local value = store:UpdateAsync("k", function(old)
		return old
	end)
	Assert.equal(value.n, 2, "retry observes commit")
end)

suite:case("budget fault and delay fault", function(env)
	local store = env.dataStores:GetDataStore("Profiles")
	env.dataStores:injectFault({ kind = "budget" })
	Assert.throws(function()
		store:GetAsync("k")
	end, "budget exhausted")

	local before = env.clock:now()
	env.dataStores:injectFault({ kind = "delay", seconds = 7 })
	store:GetAsync("k")
	Assert.equal(env.clock:now() - before, 7, "delay advanced the clock")
end)

suite:case("faults fire a set number of times, then clear", function(env)
	local store = env.dataStores:GetDataStore("Profiles")
	env.dataStores:injectFault({ kind = "error", times = 2 })
	Assert.throws(function()
		store:GetAsync("k")
	end)
	Assert.throws(function()
		store:GetAsync("k")
	end)
	store:GetAsync("k") -- third call succeeds
	env.dataStores:injectFault({ kind = "error" })
	env.dataStores:clearFaults()
	store:GetAsync("k")
	Assert.equal(env.dataStores:callCount("GetAsync"), 4, "all calls recorded")
	Assert.equal(env.dataStores:calls()[1].outcome, "error", "first outcome")
	Assert.equal(env.dataStores:calls()[3].outcome, "ok", "third outcome")
end)

suite:case("real-service limits are enforced", function(env)
	local store = env.dataStores:GetDataStore("Profiles")
	Assert.throws(function()
		store:SetAsync(string.rep("k", 51), 1)
	end, "exceeds 50")
	Assert.throws(function()
		store:SetAsync("", 1)
	end, "non-empty")
	Assert.throws(function()
		store:SetAsync("fn", { f = function() end })
	end, "may only contain")
	Assert.throws(function()
		store:SetAsync("big", string.rep("x", 4 * 1024 * 1024 + 1))
	end, "4 MiB")
end)

suite:case("seeded data is visible and versions advance", function(env)
	env.dataStores:seed("Profiles", "k", { n = 1 })
	local store = env.dataStores:GetDataStore("Profiles")
	local _, info1 = store:GetAsync("k")
	store:UpdateAsync("k", function(old)
		return old
	end)
	local _, info2 = store:GetAsync("k")
	Assert.notEqual((info1 :: any).Version, (info2 :: any).Version, "version changed")
	Assert.equal((info1 :: any).CreatedTime, (info2 :: any).CreatedTime, "created time kept")
end)

suite:caseWithSeeds("each case gets a fresh environment", { 1, 2 }, function(env, seed)
	Assert.equal(env.clock:now(), 0, "clock starts at zero")
	Assert.count(env.events, 0, "no events yet")
	Assert.isNil(env.dataStores:peek("Profiles", "k"), "empty store")
	env.logger:info("persistence", "probe", { seed = seed })
	Assert.count(env.logged("persistence", "probe"), 1, "captured")
end)

return suite:cases()
