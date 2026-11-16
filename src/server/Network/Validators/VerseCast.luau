--!strict
-- VerseCast payload validator (BM-067). Shape only: a well-formed
-- canonical Verse ID, up to two optional opaque target ids and an optional
-- aim point (three finite, bounded numbers, all or none). Whether the Verse
-- is defined, unlocked, compatible, off cooldown and affordable, and
-- whether the target is real and in range, is judged by the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Schema = require(script.Parent.Schema)

-- Studs; far beyond any place, so a bound rather than a gameplay limit.
local AIM_LIMIT = 100000

local validate = Schema.object({
	verseId = { kind = "canonicalId" },
	target = { kind = "opaqueId", maxBytes = Limits.MAX_OPAQUE_ID_BYTES, optional = true },
	targetB = { kind = "opaqueId", maxBytes = Limits.MAX_OPAQUE_ID_BYTES, optional = true },
	aimX = { kind = "number", min = -AIM_LIMIT, max = AIM_LIMIT, optional = true },
	aimY = { kind = "number", min = -AIM_LIMIT, max = AIM_LIMIT, optional = true },
	aimZ = { kind = "number", min = -AIM_LIMIT, max = AIM_LIMIT, optional = true },
})

local function parseVerseCast(raw: unknown): (Payloads.VerseCastPayload?, string?)
	local value, reason = validate(raw)
	if value == nil then
		return nil, reason
	end
	local payload = value :: Payloads.VerseCastPayload
	local given = (payload.aimX ~= nil and 1 or 0)
		+ (payload.aimY ~= nil and 1 or 0)
		+ (payload.aimZ ~= nil and 1 or 0)
	if given ~= 0 and given ~= 3 then
		return nil, "aim needs aimX, aimY and aimZ together"
	end
	-- Format only: a Verse ID is `<namespace>.<name>` (`near.close_step`).
	-- Whether the Verse exists is the adapter's question.
	if ContentRegistry.verseNamespace(payload.verseId) == nil then
		return nil, "verseId is not a verse id"
	end
	return payload, nil
end

return parseVerseCast
