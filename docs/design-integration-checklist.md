# Canonical design integration checklist

Status: 2026-11-16. This document reconciles the original Black Meridian
design with the code that exists. No gameplay code was changed to produce
it.

**Update, same day (implementation).** The designer answered A1, A2,
A3, A7 and A8 in part, A10 and A11 in part, and the Verse behaviours and
cooldowns. Those answers are implemented; see `docs/task-log.md`,
"Implementation of approved decisions". The numbers still open are in
`docs/decision-sheet.md`, and six machine IDs in `docs/id-proposals.md`.
The approved answers, recorded here for traceability:

- A1: the report's ID format; IDs `cant.nearness`, `cant.embers`,
  `cant.second_voice`, `cant.still_water`, `near.close_step`,
  `near.draw_near`, `near.between_us`, `near.no_farther`. Other IDs are
  proposed separately.
- A2: no Cant has an ability of its own; Verses are the techniques.
- A3: one Cant slot to start, the second at Waymark II; only the first is
  built for the vertical slice. Swapping at designated safe anchors is the
  proposed rule, marked for final gameplay approval.
- Dissonance bands: 0–39 Stable or manageable, with minor Burden
  pressure; 40–64 noticeable visual and audio instability; 65–84 enemy
  and environmental reactions; 85–99 fractured events possible; 100 a
  controlled rupture determined by the region or encounter, never
  arbitrary permanent inventory loss. Rises through Verse use, certain
  Relics, unstable areas, enemy attacks and failed containment. Recovers
  through stable environments, anchors, camps, approved consumables,
  encounter completion and certain cooperative actions. Raw Dissonance
  normally resets or recovers between sessions. No player-triggered
  Dissonance actions until designed.
- Burdens are tied to Cants and are not stackable pickups. Unwanted
  Company: at higher Dissonance, hostile adjacency becomes more
  dangerous, increasing the threat of certain nearby attacks. Long Way
  Home: repeated Nearness movement without returning to stable ground
  builds an increasing recovery penalty.
- Close Step proposed tuning from the report: 16-stud range, 8
  Dissonance. Not locked canon.
- Starting story: Ash Quay, then Lantern Vault, where Nearness is
  acquired; Lantern Maw is the first boss; Waymark I — Branded comes after
  the required Descent objectives and the return with the discovered
  evidence. Acquiring Nearness and earning Waymark I are separate moments.

## 1. Sources and their rank

| Rank | Source | Where it is | How it is used |
| ---- | ------ | ----------- | -------------- |
| 1 | The 22-part Black Meridian research report | Not in the repository and not found on this computer | Primary design reference. Only the details the designer quoted from it on 2026-11-16 are available (section 2) |
| 2 | `docs/technical-plan-2.0.md` | Repository | Engineering tasks, security rules and gates. It contains no mechanics |
| 3 | "Codex blueprint" packages, 18 and 20 files, dated 2026-11-01 | `Documents/Codex/2026-11-01/…/black_meridian_codex_blueprint` and `…_repaired` | Older design documents. They conflict with the report (section 3). Nothing is taken from them |

Rules applied in this document:

- A value is canon only if it is in section 2.
- Where the older documents disagree with the report, the report wins and
  the disagreement is listed. Versions are never merged.
- Where the report excerpt is silent, the value is marked as needing
  approval, even if an older document or the current code has a number.
- A number in the code is not canon because it is in the code.

**Biggest unblocker:** add the 22-part report to the repository, for
example as `docs/design/report/part-01.md` to `part-22.md`. Most open rows
below are probably answered in it, and it could then be cited line by
line.

## 2. Confirmed canon

Source for every row: the designer, 2026-11-16, quoting the 22-part
report.

