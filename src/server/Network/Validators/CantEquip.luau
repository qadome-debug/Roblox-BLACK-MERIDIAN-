--!strict
-- CantEquip payload validator (BM-064). Shape only: a known slot name and
-- an optional canonical Cant ID. Ownership, slot legality and restrictions
-- are judged by the adapter from server state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Schema = require(script.Parent.Schema)

local validate = Schema.object({
	slot = { kind = "enum", values = { "primary", "secondary" } },
	cantId = { kind = "registryId", category = "cant", optional = true },
})

local function parseCantEquip(raw: unknown): (Payloads.CantEquipPayload?, string?)
	local value, reason = validate(raw)
	if value == nil then
		return nil, reason
	end
	return value :: Payloads.CantEquipPayload, nil
end

return parseCantEquip
