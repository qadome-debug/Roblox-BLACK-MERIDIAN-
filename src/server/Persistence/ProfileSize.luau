--!strict
-- Encoded profile size and the soft/hard budgets (BM-024).
--
-- Roblox stores DataStore values as JSON. This module measures a candidate
-- profile with a deterministic JSON encoder (sorted keys, same number and
-- string rules as JSONEncode for the data a profile contains) so the
-- measurement is identical in Studio, on live servers, and under Lune.
--
-- Budgets come from Limits.PROFILE: a soft limit that triggers a warning
-- and a hard limit beyond which a mutation is rejected before it is ever
-- written. Nothing is ever truncated to fit; a profile over the hard
-- limit keeps its existing data and the mutation that would grow it fails.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Limits = require(ReplicatedStorage.Shared.Constants.Limits)

export type Verdict = "ok" | "soft" | "hard"

local ProfileSize = {}

ProfileSize.SOFT_BYTES = Limits.PROFILE.SOFT_SIZE_BYTES
ProfileSize.HARD_BYTES = Limits.PROFILE.HARD_SIZE_BYTES

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(s: string, out: { string })
	table.insert(out, '"')
	table.insert(out, (string.gsub(s, '[%c"\\]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
	end)))
	table.insert(out, '"')
end

local function encodeNumber(n: number, out: { string })
	if n ~= n or n == math.huge or n == -math.huge then
		error("ProfileSize: cannot encode a non-finite number")
	end
	if n % 1 == 0 and math.abs(n) < 2 ^ 53 then
		table.insert(out, string.format("%d", n))
	else
		table.insert(out, string.format("%.17g", n))
	end
end

local function encode(value: any, out: { string }, depth: number)
	if depth > 32 then
		error("ProfileSize: value nested deeper than 32")
	end
	local kind = type(value)
	if kind == "nil" then
		table.insert(out, "null")
	elseif kind == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif kind == "number" then
		encodeNumber(value, out)
	elseif kind == "string" then
		encodeString(value, out)
	elseif kind == "table" then
		local count = 0
		for _ in value do
			count += 1
		end
		if count == #value and count > 0 then
			table.insert(out, "[")
			for i = 1, count do
				if i > 1 then
					table.insert(out, ",")
				end
				encode(value[i], out, depth + 1)
			end
			table.insert(out, "]")
		else
			local keys = {}
			for key in value do
				if type(key) ~= "string" then
					error("ProfileSize: object keys must be strings, got " .. typeof(key))
				end
				table.insert(keys, key)
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, key in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				encodeString(key, out)
				table.insert(out, ":")
				encode(value[key], out, depth + 1)
			end
			table.insert(out, "}")
		end
	else
		error("ProfileSize: cannot encode a " .. kind)
	end
end

-- Deterministic JSON text for `value`.
function ProfileSize.encode(value: any): string
	local out = {}
	encode(value, out, 0)
	return table.concat(out)
end

function ProfileSize.encodedBytes(value: any): number
	return #ProfileSize.encode(value)
end

function ProfileSize.classify(bytes: number): Verdict
	if bytes > ProfileSize.HARD_BYTES then
		return "hard"
	elseif bytes > ProfileSize.SOFT_BYTES then
		return "soft"
	end
	return "ok"
end

-- Decides whether a candidate profile may be written. Returns the verdict
-- and the measured size; "hard" means reject the mutation.
function ProfileSize.check(candidate: any): (Verdict, number)
	local bytes = ProfileSize.encodedBytes(candidate)
	return ProfileSize.classify(bytes), bytes
end

return table.freeze(ProfileSize)
