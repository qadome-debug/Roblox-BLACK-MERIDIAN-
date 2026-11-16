# Decision sheet — Nearness, Dissonance, Burdens

Status: 2026-11-16. For approval by the designer.

**Every number below is a PROVISIONAL recommendation.** None of them is in
the code. The four Nearness Verses are registered with their confirmed
cooldowns and refuse to cast until this sheet is answered. Nothing else
starts working before approval.

How to answer: for each row, "approve", a different value, or "ask the
report". If the 22-part report has a value, the report wins.

## Context for the numbers

The combat core numbers are engineering defaults, not canon (checklist
item A13). The recommendations are sized against them, so they move if
the core moves:

| Current engineering default | Value |
| --------------------------- | ----- |
| Stamina pool at base attributes | 140 |
| Stamina regeneration | 20 per second, after 1 second without spending |
| Walk speed | about 16 studs per second |
| Melee reach | 6 studs |
| Attack / dodge / parry cost | 20 / 25 / 15 stamina |
| Enemy aggro / leash range | 20 / 40 studs |

## 1. Rules shared by all four Verses

| # | Decision | Recommendation (PROVISIONAL) | Effect on play |
| - | -------- | ---------------------------- | -------------- |
| 1.1 | What a Verse costs | A small stamina cost per Verse, plus Dissonance as the main price | Stamina keeps Verses competing with dodges and attacks for the same budget. Dissonance makes heavy Verse use change the world rather than just run a meter dry. No separate mana bar |
| 1.2 | Which states a Verse can be cast from | Idle and Guarding for all four. Close Step also from the recovery phase of an attack | Close Step becomes a gap-closer that can follow a swing. The other three stay deliberate choices. Today the code requires Idle |
| 1.3 | What interrupts a cast with a wind-up | Stagger and death interrupt. An ordinary hit does not | Players are not punished for chip damage, but a heavy hit or guard break still stops them. Today any hit interrupts |
| 1.4 | What an interrupted cast loses | The stamina cost and the full cooldown, as today | Stops players from "fishing" for casts. Harsher alternative: none. Softer alternative: half cooldown |
| 1.5 | Bosses and elites | Bosses cannot be moved by Draw Near or tethered by Between Us. Elites are pulled half the distance. No Farther affects everyone | Boss arenas keep their designed spacing. Nearness stays useful against bosses through movement and zones |

## 2. Close Step — confirmed: 7 s cooldown, shortens the path to a valid point and lunges toward it

