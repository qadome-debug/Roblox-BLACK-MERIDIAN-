--!strict
-- CombatInput payload validator (BM-061). Shape only: the enum, a bounded
-- integer sequence and an optional opaque target id. Cadence, resources,
-- combat state and hit windows are judged by the simulation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Schema = require(script.Parent.Schema)

local KINDS = { "Attack", "Dodge", "Guard", "Parry", "Release", "Lock", "Unlock", "CycleTarget" }

local validate = Schema.object({
	kind = { kind = "enum", values = KINDS },
	sequence = { kind = "integer", min = 1, max = Limits.MAX_REVISION },
	target = { kind = "opaqueId", maxBytes = Limits.MAX_OPAQUE_ID_BYTES, optional = true },
})

local function parseCombatInput(raw: unknown): (Payloads.CombatInputPayload?, string?)
	local value, reason = validate(raw)
	if value == nil then
		return nil, reason
	end
	local payload = value :: Payloads.CombatInputPayload
	if payload.kind == "Lock" and payload.target == nil then
		return nil, "Lock requires a target"
	end
	return payload, nil
end

return parseCombatInput
