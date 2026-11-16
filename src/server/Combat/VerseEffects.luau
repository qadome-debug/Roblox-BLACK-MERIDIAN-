--!strict
-- Server effects of the Nearness Verses.
--
--   close_step   shortens the path to a valid point and lunges toward it
--   draw_near    pulls an eligible enemy toward the caster
--   between_us   a temporary adjacency tether between two targets
--   no_farther   a temporary zone that compresses escape distance
--
-- Everything here is server-owned. A client sends an aim point and target
-- hints; the server picks the destination, the targets and every position.
-- Nothing here is final balance: every number is read from the Verse
-- definition's `params` (Content/NearnessTuning), so it can be changed in
-- one place after the Verses have been played.
--
-- Safety rules, all enforced here and tested:
--
--   * Movement goes through the injected world port. A destination is the
--     farthest valid point along the path, so nothing crosses a wall, a
--     locked door or an encounter boundary, and nothing is placed above
--     `maxRise` or over a void.
--   * Bosses (displacement "immune") are never pulled or tethered, and are
--     not slowed by a zone unless a definition says so. Elites are moved
--     by a reduced amount.
--   * Pulls and tethers move a target a little each simulation step, at a
--     bounded speed, and stop at the first obstruction. They never teleport
--     a target repeatedly and never touch physics.
--   * A tether never moves the caster, and a zone never affects the
--     caster's team.
--   * Fields end when their owner or a tethered target dies or leaves, and
--     the number of active fields is capped.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Resources = require(script.Parent.Resources)
local Simulation = require(script.Parent.Simulation)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)
local Verses = require(script.Parent.Verses)

type Combatant = Simulation.Combatant

-- Farthest valid point on the path from `from` toward `to`, grounded; `from`
-- itself when nothing is reachable.
export type World = {
	sweep: (from: Vec3.Vec3, to: Vec3.Vec3) -> Vec3.Vec3,
}

export type Deps = {
	world: World,
	-- Moves a combatant to a position the server has chosen (and its
	-- character, for a player).
	move: (id: string, to: Vec3.Vec3) -> (),
}

export type Layer = {
	effects: { [string]: Verses.Effect },
	-- Advance pulls, tethers and zones. Call once per step, after enemy AI.
	tick: (self: Layer, step: number) -> (),
	forget: (self: Layer, id: string) -> (),
	counts: (self: Layer) -> { pulls: number, tethers: number, zones: number },
}

local VerseEffects = {}

VerseEffects.MAX_ACTIVE = 64

type Pull = { anchor: string, stop: number, perStep: number, stepsLeft: number }
type Tether = {
	a: string,
	b: string,
	caster: string,
	maxDistance: number,
	speedPerStep: number,
	eliteScale: number,
	endsStep: number,
}
type Zone = {
	caster: string,
	team: string,
	center: Vec3.Vec3,
	radius: number,
	awayScale: number,
	affectsBosses: boolean,
	endsStep: number,
}

local function flat(v: Vec3.Vec3): Vec3.Vec3
	return { x = v.x, y = 0, z = v.z }
end

local function flatUnit(v: Vec3.Vec3): Vec3.Vec3?
	local f = flat(v)
	local m = Vec3.magnitude(f)
	if m < 1e-6 then
		return nil
	end
	return Vec3.scale(f, 1 / m)
end

