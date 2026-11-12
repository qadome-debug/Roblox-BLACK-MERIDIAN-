--!strict
-- BM-005: the shared contracts type-check (enforced by luau-lsp) and their
-- runtime registries agree with the plan's request surface.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.Shared.Contracts.Actions)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)

-- Compile-time checks: these literals must satisfy the exported types.
local _request: Protocol.ActionRequest = {
	v = Protocol.VERSION,
	requestId = "client-generated-uuid",
	sessionEpoch = "server-issued-epoch",
	seq = 42,
	action = "QuestChoice",
	payload = { questId = "quest-x", nodeId = "n", choiceId = "c", offerId = "o", revision = 7 },
}

local _result: Protocol.ActionResult = {
	requestId = "client-generated-uuid",
	status = "OK",
	action = "QuestChoice",
	stateRevision = 8,
	data = { questId = "quest-x", nextNodeId = "n2" } :: { [string]: unknown },
}

local _questChoice: Payloads.QuestChoicePayload = {
	questId = "quest-x",
	nodeId = "node",
	choiceId = "choice",
	offerId = "offer",
	revision = 0,
}

local _travelReady: Payloads.TravelReadyPayload =
	{ ticketId = "ticket", ready = true, revision = 3 }

local _profile: Profile.PlayerProfile = {
	schemaVersion = Profile.SCHEMA_VERSION,
	revision = 0,
	lease = nil,
	chapterId = "",
	quests = { active = {}, completed = {} },
	cants = { unlocked = {}, equipped = nil, verses = {} },
	burdens = { discovered = {}, active = {}, dissonance = 0 },
	waymarks = {},
	inventory = {},
	balances = {},
	descents = { unlockedTiers = {}, bestClears = {} },
	receipts = { permanent = {}, seasonal = {}, pending = {} },
}

local cases = {}
local function case(name: string, run: () -> ())
	table.insert(cases, { name = name, run = run })
end

local EXPECTED_ACTIONS = {
	"ClientHello",
	"CombatInput",
	"CantEquip",
	"VerseCast",
	"DissonanceAction",
	"BurdenChoice",
	"QuestChoice",
	"WaymarkActivate",
	"RespawnRequest",
	"ReviveRequest",
	"InventoryEquip",
	"NPCInteract",
	"CollectibleClaim",
	"TravelReady",
	"TravelPropose",
	"DescentEnter",
	"StarterCantSelect",
	"CraftRequest",
	"VendorPurchase",
	"DescentQueue",
	"DescentCancel",
	"PartyInvite",
	"PartyAccept",
	"PartyLeave",
	"PartyKick",
	"SettingsUpdate",
}

case("action registry matches the plan's request surface exactly", function()
	assert(
		#Actions.ALL == #EXPECTED_ACTIONS,
		"expected " .. #EXPECTED_ACTIONS .. " actions, got " .. #Actions.ALL
	)
	for _, name in EXPECTED_ACTIONS do
		assert(Actions.resolve(name) == name, "missing action " .. name)
	end
end)

case("forbidden actions are not registered", function()
	for _, name in
		{ "GrantReward", "CompleteQuest", "SetWaymark", "ApplyDamage", "FinishDescent", "" }
	do
		assert(Actions.resolve(name) == nil, name .. " must not be an action")
	end
	assert(Actions.resolve(nil) == nil, "nil")
	assert(Actions.resolve(1) == nil, "number")
	assert(Actions.resolve("questchoice") == nil, "case must match exactly")
	assert(Actions.resolve("QuestChoice ") == nil, "no trailing space")
end)

case("every action has an owning task and a known rate class", function()
	for _, name: Actions.ActionName in Actions.ALL do
		local info = Actions.info(name)
		assert(string.match(info.owningTask, "^BM%-%d%d%d$"), name .. " owning task")
		assert(
			(Limits.RATE :: any)[info.rateClass] ~= nil,
			name .. " rate class " .. info.rateClass
		)
	end
end)

case("registries are frozen", function()
	assert(table.isfrozen(Actions.ALL), "ALL")
	assert(table.isfrozen(Actions.REGISTRY), "REGISTRY")
	assert(table.isfrozen(Limits), "Limits")
	assert(table.isfrozen(Limits.PROFILE), "Limits.PROFILE")
	assert(table.isfrozen(Limits.RATE.combat), "rate entry")
	assert(table.isfrozen(Protocol.REMOTES), "REMOTES")
end)

case("limits match the plan", function()
	assert(Limits.MAX_CANONICAL_ID_BYTES == 48, "canonical id bytes")
	assert(Limits.MAX_OPAQUE_ID_BYTES == 64, "opaque id bytes")
	assert(Limits.RATE.combat.perSecond == 15 and Limits.RATE.combat.burst == 20, "combat rate")
	assert(Limits.RATE.envelope.maxPayloadBytes == 1024, "envelope payload")
	assert(Limits.PROFILE.SOFT_SIZE_BYTES == 131072, "soft size")
	assert(Limits.PROFILE.HARD_SIZE_BYTES == 196608, "hard size")
	assert(Limits.PROFILE.MAX_ACTIVE_QUESTS == 12, "active quests")
	assert(Limits.PROFILE.MAX_PENDING_INTENTS == 32, "pending intents")
	assert(Limits.LEASE.LIFETIME_SECONDS == 90, "lease lifetime")
	assert(Limits.LEASE.RENEWAL_INTERVAL_SECONDS == 30, "lease renewal")
	assert(Limits.DUPLICATE_RESULT_CACHE_SECONDS == 600, "duplicate cache")
end)

case("protocol basics", function()
	assert(Protocol.VERSION == 1, "version")
	assert(Protocol.REMOTES.ACTION_REQUEST == "ActionRequest", "ingress name")
	assert(Protocol.isSuccess(_result), "OK is success")
	local rejected: Protocol.ActionResult =
		{ requestId = "r", status = "REPLAY", action = "QuestChoice" }
	assert(not Protocol.isSuccess(rejected), "REPLAY is not success")
end)

return cases
