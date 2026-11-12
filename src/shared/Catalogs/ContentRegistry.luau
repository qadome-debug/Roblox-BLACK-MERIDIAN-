--!strict
-- Canonical content registry (BM-004).
--
-- Defines the schema for canonical content IDs, validates a content dataset
-- against it, and builds a frozen registry for lookups. IDs are defined only
-- here, in data checked into the repository; nothing at runtime, and nothing
-- from a client, can add one.
--
-- ID rules: lowercase ASCII letters, digits and hyphens; starts with the
-- category prefix (for example `cant-`); at most Limits.MAX_CANONICAL_ID_BYTES
-- bytes; unique across every category.

local Limits = require(script.Parent.Parent.Constants.Limits)

export type Category =
	"chapter"
	| "region"
	| "quest"
	| "cant"
	| "verse"
	| "burden"
	| "waymark"
	| "boss"
	| "descent"

export type ChapterEntry = { id: string, name: string, launchRequired: boolean, order: number }
export type RegionEntry = {
	id: string,
	name: string,
	launchRequired: boolean,
	waymarkIds: { string },
	travelLinkIds: { string },
}
export type QuestEntry = {
	id: string,
	name: string,
	launchRequired: boolean,
	chapterId: string,
	regionId: string,
}
export type CantEntry = {
	id: string,
	name: string,
	launchRequired: boolean,
	starterEligible: boolean,
	verseIds: { string },
}
export type VerseEntry = { id: string, name: string, launchRequired: boolean, cantId: string }
export type BurdenEntry = { id: string, name: string, launchRequired: boolean }
export type WaymarkEntry = {
	id: string,
	name: string,
	launchRequired: boolean,
	rank: number,
	regionId: string?,
}
export type BossEntry = { id: string, name: string, launchRequired: boolean, locationId: string }
export type DescentEntry = {
	id: string,
	name: string,
	launchRequired: boolean,
	entranceRegionId: string?,
}

export type ContentData = {
	chapters: { ChapterEntry },
	regions: { RegionEntry },
	quests: { QuestEntry },
	cants: { CantEntry },
	verses: { VerseEntry },
	burdens: { BurdenEntry },
	waymarks: { WaymarkEntry },
	bosses: { BossEntry },
	descents: { DescentEntry },
}

export type Registry = {
	has: (self: Registry, category: Category, id: string) -> boolean,
	-- Returns the id only when `value` is a string naming an existing entry of
	-- that category. This is the entry point for validating client input.
	resolve: (self: Registry, category: Category, value: unknown) -> string?,
	categoryOf: (self: Registry, id: string) -> Category?,
	ids: (self: Registry, category: Category) -> { string },
	count: (self: Registry, category: Category) -> number,
	getChapter: (self: Registry, id: string) -> ChapterEntry?,
	getRegion: (self: Registry, id: string) -> RegionEntry?,
	getQuest: (self: Registry, id: string) -> QuestEntry?,
	getCant: (self: Registry, id: string) -> CantEntry?,
	getVerse: (self: Registry, id: string) -> VerseEntry?,
	getBurden: (self: Registry, id: string) -> BurdenEntry?,
	getWaymark: (self: Registry, id: string) -> WaymarkEntry?,
	getBoss: (self: Registry, id: string) -> BossEntry?,
	getDescent: (self: Registry, id: string) -> DescentEntry?,
}

type FieldKind = "string" | "boolean" | "positiveInteger" | "id" | "idList"
type FieldSpec = { kind: FieldKind, ref: { Category }?, optional: boolean? }
type CategorySpec = { key: string, prefix: string, fields: { [string]: FieldSpec } }

local CATEGORIES: { Category } =
	{ "chapter", "region", "quest", "cant", "verse", "burden", "waymark", "boss", "descent" }

