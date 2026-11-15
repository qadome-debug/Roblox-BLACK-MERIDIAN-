--!strict
-- Server hitboxes, hit windows, collision filtering and target
-- eligibility (BM-055).
--
-- A hit exists only when the server finds it: during the Active frames of
-- an attack, for each other combatant that is alive, hostile, inside the
-- attack's reach, height band and arc, unobstructed, and not already hit
-- by this swing. Clients never claim hits; the `target` field on an intent
-- is a preference for target selection (BM-059), never evidence.
--
-- Hit resolution produces Hit records and events. Damage, defenses and
-- invulnerability (BM-056/057) subscribe to those records; this module
-- deals no damage itself.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Simulation = require(script.Parent.Simulation)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

export type Shape = {
	-- Horizontal reach in studs from the attacker's position.
	reach: number,
	-- Half of the total arc in degrees, measured from the facing vector.
	halfAngle: number,
	-- Allowed vertical separation in studs.
	height: number,
}

export type Hit = {
	attackerId: string,
	targetId: string,
	actionId: number,
	step: number,
	frame: number,
	distance: number,
}

export type HitListener = (
	hit: Hit,
	attacker: Simulation.Combatant,
	target: Simulation.Combatant
) -> ()

export type Deps = {
	-- Returns false when something blocks the segment between the two
	-- points. The Roblox adapter raycasts; the default sees everything.
	lineOfSight: ((from: Vec3.Vec3, to: Vec3.Vec3) -> boolean)?,
	-- Hit shapes by action kind; kinds without a shape never hit.
	shapes: { [string]: Shape }?,
	friendlyFire: boolean?,
	-- Extra per-pair filter (invulnerability frames, BM-056).
	canHit: ((attacker: Simulation.Combatant, target: Simulation.Combatant) -> boolean)?,
}

export type Hitboxes = {
	onHit: (self: Hitboxes, listener: HitListener) -> (),
	-- Eligible targets for `attacker` right now, ignoring the per-swing
	-- duplicate filter. For target acquisition (BM-059) and tests.
	candidates: (self: Hitboxes, attackerId: string) -> { string },
	-- Number of distinct targets hit by the attacker's current swing.
	hitsThisSwing: (self: Hitboxes, attackerId: string) -> number,
}

local Hitboxes = {}

Hitboxes.DEFAULT_SHAPES = table.freeze({
	Attack = table.freeze({ reach = 6, halfAngle = 60, height = 6 }),
} :: { [string]: Shape })

Hitboxes.MAX_REACH = 64

function Hitboxes.validateShape(value: unknown): { string }
	local problems = {}
	if type(value) ~= "table" then
		return { "shape must be a table" }
	end
	local s = value :: { [any]: unknown }
	local function finite(v: unknown): boolean
		return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
	end
	if
		not finite(s.reach)
		or (s.reach :: number) <= 0
		or (s.reach :: number) > Hitboxes.MAX_REACH
	then
		table.insert(problems, "reach must be in (0, " .. Hitboxes.MAX_REACH .. "]")
	end
	if not finite(s.halfAngle) or (s.halfAngle :: number) <= 0 or (s.halfAngle :: number) > 180 then
		table.insert(problems, "halfAngle must be in (0, 180]")
	end
	if not finite(s.height) or (s.height :: number) <= 0 then
		table.insert(problems, "height must be positive")
	end
	return problems
end

type Swing = { actionId: number, hit: { [string]: boolean } }

function Hitboxes.attach(sim: Simulation.Simulation, deps: Deps?): Hitboxes
	local options: Deps = deps or {}
	local shapes = options.shapes or Hitboxes.DEFAULT_SHAPES
	for kind, shape in shapes do
		local problems = Hitboxes.validateShape(shape)
		if #problems > 0 then
			error(
				"Hitboxes.attach: shape " .. tostring(kind) .. ": " .. table.concat(problems, "; "),
				2
			)
		end
	end
	local lineOfSight: (Vec3.Vec3, Vec3.Vec3) -> boolean = options.lineOfSight
		or function(_: Vec3.Vec3, _: Vec3.Vec3): boolean
			return true
		end
	local friendlyFire = options.friendlyFire == true
	local canHit = options.canHit
	local listeners: { HitListener } = {}
	local swings: { [string]: Swing } = {}

	local hitboxes = {} :: Hitboxes

	local function eligible(
		attacker: Simulation.Combatant,
		target: Simulation.Combatant,
		shape: Shape
	): number?
		if target.id == attacker.id or target.action.state == "Dead" then
			return nil
		end
		if not friendlyFire and target.team == attacker.team then
			return nil
		end
		local distance = Vec3.flatDistance(attacker.position, target.position)
		if distance > shape.reach then
			return nil
		end
		if math.abs(target.position.y - attacker.position.y) > shape.height then
			return nil
		end
		if distance > 1e-3 then
			local toTarget = Vec3.sub(target.position, attacker.position)
			toTarget = Vec3.unit(Vec3.new(toTarget.x, 0, toTarget.z))
			local facing = Vec3.unit(Vec3.new(attacker.facing.x, 0, attacker.facing.z))
			local cosine = Vec3.dot(facing, toTarget)
			if cosine < math.cos(math.rad(shape.halfAngle)) - 1e-9 then
				return nil
			end
		end
		if canHit ~= nil and not canHit(attacker, target) then
			return nil
		end
		if not lineOfSight(attacker.position, target.position) then
			return nil
		end
		return distance
	end

	local function shapeFor(attacker: Simulation.Combatant): Shape?
		local def = attacker.action.def
		if def == nil then
			return nil
		end
		return shapes[def.kind]
	end

	function hitboxes:candidates(attackerId: string): { string }
		local attacker = sim:get(attackerId)
		local out = {}
		if attacker == nil then
			return out
		end
		local shape = shapeFor(attacker) or shapes.Attack
		if shape == nil then
			return out
		end
		for _, id in sim:ids() do
			local target = sim:get(id)
			if target ~= nil and eligible(attacker, target, shape) ~= nil then
				table.insert(out, id)
			end
		end
		return out
	end

	function hitboxes:hitsThisSwing(attackerId: string): number
		local attacker = sim:get(attackerId)
		local swing = swings[attackerId]
		if
			attacker == nil
			or swing == nil
			or attacker.action.def == nil
			or swing.actionId ~= attacker.action.actionId
		then
			return 0
		end
		local n = 0
		for _ in swing.hit do
			n += 1
		end
		return n
	end

	function hitboxes:onHit(listener: HitListener)
		table.insert(listeners, listener)
	end

	sim:onActive(function(attacker: Simulation.Combatant, frame: number, step: number)
		local shape = shapeFor(attacker)
		if shape == nil then
			return
		end
		local swing = swings[attacker.id]
		if swing == nil or swing.actionId ~= attacker.action.actionId then
			swing = { actionId = attacker.action.actionId, hit = {} }
			swings[attacker.id] = swing
		end
		for _, id in sim:ids() do
			local target = sim:get(id)
			if target == nil or swing.hit[id] then
				continue
			end
			local distance = eligible(attacker, target, shape)
			if distance == nil then
				continue
			end
			swing.hit[id] = true
			sim:emit("hit", attacker.id, { target = id, actionId = swing.actionId, frame = frame })
			local hit: Hit = {
				attackerId = attacker.id,
				targetId = id,
				actionId = swing.actionId,
				step = step,
				frame = frame,
				distance = distance,
			}
			for _, listener in listeners do
				listener(hit, attacker, target)
			end
		end
	end)

	return table.freeze(hitboxes)
end

return table.freeze(Hitboxes)
