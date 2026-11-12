--!strict
-- BM-013: payload validators accept exactly their schema; fuzzing finds no
-- crash and no malformed acceptance.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Fuzz = require(ServerStorage.Tests.Support.Fuzz)
local Schema = require(ServerScriptService.Server.Network.Validators.Schema)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Validators = require(ServerScriptService.Server.Network.Validators)

local suite = Suite.new("Validators")

local questChoice = Validators.forAction("QuestChoice") :: Validators.Validator
local travelReady = Validators.forAction("TravelReady") :: Validators.Validator
local clientHello = Validators.forAction("ClientHello") :: Validators.Validator

local function goodQuestChoice(): { [string]: unknown }
	return {
		questId = "quest-x",
		nodeId = "node-1",
		choiceId = "choice-a",
		offerId = "Offer_1-abc",
		revision = 7,
	}
end

local function goodTravelReady(): { [string]: unknown }
	return { ticketId = "ticket-9", ready = true, revision = 3 }
end

-- Mixed-type value lists for boundary loops. A trailing nil is kept as an
-- explicit hole-free entry by building the list from varargs.
local function mixed(...: any): { any }
	local list = {}
	for i = 1, select("#", ...) do
		list[i] = select(i, ...)
	end
	return list
end

local function expectReject(validator: Validators.Validator, raw: unknown, needle: string)
	local value, reason = validator(raw)
	Assert.isNil(value, "must reject (" .. tostring(reason) .. ")")
	Assert.contains(tostring(reason), needle, "reason")
end

suite:case("registered validators match the plan's fixed contracts", function()
	Assert.deepEqual(
		Validators.registered(),
		{ "ClientHello", "QuestChoice", "TravelReady" },
		"registered set"
	)
	Assert.isNil(Validators.forAction("CombatInput"), "no validator yet for CombatInput")
end)

suite:case("QuestChoice accepts the 3.4 contract and returns a fresh typed copy", function()
	local raw = goodQuestChoice()
	local value = questChoice(raw) :: any
	Assert.notNil(value, "accepted")
	Assert.deepEqual(value, raw, "same fields")
	Assert.isTrue(value ~= raw, "fresh table, not the input")
	raw.questId = "changed"
	Assert.equal(value.questId, "quest-x", "copy is independent")
end)

suite:case("QuestChoice rejects every malformed field", function()
	local raw = goodQuestChoice()
	raw.userId = 1
	expectReject(questChoice, raw, "unexpected field userId")

	raw = goodQuestChoice()
	raw.revision = nil
	expectReject(questChoice, raw, "missing field revision")

	for _, bad in mixed("", "Quest-X", "quest x", "quest.x", string.rep("q", 49), 5, true, {}) do
		raw = goodQuestChoice()
		raw.questId = bad
		expectReject(questChoice, raw, "questId is not a canonical id")
	end

	for _, bad in mixed("", "offer id", "offer;1", string.rep("o", 65), 1) do
		raw = goodQuestChoice()
		raw.offerId = bad
		expectReject(questChoice, raw, "offerId is not a valid opaque id")
	end

	for _, bad in mixed(-1, 1.5, 0 / 0, math.huge, 2 ^ 31, "7", true) do
		raw = goodQuestChoice()
		raw.revision = bad
		expectReject(questChoice, raw, "revision is not a valid revision")
	end

	expectReject(questChoice, nil, "not a table")
	expectReject(questChoice, "quest-x", "not a table")
	expectReject(questChoice, {}, "missing field")
end)

suite:case("TravelReady accepts the 3.5 contract with a strict boolean", function()
	local value = travelReady(goodTravelReady()) :: any
	Assert.notNil(value, "accepted")
	Assert.equal(value.ready, true, "ready")

	for _, bad in mixed("true", 1, {}, nil) do
		local raw = goodTravelReady()
		raw.ready = bad
		expectReject(
			travelReady,
			raw,
			if bad == nil then "missing field ready" else "ready is not a boolean"
		)
	end
	local raw = goodTravelReady()
	raw.ready = false
	Assert.notNil(travelReady(raw), "false is a valid boolean")
	raw.destination = "region-elsewhere"
	expectReject(travelReady, raw, "unexpected field destination")
end)