| Ref | Confirmed statement |
| --- | ------------------- |
| C1 | The four launch Cants are Nearness, Embers, Second Voice and Still Water |
| C2 | Cants are supernatural disciplines. Verses are their techniques |
| C3 | Close Step, ID `near.close_step`: 7-second cooldown. Shortens the path to a valid destination and lunges toward it |
| C4 | Draw Near, ID `near.draw_near`: 11-second cooldown. Pulls eligible enemies or objects toward an anchor |
| C5 | Between Us, ID `near.between_us`: 16-second cooldown. Creates a temporary adjacency tether |
| C6 | No Farther, ID `near.no_farther`: 24-second cooldown. Creates a zone that compresses escape distance |
| C7 | Nearness's default Burden is Unwanted Company |
| C8 | Nearness's alternate mastery Burden is Long Way Home |
| C9 | Dissonance bands: 0–39 Stable; 40–64 Noticeable instability; 65–84 Enemy and environmental reactions; 85–99 Fractured event risk; 100 Controlled rupture |
| C10 | Dissonance normally recovers in stable areas |
| C11 | Dissonance should not persist as a raw value across sessions |
| C12 | Ash Quay is the first region |
| C13 | Lantern Vault is the first Descent |
| C14 | Lantern Maw is the first boss |
| C15 | Players acquire Nearness through the introductory storyline |
| C16 | After completing the required Descent objectives, players earn Waymark I — Branded |

## 3. Conflicts with the older documents

These are listed so nothing is chosen silently. In every row the report
is followed and the older value is not used.

| Topic | 22-part report (followed) | Older Codex blueprint (not used) |
| ----- | ------------------------- | -------------------------------- |
| Nearness Verse names | Close Step, Draw Near, Between Us, No Farther | Foldstep, Drawn Edge, Return Arc, Close the Gap |
| Verse IDs | `near.close_step` style | `verse.foldstep` style |
| Verse cooldowns | 7 s, 11 s, 16 s, 24 s | Foldstep 6 s, Drawn Edge 9 s |
| Nearness Burdens | Unwanted Company (default), Long Way Home (alternate mastery) | Distance Repaid, Fixed Horizon, Borrowed Ground |
| Dissonance structure | Five bands on a 0–100 scale | Three tiers declared per region |
| How Nearness is acquired | Through the introductory storyline | A four-Cant choice in Lantern Vault |

Agreements, for the record: the four launch Cant names, Ash Quay,
Lantern Vault, Lantern Maw, and "I — Branded" for the first Waymark.

The older blueprint also gives numbers the report excerpt does not cover:
Dissonance cost per Verse, melee timings and stamina costs. They belong
to the other version's Verses and combat model. They are **not** used as
defaults; the matching rows below stay open.

## 4. Cant activation review

**Finding.** The code gives every Cant a standalone activation: one
cooldown, one cost and one effect per Cant (`Combat/Cants.luau`,
`activate`). Nearness has a placeholder kit there. The plan's wording for
BM-063, "Activation, cooldown, resource, and combat-state cases", led to
it.

**What the report says (C2).** A Cant is a discipline and its Verses are
the techniques. Every confirmed Nearness mechanic is a Verse (C3–C6) or a
Burden (C7, C8). Nothing confirmed describes Nearness doing anything by
itself.

**Conclusion.** The standalone activation is an engineering assumption
with no support in the confirmed design. It must not be finished as if it
were canon.

**Proposed change, needs approval (A2):**

- A Cant in the code becomes what it is in the design: an equipped
  discipline that decides which Verses can be cast and which Burden
  applies.
- `activate`, the `Kit` type, the placeholder Nearness kit and the
  `cant_activated` cue are removed, together with the play-test shortcut
  that calls them.
- BM-063 "Nearness functions throughout the vertical slice" is then met
  by: Nearness can be owned and equipped, its four Verses work, and its
  Burden applies. Its "activation, cooldown, resource" tests become the
  Verse tests.

Until A2 is answered the activation stays as it is today: unreachable
from any client and marked PLACEHOLDER.

## 5. Checklist

Status values:

