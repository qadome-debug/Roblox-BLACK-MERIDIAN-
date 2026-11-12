--!strict
-- Seeded deterministic random number generator (BM-007).
--
-- xoshiro128** seeded through splitmix32, implemented with 32-bit integer
-- arithmetic only, so the same seed produces the same sequence on every
-- platform (Studio, live servers, Lune) regardless of the engine's own
-- Random implementation.
--
-- Rules:
--   * Gameplay outcomes (loot, encounter rolls, crits) come from a server
--     Rng seeded by the server. A client never supplies a seed or a roll.
--   * Each subsystem forks its own stream (`rng:fork("loot")`) so adding a
--     draw in one system does not shift another system's sequence.
--   * Tests construct an Rng with a fixed seed and get identical results on
--     every run.

export type Snapshot = { seed: number, s0: number, s1: number, s2: number, s3: number }

export type Rng = {
	-- Uniform float in [0, 1) with 53 bits of precision.
	nextNumber: (self: Rng) -> number,
	-- Uniform float in [min, max).
	nextFloat: (self: Rng, min: number, max: number) -> number,
	-- Uniform integer in [min, max], both inclusive integers.
	nextInteger: (self: Rng, min: number, max: number) -> number,
	-- True with probability `chance` in [0, 1].
	chance: (self: Rng, chance: number) -> boolean,
	-- Fisher-Yates shuffle in place; returns the same table.
	shuffle: <T>(self: Rng, list: { T }) -> { T },
	-- Picks one element of a non-empty array.
	pick: <T>(self: Rng, list: { T }) -> T,
	-- Independent stream derived from this generator's seed and a label.
	-- Depends only on the seed and label, never on how many draws happened.
	fork: (self: Rng, label: string) -> Rng,
	-- Captures the exact state so a sequence can be resumed later.
	snapshot: (self: Rng) -> Snapshot,
	restore: (self: Rng, snapshot: Snapshot) -> (),
	seed: number,
}

local TWO_32 = 4294967296

-- 32-bit multiply without losing precision in doubles.
local function mul32(a: number, b: number): number
	local ah, al = bit32.rshift(a, 16), bit32.band(a, 0xFFFF)
	local bh, bl = bit32.rshift(b, 16), bit32.band(b, 0xFFFF)
	local low = al * bl
	local mid = (ah * bl + al * bh) % 65536
	return (low + mid * 65536) % TWO_32
end

local function splitmix32(state: number): (number, number)
	state = (state + 0x9E3779B9) % TWO_32
	local z = state
	z = mul32(bit32.bxor(z, bit32.rshift(z, 16)), 0x85EBCA6B)
	z = mul32(bit32.bxor(z, bit32.rshift(z, 13)), 0xC2B2AE35)
	z = bit32.bxor(z, bit32.rshift(z, 16))
	return z, state
end

-- FNV-1a over the bytes of a string.
local function hashString(text: string): number
	local hash = 0x811C9DC5
	for i = 1, #text do
		hash = mul32(bit32.bxor(hash, string.byte(text, i)), 0x01000193)
	end
	return hash
end

local function normalizeSeed(seed: number): number
	if type(seed) ~= "number" or seed ~= seed or seed == math.huge or seed == -math.huge then
		error("Rng seed must be a finite number", 3)
	end
	-- Fold the whole double into 32 bits so fractional and large seeds all
	-- produce distinct, well-mixed states.
	local whole = math.floor(math.abs(seed))
	local frac = math.abs(seed) - whole
	local low = whole % TWO_32
	local high = math.floor(whole / TWO_32) % TWO_32
	local fracBits = math.floor(frac * TWO_32)
	local mixed = bit32.bxor(low, mul32(high, 0x9E3779B9), mul32(fracBits, 0x85EBCA6B))
	if seed < 0 then
		mixed = bit32.bxor(mixed, 0xFFFFFFFF)
	end
	return mixed
end

local Rng = {}

Rng.hashString = hashString

function Rng.new(seed: number): Rng
	local seed32 = normalizeSeed(seed)

	local s0, s1, s2, s3
	do
		local state = seed32
		s0, state = splitmix32(state)
		s1, state = splitmix32(state)
		s2, state = splitmix32(state)
		s3, state = splitmix32(state)
	end

	local function next32(): number
		local result = mul32(bit32.lrotate(mul32(s1, 5), 7), 9)
		local t = bit32.lshift(s1, 9)
		s2 = bit32.bxor(s2, s0)
		s3 = bit32.bxor(s3, s1)
		s1 = bit32.bxor(s1, s2)
		s0 = bit32.bxor(s0, s3)
		s2 = bit32.bxor(s2, t)
		s3 = bit32.lrotate(s3, 11)
		return result
	end

	local rng = {} :: Rng
	rng.seed = seed32

	function rng:nextNumber(): number
		local hi = bit32.rshift(next32(), 5) -- 27 bits
		local lo = bit32.rshift(next32(), 6) -- 26 bits
		return (hi * 67108864 + lo) / 9007199254740992
	end

	function rng:nextFloat(min: number, max: number): number
		if max < min then
			error("Rng:nextFloat: max must be >= min", 2)
		end
		return min + (max - min) * self:nextNumber()
	end

	function rng:nextInteger(min: number, max: number): number
		if min % 1 ~= 0 or max % 1 ~= 0 then
			error("Rng:nextInteger expects integers", 2)
		end
		if max < min then
			error("Rng:nextInteger: max must be >= min", 2)
		end
		local range = max - min + 1
		return min + math.floor(self:nextNumber() * range)
	end

	function rng:chance(probability: number): boolean
		if probability <= 0 then
			return false
		end
		if probability >= 1 then
			return true
		end
		return self:nextNumber() < probability
	end

	function rng:shuffle<T>(list: { T }): { T }
		for i = #list, 2, -1 do
			local j = self:nextInteger(1, i)
			list[i], list[j] = list[j], list[i]
		end
		return list
	end

	function rng:pick<T>(list: { T }): T
		if #list == 0 then
			error("Rng:pick: list is empty", 2)
		end
		return list[self:nextInteger(1, #list)]
	end

	function rng:fork(label: string): Rng
		return Rng.new(bit32.bxor(seed32, mul32(hashString(label), 0x9E3779B9)))
	end

	function rng:snapshot(): Snapshot
		return table.freeze({ seed = seed32, s0 = s0, s1 = s1, s2 = s2, s3 = s3 })
	end

	function rng:restore(snapshot: Snapshot)
		if snapshot.seed ~= seed32 then
			error("Rng:restore: snapshot belongs to a different seed", 2)
		end
		s0, s1, s2, s3 = snapshot.s0, snapshot.s1, snapshot.s2, snapshot.s3
	end

	return table.freeze(rng)
end

return table.freeze(Rng)