suite:case("ClientHello accepts only a bounded integer protocol version", function()
	Assert.notNil(clientHello({ protocolVersion = 1 }), "v1")
	expectReject(clientHello, { protocolVersion = 0 }, "integer in range")
	expectReject(clientHello, { protocolVersion = 1.5 }, "integer in range")
	expectReject(clientHello, { protocolVersion = "1" }, "integer in range")
	expectReject(clientHello, { protocolVersion = 1, userId = 5 }, "unexpected field")
	expectReject(clientHello, {}, "missing field")
end)

suite:case("Schema kinds behave at their boundaries", function()
	local validate = Schema.object({
		region = { kind = "registryId", category = "cant" },
		count = { kind = "integer", min = 0, max = 10 },
		ratio = { kind = "number", min = 0, max = 1 },
		label = { kind = "string", maxBytes = 4 },
		mode = { kind = "enum", values = { "fast", "slow" } },
		note = { kind = "string", optional = true },
	})
	local base: { [string]: unknown } =
		{ region = "cant-nearness", count = 10, ratio = 1, label = "abcd", mode = "fast" }
	Assert.notNil(validate(base), "boundaries inclusive")

	local function mutate(key: string, value: unknown): { [string]: unknown }
		local copy: { [string]: unknown } = table.clone(base)
		copy[key] = value
		return copy
	end
	expectReject(validate, mutate("region", "cant-invented"), "not a known cant")
	expectReject(validate, mutate("region", "waymark-i"), "not a known cant")
	expectReject(validate, mutate("count", 11), "count is not an integer")
	expectReject(validate, mutate("count", -1), "count is not an integer")
	expectReject(validate, mutate("ratio", 1.01), "ratio is not a number")
	expectReject(validate, mutate("ratio", 0 / 0), "ratio is not a number")
	expectReject(validate, mutate("label", "abcde"), "label is not a string within 4")
	expectReject(validate, mutate("mode", "medium"), "mode is not an allowed value")
	expectReject(validate, mutate("mode", 1), "mode is not an allowed value")
	local withNote = mutate("note", "ok")
	Assert.notNil(validate(withNote), "optional present")
	Assert.notNil(validate(base), "optional absent")
end)

suite:caseWithSeeds(
	"fuzz: validators never throw and only accept well-formed payloads",
	{ 11, 12, 13 },
	function(env)
		local rng = env.rng:fork("validators")
		local checks: { { validator: Validators.Validator, template: { [string]: unknown }, verify: (any) -> () } } =
			{
				{
					validator = questChoice,
					template = goodQuestChoice(),
					verify = function(v)
						Assert.isTrue(
							#v.questId <= 48
								and string.match(v.questId, "^[a-z0-9][a-z0-9%-]*$") ~= nil,
							"questId"
						)
						Assert.isTrue(#v.offerId <= 64, "offerId")
						Assert.isTrue(v.revision >= 0 and v.revision % 1 == 0, "revision")
					end,
				},
				{
					validator = travelReady,
					template = goodTravelReady(),
					verify = function(v)
						Assert.isTrue(type(v.ready) == "boolean", "ready")
						Assert.isTrue(v.revision >= 0 and v.revision % 1 == 0, "revision")
					end,
				},
				{
					validator = clientHello,
					template = { protocolVersion = 1 },
					verify = function(v)
						Assert.isTrue(
							v.protocolVersion >= 1 and v.protocolVersion % 1 == 0,
							"protocolVersion"
						)
					end,
				},
			}

		for _, check in checks do
			local accepted, rejected = 0, 0
			for _ = 1, 1500 do
				local raw: unknown
				local mutated = true
				if rng:chance(0.75) then
					raw, mutated = Fuzz.nearMiss(rng, check.template)
				else
					raw = Fuzz.value(rng, 3)
				end
				local okCall, value, reason = pcall(check.validator, raw)
				Assert.isTrue(okCall, "validator threw: " .. tostring(value))
				if value ~= nil then
					accepted += 1
					check.verify(value)
					-- The accepted value has exactly the template's keys.
					for key in check.template do
						Assert.notNil((value :: any)[key], "accepted value has " .. key)
					end
					for key in value :: { [string]: unknown } do
						Assert.notNil(
							check.template[key],
							"accepted value has no extra key " .. key
						)
					end
				else
					rejected += 1
					Assert.isTrue(type(reason) == "string", "rejection has a reason")
					Assert.isTrue(mutated or raw == nil, "an unmutated template must be accepted")
				end
			end
			Assert.isTrue(accepted > 0 and rejected > 0, "fuzz exercised both outcomes")
		end
	end
)

return suite:cases()
