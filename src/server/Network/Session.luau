--!strict
-- Player sessions and epochs (BM-017).
--
-- A session exists per connected Player object. It carries the current
-- session epoch (a freshness identifier the server issues and rotates, not
-- a secret), the connection state, and the per-session replay and rate
-- state the dispatcher consults. Everything here is keyed by the Player
-- object the engine handed us, never by anything a client sent.
--
-- Bootstrap sequence:
--   1. PlayerAdded: a session is created with an initial epoch, which the
--      server pushes to the client (StateDelta). Only ClientHello may use it.
--   2. ClientHello: the client states its protocol version. If accepted,
--      the session becomes ready and a new epoch is issued in the result.
--      Every later request must carry that epoch.
--   3. PlayerRemoving: the session is dropped. A reconnect is a new Player
--      object and therefore a new session; requests carrying an old epoch
--      are rejected with STALE_EPOCH.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)
local Replay = require(script.Parent.Replay)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

-- The part of Player the server relies on. Tests pass plain tables.
export type PlayerLike = { UserId: number, Name: string }

export type Session = {
	userId: number,
	playerName: string,
	epoch: string,
	ready: boolean,
	profileLoaded: boolean,
	createdAt: number,
	helloAt: number?,
	replay: Replay.State,
	-- Service-owned permission flags (operator roles and the like). Never
	-- derived from client input.
	permissions: { [string]: boolean },
}

export type Deps = {
	clock: Clock.Clock,
	rng: Rng.Rng,
	logger: Logger.Logger,
	-- Called with the initial epoch when a session is created, so Bootstrap
	-- can push it to the client.
	sendEpoch: (player: PlayerLike, epoch: string) -> (),
}

export type Service = {
	onPlayerAdded: (self: Service, player: PlayerLike) -> Session,
	onPlayerRemoving: (self: Service, player: PlayerLike) -> (),
	get: (self: Service, player: PlayerLike) -> Session?,
	-- Validates the epoch a request carries against the player's session.
	checkEpoch: (self: Service, session: Session, epoch: string) -> boolean,
	-- Completes the handshake. Returns the new epoch, or a rejection status.
	hello: (
		self: Service,
		player: PlayerLike,
		protocolVersion: number
	) -> (string?, Protocol.Status?, string?),
	-- ProfileService calls this once the profile is loaded and leased.
	markProfileLoaded: (self: Service, player: PlayerLike, loaded: boolean) -> (),
	count: (self: Service) -> number,
}

local Session = {}

-- Seconds a connected client has to send ClientHello before its initial
-- epoch stops being accepted.
Session.HELLO_TIMEOUT_SECONDS = 60

local function newEpoch(rng: Rng.Rng): string
	return string.format(
		"%08x%08x%08x",
		rng:nextInteger(0, 0xFFFFFFFF),
		rng:nextInteger(0, 0xFFFFFFFF),
		rng:nextInteger(0, 0xFFFFFFFF)
	)
end

function Session.new(deps: Deps): Service
	local sessions: { [PlayerLike]: Session } = {}
	local epochRng = deps.rng:fork("session-epochs")

	local service = {} :: Service

	function service:onPlayerAdded(player: PlayerLike): Session
		local existing = sessions[player]
		if existing ~= nil then
			return existing
		end
		local session: Session = {
			userId = player.UserId,
			playerName = player.Name,
			epoch = newEpoch(epochRng),
			ready = false,
			profileLoaded = false,
			createdAt = deps.clock:now(),
			helloAt = nil,
			replay = Replay.newState(),
			permissions = {},
		}
		sessions[player] = session
		deps.logger:with({ playerId = player.UserId }):info("network", "session_created")
		deps.sendEpoch(player, session.epoch)
		return session
	end

	function service:onPlayerRemoving(player: PlayerLike)
		local session = sessions[player]
		if session == nil then
			return
		end
		sessions[player] = nil
		deps.logger:with({ playerId = player.UserId }):info("network", "session_closed", {
			ready = session.ready,
			requests = session.replay.lastSeq,
		})
	end

	function service:get(player: PlayerLike): Session?
		return sessions[player]
	end

	function service:checkEpoch(session: Session, epoch: string): boolean
		if epoch ~= session.epoch then
			return false
		end
		if not session.ready then
			-- The initial epoch is only good for a bounded hello window.
			return deps.clock:now() - session.createdAt <= Session.HELLO_TIMEOUT_SECONDS
		end
		return true
	end

	function service:hello(
		player: PlayerLike,
		protocolVersion: number
	): (string?, Protocol.Status?, string?)
		local session = sessions[player]
		if session == nil then
			return nil, "NOT_READY", "no session for player"
		end
		if session.ready then
			return nil, "REJECTED", "handshake already completed"
		end
		if protocolVersion ~= Protocol.VERSION then
			deps.logger
				:with({ playerId = player.UserId })
				:warn("network", "hello_version_mismatch", {
					clientVersion = protocolVersion,
					serverVersion = Protocol.VERSION,
				})
			return nil, "BAD_ENVELOPE", "unsupported protocol version"
		end
		session.ready = true
		session.helloAt = deps.clock:now()
		session.epoch = newEpoch(epochRng)
		deps.logger:with({ playerId = player.UserId }):info("network", "session_ready")
		return session.epoch, nil, nil
	end

	function service:markProfileLoaded(player: PlayerLike, loaded: boolean)
		local session = sessions[player]
		if session ~= nil then
			session.profileLoaded = loaded
		end
	end

	function service:count(): number
		local n = 0
		for _ in sessions do
			n += 1
		end
		return n
	end

	return table.freeze(service)
end

return table.freeze(Session)