- **Confirmed** — in section 2. Ready to implement.
- **Needs approval** — not established. Nothing will be assumed.
- **Decision** — the confirmed design and the code or plan do not fit;
  a choice is needed.
- **Engineering** — not a design matter. Listed so it is visible.

The **Ask** column refers to the approval sheet in section 6.

### 5.1 Content registry — BM-004

| # | Specification | Module | Status | Ask |
| - | ------------- | ------ | ------ | --- |
| 1 | Launch Cant names (C1) | `shared/Catalogs/Content.luau` | Confirmed | |
| 2 | Nearness Verse names and IDs (C3–C6) | `Content.luau` | Confirmed | |
| 3 | Nearness Burden names (C7, C8) | `Content.luau` | Confirmed | |
| 4 | Ash Quay, Lantern Vault, Lantern Maw (C12–C14) | `Content.luau` | Confirmed | |
| 5 | The first Waymark is "Waymark I — Branded" (C16). The registry calls it "Waymark I" | `Content.luau` | Confirmed | |
| 6 | ID format. The report writes `near.close_step`. The registry accepts only lower-case letters, digits and hyphens with a category prefix, for example `verse-…` | `shared/Catalogs/ContentRegistry.luau` (`ID_PATTERN`, prefixes), `Network/Validators/Schema.luau`, `Content/RewardCatalog.luau` (receipt segments) | Decision | A1 |
| 7 | The report's IDs for Cants, Burdens, regions, Descents, bosses and Waymarks | `Content.luau` | Needs approval | A1 |
| 8 | Verses and Burdens of Embers, Second Voice and Still Water | `Content.luau` and the three catalogs | Needs approval | A12 |
| 9 | Remaining inventory: other regions, quests, Waymarks II onward, other bosses and Descents | `Content.luau` | Needs approval | A12 |

Note on row 8: the catalogs refuse to start when a registered Cant has
no definition. Embers, Second Voice and Still Water can be registered now
only with definitions marked `provisional` and no Verses.

### 5.2 Cant registry and equipping — BM-062, BM-064

| # | Specification | Module | Status | Ask |
| - | ------------- | ------ | ------ | --- |
| 10 | Nearness is acquired through the introductory storyline (C15) | `Content/CantCatalog.luau` unlock rule; granted through `RewardService` | Confirmed | |
| 11 | Which quest or step of the introductory storyline grants it | `Content/RewardCatalog.luau` (one permanent reward) | Needs approval | A9 |
| 12 | How Embers, Second Voice and Still Water are acquired | `CantCatalog.luau` | Needs approval | A12 |
| 13 | How many Cants are equipped at once. The code assumes two slots and saves one | `CantCatalog.luau`, `Contracts/Payloads.luau` (`CantSlot`), `Validators/CantEquip.luau`, `Adapters/CantEquip.luau`, profile `cants.equipped`, `Services/Loadout.luau` | Needs approval | A3 |
| 14 | Whether any Cants exclude each other | `CantCatalog.luau` (`exclusiveWith`) | Needs approval | A3 |
| 15 | When a Cant may be changed (anywhere, at a Waymark, never in combat) | `Adapters/CantEquip.luau` | Needs approval | A3 |
| 16 | Which Verses a player has when Nearness is first acquired, and how the others unlock | `Content/VerseCatalog.luau` prerequisites, `RewardCatalog.luau` | Needs approval | A9 |

### 5.3 Nearness as a discipline — BM-063

| # | Specification | Module | Status | Ask |
| - | ------------- | ------ | ------ | --- |
| 17 | A Cant is a discipline; Verses are its techniques (C2) | `Combat/Cants.luau` | Confirmed | |
| 18 | Whether Nearness, or any Cant, has an ability of its own apart from its Verses | `Combat/Cants.luau` (`activate`, `Kit`, `PRODUCTION_KITS`) | Decision | A2 |
| 19 | Placeholder kit: 60-step cooldown, 20 stamina, no effect | `Combat/Cants.luau` | Not canon; removed under A2 | A2 |

