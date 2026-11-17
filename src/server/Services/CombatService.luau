--!strict
-- CombatService: owns the authoritative combat simulation (BM-060).
--
-- Composes the combat layer (simulation, hitboxes, damage, defense,
-- targeting, AI, replication), maps players to combatants, feeds server
-- sampled poses in, advances the fixed-step loop from the server
-- heartbeat, and pushes replication deltas and cues to clients through an
-- injected sender. The CombatInput adapter (BM-061) is the only path by
-- which a client reaches `submit`; AI reaches the same simulation through
-- its brains. Nothing here reads a remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionMachine = require(script.Parent.Parent.Combat.ActionMachine)
local Ai = require(script.Parent.Parent.Combat.Ai)
local Attributes = require(script.Parent.Parent.Combat.Attributes)
local BurdenCatalog = require(script.Parent.Parent.Content.BurdenCatalog)
local BurdenEffects = require(script.Parent.Parent.Combat.BurdenEffects)
local CantCatalog = require(script.Parent.Parent.Content.CantCatalog)
local Cants = require(script.Parent.Parent.Combat.Cants)
local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local CombatReplication = require(ReplicatedStorage.Shared.Contracts.CombatReplication)
local Damage = require(script.Parent.Parent.Combat.Damage)
local Defense = require(script.Parent.Parent.Combat.Defense)
local Dissonance = require(script.Parent.Parent.Combat.Dissonance)
local Hitboxes = require(script.Parent.Parent.Combat.Hitboxes)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Replication = require(script.Parent.Parent.Combat.Replication)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)
local Simulation = require(script.Parent.Parent.Combat.Simulation)
local Targeting = require(script.Parent.Parent.Combat.Targeting)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)
local VerseCatalog = require(script.Parent.Parent.Content.VerseCatalog)
local VerseEffects = require(script.Parent.Parent.Combat.VerseEffects)
local Verses = require(script.Parent.Parent.Combat.Verses)

export type Pose = { position: Vec3.Vec3, facing: Vec3.Vec3 }

export type Remote = "StateDelta" | "CombatCue"

export type Deps = {
	clock: Clock.Clock,
	rng: Rng.Rng,
	logger: Logger.Logger,
	telemetry: Telemetry.Telemetry,
	-- Delivers a payload to one player's client. Bootstrap wires the
	-- RemoteEvents; tests record calls.
	send: (userId: number, remote: Remote, payload: unknown) -> (),
	-- Server-sampled pose of a player's character, or nil when it has
	-- none. Never derived from client input.
	poseOf: ((userId: number) -> Pose?)?,
	lineOfSight: ((from: Vec3.Vec3, to: Vec3.Vec3) -> boolean)?,
	-- Collision queries for Verse movement. Without one, Verses that move
	-- anything cannot resolve (fail closed).
	world: VerseEffects.World?,
	-- Moves a player's character to a position the server chose. Without
	-- one only the simulation position changes (tests).
	teleport: ((userId: number, to: Vec3.Vec3) -> boolean)?,
	navigator: Ai.Navigator?,
	stepSeconds: number?,
	-- Seconds between replication pushes (default 1/20).
	replicateInterval: number?,
	-- Cant catalog (default CantCatalog.production()).
	cantCatalog: CantCatalog.Catalog?,
	-- Verse catalog (default VerseCatalog.production()) and server effects.
	verseCatalog: VerseCatalog.Catalog?,
	-- Extra or replacement Verse effects, by Verse ID or effect name.
	verseEffects: { [string]: Verses.Effect }?,
	-- Dissonance tuning and actions (defaults: nothing approved yet, so no
	-- passive recovery and no actions). A resolved Verse adds the amount
	-- its own definition states, and nothing when that is unset.
	dissonanceTuning: Dissonance.Tuning?,
	dissonanceActions: { [string]: Dissonance.ActionDef }?,
	-- World hooks for Dissonance: whether a combatant is in a stable
	-- environment, and the region or encounter handler for a rupture.
	inStableEnvironment: ((combatantId: string) -> boolean)?,
	inUnstableArea: ((combatantId: string) -> boolean)?,
	-- Burden catalog (default BurdenCatalog.production()). A player gets
	-- the default Burden of the equipped Cant; a mastery Burden needs
	-- both of these, and no mastery trial exists yet.
	burdenCatalog: BurdenCatalog.Catalog?,
	chosenBurden: ((userId: number) -> string?)?,
	masteryUnlocked: ((userId: number) -> boolean)?,
	onRupture: ((combatantId: string) -> ())?,
}

