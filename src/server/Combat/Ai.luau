--!strict
-- Enemy AI: states, aggro, navigation and attack scheduling (BM-058).
--
-- Each enemy combatant gets a brain that runs on the server every
-- simulation step and acts only through the simulation's intent API, so
-- an enemy obeys exactly the same action rules as a player and nothing a
-- client sends can steer it. Navigation goes through an injected
-- navigator (the Roblox adapter wraps PathfindingService; tests script
-- it), and the brain moves the combatant's authoritative position along
-- the returned path at the enemy's own move speed.
--
-- States: Idle (at home, scanning) -> Chase (path to target) -> Attack
-- (in range, scheduling swings) -> Return (leashed, lost target, or path
-- failures) -> Idle. A returning enemy ignores everyone and is fully
-- reset (health, resources, target) when it reaches home.
--
-- Loot ownership is tallied here from server-resolved damage, never from
-- client claims.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Damage = require(script.Parent.Damage)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Resources = require(script.Parent.Resources)
local Simulation = require(script.Parent.Simulation)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

export type AiState = "Idle" | "Chase" | "Attack" | "Return" | "Dead"

-- Returns waypoints from `from` to `to` (excluding `from`), or nil when
-- no path exists.
export type Navigator = { pathTo: (from: Vec3.Vec3, to: Vec3.Vec3) -> { Vec3.Vec3 }? }

export type Profile = {
	aggroRange: number,
	attackRange: number,
	-- Distance from home beyond which the enemy gives up and returns.
	leashRange: number,
	-- Steps a target may stay unreachable (no path) before giving up.
	maxPathFailures: number,
	-- Steps between the end of one swing and the start of the next,
	-- plus up to `attackJitterSteps` of deterministic jitter.
	attackCooldownSteps: number,
	attackJitterSteps: number,
	-- How often (in steps) to ask the navigator for a fresh path.
	repathSteps: number,
}

export type Brain = {
	id: string,
	state: AiState,
	home: Vec3.Vec3,
	targetId: string?,
	path: { Vec3.Vec3 },
	pathFailures: number,
	lastPathStep: number,
	nextAttackStep: number,
	sequence: number,
	damageBy: { [string]: number },
}

export type Deps = {
	logger: Logger.Logger,
	navigator: Navigator?,
	damage: Damage.Damage?,
}

export type Ai = {
	-- Registers an enemy already added to the simulation.
	adopt: (self: Ai, enemyId: string, profile: Profile?) -> Brain,
	forget: (self: Ai, enemyId: string) -> (),
	brain: (self: Ai, enemyId: string) -> Brain?,
	-- Runs every brain once; call after each simulation step.
	tick: (self: Ai) -> (),
	-- The combatant that dealt the most damage to this enemy, or nil.
	lootOwner: (self: Ai, enemyId: string) -> string?,
}

local Ai = {}

Ai.DEFAULT_PROFILE = table.freeze({
	aggroRange = 20,
	attackRange = 5,
	leashRange = 40,
	maxPathFailures = 3,
	attackCooldownSteps = 30,
	attackJitterSteps = 10,
	repathSteps = 10,
} :: Profile)

local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Ai.validateProfile(value: unknown): { string }
	local problems = {}
	if type(value) ~= "table" then
		return { "profile must be a table" }
	end
	local p = value :: { [string]: unknown }
	local function range(key: string, min: number, max: number, whole: boolean)
		local v = p[key]
		if
			not finite(v)
			or (v :: number) < min
			or (v :: number) > max
			or (whole and (v :: number) % 1 ~= 0)
		then
			table.insert(problems, key .. " must be in [" .. min .. ", " .. max .. "]")
		end
	end
	range("aggroRange", 1, 500, false)
	range("attackRange", 1, 64, false)
	range("leashRange", 1, 2000, false)
	range("maxPathFailures", 0, 1000, true)
	range("attackCooldownSteps", 0, 3000, true)
	range("attackJitterSteps", 0, 3000, true)
	range("repathSteps", 1, 3000, true)
	if #problems == 0 and (p.attackRange :: number) > (p.aggroRange :: number) then
		table.insert(problems, "attackRange must not exceed aggroRange")
	end
	return problems
end

local STRAIGHT_LINE: Navigator = table.freeze({
	pathTo = function(_: Vec3.Vec3, to: Vec3.Vec3): { Vec3.Vec3 }?
		return { Vec3.copy(to) }
	end,
})
Ai.STRAIGHT_LINE = STRAIGHT_LINE

