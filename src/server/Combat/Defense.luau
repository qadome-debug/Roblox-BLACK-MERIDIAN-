--!strict
-- Dodge, guard, parry, recovery and interruption outcomes (BM-057).
--
-- Hooks into the damage pipeline (BM-056) and decides, in server steps
-- only, what a hit does to a defender who is guarding or parrying:
--
--   * Parry: the defender is in the Active frames of a Parry and faces the
--     attacker. The hit does nothing; the attacker is staggered and loses
--     posture. One step late (still in windup, or already recovering) and
--     the hit lands in full, and a parry in recovery is interrupted.
--   * Guard: the defender holds a Guard and faces the attacker. Damage is
--     reduced, the defender pays posture and stamina, and keeps guarding.
--     If posture or stamina would run out the guard breaks: full damage
--     and a long stagger.
--   * Dodge: the active frames are invulnerable (BM-056); nothing here.
--   * Anything hit from behind, in windup, or in recovery is interrupted
--     by hit stun as usual.
--
-- Client animation timing never matters: a defender's state at the step
-- the server resolves the hit is the only input.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionMachine = require(script.Parent.ActionMachine)
local Damage = require(script.Parent.Damage)
local Resources = require(script.Parent.Resources)
local Simulation = require(script.Parent.Simulation)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

export type Tuning = {
	-- Half of the arc, in degrees, within which a guard or parry counts.
	frontHalfAngle: number,
	guardDamageFactor: number,
	guardPostureFactor: number,
	guardStaminaCost: number,
	guardBreakStaggerSteps: number,
	parryStaggerSteps: number,
	parryPostureDamage: number,
}

export type Defense = {
	-- True when `attacker` is inside the defender's front arc.
	facing: (
		self: Defense,
		defender: Simulation.Combatant,
		attacker: Simulation.Combatant
	) -> boolean,
	tuning: Tuning,
}

local Defense = {}

Defense.DEFAULT_TUNING = table.freeze({
	frontHalfAngle = 90,
	guardDamageFactor = 0.2,
	guardPostureFactor = 0.5,
	guardStaminaCost = 10,
	guardBreakStaggerSteps = 24,
	parryStaggerSteps = 20,
	parryPostureDamage = 30,
} :: Tuning)

local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Defense.validateTuning(value: unknown): { string }
	local problems = {}
	if type(value) ~= "table" then
		return { "tuning must be a table" }
	end
	local t = value :: { [string]: unknown }
	local function range(key: string, min: number, max: number, whole: boolean)
		local v = t[key]
		if
			not finite(v)
			or (v :: number) < min
			or (v :: number) > max
			or (whole and (v :: number) % 1 ~= 0)
		then
			table.insert(problems, key .. " must be in [" .. min .. ", " .. max .. "]")
		end
	end
	range("frontHalfAngle", 1, 180, false)
	range("guardDamageFactor", 0, 1, false)
	range("guardPostureFactor", 0, 10, false)
	range("guardStaminaCost", 0, 1000, false)
	range("guardBreakStaggerSteps", 1, 600, true)
	range("parryStaggerSteps", 1, 600, true)
	range("parryPostureDamage", 0, 1000, false)
	return problems
end

local function inFront(
	defender: Simulation.Combatant,
	attacker: Simulation.Combatant,
	halfAngle: number
): boolean
	local toAttacker = Vec3.sub(attacker.position, defender.position)
	toAttacker = Vec3.new(toAttacker.x, 0, toAttacker.z)
	if Vec3.magnitude(toAttacker) <= 1e-3 then
		return true
	end
	local facing = Vec3.unit(Vec3.new(defender.facing.x, 0, defender.facing.z))
	return Vec3.dot(facing, Vec3.unit(toAttacker)) >= math.cos(math.rad(halfAngle)) - 1e-9
end

function Defense.attach(sim: Simulation.Simulation, damage: Damage.Damage, tuning: Tuning?): Defense
	local t: Tuning = tuning or Defense.DEFAULT_TUNING
	local problems = Defense.validateTuning(t)
	if #problems > 0 then
		error("Defense.attach: " .. table.concat(problems, "; "), 2)
	end

	local defense = {} :: Defense
	defense.tuning = t

	function defense:facing(defender: Simulation.Combatant, attacker: Simulation.Combatant): boolean
		return inFront(defender, attacker, t.frontHalfAngle)
	end

	damage:onBeforeDamage(function(context)
		local target = context.target
		local attacker = context.attacker
		local action = target.action
		local state: string = action.state
		if (state ~= "Guarding" and state ~= "Parrying") or action.phase ~= "Active" then
			return
		end
		if not inFront(target, attacker, t.frontHalfAngle) then
			return
		end
		local now = sim:now()

		if state == "Parrying" then
			context.outcome = "Parried"
			context.amount = 0
			context.posture = 0
			context.stunSteps = 0
			Resources.spend(
				attacker.resources,
				"posture",
				math.min(attacker.resources.posture, t.parryPostureDamage),
				now
			)
			ActionMachine.interrupt(
				attacker.action,
				"Staggered",
				t.parryStaggerSteps,
				context.hit.step
			)
			sim:emit("parried", attacker.id, { by = target.id, steps = t.parryStaggerSteps })
			return
		end

		-- Guarding.
		local postureLoss = math.max(0, context.raw * t.guardPostureFactor)
		local staminaOk = Resources.spend(target.resources, "stamina", t.guardStaminaCost, now)
		if not staminaOk or target.resources.posture - postureLoss <= 0 then
			-- Guard break: full damage, posture to zero, long stagger.
			context.outcome = "Guarded"
			context.posture = math.max(postureLoss, target.resources.posture)
			context.stunSteps = 0
			ActionMachine.interrupt(
				target.action,
				"Staggered",
				t.guardBreakStaggerSteps,
				context.hit.step
			)
			sim:emit("guard_broken", target.id, {
				by = attacker.id,
				reason = if staminaOk then "posture" else "stamina",
				steps = t.guardBreakStaggerSteps,
			})
			return
		end
		context.outcome = "Guarded"
		context.amount = context.amount * t.guardDamageFactor
		context.posture = postureLoss
		context.stunSteps = 0
		sim:emit("guarded", target.id, { by = attacker.id, posture = postureLoss })
	end)

	return table.freeze(defense)
end

return table.freeze(Defense)