local SPECS: { [Category]: CategorySpec } = {
	chapter = {
		key = "chapters",
		prefix = "chapter-",
		fields = {
			order = { kind = "positiveInteger" },
		},
	},
	region = {
		key = "regions",
		prefix = "region-",
		fields = {
			waymarkIds = { kind = "idList", ref = { "waymark" } },
			travelLinkIds = { kind = "idList", ref = { "region" } },
		},
	},
	quest = {
		key = "quests",
		prefix = "quest-",
		fields = {
			chapterId = { kind = "id", ref = { "chapter" } },
			regionId = { kind = "id", ref = { "region" } },
		},
	},
	cant = {
		key = "cants",
		prefix = "cant-",
		fields = {
			starterEligible = { kind = "boolean" },
			verseIds = { kind = "idList", ref = { "verse" } },
		},
	},
	verse = {
		key = "verses",
		prefix = "verse-",
		fields = {
			cantId = { kind = "id", ref = { "cant" } },
		},
	},
	burden = { key = "burdens", prefix = "burden-", fields = {} },
	waymark = {
		key = "waymarks",
		prefix = "waymark-",
		fields = {
			rank = { kind = "positiveInteger" },
			regionId = { kind = "id", ref = { "region" }, optional = true },
		},
	},
	boss = {
		key = "bosses",
		prefix = "boss-",
		fields = {
			locationId = { kind = "id", ref = { "region", "descent" } },
		},
	},
	descent = {
		key = "descents",
		prefix = "descent-",
		fields = {
			entranceRegionId = { kind = "id", ref = { "region" }, optional = true },
		},
	},
}

local COMMON_FIELDS = { id = true, name = true, launchRequired = true }

local ContentRegistry = {}

ContentRegistry.CATEGORIES = table.freeze(table.clone(CATEGORIES))
ContentRegistry.ID_PATTERN = "^[a-z0-9][a-z0-9%-]*$"

