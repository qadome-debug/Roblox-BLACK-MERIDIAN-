--!strict
-- Server-to-client combat replication contract (BM-060).
--
-- Everything here is presentation data. The client renders it and uses
-- the acknowledgement to correct its own prediction; nothing in it is
-- ever sent back as evidence. Public views deliberately omit anything a
-- cheat could use: exact enemy health, resource pools, cancel windows,
-- anti-cheat flags.

export type ActionState =
	"Idle"
	| "Attacking"
	| "Dodging"
	| "Guarding"
	| "Parrying"
	| "Hit"
	| "Staggered"
	| "Dead"
export type Phase = "None" | "Windup" | "Active" | "Recovery"

-- What every client may know about any combatant.
export type PublicCombatant = {
	id: string,
	team: string,
	state: ActionState,
	phase: Phase,
	-- Monotonic per combatant; lets the client tell swings apart.
	actionId: number,
	-- Health as a fraction in [0, 1], rounded to 1/100.
	health: number,
}

-- What a client may know about its own combatant, in addition.
export type OwnCombatant = {
	id: string,
	state: ActionState,
	phase: Phase,
	actionId: number,
	health: number,
	maxHealth: number,
	stamina: number,
	maxStamina: number,
	posture: number,
	maxPosture: number,
	-- Highest intent sequence the server has judged. Any prediction the
	-- client made for a sequence at or below this is now settled.
	ackSequence: number,
	target: string?,
	engaged: boolean,
}

export type Delta = {
	kind: "combat",
	-- Simulation step the delta describes.
	revision: number,
	-- True when the client must replace everything it holds.
	full: boolean,
	own: OwnCombatant?,
	combatants: { PublicCombatant },
	removed: { string },
}

-- Visual event cues. `data` is bounded and public (BM-060 filters it).
export type Cue = {
	step: number,
	kind: string,
	id: string,
	data: { [string]: string | number | boolean }?,
}

export type CueBatch = {
	kind: "cues",
	revision: number,
	cues: { Cue },
}

return {}
