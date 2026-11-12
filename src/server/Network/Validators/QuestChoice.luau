--!strict
-- QuestChoice payload validator (Technical Plan 2.0, 3.4). Shape only; the
-- QuestChoice adapter (BM-074) checks the offer, node, choice membership,
-- expiry and revision against server state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Schema = require(script.Parent.Schema)

local validate = Schema.object({
	questId = { kind = "canonicalId" },
	nodeId = { kind = "canonicalId" },
	choiceId = { kind = "canonicalId" },
	offerId = { kind = "opaqueId", maxBytes = Limits.MAX_OPAQUE_ID_BYTES },
	revision = { kind = "revision" },
})

local function parseQuestChoice(raw: unknown): (Payloads.QuestChoicePayload?, string?)
	local value, reason = validate(raw)
	if value == nil then
		return nil, reason
	end
	return value :: Payloads.QuestChoicePayload, nil
end

return parseQuestChoice
