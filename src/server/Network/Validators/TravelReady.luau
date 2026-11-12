--!strict
-- TravelReady payload validator (Technical Plan 2.0, 3.5). Shape only; the
-- TravelReady adapter (BM-090) checks ticket ownership, party membership,
-- expiry and the roster revision against server state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Schema = require(script.Parent.Schema)

local validate = Schema.object({
	ticketId = { kind = "opaqueId", maxBytes = Limits.MAX_OPAQUE_ID_BYTES },
	ready = { kind = "boolean" },
	revision = { kind = "revision" },
})

local function parseTravelReady(raw: unknown): (Payloads.TravelReadyPayload?, string?)
	local value, reason = validate(raw)
	if value == nil then
		return nil, reason
	end
	return value :: Payloads.TravelReadyPayload, nil
end

return parseTravelReady