function Ai.attach(sim: Simulation.Simulation, deps: Deps): Ai
	local navigator = deps.navigator or STRAIGHT_LINE
	local brains: { [string]: Brain } = {}
	local profiles: { [string]: Profile } = {}
	local order: { string } = {}

	local ai = {} :: Ai

	local function log(event: string, enemyId: string, fields: Logger.RawFields?)
		deps.logger:log("debug", "gameplay", event, fields)
		sim:emit(event, enemyId, fields)
	end

	if deps.damage ~= nil then
		deps.damage:onDamage(function(record, attacker, target)
			local brain = brains[target.id]
			if brain ~= nil and record.amount > 0 then
				brain.damageBy[attacker.id] = (brain.damageBy[attacker.id] or 0) + record.amount
			end
		end)
	end

	function ai:adopt(enemyId: string, profile: Profile?): Brain
		local combatant = sim:get(enemyId)
		if combatant == nil then
			error("Ai:adopt: unknown combatant " .. tostring(enemyId), 2)
		end
		if brains[enemyId] ~= nil then
			error("Ai:adopt: already adopted " .. enemyId, 2)
		end
		local p: Profile = profile or Ai.DEFAULT_PROFILE
		local problems = Ai.validateProfile(p)
		if #problems > 0 then
			error("Ai:adopt: " .. table.concat(problems, "; "), 2)
		end
		local brain: Brain = {
			id = enemyId,
			state = "Idle",
			home = Vec3.copy(combatant.position),
			targetId = nil,
			path = {},
			pathFailures = 0,
			lastPathStep = -math.huge,
			nextAttackStep = 0,
			sequence = 0,
			damageBy = {},
		}
		brains[enemyId] = brain
		profiles[enemyId] = p
		table.insert(order, enemyId)
		table.sort(order)
		return brain
	end

	function ai:forget(enemyId: string)
		if brains[enemyId] == nil then
			return
		end
		brains[enemyId] = nil
		profiles[enemyId] = nil
		local index = table.find(order, enemyId)
		if index ~= nil then
			table.remove(order, index)
		end
	end

	function ai:brain(enemyId: string): Brain?
		return brains[enemyId]
	end

	function ai:lootOwner(enemyId: string): string?
		local brain = brains[enemyId]
		if brain == nil then
			return nil
		end
		local best: string? = nil
		local bestAmount = 0
		local ids = {}
		for id in brain.damageBy do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local amount = brain.damageBy[id]
			if amount > bestAmount then
				best = id
				bestAmount = amount
			end
		end
		return best
	end

	local function nearestHostile(enemy: Simulation.Combatant, range: number): Simulation.Combatant?
		local best: Simulation.Combatant? = nil
		local bestDistance = range
		for _, id in sim:ids() do
			local other = sim:get(id)
			if
				other == nil
				or other.id == enemy.id
				or other.team == enemy.team
				or other.action.state == "Dead"
			then
				continue
			end
			local distance = Vec3.flatDistance(enemy.position, other.position)
			if distance <= bestDistance then
				best = other
				bestDistance = distance
			end
		end
		return best
	end

	local function face(enemy: Simulation.Combatant, point: Vec3.Vec3)
		local direction = Vec3.sub(point, enemy.position)
		direction = Vec3.new(direction.x, 0, direction.z)
		if Vec3.magnitude(direction) > 1e-3 then
			enemy.facing = Vec3.unit(direction)
		end
	end

	-- Moves along the brain's path by one step's worth of distance.
	-- Returns true when the end of the path was reached.
	local function follow(enemy: Simulation.Combatant, brain: Brain): boolean
		local budget = enemy.derived.moveSpeed * sim.stepSeconds
		while budget > 0 and #brain.path > 0 do
			local waypoint = brain.path[1]
			local delta = Vec3.sub(waypoint, enemy.position)
			local distance = Vec3.magnitude(delta)
			if distance <= budget then
				enemy.position = Vec3.copy(waypoint)
				budget -= distance
				table.remove(brain.path, 1)
			else
				face(enemy, waypoint)
				enemy.position = Vec3.add(enemy.position, Vec3.scale(delta, budget / distance))
				budget = 0
			end
		end
		return #brain.path == 0
	end

	-- Asks the navigator for a path when due. Returns false on failure.
	local function repath(
		enemy: Simulation.Combatant,
		brain: Brain,
		profile: Profile,
		to: Vec3.Vec3
	): boolean
		local step = sim:stepNumber()
		if
			step - brain.lastPathStep < profile.repathSteps
			and (#brain.path > 0 or brain.pathFailures > 0)
		then
			-- Inside the repath interval: keep following, or keep waiting
			-- after a failure without counting a new one.
			return #brain.path > 0
		end
		brain.lastPathStep = step
		local path = navigator.pathTo(enemy.position, to)
		if path == nil then
			brain.path = {}
			brain.pathFailures += 1
			log("ai_path_failed", enemy.id, { failures = brain.pathFailures })
			return false
		end
		brain.path = path
		brain.pathFailures = 0
		return true
	end

	local function startReturn(brain: Brain, enemy: Simulation.Combatant, reason: string)
		brain.state = "Return"
		brain.targetId = nil
		brain.path = {}
		brain.lastPathStep = -math.huge
		log("ai_return", enemy.id, { reason = reason })
	end

	local function reset(brain: Brain, enemy: Simulation.Combatant)
		brain.state = "Idle"
		brain.targetId = nil
		brain.path = {}
		brain.pathFailures = 0
		brain.damageBy = {}
		enemy.position = Vec3.copy(brain.home)
		local resources = enemy.resources
		Resources.restore(resources, "health", enemy.derived.maxHealth, enemy.derived)
		Resources.restore(resources, "stamina", enemy.derived.maxStamina, enemy.derived)
		Resources.restore(resources, "posture", enemy.derived.maxPosture, enemy.derived)
		log("ai_reset", enemy.id)
	end

	local function currentTarget(brain: Brain): Simulation.Combatant?
		if brain.targetId == nil then
			return nil
		end
		local target = sim:get(brain.targetId :: string)
		if target == nil or target.action.state == "Dead" then
			return nil
		end
		return target
	end

	local function think(brain: Brain, enemy: Simulation.Combatant, profile: Profile)
		local state: string = brain.state
		if state == "Idle" then
			local target = nearestHostile(enemy, profile.aggroRange)
			if target ~= nil then
				brain.targetId = target.id
				brain.state = "Chase"
				brain.lastPathStep = -math.huge
				log("ai_aggro", enemy.id, { target = target.id })
			end
			return
		end

		if state == "Return" then
			if not repath(enemy, brain, profile, brain.home) then
				if brain.pathFailures > profile.maxPathFailures then
					-- Nothing leads home: snap back rather than stay stuck.
					reset(brain, enemy)
				end
				return
			end
			if follow(enemy, brain) and Vec3.flatDistance(enemy.position, brain.home) <= 0.5 then
				reset(brain, enemy)
			end
			return
		end

		-- Chase / Attack share the target checks.
		local target = currentTarget(brain)
		if target == nil then
			startReturn(brain, enemy, "target_lost")
			return
		end
		if Vec3.flatDistance(enemy.position, brain.home) > profile.leashRange then
			startReturn(brain, enemy, "leash")
			return
		end
		local distance = Vec3.flatDistance(enemy.position, target.position)

		if state == "Chase" then
			if distance <= profile.attackRange then
				brain.state = "Attack"
				brain.path = {}
				face(enemy, target.position)
				return
			end
			if not repath(enemy, brain, profile, target.position) then
				if brain.pathFailures > profile.maxPathFailures then
					startReturn(brain, enemy, "path_failed")
				end
				return
			end
			follow(enemy, brain)
			return
		end

		-- Attack.
		if distance > profile.attackRange then
			brain.state = "Chase"
			brain.lastPathStep = -math.huge
			return
		end
		face(enemy, target.position)
		if enemy.action.state ~= "Idle" then
			return
		end
		local step = sim:stepNumber()
		if step < brain.nextAttackStep then
			return
		end
		brain.sequence += 1
		local outcome =
			sim:submit(enemy.id, { kind = "Attack", sequence = brain.sequence, target = target.id })
		if outcome.ok then
			local jitter = if profile.attackJitterSteps > 0
				then sim.rng:nextInteger(0, profile.attackJitterSteps)
				else 0
			brain.nextAttackStep = step + profile.attackCooldownSteps + jitter
		end
	end

	function ai:tick()
		for _, id in order do
			local brain = brains[id]
			local enemy = sim:get(id)
			if enemy == nil then
				continue
			end
			if enemy.action.state == "Dead" then
				brain.state = "Dead"
				continue
			end
			if brain.state == "Dead" then
				continue
			end
			think(brain, enemy, profiles[id] :: Profile)
		end
	end

	return table.freeze(ai)
end

return table.freeze(Ai)
