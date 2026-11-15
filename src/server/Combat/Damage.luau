--!strict
-- Damage, defenses, invulnerability windows and death (BM-056).
--
-- Subscribes to server-found hits (BM-055) and turns each into a bounded
-- health change on the server-owned resource state. Nothing a client
-- sends reaches this module: the attacker's attack power and the target's
-- defense come from derived attributes, the hit from the hitbox pass, and
-- the only way health changes is through Simulation:damage.
--
-- Order per hit: invulnerability check (dodge active frames) -> raw
-- damage from attack power and the action's scale -> defense mitigation
-- -> defensive hooks (guard, parry; BM-057) -> clamp -> apply -> hit stun
-- -> death (handled by the simulation).

local ActionMachine = require(script.Parent.ActionMachine)
local Hitboxes = require(script.Parent.Hitboxes)
local Simulation = require(script.Parent.Simulation)

export type Outcome = "Damaged" | "Invulnerable" | "Guarded" | "Parried" | "Negated"

-- What hooks may change before the damage is applied.
export type Context = {
	hit: Hitboxes.Hit,
	attacker: Simulation.Combatant,
	target: Simulation.Combatant,
	-- Damage after mitigation; hooks may lower it (never raise past raw).
	amount: number,
	raw: number,
	-- Posture the target loses; hooks set this for guarded hits.
	posture: number,
	-- Hit stun steps; hooks may zero it (a guard absorbs the stagger).
	stunSteps: number,
	outcome: Outcome,
}

export type Hook = (context: Context) -> ()

export type Record = {
	hit: Hitboxes.Hit,
	outcome: Outcome,
	amount: number,
	posture: number,
	healthAfter: number,
	killed: boolean,
}

export type Deps = {
	-- Damage scale by action kind; kinds without a scale deal nothing.
	scales: { [string]: number }?,
	hitStunSteps: number?,
}

export type Damage = {
	onBeforeDamage: (self: Damage, hook: Hook) -> (),
	onDamage: (
		self: Damage,
		listener: (
			record: Record,
			attacker: Simulation.Combatant,
			target: Simulation.Combatant
		) -> ()
	) -> (),
	-- True while the combatant cannot be hit at all (dodge active frames).
	isInvulnerable: (self: Damage, combatant: Simulation.Combatant) -> boolean,
	-- For Hitboxes.attach({ canHit = damage.canHit }).
	canHit: (attacker: Simulation.Combatant, target: Simulation.Combatant) -> boolean,
}

local Damage = {}

Damage.MAX_HIT_DAMAGE = 1000
Damage.DEFAULT_SCALES = table.freeze({ Attack = 1.0 } :: { [string]: number })
Damage.DEFAULT_HIT_STUN_STEPS = 6

local function round2(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Raw damage from attack power and an action scale.
function Damage.raw(attackPower: number, scale: number): number
	if not finite(attackPower) or not finite(scale) or attackPower < 0 or scale < 0 then
		return 0
	end
	return round2(attackPower * scale)
end

-- Defense mitigation: defense D reduces damage to raw * 100 / (100 + D),
-- so 100 defense halves damage and no defense value reaches zero.
function Damage.mitigate(raw: number, defense: number): number
	if not finite(raw) or raw <= 0 then
		return 0
	end
	local d = if finite(defense) and defense > 0 then defense else 0
	return round2(raw * 100 / (100 + d))
end

-- Final clamp: never negative, never above the per-hit cap, never above
-- the raw amount, rounded to 1/100.
function Damage.clamp(amount: number, raw: number): number
	if not finite(amount) or amount <= 0 then
		return 0
	end
	local cap = math.min(Damage.MAX_HIT_DAMAGE, if finite(raw) then raw else 0)
	return round2(math.clamp(amount, 0, math.max(0, cap)))
end

local function isInvulnerable(combatant: Simulation.Combatant): boolean
	local action = combatant.action
	return action.state == "Dodging" and action.phase == "Active"
end

function Damage.attach(sim: Simulation.Simulation, hitboxes: Hitboxes.Hitboxes, deps: Deps?): Damage
	local options: Deps = deps or {}
	local scales = options.scales or Damage.DEFAULT_SCALES
	for kind, scale in scales do
		if not finite(scale) or scale < 0 or scale > 100 then
			error("Damage.attach: scale " .. tostring(kind) .. " must be in [0, 100]", 2)
		end
	end
	local hitStunSteps = options.hitStunSteps or Damage.DEFAULT_HIT_STUN_STEPS
	if hitStunSteps % 1 ~= 0 or hitStunSteps < 0 or hitStunSteps > 300 then
		error("Damage.attach: hitStunSteps must be a whole number of steps", 2)
	end

	local hooks: { Hook } = {}
	local listeners: { (Record, Simulation.Combatant, Simulation.Combatant) -> () } = {}

	local damage = {} :: Damage

	function damage:onBeforeDamage(hook: Hook)
		table.insert(hooks, hook)
	end

	function damage:onDamage(listener)
		table.insert(listeners, listener)
	end

	function damage:isInvulnerable(combatant: Simulation.Combatant): boolean
		return isInvulnerable(combatant)
	end

	damage.canHit = function(_: Simulation.Combatant, target: Simulation.Combatant): boolean
		return not isInvulnerable(target)
	end

	hitboxes:onHit(function(hit, attacker, target)
		if target.action.state == "Dead" then
			return
		end
		local def = attacker.action.def
		local scale = if def ~= nil then scales[def.kind] else nil
		local raw = Damage.raw(attacker.derived.attackPower, scale or 0)
		local context: Context = {
			hit = hit,
			attacker = attacker,
			target = target,
			raw = raw,
			amount = Damage.mitigate(raw, target.derived.defense),
			posture = 0,
			stunSteps = hitStunSteps,
			outcome = if isInvulnerable(target) then "Invulnerable" else "Damaged",
		}
		if context.outcome == "Invulnerable" then
			context.amount = 0
			context.stunSteps = 0
		else
			for _, hook in hooks do
				hook(context)
			end
		end
		local amount = Damage.clamp(context.amount, raw)
		local posture = Damage.clamp(context.posture, Damage.MAX_HIT_DAMAGE)
		if posture > 0 then
			-- Posture loss from a guarded hit; a break is handled by BM-057.
			local resources = target.resources
			resources.posture = round2(math.max(0, resources.posture - posture))
			resources.lastSpent.posture = sim:now()
			if resources.posture <= 0 then
				resources.postureBroken = true
			end
		end
		local applied = if amount > 0 then sim:damage(target.id, amount) else 0
		local killed = (target.action.state :: string) == "Dead"
		if not killed and applied > 0 and context.stunSteps > 0 then
			ActionMachine.interrupt(target.action, "Hit", context.stunSteps, hit.step)
			sim:emit("interrupted", target.id, { by = attacker.id, steps = context.stunSteps })
		end
		local record: Record = {
			hit = hit,
			outcome = if amount == 0 and context.outcome == "Damaged"
				then "Negated"
				else context.outcome,
			amount = applied,
			posture = posture,
			healthAfter = target.resources.health,
			killed = killed,
		}
		sim:emit("damage", target.id, {
			by = attacker.id,
			actionId = hit.actionId,
			outcome = record.outcome,
			amount = applied,
			posture = posture,
			health = record.healthAfter,
		})
		for _, listener in listeners do
			listener(record, attacker, target)
		end
	end)

	return table.freeze(damage)
end

return table.freeze(Damage)
