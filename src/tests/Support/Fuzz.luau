--!strict
-- Random value generator for fuzzing validators (BM-013).
--
-- Produces arbitrary Luau values from a seeded Rng: nil, booleans, numbers
-- (including NaN, infinities, huge and fractional values), strings of
-- varied length and content, and nested tables with mixed keys. Given a
-- template of expected fields it also produces "near-miss" tables: the
-- right shape with one field mutated, which is where validators usually
-- break.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

local Fuzz = {}

local SPECIAL_NUMBERS = {
	0,
	-0,
	1,
	-1,
	0.5,
	2 ^ 31,
	2 ^ 31 - 1,
	-(2 ^ 31),
	2 ^ 53,
	1e308,
	-1e308,
	0 / 0,
	math.huge,
	-math.huge,
}
local SPECIAL_STRINGS = {
	"",
	" ",
	"a",
	"A",
	"quest-x",
	"QUEST-X",
	"-",
	"_",
	"null",
	"nil",
	"0",
	"1e9",
	"\0",
	"\n",
	"é",
	"😀",
	"quest-x; DROP",
	"../../x",
}

function Fuzz.number(rng: Rng.Rng): number
	if rng:chance(0.4) then
		return rng:pick(SPECIAL_NUMBERS)
	end
	if rng:chance(0.5) then
		return rng:nextInteger(-1000, 1000)
	end
	return rng:nextFloat(-1e6, 1e6)
end

function Fuzz.string(rng: Rng.Rng, maxLength: number?): string
	if rng:chance(0.3) then
		return rng:pick(SPECIAL_STRINGS)
	end
	local length = rng:nextInteger(0, maxLength or 80)
	local chars = {}
	for _ = 1, length do
		local roll = rng:nextNumber()
		if roll < 0.6 then
			table.insert(chars, string.char(rng:nextInteger(97, 122))) -- a-z
		elseif roll < 0.75 then
			table.insert(chars, string.char(rng:nextInteger(48, 57))) -- 0-9
		elseif roll < 0.85 then
			table.insert(chars, rng:pick({ "-", "_", ".", "/", " " }))
		else
			table.insert(chars, string.char(rng:nextInteger(0, 255)))
		end
	end
	return table.concat(chars)
end

-- Any value, with nesting limited by `depth`.
function Fuzz.value(rng: Rng.Rng, depth: number?): unknown
	local d = depth or 3
	local roll = rng:nextNumber()
	if roll < 0.1 then
		return nil
	elseif roll < 0.2 then
		return rng:chance(0.5)
	elseif roll < 0.45 then
		return Fuzz.number(rng)
	elseif roll < 0.7 or d <= 0 then
		return Fuzz.string(rng)
	end
	local t: { [any]: unknown } = {}
	local entries = rng:nextInteger(0, 6)
	for i = 1, entries do
		local key: any
		local keyRoll = rng:nextNumber()
		if keyRoll < 0.6 then
			key = Fuzz.string(rng, 12)
		elseif keyRoll < 0.9 then
			key = i
		else
			key = Fuzz.number(rng)
		end
		if key == key and key ~= nil then
			t[key] = Fuzz.value(rng, d - 1)
		end
	end
	return t
end

-- A table shaped like `template` with every field present, where each
-- field has a chance of being replaced by a random value or removed, and
-- an extra field may be added. Returns the table and whether it was
-- mutated at all (an unmutated copy must be accepted by the validator).
function Fuzz.nearMiss(
	rng: Rng.Rng,
	template: { [string]: unknown }
): ({ [string]: unknown }, boolean)
	local out: { [string]: unknown } = {}
	local mutated = false
	for key, value in template do
		local roll = rng:nextNumber()
		if roll < 0.15 then
			mutated = true -- drop the field
		elseif roll < 0.4 then
			out[key] = Fuzz.value(rng, 2)
			mutated = true
		else
			out[key] = value
		end
	end
	if rng:chance(0.15) then
		out[Fuzz.string(rng, 10) .. "x"] = Fuzz.value(rng, 1)
		mutated = true
	end
	return out, mutated
end

return table.freeze(Fuzz)
