--!strict
-- Target acquisition, switching and engagement rules (BM-059).
--
-- A combatant's lock-on target is server state. A client may *request*
-- a target (or ask to cycle to the next one); the server grants it only
-- when the target exists, is alive and hostile, is within lock range and
-- in line of sight. Every step the server re-checks the lock and drops
-- it when the target dies, leaves, or stays out of range or sight for
-- too long. Hit resolution never consults the lock: hits are found by
-- hitboxes (BM-055); the lock only steers facing and camera cues.
--
-- Engagement: a combatant is "engaged" while it holds a target or until
-- a timeout after it last dealt or took damage. Systems such as travel
-- (BM-078) refuse to act for engaged players.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionMachine = require(script.Parent.ActionMachine)
local Damage = require(script.Parent.Damage)
local Simulation = require(script.Parent.Simulation)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)

export type Rules = {
	maxLockRange: number,
	-- Steps a target may stay out of range or out of sight before the
	-- lock drops.
	loseSteps: number,
	-- Steps after the last damage dealt or taken before disengaging.
	engageSteps: number,
}

export type Lock = { targetId: string, since: number, lostSince: number? }

export type Deps = {
	lineOfSight: ((from: Vec3.Vec3, to: Vec3.Vec3) -> boolean)?,
	damage: Damage.Damage?,
	rules: Rules?,
}

export type Targeting = {
	-- Validated lock request. `targetId == nil` clears the lock.
	request: (self: Targeting, id: string, targetId: string?) -> ActionMachine.Outcome,
	-- Locks the nearest eligible target after the current one (by
	-- distance), wrapping around; with no lock, the nearest.
	cycle: (self: Targeting, id: string) -> ActionMachine.Outcome,
	target: (self: Targeting, id: string) -> string?,
	lock: (self: Targeting, id: string) -> Lock?,
	-- Eligible targets sorted by distance.
	candidates: (self: Targeting, id: string) -> { string },
	engaged: (self: Targeting, id: string) -> boolean,
	-- Marks a combatant engaged now (for example when it is attacked
	-- without damage, or enters an arena).
	engage: (self: Targeting, id: string) -> (),
	-- Re-validates every lock; call after each simulation step.
	tick: (self: Targeting) -> (),
	rules: Rules,
}

local Targeting = {}

Targeting.DEFAULT_RULES = table.freeze({
	maxLockRange = 40,
	loseSteps = 60,
	engageSteps = 300,
} :: Rules)

local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Targeting.validateRules(value: unknown): { string }
	local problems = {}
	if type(value) ~= "table" then
		return { "rules must be a table" }
	end
	local r = value :: { [string]: unknown }
	if
		not finite(r.maxLockRange)
		or (r.maxLockRange :: number) <= 0
		or (r.maxLockRange :: number) > 500
	then
		table.insert(problems, "maxLockRange must be in (0, 500]")
	end
	for _, key in { "loseSteps", "engageSteps" } do
		local v = r[key]
		if
			not finite(v)
			or (v :: number) < 0
			or (v :: number) > 100000
			or (v :: number) % 1 ~= 0
		then
			table.insert(problems, key .. " must be a whole number of steps")
		end
	end
	return problems
end

