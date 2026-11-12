--!strict
-- Persistent player profile (Technical Plan 2.0, 4.1).
--
-- Structural types only. They say what shape a profile has, not whether a
-- particular value is within bounds; the runtime validator (BM-022, BM-032)
-- enforces Limits.PROFILE before a profile is accepted or saved. No field is
-- `any` or `unknown`: every stored value has an explicit type.

export type QuestStatus = "Locked" | "Active" | "Completed" | "Failed"

export type QuestProgress = {
	questId: string,
	nodeId: string,
	status: QuestStatus,
	revision: number,
	flags: { [string]: boolean },
	choices: { [string]: string },
}

export type QuestJournal = {
	active: { [string]: QuestProgress },
	completed: { [string]: boolean },
}

export type CantProgress = {
	unlocked: { [string]: boolean },
	equipped: string?,
	verses: { [string]: { [string]: boolean } },
}

export type BurdenProgress = {
	discovered: { [string]: boolean },
	active: { string },
	dissonance: number,
}

export type WaymarkProgress = {
	activated: boolean,
	rank: number,
}

export type InventoryStack = {
	itemId: string,
	quantity: number,
	instanceId: string?,
}

export type DescentProgress = {
	unlockedTiers: { [string]: number },
	bestClears: { [string]: number },
}

export type RewardIntent = {
	grantId: string,
	sourceId: string,
	createdAt: number,
	rewardCatalogId: string,
}

export type ReceiptState = {
	permanent: { [string]: boolean },
	seasonal: { [string]: number },
	pending: { [string]: RewardIntent },
}

export type SessionLease = {
	sessionId: string,
	jobId: string,
	fence: number,
	expiresAt: number,
}

export type PlayerProfile = {
	schemaVersion: number,
	revision: number,
	lease: SessionLease?,
	chapterId: string,
	quests: QuestJournal,
	cants: CantProgress,
	burdens: BurdenProgress,
	waymarks: { [string]: WaymarkProgress },
	inventory: { InventoryStack },
	balances: { [string]: number },
	descents: DescentProgress,
	receipts: ReceiptState,
}

local Profile = {}

-- The schema version new profiles are written at. Migrations (BM-023) move
-- older versions forward one step at a time.
Profile.SCHEMA_VERSION = 1

return table.freeze(Profile)