export type PlayerSpec = {
	base: Attributes.Base?,
	modifiers: { Attributes.Modifier }?,
	team: string?,
}

export type EnemySpec = {
	id: string,
	team: string?,
	base: Attributes.Base?,
	modifiers: { Attributes.Modifier }?,
	position: Vec3.Vec3,
	facing: Vec3.Vec3?,
	profile: Ai.Profile?,
	-- "elite" is moved by a reduced amount; "immune" (bosses) is never
	-- pulled or tethered.
	displacement: ("normal" | "elite" | "immune")?,
}

export type Service = {
	addPlayer: (self: Service, userId: number, spec: PlayerSpec?) -> (),
	removePlayer: (self: Service, userId: number) -> (),
	hasPlayer: (self: Service, userId: number) -> boolean,
	combatantId: (self: Service, userId: number) -> string,
	-- Queues a validated intent; the only client-reachable mutation.
	submit: (self: Service, userId: number, intent: Simulation.Intent) -> ActionMachine.Outcome,
	requestTarget: (self: Service, userId: number, targetId: string?) -> ActionMachine.Outcome,
	cycleTarget: (self: Service, userId: number) -> ActionMachine.Outcome,
	engaged: (self: Service, userId: number) -> boolean,
	spawnEnemy: (self: Service, spec: EnemySpec) -> (),
	despawnEnemy: (self: Service, id: string) -> boolean,
	-- Advances the simulation by elapsed seconds and replicates when due.
	tick: (self: Service, elapsed: number) -> number,
	-- Forces a replication push now (tests, join).
	replicate: (self: Service) -> (),
	ownView: (self: Service, userId: number) -> CombatReplication.OwnCombatant?,
	sim: Simulation.Simulation,
	targeting: Targeting.Targeting,
	ai: Ai.Ai,
	cants: Cants.Layer,
	verses: Verses.Layer,
	dissonance: Dissonance.Layer,
	verseEffects: VerseEffects.Layer?,
	burdens: BurdenEffects.Layer,
	verseCatalog: VerseCatalog.Catalog,
}

local CombatService = {}

CombatService.PLAYER_TEAM = "players"
CombatService.ENEMY_TEAM = "enemies"
CombatService.DEFAULT_REPLICATE_INTERVAL = 1 / 20

local function playerId(userId: number): string
	return "p-" .. tostring(userId)
end

