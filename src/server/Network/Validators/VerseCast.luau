--!strict
-- VerseCast payload validator (BM-067). Shape only: a well-formed
-- canonical Verse ID and an optional opaque target id. Whether the Verse
-- is defined, unlocked, compatible, off cooldown and affordable, and
-- whether the target is real and in range, is judged by the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Schema = require(script.Parent.Schema)

local validate = Schema.object({
	verseId = { kind = "canonicalId" },
	target = { kind = "opaqueId", maxBytes = Limits.MAX_OPAQUE_ID_BYTES, optional = true },
})

local function parseVerseCast(raw: unknown): (Payloads.VerseCastPayload?, string?)
	local value, reason = validate(raw)
	if value == nil then
		return nil, reason
	end
	local payload = value :: Payloads.VerseCastPayload
	-- Format only: a Verse ID is `<namespace>.<name>` (`near.close_step`).
	-- Whether the Verse exists is the adapter's question.
	if ContentRegistry.verseNamespace(payload.verseId) == nil then
		return nil, "verseId is not a verse id"
	end
	return payload, nil
end

return parseVerseCast
