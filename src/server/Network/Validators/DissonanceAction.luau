--!strict
-- DissonanceAction payload validator (BM-068). Shape only: one opaque
-- action id. No meter value, level or amount is accepted from a client
-- (the strict object refuses extra fields).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Schema = require(script.Parent.Schema)

local validate = Schema.object({
	actionId = { kind = "opaqueId", maxBytes = Limits.MAX_OPAQUE_ID_BYTES },
})

local function parseDissonanceAction(raw: unknown): (Payloads.DissonanceActionPayload?, string?)
	local value, reason = validate(raw)
	if value == nil then
		return nil, reason
	end
	return value :: Payloads.DissonanceActionPayload, nil
end

return parseDissonanceAction