function CombatService.new(deps: Deps): Service
	local sim = Simulation.new({
		logger = deps.logger,
		rng = deps.rng:fork("combat"),
		stepSeconds = deps.stepSeconds,
	})
	local holder: { damage: Damage.Damage? } = {}
	local hitboxes = Hitboxes.attach(sim, {
		lineOfSight = deps.lineOfSight,
		canHit = function(attacker, target)
			local d = holder.damage
			return d == nil or d.canHit(attacker, target)
		end,
	})
	local damage = Damage.attach(sim, hitboxes)
	holder.damage = damage
	Defense.attach(sim, damage)
	local targeting = Targeting.attach(sim, { lineOfSight = deps.lineOfSight, damage = damage })
	local ai = Ai.attach(sim, { logger = deps.logger, navigator = deps.navigator, damage = damage })
	local ownExtras: ((id: string) -> { dissonance: number, band: number, cooldowns: { [string]: number } }?)? =
		nil
	local replication = Replication.new(sim, {
		targeting = targeting,
		ownExtras = function(id: string)
			return if ownExtras ~= nil then ownExtras(id) else nil
		end,
	})
	local catalog = deps.cantCatalog or CantCatalog.production()
	local burdenCatalog = deps.burdenCatalog or BurdenCatalog.production()
	local burdens = BurdenEffects.attach(sim, {
		catalog = burdenCatalog,
		inStableEnvironment = deps.inStableEnvironment,
	})
	local playerIds: { [string]: number } = {}
	local cants = Cants.attach(sim, {
		resolve = function(value)
			return catalog:resolve(value)
		end,
		-- The Burden follows the equipped Cant.
		onChanged = function(id: string, cantId: string?)
			local userId = playerIds[id]
			local chosen = if userId ~= nil and deps.chosenBurden ~= nil
				then deps.chosenBurden(userId)
				else nil
			local unlocked = userId ~= nil
				and deps.masteryUnlocked ~= nil
				and deps.masteryUnlocked(userId)
			burdens:sync(id, cantId, chosen, unlocked)
		end,
	})
	local verseCatalog = deps.verseCatalog or VerseCatalog.production()
	local dissonance = Dissonance.attach(sim, {
		tuning = deps.dissonanceTuning,
		actions = deps.dissonanceActions,
		inStableEnvironment = deps.inStableEnvironment,
		inUnstableArea = deps.inUnstableArea,
		onRupture = deps.onRupture,
	})
	local verseEffects: VerseEffects.Layer? = nil
	local effects: { [string]: Verses.Effect } = {}
	if deps.world ~= nil then
		local movement = VerseEffects.attach(sim, {
			world = deps.world,
			onSelfMove = function(id: string)
				burdens:onNearnessMove(id)
			end,
			move = function(id: string, to: Vec3.Vec3)
				local combatant = sim:get(id)
				if combatant == nil then
					return
				end
				local userId = playerIds[id]
				if userId ~= nil and deps.teleport ~= nil then
					deps.teleport(userId, to)
				end
				combatant.position = Vec3.copy(to)
			end,
		})
		verseEffects = movement
		for name, effect in movement.effects do
			effects[name] = effect
		end
	end
	local extraEffects: { [string]: Verses.Effect } = deps.verseEffects or {}
	for name, effect in extraEffects do
		effects[name] = effect
	end
	local verses = Verses.attach(sim, {
		catalog = verseCatalog,
		cants = cants,
		lineOfSight = deps.lineOfSight,
		effects = effects,
		onResolved = function(casterId: string, verseId: string)
			local def = verseCatalog:get(verseId)
			if def ~= nil and def.dissonance ~= nil and def.dissonance > 0 then
				dissonance:add(casterId, def.dissonance, "verse")
			end
		end,
	})
	ownExtras = function(id: string)
		local cooldowns: { [string]: number } = {}
		for _, verseId in verseCatalog:ids() do
			local steps = verses:cooldownRemaining(id, verseId)
			if steps > 0 then
				cooldowns[verseId] = math.floor(steps * sim.stepSeconds * 10 + 0.5) / 10
			end
		end
		return {
			dissonance = math.floor(dissonance:value(id) * 10 + 0.5) / 10,
			band = dissonance:level(id),
			cooldowns = cooldowns,
		}
	end
	local replicateInterval = deps.replicateInterval or CombatService.DEFAULT_REPLICATE_INTERVAL
	sim:onStep(function(step: number)
		ai:tick()
		if verseEffects ~= nil then
			verseEffects:tick(step)
		end
		burdens:tick()
		targeting:tick()
		replication:collect()
	end)

	local players: { [number]: boolean } = {}
	local lastRevisionSent: { [number]: number } = {}
	local sinceReplicate = 0

	local service = {} :: Service
	service.sim = sim
	service.targeting = targeting
	service.ai = ai
	service.cants = cants
	service.verses = verses
	service.dissonance = dissonance
	service.verseCatalog = verseCatalog
	service.verseEffects = verseEffects
	service.burdens = burdens

	local function log(
		level: Logger.Level,
		event: string,
		userId: number?,
		fields: Logger.RawFields?
	)
		local logger = if userId ~= nil
			then deps.logger:with({ playerId = userId })
			else deps.logger
		logger:log(level, "gameplay", event, fields)
	end

	function service:combatantId(userId: number): string
		return playerId(userId)
	end

	function service:hasPlayer(userId: number): boolean
		return players[userId] == true
	end

	function service:addPlayer(userId: number, spec: PlayerSpec?)
		if players[userId] then
			return
		end
		local s: PlayerSpec = spec or {}
		local pose = if deps.poseOf ~= nil then deps.poseOf(userId) else nil
		sim:addCombatant({
			id = playerId(userId),
			team = s.team or CombatService.PLAYER_TEAM,
			base = s.base,
			modifiers = s.modifiers,
			position = if pose ~= nil then pose.position else nil,
			facing = if pose ~= nil then pose.facing else nil,
		})
		players[userId] = true
		playerIds[playerId(userId)] = userId
		lastRevisionSent[userId] = nil
		log("debug", "combat_player_added", userId)
	end

	function service:removePlayer(userId: number)
		if not players[userId] then
			return
		end
		players[userId] = nil
		lastRevisionSent[userId] = nil
		cants:forget(playerId(userId))
		burdens:forget(playerId(userId))
		verses:forget(playerId(userId))
		dissonance:forget(playerId(userId))
		if verseEffects ~= nil then
			verseEffects:forget(playerId(userId))
		end
		playerIds[playerId(userId)] = nil
		sim:removeCombatant(playerId(userId))
		replication:forgetViewer(playerId(userId))
		log("debug", "combat_player_removed", userId)
	end

	function service:submit(userId: number, intent: Simulation.Intent): ActionMachine.Outcome
		if not players[userId] then
			return { ok = false, reason = "not in combat" }
		end
		return sim:submit(playerId(userId), intent)
	end

	function service:requestTarget(userId: number, targetId: string?): ActionMachine.Outcome
		if not players[userId] then
			return { ok = false, reason = "not in combat" }
		end
		return targeting:request(playerId(userId), targetId)
	end

	function service:cycleTarget(userId: number): ActionMachine.Outcome
		if not players[userId] then
			return { ok = false, reason = "not in combat" }
		end
		return targeting:cycle(playerId(userId))
	end

	function service:engaged(userId: number): boolean
		return players[userId] == true and targeting:engaged(playerId(userId))
	end

	function service:spawnEnemy(spec: EnemySpec)
		sim:addCombatant({
			id = spec.id,
			team = spec.team or CombatService.ENEMY_TEAM,
			base = spec.base,
			modifiers = spec.modifiers,
			position = spec.position,
			facing = spec.facing,
		})
		local spawned = sim:get(spec.id)
		if spawned ~= nil and spec.displacement ~= nil then
			spawned.extra.displacement = spec.displacement
		end
		ai:adopt(spec.id, spec.profile)
	end

	function service:despawnEnemy(id: string): boolean
		ai:forget(id)
		if verseEffects ~= nil then
			verseEffects:forget(id)
		end
		return sim:removeCombatant(id)
	end

	local function applyPoses()
		local poseOf = deps.poseOf
		if poseOf == nil then
			return
		end
		for userId in players do
			local pose = poseOf(userId)
			local combatant = sim:get(playerId(userId))
			if pose ~= nil and combatant ~= nil and Vec3.isFinite(pose.position) then
				combatant.position = Vec3.copy(pose.position)
				if Vec3.isFinite(pose.facing) and Vec3.magnitude(pose.facing) > 0 then
					combatant.facing = Vec3.unit(pose.facing)
				end
			end
		end
	end

	local function deliver(userId: number, remote: Remote, payload: unknown)
		local ok, err = pcall(function()
			deps.send(userId, remote, payload)
		end)
		if not ok then
			log("warn", "combat_send_failed", userId, { remote = remote, error = tostring(err) })
		end
	end

	function service:replicate()
		local ids = {}
		for userId in players do
			table.insert(ids, userId)
		end
		table.sort(ids)
		for _, userId in ids do
			local viewer = playerId(userId)
			local delta = replication:delta(viewer, lastRevisionSent[userId])
			-- The own view changes every step (regeneration), so a delta
			-- always goes out; public entries are only the changed ones.
			deliver(userId, "StateDelta", delta)
			lastRevisionSent[userId] = delta.revision
			local cues = replication:cues(viewer)
			if #cues > 0 then
				local batch: CombatReplication.CueBatch =
					{ kind = "cues", revision = delta.revision, cues = cues }
				deliver(userId, "CombatCue", batch)
			end
		end
	end

	function service:tick(elapsed: number): number
		if type(elapsed) ~= "number" or elapsed ~= elapsed or elapsed < 0 then
			return 0
		end
		applyPoses()
		local steps = 0
		local ok, err = pcall(function()
			steps = sim:advance(elapsed)
		end)
		if not ok then
			log("error", "combat_step_crashed", nil, { error = tostring(err) })
			deps.telemetry:track("combat_step_crashed")
			return 0
		end
		sinceReplicate += elapsed
		if sinceReplicate >= replicateInterval then
			sinceReplicate = 0
			service:replicate()
		end
		return steps
	end

	function service:ownView(userId: number): CombatReplication.OwnCombatant?
		if not players[userId] then
			return nil
		end
		return replication:ownView(playerId(userId))
	end

	return table.freeze(service)
end

return table.freeze(CombatService)