### 5.4 Verse catalog and the four Nearness Verses — BM-065, BM-066, BM-067

Shared rows:

| # | Specification | Module | Status | Ask |
| - | ------------- | ------ | ------ | --- |
| 20 | Cooldowns are given in seconds (C3–C6). The catalog stores whole simulation steps | `Content/VerseCatalog.luau`, `Combat/Verses.luau` | Engineering: store seconds, convert with the simulation's step length | |
| 21 | Resource cost of each Verse, and which pool. Is there a resource besides health, stamina and posture? | `VerseCatalog.luau` (`costs`), `Combat/Resources.luau` | Needs approval | A4 |
| 22 | Dissonance gained per Verse | `Services/CombatService.luau` (placeholder: 10 per Verse) | Needs approval | A7 |
| 23 | Cast time of each Verse (instant or wind-up) | `VerseCatalog.luau` (`castSteps`) | Needs approval | A5 |
| 24 | What interrupts a cast and what is lost. The code interrupts on hit, stagger or death and keeps the cost and cooldown spent | `Combat/Verses.luau` | Needs approval | A5 |
| 25 | Whether a Verse can be cast during an attack, guard or dodge. The code requires the caster to be idle | `Combat/Verses.luau` | Needs approval | A5 |
| 26 | Whether Verses deal damage, and what the numbers scale with | new `Combat/VerseEffects`, `Combat/Damage.luau` | Needs approval | A6 |
| 27 | Whether bosses and elite enemies resist pulls, tethers and zones | new `Combat/VerseEffects`, enemy definitions | Needs approval | A6 |

Per Verse:

| # | Specification | Module | Status | Ask |
| - | ------------- | ------ | ------ | --- |
| 28 | Close Step: 7 s cooldown; shortens the path to a valid destination and lunges toward it (C3) | `VerseCatalog.luau`, new `Combat/VerseEffects` | Confirmed | |
| 29 | Close Step: how the destination is chosen (aimed point, direction, or a target), maximum range, what makes a destination valid, lunge speed, whether the player is protected during it | `Contracts/Payloads.luau` (`VerseCastPayload`), `Validators/VerseCast.luau`, `Services/CharacterService.luau` (server movement) | Needs approval | A6 |
| 30 | Draw Near: 11 s cooldown; pulls eligible enemies or objects toward an anchor (C4) | same | Confirmed | |
| 31 | Draw Near: what the anchor is, what "eligible" means, range, how far and how fast things are pulled, which objects (no pullable objects exist in the world yet) | same, plus `Combat/Ai.luau` (enemy positions) | Needs approval | A6 |
| 32 | Between Us: 16 s cooldown; creates a temporary adjacency tether (C5) | same | Confirmed | |
| 33 | Between Us: what is tethered to what, duration, what the tether does while it holds, how it breaks | new timed-effect layer | Needs approval | A6 |
| 34 | No Farther: 24 s cooldown; creates a zone that compresses escape distance (C6) | same | Confirmed | |
| 35 | No Farther: zone shape and size, placement, duration, exactly how escape distance is compressed, who is affected | new timed-effect layer | Needs approval | A6 |

### 5.5 Dissonance — BM-068

