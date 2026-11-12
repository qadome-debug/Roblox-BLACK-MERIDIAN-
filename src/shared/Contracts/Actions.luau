--!strict
-- The complete client-to-server request surface (Technical Plan 2.0, 3.3).
--
-- Every name here is an action the dispatcher may route. Anything else is
-- rejected before any gameplay code runs. Adding a name requires a backlog
-- task, a registered payload schema, a secure adapter, and abuse tests.

export type ActionName =
	"ClientHello"
	| "CombatInput"
	| "CantEquip"
	| "VerseCast"
	| "DissonanceAction"
	| "BurdenChoice"
	| "QuestChoice"
	| "WaymarkActivate"
	| "RespawnRequest"
	| "ReviveRequest"
	| "InventoryEquip"
	| "NPCInteract"
	| "CollectibleClaim"
	| "TravelReady"
	| "TravelPropose"
	| "DescentEnter"
	| "StarterCantSelect"
	| "CraftRequest"
	| "VendorPurchase"
	| "DescentQueue"
	| "DescentCancel"
	| "PartyInvite"
	| "PartyAccept"
	| "PartyLeave"
	| "PartyKick"
	| "SettingsUpdate"

-- Rate-limit class each action belongs to (keys of Limits.RATE).
export type RateClass = "combat" | "cant" | "choice" | "waymark" | "party" | "economy" | "session"

export type ActionInfo = { owningTask: string, rateClass: RateClass }

local REGISTRY: { [ActionName]: ActionInfo } = {
	ClientHello = { owningTask = "BM-017", rateClass = "session" },
	CombatInput = { owningTask = "BM-061", rateClass = "combat" },
	CantEquip = { owningTask = "BM-064", rateClass = "cant" },
	VerseCast = { owningTask = "BM-067", rateClass = "cant" },
	DissonanceAction = { owningTask = "BM-068", rateClass = "cant" },
	BurdenChoice = { owningTask = "BM-070", rateClass = "choice" },
	QuestChoice = { owningTask = "BM-074", rateClass = "choice" },
	WaymarkActivate = { owningTask = "BM-076", rateClass = "waymark" },
	RespawnRequest = { owningTask = "BM-079", rateClass = "session" },
	ReviveRequest = { owningTask = "BM-079", rateClass = "session" },
	InventoryEquip = { owningTask = "BM-080", rateClass = "cant" },
	NPCInteract = { owningTask = "BM-086", rateClass = "choice" },
	CollectibleClaim = { owningTask = "BM-088", rateClass = "waymark" },
	TravelReady = { owningTask = "BM-090", rateClass = "party" },
	TravelPropose = { owningTask = "BM-091", rateClass = "party" },
	DescentEnter = { owningTask = "BM-093", rateClass = "party" },
	StarterCantSelect = { owningTask = "BM-106", rateClass = "session" },
	CraftRequest = { owningTask = "BM-109", rateClass = "economy" },
	VendorPurchase = { owningTask = "BM-110", rateClass = "economy" },
	DescentQueue = { owningTask = "BM-115", rateClass = "party" },
	DescentCancel = { owningTask = "BM-115", rateClass = "party" },
	PartyInvite = { owningTask = "BM-116", rateClass = "party" },
	PartyAccept = { owningTask = "BM-116", rateClass = "party" },
	PartyLeave = { owningTask = "BM-116", rateClass = "party" },
	PartyKick = { owningTask = "BM-116", rateClass = "party" },
	SettingsUpdate = { owningTask = "BM-128", rateClass = "session" },
}

local ALL: { ActionName } = {}
for name in REGISTRY do
	table.insert(ALL, name)
end
table.sort(ALL)

local Actions = {}

Actions.REGISTRY = table.freeze(REGISTRY)
Actions.ALL = table.freeze(ALL)

-- Narrowing check for untrusted input. Only exact registered names pass.
function Actions.resolve(value: unknown): ActionName?
	if type(value) == "string" and REGISTRY[value :: ActionName] ~= nil then
		return value :: ActionName
	end
	return nil
end

function Actions.info(name: ActionName): ActionInfo
	return REGISTRY[name]
end

return table.freeze(Actions)