local function alive(c: Combatant?): boolean
	return c ~= nil and (c.action.state :: string) ~= "Dead" and not Resources.isDead(c.resources)
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function count(map: { [string]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

function VerseEffects.attach(sim: Simulation.Simulation, deps: Deps): Layer
	local world = deps.world
	local move = deps.move
	local pulls: { [string]: Pull } = {}
	local tethers: { [string]: Tether } = {}
	local zones: { [string]: Zone } = {}
	-- Position of each zone subject at the end of the previous tick.
	local last: { [string]: Vec3.Vec3 } = {}

	local function steps(seconds: number): number
		return math.max(1, math.floor(seconds / sim.stepSeconds + 0.5))
	end

	local function emitMotion(
		id: string,
		verseId: string,
		kind: string,
		from: Vec3.Vec3,
		to: Vec3.Vec3,
		seconds: number,
		target: string?
	)
		sim:emit("verse_motion", id, {
			verseId = verseId,
			kind = kind,
			fromX = from.x,
			fromY = from.y,
			fromZ = from.z,
			toX = to.x,
			toY = to.y,
			toZ = to.z,
			seconds = seconds,
			target = target,
		})
	end

	local function emitField(
		id: string,
		verseId: string,
		kind: string,
		state: string,
		center: Vec3.Vec3?,
		radius: number?,
		seconds: number?,
		a: string?,
		b: string?
	)
		sim:emit("verse_field", id, {
			verseId = verseId,
			kind = kind,
			state = state,
			x = if center ~= nil then center.x else nil,
			y = if center ~= nil then center.y else nil,
			z = if center ~= nil then center.z else nil,
			radius = radius,
			seconds = seconds,
			a = a,
			b = b,
		})
	end

	local function displacementScale(c: Combatant, eliteScale: number): number
		return if c.extra.displacement == "elite" then eliteScale else 1
	end

	-- Moves one combatant toward a point by at most `distance`, stopping at
	-- the first obstruction. Returns whether it moved at least half of it.
	local function stepToward(c: Combatant, toward: Vec3.Vec3, distance: number): boolean
		local direction = flatUnit(Vec3.sub(toward, c.position))
		if direction == nil or distance <= 0 then
			return false
		end
		local goal = Vec3.add(c.position, Vec3.scale(direction, distance))
		local reached = world.sweep(c.position, goal)
		local moved = Vec3.flatDistance(c.position, reached)
		if moved < distance * 0.5 then
			return false
		end
		move(c.id, reached)
		return true
	end

	local effects: { [string]: Verses.Effect } = {}

	effects.close_step = function(ctx: Verses.Context): boolean?
		local caster = ctx.caster
		local p = ctx.params
		local aimDir = if ctx.aim ~= nil then flatUnit(Vec3.sub(ctx.aim, caster.position)) else nil
		local direction = aimDir or flatUnit(caster.facing)
		if direction == nil then
			return false
		end
		local from = Vec3.copy(caster.position)
		local goal = Vec3.add(from, Vec3.scale(direction, p.range))
		local reached = world.sweep(from, goal)
		if Vec3.flatDistance(from, reached) < p.minDistance then
			return false
		end
		if reached.y - from.y > p.maxRise then
			return false
		end
		move(caster.id, reached)
		emitMotion(caster.id, ctx.verseId, "lunge", from, reached, p.lungeSeconds, nil)
		return true
	end

	effects.draw_near = function(ctx: Verses.Context): boolean?
		local caster = ctx.caster
		local target = ctx.target
		local p = ctx.params
		if target == nil or Verses.isImmune(target) then
			return false
		end
		if (pulls[target.id] == nil) and count(pulls) >= VerseEffects.MAX_ACTIVE then
			return false
		end
		local remaining = Vec3.flatDistance(target.position, caster.position) - p.stopDistance
		if remaining < 0.25 then
			return false
		end
		local total = remaining * displacementScale(target, p.eliteScale)
		local n = steps(p.pullSeconds)
		pulls[target.id] =
			{ anchor = caster.id, stop = p.stopDistance, perStep = total / n, stepsLeft = n }
		emitMotion(
			caster.id,
			ctx.verseId,
			"pull",
			target.position,
			caster.position,
			p.pullSeconds,
			target.id
		)
		return true
	end

	effects.between_us = function(ctx: Verses.Context): boolean?
		local caster = ctx.caster
		local a = ctx.target
		local b = ctx.targetB
		local p = ctx.params
		if a == nil or b == nil or Verses.isImmune(a) or Verses.isImmune(b) then
			return false
		end
		if tethers[caster.id] == nil and count(tethers) >= VerseEffects.MAX_ACTIVE then
			return false
		end
		tethers[caster.id] = {
			a = a.id,
			b = b.id,
			caster = caster.id,
			maxDistance = p.maxDistance,
			speedPerStep = p.correctionSpeed * sim.stepSeconds,
			eliteScale = p.eliteScale,
			endsStep = ctx.step + steps(p.durationSeconds),
		}
		emitField(
			caster.id,
			ctx.verseId,
			"tether",
			"start",
			nil,
			nil,
			p.durationSeconds,
			a.id,
			b.id
		)
		return true
	end

	effects.no_farther = function(ctx: Verses.Context): boolean?
		local caster = ctx.caster
		local p = ctx.params
		local from = caster.position
		local direction = if ctx.aim ~= nil then flatUnit(Vec3.sub(ctx.aim, from)) else nil
		direction = direction or flatUnit(caster.facing)
		if direction == nil then
			return false
		end
		local distance = if ctx.aim ~= nil
			then math.min(p.range, Vec3.flatDistance(from, ctx.aim))
			else p.range
		local center = world.sweep(from, Vec3.add(from, Vec3.scale(direction, distance)))
		if zones[caster.id] == nil and count(zones) >= VerseEffects.MAX_ACTIVE then
			return false
		end
		zones[caster.id] = {
			caster = caster.id,
			team = caster.team,
			center = center,
			radius = p.radius,
			awayScale = p.awayScale,
			affectsBosses = (p.affectsBosses or 0) ~= 0,
			endsStep = ctx.step + steps(p.durationSeconds),
		}
		emitField(
			caster.id,
			ctx.verseId,
			"zone",
			"start",
			center,
			p.radius,
			p.durationSeconds,
			nil,
			nil
		)
		return true
	end

	local layer = {} :: Layer
	layer.effects = effects

	local function tickPulls()
		for _, targetId in sortedKeys(pulls) do
			local pull = pulls[targetId]
			local target = sim:get(targetId)
			local anchor = sim:get(pull.anchor)
			if not alive(target) or not alive(anchor) then
				pulls[targetId] = nil
				continue
			end
			local t = target :: Combatant
			local gap = Vec3.flatDistance(t.position, (anchor :: Combatant).position) - pull.stop
			local distance = math.min(pull.perStep, gap)
			if distance <= 0 or not stepToward(t, (anchor :: Combatant).position, distance) then
				pulls[targetId] = nil
				continue
			end
			pull.stepsLeft -= 1
			if pull.stepsLeft <= 0 then
				pulls[targetId] = nil
			end
		end
	end

	local function tickTethers(step: number)
		for _, owner in sortedKeys(tethers) do
			local tether = tethers[owner]
			local a = sim:get(tether.a)
			local b = sim:get(tether.b)
			local caster = sim:get(tether.caster)
			if step >= tether.endsStep or not alive(a) or not alive(b) or not alive(caster) then
				tethers[owner] = nil
				emitField(owner, "", "tether", "end", nil, nil, nil, tether.a, tether.b)
				continue
			end
			-- The caster is never moved. Otherwise the second target is drawn
			-- toward the first.
			local anchor = a :: Combatant
			local mover = b :: Combatant
			if tether.b == tether.caster then
				anchor, mover = b :: Combatant, a :: Combatant
			end
			local gap = Vec3.flatDistance(anchor.position, mover.position) - tether.maxDistance
			if gap > 0.05 then
				local scale = displacementScale(mover, tether.eliteScale)
				stepToward(mover, anchor.position, math.min(gap, tether.speedPerStep * scale))
			end
		end
	end

	local function tickZones(step: number)
		for _, owner in sortedKeys(zones) do
			local zone = zones[owner]
			local caster = sim:get(zone.caster)
			if step >= zone.endsStep or not alive(caster) then
				zones[owner] = nil
				emitField(owner, "", "zone", "end", zone.center, zone.radius, nil, nil, nil)
				continue
			end
			for _, id in sim:ids() do
				local c = sim:get(id)
				local before = last[id]
				if
					c == nil
					or before == nil
					or id == zone.caster
					or c.team == zone.team
					or not alive(c)
					or (Verses.isImmune(c) and not zone.affectsBosses)
				then
					continue
				end
				-- Only a subject that was inside at the end of the previous tick.
				local offset = flatUnit(Vec3.sub(before, zone.center))
				if offset == nil or Vec3.flatDistance(before, zone.center) > zone.radius then
					continue
				end
				-- Movement away from the centre since the previous tick is scaled.
				local delta = flat(Vec3.sub(c.position, before))
				local outward = Vec3.dot(delta, offset)
				if outward > 0 then
					local back = Vec3.scale(offset, outward * (1 - zone.awayScale))
					local corrected = Vec3.sub(c.position, back)
					c.position = world.sweep(c.position, corrected)
				end
			end
		end
	end

	function layer:tick(step: number)
		tickZones(step)
		tickPulls()
		tickTethers(step)
		-- Remember where every combatant ended up, for the next zone check.
		table.clear(last)
		if next(zones) ~= nil then
			for _, id in sim:ids() do
				local c = sim:get(id)
				if c ~= nil then
					last[id] = Vec3.copy(c.position)
				end
			end
		end
	end

	function layer:forget(id: string)
		pulls[id] = nil
		tethers[id] = nil
		zones[id] = nil
		last[id] = nil
		for _, pull in pulls do
			if pull.anchor == id then
				pull.stepsLeft = 0
			end
		end
	end

	function layer:counts()
		return { pulls = count(pulls), tethers = count(tethers), zones = count(zones) }
	end

	return table.freeze(layer) :: any
end

return table.freeze(VerseEffects)