| # | Specification | Module | Status | Ask |
| - | ------------- | ------ | ------ | --- |
| 36 | Scale 0 to 100 with bands at 40, 65, 85 and 100, and their names (C9). The code uses placeholder thresholds 25, 50, 75, 100 and numbered levels | `Combat/Dissonance.luau` (`PROVISIONAL_TUNING`) | Confirmed | |
| 37 | Recovers in stable areas (C10). The code decays everywhere after a quiet period | `Combat/Dissonance.luau` | Confirmed in principle | |
| 38 | What counts as a stable area, and the recovery rate there. Whether anything recovers outside stable areas | `Combat/Dissonance.luau`; a "stable area" flag does not exist yet (world tasks) | Needs approval | A7 |
| 39 | Not saved as a raw value (C11). The code does not save it. The profile has an unused `burdens.dissonance` field | `Persistence/ProfileSchema.luau`, `Types/Profile.luau` | Confirmed | |
| 40 | What a player has on rejoining: zero, or a band carried over | `Services/Loadout.luau` or `CombatService.luau` | Needs approval | A8 |
| 41 | What raises Dissonance and by how much | `Services/CombatService.luau` | Needs approval | A7 |
| 42 | What each band does: "Noticeable instability", "Enemy and environmental reactions", "Fractured event risk", "Controlled rupture" | `Combat/Dissonance.luau`, `Combat/Ai.luau`, later world systems | Needs approval | A8 |
| 43 | Whether the player has Dissonance actions, their names and rules. The plan (BM-068) expects "canonical Dissonance actions"; the confirmed details name none | `Combat/Dissonance.luau` (`PRODUCTION_ACTIONS`), `Adapters/DissonanceAction.luau` | Needs approval | A8 |
| 44 | Whether other players see a player's Dissonance | `Combat/Replication.luau` | Needs approval | A8 |

### 5.6 Burdens — BM-069

| # | Specification | Module | Status | Ask |
| - | ------------- | ------ | ------ | --- |
| 45 | A Burden belongs to a Cant. Nearness has a default Burden and an alternate mastery Burden (C7, C8). The catalog has no link from Burden to Cant | `Content/BurdenCatalog.luau`, `shared/Catalogs/ContentRegistry.luau` (burden fields) | Confirmed | |
| 46 | What Unwanted Company does | `BurdenCatalog.luau`, new effect hook | Needs approval | A10 |
| 47 | What Long Way Home does, and what "mastery" requires | same | Needs approval | A10 |
| 48 | Whether exactly one Burden is active per equipped Cant | `BurdenCatalog.luau`, profile `burdens.active` | Needs approval | A10 |
| 49 | Catalog assumptions that the confirmed design does not support: acquisition from Descent, boss, quest or Waymark; 1 to 5 stacks; effects limited to stat modifiers | `BurdenCatalog.luau` | Decision | A11 |
| 50 | The plan's BM-070 "Burden offers" against a default Burden that comes with the Cant | plan task BM-070 | Decision | A11 |

### 5.7 Starting progression — later tasks, recorded now

| # | Specification | Task | Status | Ask |
| - | ------------- | ---- | ------ | --- |
| 51 | Waymark I — Branded is earned by completing the required Descent objectives (C16) | BM-075 | Confirmed | |
| 52 | Which Lantern Vault objectives are required | BM-075, BM-084 onward | Needs approval | A9 |
| 53 | The plan's BM-106 starter selection ("Nearness works by default") against C15 | BM-106 | Decision | A9 |

### 5.8 Combat core — BM-052 to BM-057

| # | Specification | Module | Status | Ask |
| - | ------------- | ------ | ------ | --- |
| 54 | Attribute names, derived stats and formulas | `Combat/Attributes.luau` | Needs approval | A13 |
| 55 | Resource pools and regeneration | `Combat/Resources.luau` | Needs approval | A13 |
| 56 | Action timings, costs, damage, guard and parry rules | `Combat/ActionMachine.luau`, `Damage.luau`, `Defense.luau` | Needs approval | A13 |

These are marked NOT CANON in the code. They do not block Nearness.

### 5.9 Engineering items the Verses need

None of these is a design question. All are new server-owned systems.