| # | Decision | Recommendation (PROVISIONAL) | Effect on play |
| - | -------- | ---------------------------- | -------------- |
| 2.1 | Range | **16 studs** (the report's illustrative value) | About one second of walking covered in a blink. Beyond melee reach, inside enemy aggro range |
| 2.2 | Dissonance gained | **8** (the report's illustrative value) | Five Close Steps from zero reach the 40 band, so steady use is visible but not punishing |
| 2.3 | Cast time | Instant | It reads as a reaction, not a spell |
| 2.4 | Lunge duration | 0.25 s | Fast enough to feel like a step, slow enough for enemies to read |
| 2.5 | Protection during the lunge | None | It does not replace the dodge. A player who lunges into an attack is hit |
| 2.6 | Stamina cost | 15 | Cheaper than a dodge, so it is the preferred way to close distance |
| 2.7 | What makes a point valid | Walkable ground; nothing solid on the straight line; no more than 4 studs above the start; not across an encounter gate or region boundary. An invalid aim is shortened to the last valid point instead of failing | Never lands a player inside a wall or past a locked door. Shortening rather than failing keeps the move from feeling unreliable |
| 2.8 | Aim | The point the camera aims at, or straight ahead when the aim is on nothing | Works the same with mouse, gamepad and touch |

## 3. Draw Near — confirmed: 11 s cooldown, pulls an eligible enemy or object toward an anchor

| # | Decision | Recommendation (PROVISIONAL) | Effect on play |
| - | -------- | ---------------------------- | -------------- |
| 3.1 | What the anchor is | The caster | Simple to read: "come here". A placed anchor could follow later |
| 3.2 | Eligible targets | One standard enemy or tagged object, in sight, within range | Precise and readable. A multi-target pull would be much stronger |
| 3.3 | Range | 20 studs | Matches enemy aggro range, so it reaches anything already engaging |
| 3.4 | Pull distance | Until the target is 4 studs from the anchor, inside melee reach | A pull leads directly into an attack |
| 3.5 | Pull duration | 0.35 s | Visible travel; other players can react |
| 3.6 | Cast time | 0.2 s | A short tell before the pull |
| 3.7 | Stamina / Dissonance | 20 / 10 | Costs about as much as an attack |
| 3.8 | Objects | Waits for world content: no pullable objects exist yet | None until the world tasks add them |

## 4. Between Us — confirmed: 16 s cooldown, creates a temporary adjacency tether between two targets

| # | Decision | Recommendation (PROVISIONAL) | Effect on play |
| - | -------- | ---------------------------- | -------------- |
| 4.1 | Which two targets | The caster picks two, each within 20 studs. One may be the caster | Lets a player chain an enemy to themselves, to another enemy, or two enemies together |
| 4.2 | What the tether enforces | The two cannot be more than 8 studs apart; a target pulled past that is drawn back | "Adjacency" made concrete: no kiting away and no splitting a pair |
| 4.3 | Duration | 6 s | Long enough to fight inside it, shorter than the cooldown |
| 4.4 | What breaks it | Either target dying, the caster dying, a forced teleport | No invisible tethers left behind |
| 4.5 | Cast time | 0.3 s | |
| 4.6 | Stamina / Dissonance | 25 / 12 | |

## 5. No Farther — confirmed: 24 s cooldown, creates a temporary zone that compresses escape distance

| # | Decision | Recommendation (PROVISIONAL) | Effect on play |
| - | -------- | ---------------------------- | -------------- |
| 5.1 | Shape and size | A circle, 10 studs radius | Covers a small group fight |
| 5.2 | Placement | At the aimed point, within 20 studs | |
| 5.3 | What "compresses escape distance" means | Movement away from the centre is 50% slower; movement toward it is normal | Enemies cannot flee or kite, and nothing is stunned |
| 5.4 | Who is affected | Enemies only | Allies are never trapped by a friend |
| 5.5 | Duration | 5 s | The strongest Verse, kept short |
| 5.6 | Cast time | 0.4 s | The longest tell, matching the longest cooldown |
| 5.7 | Stamina / Dissonance | 30 / 15 | The most expensive Verse in both resources |

## 6. Dissonance amounts

The bands, sources and recovery routes are confirmed and built. Only the
amounts are open.

| # | Decision | Recommendation (PROVISIONAL) | Effect on play |
| - | -------- | ---------------------------- | -------------- |
| 6.1 | Verse use | As in sections 2 to 5: 8, 10, 12, 15 | A full rotation of all four adds 45, into the 40 band |
| 6.2 | Unstable areas | +1 per second while inside | A minute in a bad place reaches 65 without using a Verse |
| 6.3 | Enemy attacks | +3 per hit, only from enemies the design marks as raising Dissonance | Some enemies are dangerous for more than damage |
| 6.4 | Failed containment | +15 per failure | A real setback, not a disaster |
| 6.5 | Relics | Defined per Relic | Waits for Relic design |
| 6.6 | Stable environment | −5 per second | 40 back to 0 in 8 seconds of calm |
| 6.7 | Anchor | Reset to 0 | Anchors are the clean slate |
| 6.8 | Camp | −30 once per camp use | A partial reset in the field |
| 6.9 | Approved consumable | −20 | Per item, when items are designed |
| 6.10 | Encounter completion | −20 | Winning a fight relieves pressure |
| 6.11 | Cooperative actions | −10 for each participant | Waits for the co-op design |
| 6.12 | After a rupture | The region or encounter decides. Default: the meter drops to 60 | Out of the danger bands, not back to calm |
| 6.13 | On rejoin | 0 | Confirmed in principle: raw Dissonance is not carried between sessions |

## 7. Nearness Burdens

| # | Decision | Recommendation (PROVISIONAL) | Effect on play |
| - | -------- | ---------------------------- | -------------- |
| 7.1 | Unwanted Company: from which Dissonance it acts | From 40 (Noticeable instability) | Calm play is untouched. Pressure starts with the first visible band |
| 7.2 | Unwanted Company: "adjacent" | Within 6 studs, the melee reach | Fighting at Nearness's natural range is the risk |
| 7.3 | Unwanted Company: "certain nearby attacks" | Melee attacks only | Ranged enemies are unaffected; the Burden is about closeness |
| 7.4 | Unwanted Company: how much more dangerous | Damage from adjacent melee attacks ×1.15 at 40–64, ×1.30 at 65–84, ×1.50 from 85 | Rewards shedding Dissonance before a melee brawl |
| 7.5 | Long Way Home: what counts as "Nearness movement" | Each Close Step, and each time the player is moved by their own Verse | |
| 7.6 | Long Way Home: what "recovery penalty" means | **Needs the report.** It could mean stamina recovery, Dissonance recovery or health recovery. The recommendation below assumes stamina | |
| 7.7 | Long Way Home: size | −10% stamina regeneration per counted move, up to −50%; cleared on reaching stable ground | Long chains of movement get slower to sustain; returning to safety resets it |
| 7.8 | Mastery requirement for Long Way Home | **Needs the report** | No recommendation |

## 8. Loadout rule already approved, flagged for final review

| # | Rule | Status |
| - | ---- | ------ |
| 8.1 | One Cant slot to start; Waymark II unlocks the second | Approved |
| 8.2 | Cants may be swapped only at designated safe anchors | Approved as the proposed rule, marked for final gameplay approval. It is enforced once anchors exist in the world |
