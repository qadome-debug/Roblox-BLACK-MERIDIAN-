--!strict
-- BM-004 fixtures: duplicate, invalid, and missing-reference content.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Canon = require(ReplicatedStorage.Shared.Catalogs.Canon)
local Content = require(ReplicatedStorage.Shared.Catalogs.Content)
local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)

type Data = ContentRegistry.ContentData

-- A small, internally consistent dataset. Test IDs only; not canon.
local function base(): Data
	return {
		chapters = {
			{ id = "chapter-t1", name = "Test Chapter One", launchRequired = true, order = 1 },
		},
		regions = {
			{
				id = "region-ta",
				name = "Test Region A",
				launchRequired = true,
				waymarkIds = { "waymark-ta1" },
				travelLinkIds = { "region-tb" },
			},
			{
				id = "region-tb",
				name = "Test Region B",
				launchRequired = false,
				waymarkIds = {},
				travelLinkIds = { "region-ta" },
			},
		},
		quests = {
			{
				id = "quest-t1",
				name = "Test Quest",
				launchRequired = true,
				chapterId = "chapter-t1",
				regionId = "region-ta",
			},
		},
		cants = {
			{
				id = "cant.t",
				name = "Test Cant",
				launchRequired = true,
				starterEligible = false,
				verseIds = { "t.v1" },
			},
		},
		verses = {
			{ id = "t.v1", name = "Test Verse", launchRequired = true, cantId = "cant.t" },
		},
		burdens = {
			{ id = "burden-t", name = "Test Burden", launchRequired = true, cantId = "cant.t" },
		},
		waymarks = {
			{
				id = "waymark-ta1",
				name = "Test Waymark",
				launchRequired = true,
				rank = 1,
				regionId = "region-ta",
			},
		},
		bosses = {
			{ id = "boss-t", name = "Test Boss", launchRequired = true, locationId = "descent-t" },
		},
		descents = {
			{
				id = "descent-t",
				name = "Test Descent",
				launchRequired = true,
				entranceRegionId = "region-ta",
			},
		},
	}
end