function Targeting.attach(sim: Simulation.Simulation, deps: Deps?): Targeting
	local options: Deps = deps or {}
	local rules: Rules = options.rules or Targeting.DEFAULT_RULES
	local problems = Targeting.validateRules(rules)
	if #problems > 0 then
		error("Targeting.attach: " .. table.concat(problems, "; "), 2)
	end
	local lineOfSight: (Vec3.Vec3, Vec3.Vec3) -> boolean = options.lineOfSight
		or function(_: Vec3.Vec3, _: Vec3.Vec3): boolean
			return true
		end
	local locks: { [string]: Lock } = {}
	local lastCombat: { [string]: number } = {}

	local targeting = {} :: Targeting
	targeting.rules = rules

	-- Why a target is not eligible for `id`, or nil when it is.
	local function ineligible(me: Simulation.Combatant, target: Simulation.Combatant?): string?
		if target == nil then
			return "unknown target"
		end
		local t = target :: Simulation.Combatant
		if t.id == me.id then
			return "cannot target yourself"
		end
		if t.team == me.team then
			return "cannot target an ally"
		end
		if (t.action.state :: string) == "Dead" then
			return "target is dead"
		end
		if Vec3.distance(me.position, t.position) > rules.maxLockRange then
			return "target out of range"
		end
		if not lineOfSight(me.position, t.position) then
			return "target not in sight"
		end
		return nil
	end

	local function drop(id: string, reason: string)
		local lock = locks[id]
		if lock == nil then
			return
		end
		locks[id] = nil
		sim:emit("target_lost", id, { target = lock.targetId, reason = reason })
	end

	local function acquire(me: Simulation.Combatant, targetId: string): ActionMachine.Outcome
		local reason = ineligible(me, sim:get(targetId))
		if reason ~= nil then
			return { ok = false, reason = reason }
		end
		local existing = locks[me.id]
		if existing ~= nil and existing.targetId == targetId then
			existing.lostSince = nil
			return { ok = true }
		end
		if existing ~= nil then
			drop(me.id, "switched")
		end
		locks[me.id] = { targetId = targetId, since = sim:stepNumber(), lostSince = nil }
		sim:emit("target_acquired", me.id, { target = targetId })
		return { ok = true }
	end

	function targeting:request(id: string, targetId: string?): ActionMachine.Outcome
		local me = sim:get(id)
		if me == nil then
			return { ok = false, reason = "unknown combatant" }
		end
		if (me.action.state :: string) == "Dead" then
			return { ok = false, reason = "dead" }
		end
		if targetId == nil then
			drop(id, "cleared")
			return { ok = true }
		end
		if type(targetId) ~= "string" or #targetId == 0 or #targetId > 64 then
			return { ok = false, reason = "invalid target id" }
		end
		return acquire(me, targetId)
	end

	function targeting:candidates(id: string): { string }
		local me = sim:get(id)
		local out: { { id: string, distance: number } } = {}
		if me == nil then
			return {}
		end
		for _, otherId in sim:ids() do
			local other = sim:get(otherId)
			if other ~= nil and ineligible(me, other) == nil then
				table.insert(
					out,
					{ id = otherId, distance = Vec3.distance(me.position, other.position) }
				)
			end
		end
		table.sort(out, function(a, b)
			if a.distance ~= b.distance then
				return a.distance < b.distance
			end
			return a.id < b.id
		end)
		local ids = {}
		for _, entry in out do
			table.insert(ids, entry.id)
		end
		return ids
	end

	function targeting:cycle(id: string): ActionMachine.Outcome
		local me = sim:get(id)
		if me == nil then
			return { ok = false, reason = "unknown combatant" }
		end
		if (me.action.state :: string) == "Dead" then
			return { ok = false, reason = "dead" }
		end
		local list = targeting:candidates(id)
		if #list == 0 then
			return { ok = false, reason = "no eligible target" }
		end
		local lock = locks[id]
		local index = 0
		if lock ~= nil then
			index = table.find(list, lock.targetId) or 0
		end
		local nextId = list[index % #list + 1]
		return acquire(me, nextId)
	end

	function targeting:target(id: string): string?
		local lock = locks[id]
		return if lock ~= nil then lock.targetId else nil
	end

	function targeting:lock(id: string): Lock?
		local lock = locks[id]
		return if lock ~= nil then table.clone(lock) else nil
	end

	function targeting:engage(id: string)
		if sim:get(id) ~= nil then
			lastCombat[id] = sim:stepNumber()
		end
	end

	function targeting:engaged(id: string): boolean
		if locks[id] ~= nil then
			return true
		end
		local last = lastCombat[id]
		return last ~= nil and sim:stepNumber() - last < rules.engageSteps
	end

	if options.damage ~= nil then
		options.damage:onDamage(function(record, attacker, target)
			if record.amount > 0 or record.outcome ~= "Negated" then
				lastCombat[attacker.id] = sim:stepNumber()
				lastCombat[target.id] = sim:stepNumber()
			end
		end)
	end

	function targeting:tick()
		local step = sim:stepNumber()
		local ids = {}
		for id in locks do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local lock = locks[id]
			local me = sim:get(id)
			if me == nil or (me.action.state :: string) == "Dead" then
				drop(id, if me == nil then "removed" else "dead")
				continue
			end
			local target = sim:get(lock.targetId)
			if target == nil or (target.action.state :: string) == "Dead" then
				drop(id, if target == nil then "target removed" else "target died")
				continue
			end
			local reason = ineligible(me, target)
			if reason == nil then
				lock.lostSince = nil
			elseif lock.lostSince == nil then
				lock.lostSince = step
			elseif step - (lock.lostSince :: number) + 1 >= rules.loseSteps then
				drop(id, reason)
			end
		end
		-- Forget stale engagement marks so the table never grows.
		for id, last in lastCombat do
			if step - last >= rules.engageSteps or sim:get(id) == nil then
				lastCombat[id] = nil
			end
		end
	end

	return table.freeze(targeting)
end

return table.freeze(Targeting)
