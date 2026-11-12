--!strict
-- Request envelope parsing and response construction (BM-012).
--
-- `parse` is step 1 of the validation sequence: it turns an untrusted value
-- from the wire into a typed envelope or a rejection status, checking the
-- protocol version, the shape and bounds of every envelope field, that the
-- action is registered, and that the payload is a bounded structure (depth,
-- field count, array length, string length, finite numbers, encoded size)
-- before any action-specific code looks at it.
--
-- The payload is still `unknown` after parsing. Only the action's validator
-- (BM-013) turns it into a typed value.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.Shared.Contracts.Actions)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)

export type ParsedRequest = {
	v: number,
	requestId: string,
	sessionEpoch: string,
	seq: number,
	action: Actions.ActionName,
	rateClass: Actions.RateClass,
	payload: unknown,
	-- Approximate encoded size of the payload, for rate accounting.
	payloadBytes: number,
}

local ID_PATTERN = "^[%w%-_]+$"
local MAX_SEQ = 2147483647

local ENVELOPE_FIELDS =
	{ v = true, requestId = true, sessionEpoch = true, seq = true, action = true, payload = true }

local Envelope = {}

local function isInteger(value: unknown, min: number, max: number): boolean
	return type(value) == "number"
		and value == value
		and value >= min
		and value <= max
		and value % 1 == 0
end

local function isId(value: unknown, maxBytes: number): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= maxBytes
		and string.match(value, ID_PATTERN) ~= nil
end

-- Walks a payload and returns (bytes, nil) when it is within bounds, or
-- (0, reason) otherwise. Bounds come from Limits.
local function measure(value: unknown, depth: number): (number, string?)
	local kind = typeof(value)
	if kind == "nil" then
		return 4, nil
	elseif kind == "boolean" then
		return 5, nil
	elseif kind == "number" then
		local n = value :: number
		if n ~= n or n == math.huge or n == -math.huge then
			return 0, "non-finite number"
		end
		return #tostring(n), nil
	elseif kind == "string" then
		local s = value :: string
		if #s > Limits.MAX_STRING_BYTES then
			return 0, "string longer than " .. Limits.MAX_STRING_BYTES .. " bytes"
		end
		return #s + 2, nil
	elseif kind == "table" then
		if depth > Limits.MAX_PAYLOAD_DEPTH then
			return 0, "nesting deeper than " .. Limits.MAX_PAYLOAD_DEPTH
		end
		local t = value :: { [any]: unknown }
		local total = 2
		local fields = 0
		local arrayItems = 0
		for key, item in t do
			local keyKind = type(key)
			if keyKind == "number" then
				if key ~= key or key % 1 ~= 0 or key < 1 then
					return 0, "non-sequential numeric key"
				end
				arrayItems += 1
				if arrayItems > Limits.MAX_PAYLOAD_ARRAY_ITEMS then
					return 0, "array longer than " .. Limits.MAX_PAYLOAD_ARRAY_ITEMS
				end
				total += 1
			elseif keyKind == "string" then
				fields += 1
				if fields > Limits.MAX_PAYLOAD_FIELDS then
					return 0, "more than " .. Limits.MAX_PAYLOAD_FIELDS .. " fields"
				end
				if #(key :: string) > Limits.MAX_STRING_BYTES then
					return 0, "field name too long"
				end
				total += #(key :: string) + 3
			else
				return 0, "unsupported key type " .. keyKind
			end
			local bytes, reason = measure(item, depth + 1)
			if reason ~= nil then
				return 0, reason
			end
			total += bytes + 1
		end
		if arrayItems > 0 and arrayItems ~= #t then
			return 0, "sparse array"
		end
		return total, nil
	end
	return 0, "unsupported value type " .. kind
end

Envelope.measure = function(value: unknown): (number, string?)
	return measure(value, 1)
end

-- Parses an untrusted envelope. Returns the typed request, or nil with the
-- rejection status and a server-side reason (never sent to the client).
function Envelope.parse(raw: unknown): (ParsedRequest?, Protocol.Status?, string?)
	if type(raw) ~= "table" then
		return nil, "BAD_ENVELOPE", "envelope is not a table"
	end
	local t = raw :: { [any]: unknown }

	local count = 0
	for key in t do
		if type(key) ~= "string" or not ENVELOPE_FIELDS[key] then
			return nil, "BAD_ENVELOPE", "unexpected envelope field " .. tostring(key)
		end
		count += 1
		if count > 6 then
			return nil, "BAD_ENVELOPE", "too many envelope fields"
		end
	end

	if t.v ~= Protocol.VERSION then
		return nil, "BAD_ENVELOPE", "unsupported protocol version " .. tostring(t.v)
	end
	if not isId(t.requestId, Limits.MAX_REQUEST_ID_BYTES) then
		return nil, "BAD_ENVELOPE", "invalid requestId"
	end
	if not isId(t.sessionEpoch, Limits.MAX_OPAQUE_ID_BYTES) then
		return nil, "BAD_ENVELOPE", "invalid sessionEpoch"
	end
	if not isInteger(t.seq, 0, MAX_SEQ) then
		return nil, "BAD_ENVELOPE", "invalid seq"
	end

	local resolved = Actions.resolve(t.action)
	if resolved == nil then
		return nil, "UNKNOWN_ACTION", "unregistered action " .. tostring(t.action)
	end
	-- Refinement widens singleton unions in the current solver; the cast
	-- through any restores the registered-name type.
	local action: Actions.ActionName = resolved :: any
	local info = Actions.info(action)

	local payload = t.payload
	if payload ~= nil and type(payload) ~= "table" then
		return nil, "BAD_ENVELOPE", "payload must be a table or nil"
	end
	local bytes, reason = measure(payload, 1)
	if reason ~= nil then
		return nil, "BAD_ENVELOPE", "payload " .. reason
	end
	local classLimit = Limits.RATE[info.rateClass].maxPayloadBytes
	local envelopeLimit = Limits.RATE.envelope.maxPayloadBytes
	if bytes > classLimit or bytes > envelopeLimit then
		return nil,
			"BAD_ENVELOPE",
			string.format("payload of %d bytes exceeds the %s limit", bytes, info.rateClass)
	end

	return {
		v = Protocol.VERSION,
		requestId = t.requestId :: string,
		sessionEpoch = t.sessionEpoch :: string,
		seq = t.seq :: number,
		action = action,
		rateClass = info.rateClass,
		payload = payload,
		payloadBytes = bytes,
	},
		nil,
		nil
end

-- Builds a success result.
function Envelope.ok(
	requestId: string,
	action: string,
	stateRevision: number?,
	data: { [string]: any }?
): Protocol.ActionResult
	return {
		requestId = requestId,
		status = "OK",
		action = action,
		stateRevision = stateRevision,
		data = data :: { [string]: unknown }?,
	}
end

-- Builds a rejection. `message` must already be client-safe (BM-019).
function Envelope.reject(
	requestId: string?,
	action: string?,
	status: Protocol.Status,
	message: string?
): Protocol.ActionResult
	return {
		requestId = requestId or "",
		status = status,
		action = action or "",
		message = message,
	}
end

return table.freeze(Envelope)
