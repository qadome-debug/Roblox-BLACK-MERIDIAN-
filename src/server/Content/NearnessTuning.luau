--!strict
-- Nearness Verse tuning: every value the four Verses use, in one place.
--
-- CONFIRMED BY THE DESIGN (22-part report):
--   * the four Verses, their IDs and what each does;
--   * cooldowns of 7, 11, 16 and 24 seconds;
--   * Dissonance is gained by use and is not spent like mana.
--
-- INITIAL BALANCING VALUES (approved 2026-11-16 as a starting point, to be
-- adjusted after the Verses have been played; NOT final balance): every
-- other number below. The report's illustrative Close Step values (16
-- studs, 8 Dissonance) are used for that Verse. Change a number here and
-- nothing else; the catalog, the effects and the tests read it from this
-- table.
--
-- Cast times and costs are in seconds and stamina. Distances are studs.
-- Combat attributes and formulas are still engineering defaults, so the
-- stamina costs are sized against today's stamina pool and move with it.

export type Verse = {
	id: string,
	cooldownSeconds: number,
	castSeconds: number,
	-- Stamina spent when the cast starts, even if it is interrupted.
	stamina: number,
	-- Dissonance gained only when the Verse actually executes.
	dissonance: number,
	targeting: string,
	castFrom: { string },
	effect: string,
	params: { [string]: number },
}

local NearnessTuning: { Verse } = {
	{
		id = "near.close_step",
		cooldownSeconds = 7,
		castSeconds = 0,
		stamina = 15,
		dissonance = 8,
		targeting = "direction",
		-- Also from the recovery phase of an attack: a gap-closer that can
		-- follow a swing.
		castFrom = { "Idle", "Guarding", "AttackRecovery" },
		effect = "close_step",
		params = {
			range = 16, -- farthest destination along the aim
			maxRise = 4, -- highest step up from the start
			lungeSeconds = 0.25, -- presentation time of the lunge
			minDistance = 1, -- shorter than this is no move at all
		},
	},
	{
		id = "near.draw_near",
		cooldownSeconds = 11,
		castSeconds = 0.2,
		stamina = 20,
		dissonance = 10,
		targeting = "combatant",
		castFrom = { "Idle", "Guarding" },
		effect = "draw_near",
		params = {
			range = 20, -- caster to target
			stopDistance = 4, -- the pull ends this close to the caster
			pullSeconds = 0.35,
			eliteScale = 0.5, -- elites are pulled half the distance
			refuseImmune = 1, -- bosses cannot be targeted
		},
	},
	{
		id = "near.between_us",
		cooldownSeconds = 16,
		castSeconds = 0.3,
		stamina = 25,
		dissonance = 12,
		targeting = "pair",
		castFrom = { "Idle", "Guarding" },
		effect = "between_us",
		params = {
			range = 20, -- caster to each target
			maxDistance = 8, -- the two may not be farther apart than this
			durationSeconds = 6,
			correctionSpeed = 14, -- studs per second a straying target is drawn back
			eliteScale = 0.5,
			refuseImmune = 1,
		},
	},
	{
		id = "near.no_farther",
		cooldownSeconds = 24,
		castSeconds = 0.4,
		stamina = 30,
		dissonance = 15,
		targeting = "point",
		castFrom = { "Idle", "Guarding" },
		effect = "no_farther",
		params = {
			range = 20, -- caster to the zone centre
			radius = 20, -- doubled from 10 at the owner's request after hands-on play
			durationSeconds = 5,
			slowScale = 0.4, -- all movement inside runs at 40% speed (60% slower)
			affectsBosses = 0, -- bosses keep their own mechanics
		},
	},
}

return table.freeze(NearnessTuning)
