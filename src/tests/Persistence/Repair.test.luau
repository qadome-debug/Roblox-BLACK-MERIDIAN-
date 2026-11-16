--!strict
-- BM-032: corrupt nested fields and schema drift are quarantined; repair
-- is conservative and auditable.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local ProfileSchema = require(ServerScriptService.Server.Persistence.ProfileSchema)
local Repair = require(ServerScriptService.Server.Persistence.Repair)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Repair")

suite:case("missing containers are filled in and reported", function()
	local raw: any = ProfileSchema.default()
	raw.receipts.pending = nil
	raw.descents = nil
	raw.burdens.dissonance = nil
	Assert.isTrue(#ProfileSchema.validate(raw) > 0, "starts invalid")
	local report = Repair.attempt(raw)
	Assert.isTrue(report.repaired, "repaired: " .. table.concat(report.remaining, "; "))
	table.sort(report.changes)
	Assert.deepEqual(report.changes, {
		"added missing burdens.dissonance",
		"added missing descents",
		"added missing receipts.pending",
	}, "every change listed")
	Assert.isNil(raw.descents, "input not mutated")
	Assert.count(ProfileSchema.validate(report.profile), 0, "result validates")
end)

suite:case("an invalid lease is reset; progression is never touched", function()
	local raw: any = ProfileSchema.default()
	raw.lease = { sessionId = "bad id!", jobId = "j", fence = -1, expiresAt = 1 }
	raw.balances["currency-test"] = 42
	raw.receipts.permanent["r1"] = true
	local report = Repair.attempt(raw)
	Assert.isTrue(report.repaired, "repaired")
	Assert.deepEqual(report.changes, { "reset invalid lease" }, "only the lease")
	Assert.equal(report.profile.balances["currency-test"], 42, "balance kept")
	Assert.equal(report.profile.receipts.permanent.r1, true, "receipt kept")
end)

suite:case("data that cannot be fixed safely stays quarantined", function()
	local raw: any = ProfileSchema.default()
	raw.balances["currency-test"] = -5 -- a negative balance is not ours to guess
	raw.cants.unlocked["cant.invented"] = true -- an unknown ID might be a registry gap
	local report = Repair.attempt(raw)
	Assert.isFalse(report.repaired, "not repaired")
	Assert.count(report.changes, 0, "nothing changed")
	Assert.count(report.remaining, 2, "both problems remain")
	Assert.equal(report.profile.balances["currency-test"], -5, "data preserved for an operator")
	Assert.equal(report.profile.cants.unlocked["cant.invented"], true, "unknown unlock preserved")
end)

suite:case("non-table records and future schemas are not repaired", function()
	local report = Repair.attempt("corrupt")
	Assert.isFalse(report.repaired, "string")
	Assert.isNil(report.profile, "no profile")
	local future = Repair.attempt({ schemaVersion = 9 })
	Assert.isFalse(future.repaired, "future schema still fails validation")
	Assert.equal(future.profile.schemaVersion, 9, "version untouched")
end)

suite:case("a valid profile is reported as repaired with no changes", function()
	local report = Repair.attempt(ProfileSchema.default())
	Assert.isTrue(report.repaired, "valid")
	Assert.count(report.changes, 0, "no changes")
end)

return suite:cases()
