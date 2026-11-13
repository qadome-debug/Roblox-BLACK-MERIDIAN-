--!strict
-- BM-019: every status has a client-safe message; rejections are logged
-- under the right category and counted.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Rejections = require(ServerScriptService.Server.Network.Rejections)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local suite = Suite.new("Rejections")

local STATUSES = {
	"BAD_ENVELOPE",
	"UNKNOWN_ACTION",
	"NOT_READY",
	"STALE_EPOCH",
	"REPLAY",
	"RATE_LIMITED",
	"BAD_PAYLOAD",
	"UNAUTHORIZED",
	"STALE_STATE",
	"REJECTED",
	"INTERNAL",
}

suite:case("every rejection status has a fixed message with no internals", function()
	for _, status in STATUSES do
		local message = Rejections.message(status :: any)
		Assert.isTrue(#message > 0, status .. " has a message")
		Assert.isTrue(string.match(message, "%d") == nil, status .. " message has no numbers")
		for _, banned in
			{ "token", "bucket", "seq", "epoch ", "fingerprint", "threshold", "validator" }
		do
			Assert.isTrue(
				string.find(string.lower(message), banned, 1, true) == nil,
				status .. " leaks " .. banned
			)
		end
	end
	Assert.equal(Rejections.message("OK" :: any), "", "OK has no message")
	Assert.equal(
		Rejections.message("Bogus" :: any),
		Rejections.message("INTERNAL"),
		"unknown falls back"
	)
end)

suite:case("abuse statuses are classified", function()
	for _, status in
		{
			"BAD_ENVELOPE",
			"UNKNOWN_ACTION",
			"STALE_EPOCH",
			"REPLAY",
			"RATE_LIMITED",
			"BAD_PAYLOAD",
			"UNAUTHORIZED",
		}
	do
		Assert.isTrue(Rejections.isAbuse(status :: any), status)
	end
	for _, status in { "NOT_READY", "STALE_STATE", "REJECTED", "INTERNAL", "OK" } do
		Assert.isFalse(Rejections.isAbuse(status :: any), status)
	end
end)

suite:case("build logs the real reason by category and counts telemetry", function(env)
	local deps = { logger = env.logger, telemetry = Telemetry.new(env.logger) }
	local result = Rejections.build(deps, "r1", "QuestChoice", "REPLAY", "seq 5 <= 9")
	Assert.equal(result.status, "REPLAY", "status")
	Assert.equal(result.requestId, "r1", "request id")
	Assert.equal(result.message, Rejections.message("REPLAY"), "safe message")
	Assert.isNil(result.data, "no data")

	Rejections.build(deps, "r2", "QuestChoice", "STALE_STATE", "revision 3 != 4")
	Rejections.build(deps, nil, nil, "INTERNAL", "boom")

	local security = env.logged("security", "request_rejected")
	Assert.count(security, 1, "replay is a security event")
	Assert.equal(security[1].fields.reason, "seq 5 <= 9", "reason kept server-side")
	Assert.count(env.logged("gameplay", "request_rejected"), 1, "stale state is gameplay")
	Assert.count(env.logged("network", "request_failed"), 1, "internal is a failure")
	Assert.count(env.logged("telemetry", "request_rejected"), 3, "every rejection counted")
	Assert.equal(
		env.logged("telemetry", "request_rejected")[3].fields.status,
		"INTERNAL",
		"status in telemetry"
	)
end)

return suite:cases()
