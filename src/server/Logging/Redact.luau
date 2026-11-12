--!strict
-- Log field sanitization (BM-008).
--
-- Every field attached to a log event passes through here before any sink
-- sees it. The rules make it impossible to log a profile dump, a payload
-- table, or a secret by accident:
--   * only string, number and boolean values survive; tables, functions,
--     userdata and Instances are replaced with a marker,
--   * keys that look like secrets are redacted regardless of value,
--   * strings are truncated, non-finite numbers are stringified,
--   * the field count and key format are bounded.

export type Scalar = string | number | boolean
export type Fields = { [string]: Scalar }

local MAX_FIELDS = 24
local MAX_KEY_LENGTH = 32
local MAX_STRING_BYTES = 256
local KEY_PATTERN = "^[a-zA-Z][a-zA-Z0-9_]*$"

-- Keys reserved by the event envelope. A field using one is dropped so it
-- can never masquerade as envelope data.
local RESERVED = {
	ts = true,
	level = true,
	category = true,
	event = true,
	correlationId = true,
	playerId = true,
}

-- Any key containing one of these (case-insensitive) is redacted.
local SECRET_FRAGMENTS = {
	"secret",
	"token",
	"password",
	"passwd",
	"credential",
	"cookie",
	"authorization",
	"apikey",
	"api_key",
	"privatekey",
	"private_key",
	"bearer",
}

local Redact = {}

Redact.MAX_FIELDS = MAX_FIELDS
Redact.MAX_STRING_BYTES = MAX_STRING_BYTES
Redact.REDACTED = "[redacted]"

function Redact.isSecretKey(key: string): boolean
	local lower = string.lower(key)
	for _, fragment in SECRET_FRAGMENTS do
		if string.find(lower, fragment, 1, true) then
			return true
		end
	end
	return false
end

function Redact.scalar(value: unknown): Scalar
	local kind = typeof(value)
	if kind == "string" then
		local text = value :: string
		if #text > MAX_STRING_BYTES then
			return string.sub(text, 1, MAX_STRING_BYTES) .. "[truncated]"
		end
		return text
	elseif kind == "number" then
		local n = value :: number
		if n ~= n then
			return "[nan]"
		elseif n == math.huge then
			return "[inf]"
		elseif n == -math.huge then
			return "[-inf]"
		end
		return n
	elseif kind == "boolean" then
		return value :: boolean
	end
	return "[dropped:" .. kind .. "]"
end

-- Returns a fresh, sanitized copy of `raw` plus the number of fields that
-- were dropped or altered (for the logger's own diagnostics).
function Redact.fields(raw: unknown): (Fields, number)
	local out: Fields = {}
	local altered = 0
	if raw == nil then
		return out, 0
	end
	if type(raw) ~= "table" then
		out.fields = "[dropped:" .. typeof(raw) .. "]"
		return out, 1
	end

	local keys = {}
	for key in raw :: { [any]: unknown } do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local count = 0
	for _, key in keys do
		local value = (raw :: { [any]: unknown })[key]
		if type(key) ~= "string" or #key > MAX_KEY_LENGTH or not string.match(key, KEY_PATTERN) then
			altered += 1
			continue
		end
		if RESERVED[key] then
			altered += 1
			continue
		end
		if count >= MAX_FIELDS then
			altered += 1
			continue
		end
		count += 1
		if Redact.isSecretKey(key) then
			out[key] = Redact.REDACTED
			altered += 1
			continue
		end
		local clean = Redact.scalar(value)
		if clean ~= value then
			altered += 1
		end
		out[key] = clean
	end

	return out, altered
end

return table.freeze(Redact)