local function expectClean(data: unknown)
	local errors = ContentRegistry.validate(data)
	assert(#errors == 0, "expected no errors, got:\n  " .. table.concat(errors, "\n  "))
end

local function expectError(data: unknown, needle: string)
	local errors = ContentRegistry.validate(data)
	for _, err in errors do
		if string.find(err, needle, 1, true) then
			return
		end
	end
	error(
		string.format(
			"expected an error containing %q, got:\n  %s",
			needle,
			table.concat(errors, "\n  ")
		)
	)
end

local cases = {}

local function case(name: string, run: () -> ())
	table.insert(cases, { name = name, run = run })
end

-- Sets a field on an entry while bypassing the static type, so fixtures can
-- be made deliberately wrong.
local function set(target: any, key: string, value: any)
	target[key] = value
end

case("base fixture is valid", function()
	expectClean(base())
end)

case("checked-in Content.luau is canonical", function()
	expectClean(Content)
end)

case("Canon exposes Nearness and Waymark I", function()
	assert(Canon:has("cant", "cant.nearness"), "cant.nearness missing")
	assert(Canon:getCant("cant.nearness") ~= nil, "getCant failed")
	assert(
		(Canon:getCant("cant.nearness") :: any).starterEligible == false,
		"Nearness is acquired in the story, not owned at creation"
	)
	for _, id in { "cant.embers", "cant.second_voice", "cant.still_water" } do
		assert(Canon:has("cant", id), id .. " missing")
	end
	for _, id in { "near.close_step", "near.draw_near", "near.between_us", "near.no_farther" } do
		assert(Canon:has("verse", id), id .. " missing")
		assert((Canon:getVerse(id) :: any).cantId == "cant.nearness", id .. " belongs to Nearness")
	end
	assert(Canon:has("waymark", "waymark-i"), "waymark-i missing")
	assert(Canon:categoryOf("waymark-i") == "waymark", "categoryOf")
	assert(Canon:count("cant") == 4, "four launch Cants")
	assert(Canon:count("verse") == 4, "four Nearness Verses")
end)

case("Canon is frozen", function()
	assert(table.isfrozen(Canon :: any), "registry not frozen")
	local cant = Canon:getCant("cant.nearness") :: any
	assert(table.isfrozen(cant), "entry not frozen")
	assert(table.isfrozen(cant.verseIds), "nested list not frozen")
	assert(table.isfrozen(Content :: any), "source data not frozen after build")
end)

case("resolve accepts only known ids of the right category", function()
	assert(Canon:resolve("cant", "cant.nearness") == "cant.nearness", "known id")
	assert(Canon:resolve("verse", "cant.nearness") == nil, "wrong category")
	assert(Canon:resolve("cant", "cant.invented") == nil, "unknown id")
	assert(Canon:resolve("cant", 42) == nil, "number")
	assert(Canon:resolve("cant", nil) == nil, "nil")
	assert(Canon:resolve("cant", { "cant.nearness" }) == nil, "table")
end)

case("duplicate id across categories", function()
	local data = base()
	table.insert(
		data.burdens,
		{ id = "cant.t", name = "Dup", launchRequired = false, cantId = "cant.t" }
	)
	expectError(data, "duplicate id")
end)

case("duplicate id within a category", function()
	local data = base()
	table.insert(
		data.burdens,
		{ id = "burden-t", name = "Dup", launchRequired = false, cantId = "cant.t" }
	)
	expectError(data, "duplicate id")
end)

case("invalid id characters", function()
	for _, bad in
		{ "Burden-T", "burden t", "", "-burden", ".burden", "burden-", "burden..t", "burden-t." }
	do
		local data = base()
		data.burdens[1].id = bad
		expectError(data, "invalid id")
	end
end)

case("the approved report format: dots and underscores", function()
	for _, good in { "cant.nearness", "near.close_step", "cant.second_voice", "waymark-i" } do
		assert(ContentRegistry.isValidId(good), good .. " must be a valid id")
	end
	assert(ContentRegistry.verseNamespace("near.close_step") == "near", "namespace")
	assert(ContentRegistry.verseNamespace("close_step") == nil, "a Verse ID needs a namespace")
	assert(ContentRegistry.verseNamespace("cant.nearness") == nil, "a Cant ID is not a Verse ID")
	assert(ContentRegistry.verseNamespace("near.close.step") == nil, "one dot only")

	-- A Cant is `cant.<name>`; the hyphen style is no longer accepted for it.
	local data = base()
	data.cants[1].id = "cant-t"
	expectError(data, "id must start with 'cant.'")

	-- A Verse is `<namespace>.<name>`.
	data = base()
	data.verses[1].id = "verse-t1"
	expectError(data, "id must have the form '<namespace>.<name>'")
end)

case("a Verse namespace belongs to one Cant", function()
	local data = base()
	table.insert(data.cants, {
		id = "cant.u",
		name = "Other Cant",
		launchRequired = false,
		starterEligible = false,
		verseIds = { "t.v9" },
	})
	table.insert(
		data.verses,
		{ id = "t.v9", name = "Stray", launchRequired = false, cantId = "cant.u" }
	)
	expectError(data, "namespace 't' already belongs to cant.t")

	data = base()
	table.insert(data.cants[1].verseIds, "other.v1")
	table.insert(
		data.verses,
		{ id = "other.v1", name = "Split", launchRequired = false, cantId = "cant.t" }
	)
	expectError(data, "verses of cant.t use the namespace 't'")
end)

case("a Burden names the Cant it belongs to", function()
	local data = base()
	data.burdens[1].cantId = "cant.missing"
	expectError(data, "cant.missing")
	data = base()
	set(data.burdens[1], "cantId", nil)
	expectError(data, "missing field 'cantId'")
end)

case("id too long", function()
	local data = base()
	data.burdens[1].id = "burden-" .. string.rep("a", 48)
	expectError(data, "invalid id")
end)

case("id with wrong prefix", function()
	local data = base()
	data.burdens[1].id = "cant.pretending"
	expectError(data, "must start with 'burden-'")
end)

case("missing reference", function()
	local data = base()
	data.quests[1].regionId = "region-nowhere"
	expectError(data, "references unknown id")
end)

case("reference to wrong category", function()
	local data = base()
	data.bosses[1].locationId = "cant.t"
	expectError(data, "must reference a region or descent")
end)

case("self reference", function()
	local data = base()
	data.regions[1].travelLinkIds = { "region-ta" }
	expectError(data, "references itself")
end)

case("unknown field", function()
	local data = base()
	set(data.burdens[1], "power", 9)
	expectError(data, "unknown field")
end)

case("missing field", function()
	local data = base()
	set(data.waymarks[1], "rank", nil)
	expectError(data, "missing field 'rank'")
end)

case("wrong field type", function()
	local data = base()
	set(data.waymarks[1], "rank", "1")
	expectError(data, "rank must be a positive integer")
	data = base()
	set(data.cants[1], "starterEligible", "yes")
	expectError(data, "starterEligible must be a boolean")
	data = base()
	set(data.cants[1], "verseIds", "t.v1")
	expectError(data, "verseIds must be an array")
	data = base()
	set(data.chapters[1], "order", 0)
	expectError(data, "order must be a positive integer")
end)

case("name bounds", function()
	local data = base()
	data.burdens[1].name = ""
	expectError(data, "name must be a string")
	data = base()
	data.burdens[1].name = string.rep("n", 65)
	expectError(data, "name must be a string")
end)

case("launchRequired must be boolean", function()
	local data = base()
	set(data.burdens[1], "launchRequired", nil)
	expectError(data, "launchRequired must be a boolean")
end)

case("list entries must be unique", function()
	local data = base()
	data.cants[1].verseIds = { "t.v1", "t.v1" }
	expectError(data, 'lists "t.v1" twice')
end)

case("verse and cant must agree", function()
	local data = base()
	table.insert(
		data.verses,
		{ id = "t.v2", name = "Orphan", launchRequired = false, cantId = "cant.t" }
	)
	expectError(data, "does not list this Verse")

	data = base()
	table.insert(data.cants, {
		id = "cant.u",
		name = "Other",
		launchRequired = false,
		starterEligible = false,
		verseIds = { "t.v1" },
	})
	expectError(data, "whose cantId is not this Cant")
end)

case("waymark and region must agree", function()
	local data = base()
	data.waymarks[1].regionId = "region-tb"
	expectError(data, "does not list this Waymark")

	data = base()
	data.waymarks[1].regionId = nil
	expectError(data, "whose regionId is not this region")

	data = base()
	data.waymarks[1].regionId = nil
	data.regions[1].waymarkIds = {}
	expectClean(data)
end)

case("chapter order must be unique", function()
	local data = base()
	table.insert(
		data.chapters,
		{ id = "chapter-t2", name = "Two", launchRequired = false, order = 1 }
	)
	expectError(data, "order 1 is already used")
end)

case("lists must be arrays and present", function()
	local data = base()
	set(data, "burdens", { a = 1 })
	expectError(data, "'burdens' must be an array")
	data = base()
	set(data, "burdens", nil)
	expectError(data, "missing list 'burdens'")
	data = base()
	set(data, "extras", {})
	expectError(data, "unknown top-level key")
	expectError("nope", "content data must be a table")
	expectError({ chapters = { 5 } }, "chapters[1] must be a table")
end)

case("build rejects invalid data", function()
	local data = base()
	data.quests[1].chapterId = "chapter-none"
	local ok, err = pcall(ContentRegistry.build, data)
	assert(not ok, "build should fail")
	assert(
		string.find(tostring(err), "not canonical", 1, true),
		"error should say why: " .. tostring(err)
	)
end)

case("build returns a registry with sorted ids", function()
	local registry = ContentRegistry.build(base())
	local regions = registry:ids("region")
	assert(#regions == 2 and regions[1] == "region-ta" and regions[2] == "region-tb", "ids sorted")
	assert(registry:getBoss("boss-t") ~= nil, "getBoss")
	assert(registry:getBoss("descent-t") == nil, "getBoss wrong category")
	assert(registry:getDescent("descent-t") ~= nil, "getDescent")
end)

return cases
