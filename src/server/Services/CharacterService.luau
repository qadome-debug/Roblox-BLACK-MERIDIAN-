--!strict
-- CharacterService: server-owned character lifecycle and position
-- sampling (BM-051).
--
-- The server never trusts a client-supplied position. Every interaction
-- that depends on where a player is (Waymark proximity, NPC range, melee
-- reach) asks this service, which samples the server-side character rig
-- through an injected adapter. Samples are cached per tick so a burst of
-- checks costs one read, and consecutive samples are checked for
-- plausibility: an implausible jump is flagged (telemetry) and the last
-- plausible position is kept as the authoritative one until the character
-- is respawned or teleported by the server.
--
-- States: None (no character) -> Alive -> Dead -> None. Only the server
-- moves a character between states.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

export type Vec3 = Vec3.Vec3

export type MoveState =
	"Idle"
	| "Walking"
	| "Airborne"
	| "Swimming"
	| "Climbing"
	| "Seated"
	| "Unknown"

export type LifeState = "None" | "Alive" | "Dead"

-- What the server reads from a live character. The Roblox adapter wraps a
-- Model with a Humanoid; tests use a scripted rig.
export type Rig = {
	position: () -> Vec3?,
	moveState: () -> MoveState,
	-- Moves the character; only the server calls this.
	teleport: (to: Vec3) -> (),
}

export type Snapshot = {
	position: Vec3,
	moveState: MoveState,
	sampledAt: number,
	-- True when the latest raw sample was rejected as implausible.
	suspicious: boolean,
}

export type Deps = {
	clock: Clock.Clock,
	logger: Logger.Logger,
	telemetry: Telemetry.Telemetry,
	-- Highest plausible speed in studs per second, including falls and
	-- dashes. Tuned by BM-098/BM-131; generous by default.
	maxSpeed: number?,
	-- Minimum seconds between fresh samples of the same character.
	sampleInterval: number?,
}

export type Service = {
	onCharacterAdded: (self: Service, userId: number, rig: Rig) -> (),
	onCharacterRemoving: (self: Service, userId: number) -> (),
	onDied: (self: Service, userId: number) -> (),
	lifeState: (self: Service, userId: number) -> LifeState,
	-- Current authoritative snapshot, or nil without a live character.
	sample: (self: Service, userId: number) -> Snapshot?,
	-- Horizontal distance from the character to a point, or nil.
	distanceTo: (self: Service, userId: number, point: Vec3) -> number?,
	isWithin: (self: Service, userId: number, point: Vec3, radius: number) -> boolean,
	-- Server-initiated move; resets plausibility tracking.
	teleport: (self: Service, userId: number, to: Vec3) -> boolean,
	count: (self: Service) -> number,
}

type Entry = {
	rig: Rig,
	life: LifeState,
	last: Snapshot?,
	spawnedAt: number,
	flags: number,
}

local CharacterService = {}

CharacterService.DEFAULT_MAX_SPEED = 120
CharacterService.DEFAULT_SAMPLE_INTERVAL = 1 / 30

function CharacterService.new(deps: Deps): Service
	local maxSpeed = deps.maxSpeed or CharacterService.DEFAULT_MAX_SPEED
	local sampleInterval = deps.sampleInterval or CharacterService.DEFAULT_SAMPLE_INTERVAL
	local entries: { [number]: Entry } = {}

	local service = {} :: Service

	local function log(
		level: Logger.Level,
		event: string,
		userId: number,
		fields: Logger.RawFields?
	)
		deps.logger:with({ playerId = userId }):log(level, "gameplay", event, fields)
	end

	function service:onCharacterAdded(userId: number, rig: Rig)
		local now = deps.clock:now()
		local position = rig.position()
		entries[userId] = {
			rig = rig,
			life = "Alive",
			last = if position ~= nil and Vec3.isFinite(position)
				then {
					position = Vec3.copy(position),
					moveState = rig.moveState(),
					sampledAt = now,
					suspicious = false,
				}
				else nil,
			spawnedAt = now,
			flags = 0,
		}
		log("debug", "character_spawned", userId)
	end

	function service:onCharacterRemoving(userId: number)
		if entries[userId] ~= nil then
			entries[userId] = nil
			log("debug", "character_removed", userId)
		end
	end

	function service:onDied(userId: number)
		local entry = entries[userId]
		if entry ~= nil and entry.life == "Alive" then
			entry.life = "Dead"
			log(
				"debug",
				"character_died",
				userId,
				{ aliveSeconds = deps.clock:now() - entry.spawnedAt }
			)
		end
	end

	function service:lifeState(userId: number): LifeState
		local entry = entries[userId]
		return if entry ~= nil then entry.life else "None"
	end

	function service:sample(userId: number): Snapshot?
		local entry = entries[userId]
		if entry == nil or entry.life ~= "Alive" then
			return nil
		end
		local now = deps.clock:now()
		local last = entry.last
		if last ~= nil and now - last.sampledAt < sampleInterval then
			return last
		end

		local raw = entry.rig.position()
		if raw == nil or not Vec3.isFinite(raw) then
			-- No readable position: keep the last known one if any.
			return last
		end
		local moveState: MoveState = entry.rig.moveState() :: any

		if last ~= nil then
			local dt = now - last.sampledAt
			local moved = Vec3.distance(last.position, raw)
			if dt > 0 and moved / dt > maxSpeed then
				entry.flags += 1
				log("warn", "character_implausible_move", userId, {
					studs = moved,
					seconds = dt,
					flags = entry.flags,
				})
				deps.telemetry:track("character_implausible_move", { userId = userId })
				-- Keep the last plausible position as authoritative.
				entry.last = {
					position = last.position,
					moveState = moveState,
					sampledAt = now,
					suspicious = true,
				}
				return entry.last
			end
		end

		entry.last = {
			position = Vec3.copy(raw),
			moveState = moveState,
			sampledAt = now,
			suspicious = false,
		}
		return entry.last
	end

	function service:distanceTo(userId: number, point: Vec3): number?
		local snapshot = service:sample(userId)
		if snapshot == nil then
			return nil
		end
		return Vec3.flatDistance(snapshot.position, point)
	end

	function service:isWithin(userId: number, point: Vec3, radius: number): boolean
		local distance = service:distanceTo(userId, point)
		return distance ~= nil and distance <= radius
	end

	function service:teleport(userId: number, to: Vec3): boolean
		local entry = entries[userId]
		if entry == nil or entry.life ~= "Alive" or not Vec3.isFinite(to) then
			return false
		end
		entry.rig.teleport(to)
		entry.last = {
			position = Vec3.copy(to),
			moveState = entry.rig.moveState(),
			sampledAt = deps.clock:now(),
			suspicious = false,
		}
		log("debug", "character_teleported", userId)
		return true
	end

	function service:count(): number
		local n = 0
		for _ in entries do
			n += 1
		end
		return n
	end

	return table.freeze(service)
end

return table.freeze(CharacterService)