| # | Item | Module | Why |
| - | ---- | ------ | --- |
| 57 | Aim in the cast request: a point or direction, bounded and finite, treated as a hint | `Contracts/Payloads.luau`, `Validators/VerseCast.luau`, `Combat/Verses.luau` | Close Step, Draw Near and No Farther are not aimed at a single combatant |
| 58 | Server check that a destination is reachable and open | new world-query port, injected like the navigator | "Valid destination" (C3) |
| 59 | Server-moved characters that the movement check does not flag | `Services/CharacterService.luau`, `Combat/Simulation.luau` | Lunge and pull |
| 60 | Timed effects with an owner, targets and an end step | new `Combat/Effects` | Tether and zone |
| 61 | Replication of zones, tethers, cast state and cooldowns | `Contracts/CombatReplication.luau`, `Combat/Replication.luau`, client `CombatState` | Nothing can be shown or predicted without it |
| 62 | Client input: bindings for four Verses and aim | new client module | The client sends no gameplay input today |

## 6. Approval sheet

Short answers are enough. Where the report has the answer, pasting that
part is best. A1 to A8 are needed to finish Nearness, its Verses and
Dissonance. A10 and A11 are needed for the first Burden.

| Ask | Question | Blocks |
| --- | -------- | ------ |
| A1 | **IDs.** Use the report's IDs exactly (`near.close_step`) and change the registry to accept them? If yes, what are the report's IDs for the Nearness Cant, the two Burdens, Ash Quay, Lantern Vault, Lantern Maw and Waymark I? No player data exists yet, so the two IDs in use (`cant-nearness`, `waymark-i`) can still be renamed for free | Registering anything |
| A2 | **Cant activation.** Confirm that a Cant has no ability of its own and is used only through its Verses, so the standalone activation is removed | BM-063 |
| A3 | **Loadout.** How many Cants are equipped at once? Can a player change Cant, and where? | BM-062, BM-064 |
| A4 | **Costs.** What does each of the four Verses cost, and from which resource? | BM-066 |
| A5 | **Casting.** Is each Verse instant or does it have a cast time? Can it be cast mid-attack? Does being hit interrupt it, and is the cooldown or cost lost? | BM-066, BM-067 |
| A6 | **Verse details.** For each Verse the items in rows 26 to 35: range, targeting, duration, strength, damage, and how bosses react | BM-066 |
| A7 | **Dissonance gain and recovery.** What raises it and by how much? What is a stable area, and how fast does it recover there? | BM-068 |
| A8 | **Dissonance effects.** What does each band do? Are there player Dissonance actions? What does a player have on rejoining? Is it visible to others? | BM-068 |
| A9 | **Acquisition.** Which introductory step grants Nearness, which Verses come with it, how the rest unlock, and which Lantern Vault objectives are required for Waymark I | BM-064, BM-075, BM-106 |
| A10 | **Nearness Burdens.** What do Unwanted Company and Long Way Home do? Is exactly one active at a time? What does mastery require? | BM-069 |
| A11 | **Burden model.** Are Burdens only ever tied to a Cant (default plus alternates), or are some also offered during play, as BM-070 assumes? Can a Burden stack? | BM-069, BM-070 |
| A12 | **Other Cants.** Verses, Burdens and acquisition for Embers, Second Voice and Still Water. Not needed for the vertical slice | Full BM-062, BM-065 |
| A13 | **Combat core.** Confirm or replace attribute names, pools, formulas and timings | Acceptance of BM-052 to BM-057 |

## 7. What can be implemented from confirmed canon alone

Once this checklist is agreed, these need no further approval:

- Dissonance bands at 40, 65, 85 and 100 with their names (row 36).
- Dissonance is never saved (row 39). The unused profile field is left at
  zero and removed in the next schema migration.
- The Burden-to-Cant link in the catalog schema (row 45).
- Cooldowns in seconds in the Verse catalog (row 20).
- The engineering items in 5.9, built and tested with fixture Verses.

These need only A1 (the ID decision):

- Registering the four Cants, four Nearness Verses, two Burdens, Ash
  Quay, Lantern Vault, Lantern Maw and Waymark I — Branded.

Everything else waits for the answers in section 6. The exact code
changes are in `docs/implementation-plan-bm-062-069.md`.
