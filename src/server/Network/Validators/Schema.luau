--!strict
-- Strict payload schema builder (BM-013).
--
-- A schema lists exactly the fields a payload may contain and the kind of
-- each. The validator it builds rejects extra fields, missing required
-- fields, wrong types, out-of-range numbers, non-finite numbers, malformed
-- IDs, and strings over their byte limit. It never throws on any input and
-- never returns a value that does not satisfy the schema.
--
-- Shape only: ownership, offers, revisions and world state are checked by
-- the adapter after validation, against server state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)

export type FieldKind =
	"canonicalId" -- ContentRegistry ID format, <= 48 bytes (format only)
	| "registryId" -- canonicalId that also exists in Canon under `category`
	| "opaqueId" -- server-issued ID: [A-Za-z0-9-_], <= 64 bytes
	| "revision" -- integer 0 .. Limits.MAX_REVISION
	| "integer" -- integer within [min, max]
	| "number" -- finite number within [min, max]
	| "boolean"
	| "string" -- any string up to maxBytes
	| "enum" -- one of `values`

export type FieldSpec = {
	kind: FieldKind,
	optional: boolean?,
	min: number?,
	max: number?,
	maxBytes: number?,
	values: { string }?,
	category: ContentRegistry.Category?,
}

export type Validator = (raw: unknown) -> (unknown?, string?)

local OPAQUE_PATTERN = "^[%w%-_]+$"

local Schema = {}

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function checkField(name: string, spec: FieldSpec, value: unknown): (unknown?, string?)
	local kind = spec.kind
	if kind == "canonicalId" then
		if not ContentRegistry.isValidId(value) then
			return nil, name .. " is not a canonical id"
		end
		return value, nil
	elseif kind == "registryId" then
		local category = spec.category
		if category == nil then
			return nil, name .. " schema is missing its category"
		end
		local resolved = Canon:resolve(category :: ContentRegistry.Category, value)
		if resolved == nil then
			return nil, name .. " is not a known " .. (category :: string)
		end
		return resolved, nil
	elseif kind == "opaqueId" then
		local maxBytes = spec.maxBytes or Limits.MAX_OPAQUE_ID_BYTES
		if
			type(value) ~= "string"
			or #value < 1
			or #value > maxBytes
			or not string.match(value, OPAQUE_PATTERN)
		then
			return nil, name .. " is not a valid opaque id"
		end
		return value, nil
	elseif kind == "revision" then
		if
			not isFinite(value)
			or (value :: number) < 0
			or (value :: number) > Limits.MAX_REVISION
			or (value :: number) % 1 ~= 0
		then
			return nil, name .. " is not a valid revision"
		end
		return value, nil
	elseif kind == "integer" then
		local min = spec.min or -Limits.MAX_REVISION
		local max = spec.max or Limits.MAX_REVISION
		if
			not isFinite(value)
			or (value :: number) % 1 ~= 0
			or (value :: number) < min
			or (value :: number) > max
		then
			return nil, name .. " is not an integer in range"
		end
		return value, nil
	elseif kind == "number" then
		local min = spec.min or -math.huge
		local max = spec.max or math.huge
		if not isFinite(value) or (value :: number) < min or (value :: number) > max then
			return nil, name .. " is not a number in range"
		end
		return value, nil
	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			return nil, name .. " is not a boolean"
		end
		return value, nil
	elseif kind == "string" then
		local maxBytes = spec.maxBytes or Limits.MAX_STRING_BYTES
		if type(value) ~= "string" or #value > maxBytes then
			return nil, name .. " is not a string within " .. maxBytes .. " bytes"
		end
		return value, nil
	elseif kind == "enum" then
		local values = spec.values
		if type(value) ~= "string" or values == nil or table.find(values, value) == nil then
			return nil, name .. " is not an allowed value"
		end
		return value, nil
	end
	return nil, name .. " has an unknown schema kind"
end

-- Builds a validator for an object with exactly `fields`. The returned
-- table is a fresh copy containing only the validated fields.
function Schema.object(fields: { [string]: FieldSpec }): Validator
	local names: { string } = {}
	for name in fields do
		table.insert(names, name)
	end
	table.sort(names)
	local maxFields = #names

	return function(raw: unknown): (unknown?, string?)
		if type(raw) ~= "table" then
			return nil, "payload is not a table"
		end
		local input = raw :: { [any]: unknown }

		local count = 0
		for key in input do
			if type(key) ~= "string" or fields[key] == nil then
				return nil, "unexpected field " .. tostring(key)
			end
			count += 1
			if count > maxFields then
				return nil, "too many fields"
			end
		end

		local out: { [string]: unknown } = {}
		for _, name in names do
			local spec = fields[name]
			local value = input[name]
			if value == nil then
				if spec.optional then
					continue
				end
				return nil, "missing field " .. name
			end
			local clean, reason = checkField(name, spec, value)
			if reason ~= nil then
				return nil, reason
			end
			out[name] = clean
		end
		return out, nil
	end
end

return table.freeze(Schema)
