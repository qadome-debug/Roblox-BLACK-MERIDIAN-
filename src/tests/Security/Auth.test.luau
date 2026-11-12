--!strict
-- BM-014: identity comes from the Player object and the session, never
-- from the payload.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Auth = require(ServerScriptService.Server.Network.Auth)
local Session = require(ServerScriptService.Server.Network.Session)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Auth")

local function setup(env: Suite.Env, userId: number)
	local sessions = Session.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		sendEpoch = function() end,
	})
	local player: Session.PlayerLike = { UserId = userId, Name = "p" .. userId }
	local session = sessions:onPlayerAdded(player)
	local ctx = Auth.contextFor(player, session, "QuestChoice", "req-1", "corr-1", env.logger)
	return ctx, session
end

suite:case("context identity comes from the Player object", function(env)
	local ctx = setup(env, 42)
	Assert.equal(ctx.userId, 42, "userId")
	Assert.equal(ctx.playerName, "p42", "name")
	Assert.equal(ctx.action, "QuestChoice", "action")
	Assert.equal(ctx.requestId, "req-1", "requestId")
	Assert.equal(ctx.correlationId, "corr-1", "correlationId")
	Assert.isTrue(table.isfrozen(ctx :: any), "frozen")
	Assert.equal(ctx.logger.context.playerId, 42, "logger bound to the player")
	Assert.equal(ctx.logger.context.correlationId, "corr-1", "logger bound to the request")
end)

suite:case("a forged owner id in a payload cannot pass an ownership check", function(env)
	local ctx = setup(env, 42)
	-- The adapter looks up the real owner from server state; whatever the
	-- client claimed is irrelevant to this call.
	Assert.isNil(Auth.requireOwner(ctx, 42), "real owner passes")
	Assert.equal(Auth.requireOwner(ctx, 7), "UNAUTHORIZED", "other owner denied")
	Assert.equal(Auth.requireOwner(ctx, nil), "UNAUTHORIZED", "unknown owner denied")
	Assert.count(env.logged("security", "ownership_denied"), 2, "denials logged as security events")
end)

suite:case("permissions are service-granted flags on the session", function(env)
	local ctx, session = setup(env, 42)
	Assert.equal(Auth.requirePermission(ctx, "operator.recovery"), "UNAUTHORIZED", "no flag")
	session.permissions["operator.recovery"] = true
	Assert.isNil(Auth.requirePermission(ctx, "operator.recovery"), "granted")
	Assert.equal(
		Auth.requirePermission(ctx, "operator.grant"),
		"UNAUTHORIZED",
		"other flag still denied"
	)
end)

suite:case("membership is checked against a server-owned roster", function(env)
	local ctx = setup(env, 42)
	Assert.isNil(Auth.requireMember(ctx, { 1, 42, 3 }), "member")
	Assert.equal(Auth.requireMember(ctx, { 1, 2, 3 }), "UNAUTHORIZED", "not a member")
	Assert.equal(Auth.requireMember(ctx, {}), "UNAUTHORIZED", "empty roster")
end)

return suite:cases()