function ContentRegistry.isValidId(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= Limits.MAX_CANONICAL_ID_BYTES
		and string.match(value, ContentRegistry.ID_PATTERN) ~= nil
end

function ContentRegistry.prefixFor(category: Category): string
	return SPECS[category].prefix
end

local function describe(value: unknown): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return typeof(value) .. (if value == nil then "" else " " .. tostring(value))
end

local function isArray(value: { [any]: any }): boolean
	local count = 0
	for _ in value do
		count += 1
	end
	return count == #value
end

local function isPositiveInteger(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and value >= 1
		and value % 1 == 0
		and value < 2 ^ 31
end

local function contains(list: { string }, item: string): boolean
	return table.find(list, item) ~= nil
end

local function describeCategories(list: { Category }): string
	local names: { string } = {}
	for _, category: Category in list do
		table.insert(names, category)
	end
	return table.concat(names, " or ")
end

type Located = { category: Category, entry: { [string]: unknown }, where: string }

-- Returns every problem found. An empty list means the data is canonical.
function ContentRegistry.validate(data: unknown): { string }
	local errors: { string } = {}
	local function fail(message: string)
		table.insert(errors, message)
	end

	if type(data) ~= "table" then
		fail("content data must be a table, got " .. typeof(data))
		return errors
	end
	local root = data :: { [any]: unknown }

	local allowedKeys: { [string]: boolean } = {}
	for _, category: Category in CATEGORIES do
		allowedKeys[SPECS[category].key] = true
	end
	for key in root do
		if type(key) ~= "string" or not allowedKeys[key] then
			fail("unknown top-level key " .. describe(key))
		end
	end

	local index: { [string]: Located } = {}
	local located: { Located } = {}

	-- Pass 1: shape, IDs, field types.
	for _, category: Category in CATEGORIES do
		local spec = SPECS[category]
		local list = root[spec.key]
		if list == nil then
			fail("missing list '" .. spec.key .. "'")
			continue
		end
		if type(list) ~= "table" or not isArray(list :: { [any]: any }) then
			fail("'" .. spec.key .. "' must be an array")
			continue
		end

		for i, raw in ipairs(list :: { unknown }) do
			local where = string.format("%s[%d]", spec.key, i)
			if type(raw) ~= "table" then
				fail(where .. " must be a table, got " .. typeof(raw))
				continue
			end
			local entry = raw :: { [string]: unknown }

			local id = entry.id
			if not ContentRegistry.isValidId(id) then
				fail(where .. ": invalid id " .. describe(id))
			else
				local idStr = id :: string
				where = where .. " (" .. idStr .. ")"
				if string.sub(idStr, 1, #spec.prefix) ~= spec.prefix then
					fail(where .. ": id must start with '" .. spec.prefix .. "'")
				end
				local existing = index[idStr]
				if existing ~= nil then
					fail(where .. ": duplicate id, already defined at " .. existing.where)
				else
					local record: Located = { category = category, entry = entry, where = where }
					index[idStr] = record
					table.insert(located, record)
				end
			end

			local name = entry.name
			if type(name) ~= "string" or #name < 1 or #name > Limits.MAX_CONTENT_NAME_BYTES then
				fail(
					where
						.. ": name must be a string of 1-"
						.. Limits.MAX_CONTENT_NAME_BYTES
						.. " bytes"
				)
			end
			if type(entry.launchRequired) ~= "boolean" then
				fail(where .. ": launchRequired must be a boolean")
			end

			for key in entry do
				if
					type(key) ~= "string" or (not COMMON_FIELDS[key] and spec.fields[key] == nil)
				then
					fail(where .. ": unknown field " .. describe(key))
				end
			end

			for fieldName, field in spec.fields do
				local value = entry[fieldName]
				if value == nil then
					if not field.optional then
						fail(where .. ": missing field '" .. fieldName .. "'")
					end
					continue
				end
				if field.kind == "string" then
					if type(value) ~= "string" then
						fail(where .. ": " .. fieldName .. " must be a string")
					end
				elseif field.kind == "boolean" then
					if type(value) ~= "boolean" then
						fail(where .. ": " .. fieldName .. " must be a boolean")
					end
				elseif field.kind == "positiveInteger" then
					if not isPositiveInteger(value) then
						fail(where .. ": " .. fieldName .. " must be a positive integer")
					end
				elseif field.kind == "id" then
					if not ContentRegistry.isValidId(value) then
						fail(
							where
								.. ": "
								.. fieldName
								.. " must be a canonical id, got "
								.. describe(value)
						)
					end
				elseif field.kind == "idList" then
					if type(value) ~= "table" or not isArray(value :: { [any]: any }) then
						fail(where .. ": " .. fieldName .. " must be an array of ids")
					else
						local seen: { [string]: boolean } = {}
						for j, item in ipairs(value :: { unknown }) do
							if not ContentRegistry.isValidId(item) then
								fail(
									string.format(
										"%s: %s[%d] must be a canonical id, got %s",
										where,
										fieldName,
										j,
										describe(item)
									)
								)
							elseif seen[item :: string] then
								fail(
									string.format(
										"%s: %s lists %q twice",
										where,
										fieldName,
										item :: string
									)
								)
							else
								seen[item :: string] = true
							end
						end
					end
				end
			end
		end
	end

	-- Pass 2: references.
	local function checkRef(
		record: Located,
		fieldName: string,
		value: string,
		allowed: { Category }
	)
		if value == record.entry.id then
			fail(record.where .. ": " .. fieldName .. " references itself")
			return
		end
		local target = index[value]
		if target == nil then
			fail(
				record.where
					.. ": "
					.. fieldName
					.. " references unknown id "
					.. string.format("%q", value)
			)
			return
		end
		if table.find(allowed, target.category) == nil then
			fail(
				record.where
					.. ": "
					.. fieldName
					.. " must reference a "
					.. describeCategories(allowed)
					.. ", but "
					.. string.format("%q", value)
					.. " is a "
					.. target.category
			)
		end
	end

	for _, record in located do
		local spec = SPECS[record.category]
		for fieldName, field in spec.fields do
			local value = record.entry[fieldName]
			if field.ref == nil or value == nil then
				continue
			end
			if field.kind == "id" and type(value) == "string" then
				checkRef(record, fieldName, value, field.ref)
			elseif field.kind == "idList" and type(value) == "table" then
				for _, item in ipairs(value :: { unknown }) do
					if type(item) == "string" then
						checkRef(record, fieldName, item, field.ref)
					end
				end
			end
		end
	end

	-- Pass 3: cross-entry consistency.
	local chapterOrders: { [number]: string } = {}
	for _, record in located do
		local entry = record.entry
		local id = entry.id :: string

		if record.category == "chapter" and isPositiveInteger(entry.order) then
			local order = entry.order :: number
			local other = chapterOrders[order]
			if other ~= nil then
				fail(record.where .. ": order " .. order .. " is already used by " .. other)
			else
				chapterOrders[order] = id
			end
		elseif record.category == "cant" and type(entry.verseIds) == "table" then
			for _, verseId in ipairs(entry.verseIds :: { unknown }) do
				local verse = if type(verseId) == "string" then index[verseId] else nil
				if verse ~= nil and verse.category == "verse" and verse.entry.cantId ~= id then
					fail(
						record.where
							.. ": lists verse "
							.. string.format("%q", verseId :: string)
							.. " whose cantId is not this Cant"
					)
				end
			end
		elseif record.category == "verse" and type(entry.cantId) == "string" then
			local cant = index[entry.cantId :: string]
			if cant ~= nil and cant.category == "cant" then
				local verseIds = cant.entry.verseIds
				if type(verseIds) == "table" and not contains(verseIds :: { string }, id) then
					fail(
						record.where
							.. ": cant "
							.. string.format("%q", entry.cantId :: string)
							.. " does not list this Verse in verseIds"
					)
				end
			end
		elseif record.category == "region" and type(entry.waymarkIds) == "table" then
			for _, waymarkId in ipairs(entry.waymarkIds :: { unknown }) do
				local waymark = if type(waymarkId) == "string" then index[waymarkId] else nil
				if
					waymark ~= nil
					and waymark.category == "waymark"
					and waymark.entry.regionId ~= id
				then
					fail(
						record.where
							.. ": lists waymark "
							.. string.format("%q", waymarkId :: string)
							.. " whose regionId is not this region"
					)
				end
			end
		elseif record.category == "waymark" and type(entry.regionId) == "string" then
			local region = index[entry.regionId :: string]
			if region ~= nil and region.category == "region" then
				local waymarkIds = region.entry.waymarkIds
				if type(waymarkIds) == "table" and not contains(waymarkIds :: { string }, id) then
					fail(
						record.where
							.. ": region "
							.. string.format("%q", entry.regionId :: string)
							.. " does not list this Waymark in waymarkIds"
					)
				end
			end
		end
	end

	return errors
end

local function deepFreeze(value: any)
	if type(value) == "table" and not table.isfrozen(value) then
		table.freeze(value)
		for _, child in value do
			deepFreeze(child)
		end
	end
end

-- Validates and freezes `data`, then returns a registry over it. Errors if
-- the data is not canonical, so a bad dataset can never be served.
function ContentRegistry.build(data: ContentData): Registry
	local problems = ContentRegistry.validate(data)
	if #problems > 0 then
		error(
			"ContentRegistry: content data is not canonical:\n  " .. table.concat(problems, "\n  "),
			2
		)
	end
	deepFreeze(data)

	local byId: { [string]: { category: Category, entry: any } } = {}
	local idsByCategory: { [Category]: { string } } = {}
	for _, category: Category in CATEGORIES do
		local ids = {}
		for _, entry in (data :: any)[SPECS[category].key] :: { { id: string } } do
			byId[entry.id] = { category = category, entry = entry }
			table.insert(ids, entry.id)
		end
		table.sort(ids)
		idsByCategory[category] = table.freeze(ids)
	end

	local function lookup(category: Category, id: string): any?
		local found = byId[id]
		if found ~= nil and found.category == category then
			return found.entry
		end
		return nil
	end

	local registry = {} :: Registry

	function registry:has(category: Category, id: string): boolean
		return lookup(category, id) ~= nil
	end

	function registry:resolve(category: Category, value: unknown): string?
		if type(value) == "string" and lookup(category, value) ~= nil then
			return value
		end
		return nil
	end

	function registry:categoryOf(id: string): Category?
		local found = byId[id]
		return if found ~= nil then found.category else nil
	end

	function registry:ids(category: Category): { string }
		return idsByCategory[category]
	end

	function registry:count(category: Category): number
		return #idsByCategory[category]
	end

	function registry:getChapter(id)
		return lookup("chapter", id)
	end
	function registry:getRegion(id)
		return lookup("region", id)
	end
	function registry:getQuest(id)
		return lookup("quest", id)
	end
	function registry:getCant(id)
		return lookup("cant", id)
	end
	function registry:getVerse(id)
		return lookup("verse", id)
	end
	function registry:getBurden(id)
		return lookup("burden", id)
	end
	function registry:getWaymark(id)
		return lookup("waymark", id)
	end
	function registry:getBoss(id)
		return lookup("boss", id)
	end
	function registry:getDescent(id)
		return lookup("descent", id)
	end

	return table.freeze(registry)
end

return ContentRegistry
