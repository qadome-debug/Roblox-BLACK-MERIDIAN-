--!strict
-- Canonical IDs that were renamed, and the one place that knows how.
--
-- Saved data is never renamed silently. Each rename has a profile
-- migration (Migrations.luau) and, for permanent reward receipts that were
-- moved into archive records, a read-time translation here: an archive
-- record is never rewritten, so a receipt archived under an old ID is
-- recognised under the new one when the archive is read.
--
--   v2 -> v3  cant-nearness -> cant.nearness         (design report format)
--   v3 -> v4  waymark-i     -> waymark.branded       (approved 2026-11-16)

local LegacyIds = {}

LegacyIds.CANT = table.freeze({
	["cant-nearness"] = "cant.nearness",
} :: { [string]: string })

LegacyIds.WAYMARK = table.freeze({
	["waymark-i"] = "waymark.branded",
} :: { [string]: string })

-- Renames the keys of a map, merging tables when both the old and the new
-- key exist (the new key's own entries win) and keeping the new key's value
-- otherwise.
function LegacyIds.renameKeys(map: { [any]: any }, renames: { [string]: string }): { [any]: any }
	local out: { [any]: any } = {}
	for key, value in map do
		if renames[key] == nil then
			out[key] = value
		end
	end
	for key, value in map do
		local renamed = renames[key]
		if renamed ~= nil then
			local existing = out[renamed]
			if type(existing) == "table" and type(value) == "table" then
				for innerKey, innerValue in value do
					if existing[innerKey] == nil then
						existing[innerKey] = innerValue
					end
				end
			elseif existing == nil then
				out[renamed] = value
			end
		end
	end
	return out
end

-- Receipt IDs are colon-separated (`p:waymark:waymark-i:reward-x`). A
-- legacy ID is replaced only when it is a whole segment, so an ID that
-- merely contains the old text is left alone.
function LegacyIds.receipt(receiptId: string, renames: { [string]: string }?): string
	local table_ = renames or LegacyIds.WAYMARK
	local parts = string.split(receiptId, ":")
	local changed = false
	for index, part in parts do
		local renamed = table_[part]
		if renamed ~= nil then
			parts[index] = renamed
			changed = true
		end
	end
	return if changed then table.concat(parts, ":") else receiptId
end

return table.freeze(LegacyIds)
