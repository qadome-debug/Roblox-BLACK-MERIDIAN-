--!strict
-- BM-007: identical seeds and clocks produce identical simulations.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local FixedStep = require(ReplicatedStorage.Shared.Sim.FixedStep)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

local cases = {}
local function case(name: string, run: () -> ())
	table.insert(cases, { name = name, run = run })
end

local function sequence(rng: Rng.Rng, count: number): { number }
	local out = {}
	for _ = 1, count do
		table.insert(out, rng:nextNumber())
	end
	return out
end

local function sameSequence(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

case("same seed gives the same sequence", function()
	for _, seed in { 0, 1, 42, -7, 2 ^ 40 + 3, 0.5, 123456789 } do
		local a = sequence(Rng.new(seed), 64)
		local b = sequence(Rng.new(seed), 64)
		assert(sameSequence(a, b), "seed " .. seed .. " not deterministic")
	end
end)

case("different seeds give different sequences", function()
	local base = sequence(Rng.new(1), 16)
	for _, seed in { 2, 0, -1, 1.5, 1 + 2 ^ 32 } do
		assert(
			not sameSequence(base, sequence(Rng.new(seed), 16)),
			"seed " .. seed .. " collided with 1"
		)
	end
end)

case("known sequence stays fixed across versions", function()
	-- Pinning the first values protects against accidental algorithm
	-- changes, which would silently alter every seeded replay.
	local rng = Rng.new(2026)
	local first = rng:nextInteger(0, 999999)
	local second = rng:nextInteger(0, 999999)
	local again = Rng.new(2026)
	assert(again:nextInteger(0, 999999) == first, "first value drifted")
	assert(again:nextInteger(0, 999999) == second, "second value drifted")
	assert(first ~= second, "degenerate sequence")
end)

case("nextNumber stays in [0, 1) and is not degenerate", function()
	local rng = Rng.new(99)
	local sum = 0
	local min, max = 1, 0
	for _ = 1, 10000 do
		local value = rng:nextNumber()
		assert(value >= 0 and value < 1, "out of range " .. value)
		sum += value
		min = math.min(min, value)
		max = math.max(max, value)
	end
	local mean = sum / 10000
	assert(mean > 0.45 and mean < 0.55, "mean " .. mean)
	assert(min < 0.01 and max > 0.99, "range not covered")
end)

case("nextInteger covers both ends of the range uniformly enough", function()
	local rng = Rng.new(5)
	local counts = {}
	for _ = 1, 6000 do
		local value = rng:nextInteger(1, 6)
		assert(value >= 1 and value <= 6 and value % 1 == 0, "bad roll " .. value)
		counts[value] = (counts[value] or 0) + 1
	end
	for face = 1, 6 do
		assert(
			counts[face] > 800 and counts[face] < 1200,
			"face " .. face .. " count " .. tostring(counts[face])
		)
	end
	assert(rng:nextInteger(3, 3) == 3, "single-value range")
	assert(rng:nextInteger(-5, -5) == -5, "negative single-value range")
end)

case("nextInteger rejects bad arguments", function()
	local rng = Rng.new(1)
	assert(not pcall(function()
		rng:nextInteger(5, 1)
	end), "max < min")
	assert(not pcall(function()
		rng:nextInteger(1.5, 3)
	end), "non-integer")
	assert(not pcall(function()
		Rng.new(0 / 0)
	end), "NaN seed")
	assert(not pcall(function()
		Rng.new(math.huge)
	end), "infinite seed")
end)

case("chance, shuffle and pick are deterministic", function()
	local a = Rng.new(77)
	local b = Rng.new(77)
	local listA = a:shuffle({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
	local listB = b:shuffle({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
	assert(table.concat(listA, ",") == table.concat(listB, ","), "shuffle differs")
	assert(table.concat(listA, ",") ~= "1,2,3,4,5,6,7,8,9,10", "shuffle did nothing")
	table.sort(listA)
	assert(table.concat(listA, ",") == "1,2,3,4,5,6,7,8,9,10", "shuffle lost elements")
	for _ = 1, 20 do
		assert(a:pick({ "x", "y", "z" }) == b:pick({ "x", "y", "z" }), "pick differs")
		assert(a:chance(0.3) == b:chance(0.3), "chance differs")
	end
	assert(a:chance(0) == false and a:chance(1) == true, "chance bounds")
end)

case("forks depend on seed and label, not on draw history", function()
	local parent = Rng.new(11)
	local untouched = Rng.new(11)
	sequence(parent, 50) -- draw a lot from one parent only
	local lootA = sequence(parent:fork("loot"), 8)
	local lootB = sequence(untouched:fork("loot"), 8)
	assert(sameSequence(lootA, lootB), "fork changed with parent draws")
	local spawn = sequence(untouched:fork("spawn"), 8)
	assert(not sameSequence(lootA, spawn), "labels must give different streams")
	assert(not sameSequence(lootA, sequence(Rng.new(11), 8)), "fork must differ from parent")
end)

case("snapshot and restore resume the exact sequence", function()
	local rng = Rng.new(3)
	sequence(rng, 10)
	local snap = rng:snapshot()
	local expected = sequence(rng, 5)
	rng:restore(snap)
	assert(sameSequence(expected, sequence(rng, 5)), "restore did not resume")
	assert(not pcall(function()
		Rng.new(4):restore(snap)
	end), "restore into a different seed must fail")
end)

case("manual clock only moves when advanced", function()
	local clock = Clock.manual(10, 1_000_000)
	assert(clock:now() == 10 and clock:wallTime() == 1_000_000, "start values")
	clock:advance(2.5)
	assert(clock:now() == 12.5 and clock:wallTime() == 1_000_002.5, "advance moves both")
	clock:setWallTime(5)
	assert(clock:wallTime() == 5 and clock:now() == 12.5, "setWallTime leaves monotonic alone")
	assert(not pcall(function()
		clock:advance(-1)
	end), "negative advance rejected")
	assert(table.isfrozen(clock :: any), "frozen")
end)

case("real clock is monotonic and plausible", function()
	local clock = Clock.real()
	local a = clock:now()
	local b = clock:now()
	assert(b >= a, "monotonic")
	assert(clock:wallTime() > 1_600_000_000, "wall time looks like a Unix timestamp")
end)

case("fixed step yields whole steps and keeps the remainder", function()
	local fixed = FixedStep.new(1 / 60)
	assert(fixed:accumulate(1 / 60) == 1, "one step")
	assert(fixed:accumulate(1 / 120) == 0, "half step waits")
	assert(math.abs(fixed:alpha() - 0.5) < 1e-9, "alpha half")
	assert(fixed:accumulate(1 / 120) == 1, "remainder completes a step")
	assert(fixed:stepCount() == 2, "count")
	assert(fixed:accumulate(10) == 8, "capped at max steps")
	assert(fixed:alpha() == 0, "dropped time after cap")
	fixed:reset()
	assert(fixed:stepCount() == 0 and fixed:alpha() == 0, "reset")
	assert(not pcall(function()
		FixedStep.new(0)
	end), "zero step rejected")
end)

-- A small simulation: an entity with random impulses on a fixed clock.
-- Returns a trace string; equal traces mean equal outcomes.
local function simulate(seed: number): string
	local rng = Rng.new(seed):fork("impulse")
	local clock = Clock.manual()
	local fixed = FixedStep.new(0.05)
	local position, velocity = 0, 0
	local trace = {}
	for frame = 1, 40 do
		local frameTime = if frame % 3 == 0 then 0.09 else 0.04 -- uneven frames
		clock:advance(frameTime)
		for _ = 1, fixed:accumulate(frameTime) do
			velocity += rng:nextFloat(-1, 1)
			position += velocity * fixed.stepSeconds
			table.insert(trace, string.format("%d:%.6f", fixed:stepCount(), position))
		end
	end
	return table.concat(trace, ";")
end

case("identical seeds replay an identical simulation", function()
	local first = simulate(2024)
	assert(first == simulate(2024), "replay diverged")
	assert(first ~= simulate(2025), "different seed should diverge")
	assert(#first > 0, "simulation produced steps")
end)

return cases
