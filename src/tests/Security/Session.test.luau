--!strict
-- BM-017: sessions, epochs, and the ClientHello handshake.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Session = require(ServerScriptService.Server.Network.Session)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Session")

local function make(env: Suite.Env)
	local sent: { { player: Session.PlayerLike, epoch: string } } = {}
	local service = Session.new({
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		sendEpoch = function(player, epoch)
			table.insert(sent, { player = player, epoch = epoch })
		end,
	})
	return service, sent
end

local function player(id: number): Session.PlayerLike
	return { UserId = id, Name = "player" .. id }
end

suite:case("joining creates a session and pushes an initial epoch", function(env)
	local service, sent = make(env)
	local p = player(1)
	local session = service:onPlayerAdded(p)
	Assert.equal(session.userId, 1, "userId from the Player object")
	Assert.isFalse(session.ready, "not ready before hello")
	Assert.isFalse(session.profileLoaded, "no profile yet")
	Assert.count(sent, 1, "epoch pushed")
	Assert.equal(sent[1].epoch, session.epoch, "pushed the session epoch")
	Assert.isTrue(
		#session.epoch == 24 and string.match(session.epoch, "^[0-9a-f]+$") ~= nil,
		"epoch format"
	)
	Assert.equal(service:onPlayerAdded(p), session, "idempotent join")
	Assert.equal(service:count(), 1, "one session")
	Assert.count(env.logged("network", "session_created"), 1, "logged")
end)

suite:case("hello rotates the epoch and marks the session ready", function(env)
	local service = make(env)
	local p = player(1)
	local session = service:onPlayerAdded(p)
	local initial = session.epoch
	Assert.isTrue(service:checkEpoch(session, initial), "initial epoch valid before hello")

	local epoch, status = service:hello(p, 1)
	Assert.isNil(status, "accepted")
	Assert.notNil(epoch, "new epoch issued")
	Assert.notEqual(epoch, initial, "epoch rotated")
	Assert.isTrue(session.ready, "ready")
	Assert.isTrue(service:checkEpoch(session, epoch :: string), "new epoch valid")
	Assert.isFalse(service:checkEpoch(session, initial), "old epoch rejected after hello")

	local again, status2 = service:hello(p, 1)
	Assert.isNil(again, "second hello refused")
	Assert.equal(status2, "REJECTED", "status")
end)

suite:case("hello with the wrong protocol version is rejected and logged", function(env)
	local service = make(env)
	local p = player(1)
	local session = service:onPlayerAdded(p)
	local epoch, status = service:hello(p, 2)
	Assert.isNil(epoch, "no epoch")
	Assert.equal(status, "BAD_ENVELOPE", "status")
	Assert.isFalse(session.ready, "still not ready")
	Assert.count(env.logged("network", "hello_version_mismatch"), 1, "logged")
	Assert.isNil((service:hello(player(9), 1)), "unknown player")
end)

suite:case("the initial epoch expires if hello never arrives", function(env)
	local service = make(env)
	local p = player(1)
	local session = service:onPlayerAdded(p)
	env.clock:advance(Session.HELLO_TIMEOUT_SECONDS)
	Assert.isTrue(service:checkEpoch(session, session.epoch), "valid at the boundary")
	env.clock:advance(1)
	Assert.isFalse(service:checkEpoch(session, session.epoch), "expired after the window")
end)

suite:case("epochs are per session and a reconnect gets a new one", function(env)
	local service = make(env)
	local first = player(1)
	local a = service:onPlayerAdded(first)
	service:hello(first, 1)
	local oldEpoch = a.epoch
	service:onPlayerRemoving(first)
	Assert.isNil(service:get(first), "session dropped")
	Assert.equal(service:count(), 0, "none left")

	local second = player(1) -- same UserId, new Player object
	local b = service:onPlayerAdded(second)
	Assert.notEqual(b.epoch, oldEpoch, "fresh epoch")
	Assert.isFalse(service:checkEpoch(b, oldEpoch), "old epoch rejected on the new session")
	Assert.isFalse(b.ready, "must hello again")

	local other = service:onPlayerAdded(player(2))
	Assert.isFalse(service:checkEpoch(other, b.epoch), "another player's epoch is not accepted")
end)

suite:case("profile readiness is set by the server only", function(env)
	local service = make(env)
	local p = player(1)
	local session = service:onPlayerAdded(p)
	service:markProfileLoaded(p, true)
	Assert.isTrue(session.profileLoaded, "marked")
	service:markProfileLoaded(p, false)
	Assert.isFalse(session.profileLoaded, "cleared")
	service:markProfileLoaded(player(5), true) -- unknown player: no error
end)

suite:caseWithSeeds("epochs are unpredictable across many sessions", { 3, 4 }, function(env)
	local service = make(env)
	local seen: { [string]: boolean } = {}
	for i = 1, 200 do
		local p = player(i)
		local session = service:onPlayerAdded(p)
		Assert.isNil(seen[session.epoch], "initial epoch unique")
		seen[session.epoch] = true
		local epoch = service:hello(p, 1) :: string
		Assert.isNil(seen[epoch], "rotated epoch unique")
		seen[epoch] = true
	end
end)

return suite:cases()
