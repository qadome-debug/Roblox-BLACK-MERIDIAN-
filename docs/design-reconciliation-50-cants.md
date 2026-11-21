# Design reconciliation and consistency audit: the 50-Cant research

Status: 2026-11-21. **An audit only. No game code, test, schema, catalog or
demo was changed to produce it.** Nothing in the 50-Cant research is treated
as approved. BM-070 stays on hold.

## 0. What was compared

| Short name | What it is | Where it stands |
| ---------- | ---------- | --------------- |
| **22-part report** | "Comprehensive Game Development and Codex Implementation Blueprint", dated 2026-11-09, Parts 1 to 22 | The design the confirmed canon (C1 to C16) was quoted from. Names, IDs and cooldowns in it match the repo. It had not been available to me before; this audit is the first time I read it whole |
| **Technical Plan 2.0** | The 136-task engineering plan | Already in the repo as `docs/technical-plan-2.0.md`. Task numbers here are the repo's numbers |
| **50-Cant research** | "Definitive 50-Cant RPG, Progression, Transformation, Lineage, and Roblox Implementation Blueprint", 23 parts | A proposal. Its own text says nothing was implemented and the repo was not inspected |
| **Repo** | `main` at `331017d` | Inspected for this audit: `Combat/Attributes`, `Combat/Dissonance`, `Combat/BurdenEffects`, `Content/*`, `Persistence/ProfileSchema`, `Types/Profile`, `Limits`, `Services/Loadout`, `Network/Adapters/CantEquip`, `docs/*` |

Two things the 22-part report settles that I had listed as missing last
time. Its Part 8 gives the Verse names, IDs, cooldowns, modifiers and both
Burdens for Embers, Second Voice and Still Water. Its Part 20 is the
original 96-task register, which the 50-Cant research says is unavailable.
Both are used below.

## 1. Result in brief

1. **The 50-Cant research changes the progression model, not just the
   content.** Three of its headline decisions contradict approved canon or an
   approved decision: character levels and XP (the 22-part report says
   "Waymark-based rather than conventional levels"), exactly one primary Cant
   (approved A3: a second slot at Waymark II), and a random behavior-weighted
   awakening (canon C15: Nearness is acquired through the introductory
   storyline). None of the three can be adopted without your decision.
2. **Your six suspected stat totals are correct, and no other Cant has a
   wrong total.** I parsed all 50 dossiers. Second Voice and Empty Hand sum
   to 13; True Name, Hush, Pale Ink and Cold Witness sum to 11. I also found
   a swapped primary and secondary (Returned Blow) and unfinished drafting
   text in two dossiers (section 4).
3. **The new Dissonance persistence proposal conflicts with canon C11**
   ("should not persist as a raw value across sessions").
4. **The new "death clears temporary Burden stacks" rule conflicts with your
   2026-11-21 instruction** not to clear supernatural state on production
   death until it is designed.
5. **The 50-Cant research claims an anti-relog policy already exists.** It
   does not. A rejoining player gets fresh state today. That is a known gap.
6. **Cants 11 to 50 are not implementable from the text.** Verse IDs,
   modifier IDs, Burden IDs, cast times, most Waymark unlock lists and the
   acquisition weights are missing (section 5).
7. **The working code is compatible with a careful rollout.** The profile
   stores one equipped Cant, so one primary Cant needs no schema change. The
   attribute layer is isolated and labelled "not canon". The secure
   networking, leases, receipts and the lifecycle fix are untouched by any
   proposal if the sequence in section 9 is followed.

## 2. Direct conflicts with approved canon or approved decisions

Each row needs your decision. Section 8 gives the numbered decisions.

| # | Topic | 22-part report / approved | 50-Cant research | Effect if adopted blindly |
| - | ----- | ------------------------- | ---------------- | ------------------------- |
| D1 | Character levels | "Waymark-based rather than conventional levels"; "Generic XP levels" rejected in its design table; ordinary enemies are not the primary XP source "because the game does not use conventional XP levels" | Level 60, XP curve, 118 attribute points | A different game loop. Adds a third progression track and an XP economy that must go through the reward path |
| D2 | One Cant or two | Approved A3 and `CantCatalog`: one slot at start, a second at Waymark II. Waymark II unlocks "second Cant slot/build layer" | Exactly one primary Cant. No second primary, ever | The Waymark II reward disappears. `CantCatalog` slots `primary`/`secondary` lose their second use. Waymark II needs another reward |
| D3 | How Nearness is acquired | C15: through the introductory storyline. First 30 minutes: "acquired Nearness, used one Verse in combat and one in traversal" | A behavior vector and a weighted random draw at the first Descent. Nearness is one of 50 possible results | The vertical slice (BM-063, 066, 075, 096) assumes Nearness. A random draw cannot guarantee it |
| D4 | Verse unlock pace | Two Verses by about 30 minutes; the vertical slice implements the Nearness Verses "required by the vertical slice" | Waymark I unlocks Verse 1 only. Verse 2 at II, Verse 3 at III, Verse 4 (No Farther) at IV | The slice would have one Verse, not two or four. The demo (Studio only) is unaffected |
| D5 | Dissonance persistence | C11: not persisted as a raw value | A `DissonanceCheckpoint` (value, band, time) written at 40, 65, 85, 100 and on transitions; rejoin restores the higher of the last checkpoint and a session handoff | Needs C11 amended, a schema change, and a clock/exploit design |
| D6 | Dissonance recovery | C10: recovers in stable areas. Checklist row 37 already judged "decays everywhere after a quiet period" wrong | Natural decay after 20 s idle, 1 per 6 s, down to 40, anywhere | Reintroduces the rule row 37 removed |
| D7 | Death and Burden stacks | 2026-11-21: production death must not auto-clear Dissonance or cooldowns; design it carefully. Code keeps Burden penalty and moves across respawn | "Death clears temporary Burden stacks but not the selected Burden" | A Long Way Home player could die to shed the penalty, the loophole you named |
| D8 | Burden assignment | A Cant has a default Burden; the alternate comes through mastery (checklist C7, C8; `BurdenCatalog` roles `default`/`mastery`) | Two Burdens scored at awakening; the higher is offered first, a bounded random draw can pick the second; the alternate is discoverable at mastery 15 | The `default`/`mastery` roles stop describing reality. BM-070 "Burden offers" is still unresolved |
| D9 | Nearness numbers | Approved as initial balance (`NearnessTuning`). No Farther was changed after your hands-on test to a 20-stud, 40%, all-direction slow | Preserves "10-stud radius, 50% outward" and different costs (section 6) | The research would silently undo your latest change |
| D10 | Unwanted Company | `docs/unwanted-company-proposal.md`: attention, tempo and crowding by Dissonance band; unapproved | Attention mark 8 s, +15% target weight, +8% posture damage within 8 studs | Two competing unapproved proposals |
| D11 | Cooldowns | 22-part report: Hearthless Sun 26 s, Chorus of One 28 s | 27 s and 29 s | Two cooldowns disagree by one second |
| D12 | Close Step Dissonance | 22-part report example: 8 | 6 (and stamina 16, cast 0.12 s) | See section 6 |
| D13 | Cooldown persistence | Known gap: "Verse cooldowns reset when a player rejoins" | Store small absolute expiry timestamps at session close and major checkpoints | Needs a design (see section 7) |

## 3. Conflicts with the existing code and schema

| # | Area | Repo today | 50-Cant research | Verdict and safe handling |
| - | ---- | ---------- | ---------------- | ------------------------- |
| C1 | Attributes | Four: `vigor`, `might`, `grace`, `will`. Marked "NOT CANON". 8 derived stats. 37 references in 9 files | Six: Might, Agility, Vitality, Endurance, Focus, Resolve | Replaceable. Contained in `Combat/Attributes.luau` and its tests. Only `might` keeps its name. Needs your approval of the six names and formulas first (D-A in section 8) |
| C2 | Starting numbers | Health 200, stamina 140 at base 10 | Health 100, stamina 100 at base 10 | **Every number sized against today's pools moves.** Nearness stamina costs 15 to 30 are 11% to 21% of 140 but 15% to 30% of 100. Enemy damage tests move. Rebalance is a task, not a side effect |
| C3 | Posture, stamina, guard | Posture exists in `Resources` | Heavy use of posture; separate Guard stat (`70 + 2.5 END + 0.7 MIGHT`) | Guard is not a separate resource today. Decide whether it is a new pool or a derived cap |
| C4 | Profile schema | Version 4. Has `cants {unlocked, equipped, verses}`, `burdens {discovered, active, dissonance}`, `waymarks` map, `receipts`. No level, XP, allocation, mastery, transformation, lineage or checkpoint | All of those added | A migration to schema 5 is required. No production data exists (nothing published), so the "existing Nearness account" branch of the proposed migration has nothing to migrate. The unused `burdens.dissonance` field was already scheduled for removal in the next migration; D5 would reuse or replace it |
| C5 | Profile limits | `MAX_UNLOCKED_CANTS = 32`, `MAX_VERSE_UNLOCKS = 128`, `MAX_DISCOVERED_BURDENS = 64`, `MAX_PERMANENT_RECEIPTS = 1024` | 50 Cants, 200 Verses, 100 Burdens | Not a problem under one primary Cant per character. It becomes one if the profile ever lists all Cants as "unlocked". Raise nothing until D2 is decided |
| C6 | Waymark model | Waymarks are IDs in a map; `waymark.branded` is rank 1 | Waymark is a single rank 0 to VI plus `completedTrials` | Keep the map and derive the rank as the highest activated rank. Only `waymark.branded` has an ID; II to VI need IDs (decision D-F) |
| C7 | Cant equip | `CantEquip` lets a client equip or unequip any unlocked Cant (primary slot only is backed) | The awakening commit is "not client-callable" | If one primary Cant is adopted, `CantEquip` becomes a restricted or removed surface. It is a validated adapter today, so it is not a security hole, but it is a feature that contradicts the new model |
| C8 | Verse unlock | `cants.verses[cantId][verseId]`, grantable through `RewardCatalog` `Grants.verses` | Verses unlock by Waymark and mastery | Compatible. Gating by Waymark is a rule in data, not a schema change |
| C9 | Receipts | `p:<sourceKind>:<sourceId>:<rewardId>` and `s:...`, 64-byte limit, from `RewardCatalog` | `xp:quest:<questId>:<player>`, `awakening:...`, `lineage:...` | Do not add a second receipt grammar. Map each proposed receipt to the existing format by adding source kinds (`awakening`, `mastery`, `lineage`) and an `xp` grant. The `<player>` part is redundant inside one player's profile and would put a user ID into stored keys |
| C10 | Content registry | Categories: chapter, region, quest, cant, verse, burden, waymark, boss, descent. `launchRequired` per item | Adds Lineages, Waymark III to VI, transformations, modifiers, passives | New categories need your ID-format approval. `lineage.bellbound` matches the existing dotted style |
| C11 | Launch scope | 4 launch Cants (`launchRequired = true`) | BM-120 fails unless all 50 Cants are complete | See decision D-C. This is the largest scope question |
| C12 | Burden state | `burdens.active` is a list up to 8 | One active Burden | Tighten to one later. No effect now |
| C13 | Mastery | Only a boolean (`masteryUnlocked`) for the Long Way Home choice | Mastery levels 1 to 30 per Cant | Mastery is a new system. Keep the boolean working until it exists |
| C14 | Band names | `Stable`, `Noticeable instability`, `Enemy and environmental reactions`, `Fractured event risk`, `Controlled rupture` (canon) | `Stable`, `Distorted`, `Reactive`, `Fractured`, `Rupture` | Keep the canon names. Treat the new names as nicknames only |
| C15 | Dissonance recovery numbers | `PRODUCTION_TUNING`: stable 5 per second, camp 30, consumable 20, encounter 20, cooperative 10, rupture reset 60 | Anchor to 10, safe hub to 0, field camp up to 25 but not below 20 inside a Descent, consumables 10 to 20 | The rupture reset matches (60). Everything else differs and is unapproved on both sides. No change now |

## 4. Attribute-budget audit

Method: I parsed the "Stats" and "caps" string of every dossier and checked
the sum, the 5/3/2/1/1/0 shape, the caps shape (one 60, one 55, four 50), and
the primary/secondary against the overview table. The 22-part report has no
attribute system, so there is nothing to compare against.

**Confirmed: the six Cants you named.**

| # | Cant | Bonuses M/A/V/E/F/R | Sum | Primary / secondary (caps) | Smallest one-point correction (PROPOSAL) | Alternative |
| - | ---- | ------------------- | --- | -------------------------- | ---------------------------------------- | ----------- |
| 3 | Second Voice | 1/3/1/1/2/5 | **13** | Resolve / Agility | Might 1 to 0 gives 0/3/1/1/2/5 (the exact shape 5/3/2/1/1/0) | Vitality 1 to 0 |
| 23 | Empty Hand | 1/5/1/0/1/5 | **13** | Agility / Resolve | Two +5 values, but Resolve is the secondary (cap 55), so it should be 3. Resolve 5 to 3 gives 11, then Focus +1: 1/5/1/0/2/3 | Might +1 instead of Focus |
| 6 | True Name | 0/1/1/1/3/5 | **11** | Resolve / Focus | Endurance 1 to 2 gives 0/1/1/2/3/5 | Agility or Vitality +1 |
| 7 | Hush | 0/5/1/1/1/3 | **11** | Agility / Resolve | Focus 1 to 2 gives 0/5/1/1/2/3 | Endurance +1 |
| 14 | Pale Ink | 0/1/1/1/5/3 | **11** | Focus / Resolve | Endurance 1 to 2 gives 0/1/1/2/5/3, the shape Dead Reckoning, Lost Hour and Ninefold Light already use | Agility or Vitality +1 |
| 29 | Cold Witness | 0/1/1/1/3/5 | **11** | Resolve / Focus | Endurance 1 to 2 gives 0/1/1/2/3/5 | Agility or Vitality +1 |

The corrections are proposals. Which stat gets the point is a design choice
(it changes the character), so none is applied. True Name and Cold Witness
have identical wrong strings, which suggests one copied template, not two
separate mistakes.

**Additional findings, not in your list.**

| # | Finding | Detail |
| - | ------- | ------ |
| 22 | Primary and secondary swapped | The overview table says Endurance / Might. The dossier gives Might +5 and caps 60/50/50/55/50/50, so Might is primary and Endurance secondary. The table is probably the error |
| 35 | Unfinished drafting text | Rust Gospel reads "1/0/1/1/5/5? would exceed budget, so finalized 1/0/1/2/5/3". Final value sums to 12 and matches the table |
| 38 | Unfinished drafting text | Dead Reckoning reads "0/1/1/1/5/5? corrected 0/1/1/2/5/3". Final value sums to 12 |
| 2, 11, 15, 18, 31 | Non-standard shape, still 12 | 5/3/1/1/1/1 (Embers, Threshold, Borrowed Shape, Rain Debt) and 5/4/1/1/1/0 (Borrowed Breath). Allowed by "a few Cants use another arrangement", but Borrowed Breath's secondary is +4 not +3 |
| all | Caps are consistent | All 50 have caps of exactly 60, 55, 50, 50, 50, 50 |
| all | Primary holds the +5 | In every Cant the cap-60 attribute has the largest bonus |
| 24 of 50 | Identical bonus profile to another Cant | 11 shared profiles (for example Dead Reckoning, Lost Hour, Ninefold Light). Not an error. It means identity rests on Verses, not on stats. 39 of 50 follow the exact 5/3/2/1/1/0 shape |
| Verified | XP curve | The formula, the table and the 253,806 total agree on every row (script check, 0 mismatches). 59 level-ups give 118 points. 60 + 12 + 118 gives 190 |

## 5. Missing implementation detail in Cants 11 to 50

Counted from the text. "Of 50" means all dossiers; the shorter dossiers
(11 to 50) are the weak part.

| Needed to implement | State in the research |
| ------------------- | --------------------- |
| Verse IDs | Present for Cants 1 to 3 only (`near.`, `ember.`, `voice.`). Still Water's IDs (`water.*`) are in the 22-part report, not here. **Cants 5 to 50 have none**, so no namespace can be checked for uniqueness |
| Modifier IDs, passive IDs, form IDs, ultimate IDs, Burden IDs | None for any Cant (400 modifiers, 50 passives, 150 form entries, 100 Burdens are names only) |
| Cast time per Verse | Complete for 3 Cants (1, 2, 4). Partial for several others. Absent for most of 11 to 50 |
| Verse stamina, Dissonance, cooldown | Present for all but one Verse. **Quiet Crown's Trespass has none** ("CD passive per target") |
| Waymark I to VI unlock list | Explicit for Cants 1 to 6 and 11 only (7 of 50). The universal skeleton fills the rest only in outline |
| Transformation stamina cost | Given for Nearness and Embers only. The others have duration, cooldown and Dissonance but no stamina cost |
| Ultimate duration, cooldown, cost | Cooldown and cost are absent for nearly all; "8s/120s" appears for Nearness only |
| Acquisition category and weights | Category named for 8 Cants (4 open, 1 narrow, 3 veiled) against a target of 25 / 15 / 10. **The weight matrix `w_cj` for 50 Cants is absent.** Without it the awakening cannot be implemented. Eligibility predicates are absent too |
| Burden rules | Only Nearness's two Burdens have the full set the research itself demands (trigger, consequence, reset, Dissonance link, form link, multiplayer). The other 98 are one line each; many have no number |
| Mastery trials | The unlock table is generic. No Cant has its own mastery events or challenges |
| Dissonance band effects per Cant | Only Nearness has them |
| Assets and tests | Asset lists for a few Cants and test lists for a minority (counted by text search, so approximate) |
| Dissonance range check | The category table gives "major zone/support" 10 to 14, but about 24 Verses cost 15 or 16 |
| Transformation envelope check | All 50 forms sit inside the stated envelope (14 to 22 s, 75 to 120 s, 12 to 24 Dissonance). 48 parsed by script; Nearness and Embers are worded differently and I checked them by hand |
| Boss rule | Stated once as a global rule. Per-Cant boss substitutions exist for most dossiers, not all |

## 6. Nearness: what the code holds against what the research restates

The research says the reported prototype values "should not be silently
replaced". Current code holds your approved values and your 2026-11-21 change.

| Verse | Cooldown | Cast time | Stamina | Dissonance | Range / effect |
| ----- | -------- | --------- | ------- | ---------- | -------------- |
| Close Step | 7 s (same) | **0** in code; 0.12 s in research | 15; research 16 | **8** (matches the 22-part report); research **6** | 16 studs (same) |
| Draw Near | 11 s (same) | 0.2; research 0.25 | 20 (same) | 10; research 9 | 20 studs, pulled to 4 (same) |
| Between Us | 16 s (same) | 0.3 (same) | 25; research **22** | 12; research 11 | 8 studs, 6 s (same) |
| No Farther | 24 s (same) | 0.4; research 0.45 | 30 (same) | 15; research 14 | **Code: radius 20, all movement slowed to 40%. Research: radius 10, outward movement 50%** |

Recommendation: keep the code values as the approved baseline. Record the
research values as "candidates" in a balance table for a later playtest. The
research's own audit line still lists No Farther as 10 studs and 50%; it needs
updating before it is used again.

Not built, listed so nothing is assumed: the passive Shorter Than It Looks,
the eight Verse modifiers, the Folded Walker form, the evolved form, the
ultimate All Roads Touch, and the Waymark-based Verse gating.

## 7. Death, respawn, Burden, Dissonance and reconnect

| Rule | Approved or built now | 50-Cant research | Reconciliation |
| ---- | --------------------- | ---------------- | -------------- |
| Production death | `respawnPlayer` revives. Dissonance, cooldowns, Burden penalty and lingering effects are kept. Open design question | Death clears temporary Burden stacks, keeps the selected Burden | **Conflict (D7).** Keep today's behavior until the death design is approved. Do not add a Burden-stack clear |
| Studio demo H reset | Full wipe of health, stamina, Dissonance, cooldowns, Burden state. Studio only | Not addressed | Unchanged. Keep isolated |
| Reconnect | `removePlayer` forgets everything. Rejoin is fresh state (Dissonance 0, cooldowns reset). Known gap | Claims an anti-relog policy already prevents escape; proposes checkpoints | **The claim is wrong for this repo.** The gap is real. The checkpoint design (D5) is the proposed fix and needs C11 amended |
| Selected Burden | Saved on the profile | Persists across death and sessions | Compatible |
| Temporary Burden stack across rejoin | Lost today | "Carried in trusted handoff or reset only if no exploit" | Undecided in the research. Needs the same design as Dissonance |
| Transformation on death, teleport, reconnect | No transformation exists | Ends; clears cosmetics; remaining cooldown reconstructed from a bounded value | No conflict. Compatible with the lifecycle fix. Needs the cooldown design |
| Rupture | Reset to 60, placeholder | Reset to 60 recommended, severity by region, Cant, Burden, party, recent ruptures | Consistent. Severity rules need approval |
| Resolve and Dissonance | None | Resolve reduces consequences, never gain | No conflict |

A design principle your 2026-11-21 instruction implies and the research also
states: **dying or rejoining must not remove supernatural consequences that
staying alive would have kept.** The simplest rule that meets it is that a
player never ends up with less Dissonance, fewer active cooldowns or a lighter
Burden penalty after dying or rejoining than if they had stayed alive, except
through a sanctioned recovery (stable area, anchor, camp). Production does
this for death now. For reconnect it needs persistence, which is D-G and D-H.

## 8. Decisions requiring your approval

I give a recommendation for each. Nothing is implemented until you answer.

**Direction (blocks everything else).**

| # | Decision | Recommendation |
| - | -------- | -------------- |
| D-A | Adopt character levels and six attributes, replacing the "Waymark-only" canon? | Adopt as a design proposal only after you confirm the 22-part report's "no conventional levels" line is superseded. If yes, change nothing in combat until the formulas are approved |
| D-B | One primary Cant per character, replacing the second slot at Waymark II? | Yes if you want it, but then name the new Waymark II reward. `CantEquip` and the `secondary` slot are retired or narrowed |
| D-C | How many Cants are launch-required? | Keep 4 launch Cants (`launchRequired`) and mark the other 46 as planned, not launch. A BM-120 that needs 50 Cants is a multi-year gate |
| D-D | Awakening: random behavior draw, guaranteed Nearness for the vertical slice, or both? | Slice guarantees Nearness through a scripted first Descent; the behavior draw is a later, separate task. This keeps BM-063, 066, 075 and 096 unchanged |
| D-E | Verse unlock pace: Verse 1 at Waymark I (research) or two Verses early (22-part report)? | Follow the 22-part report for the slice: two early Verses. Decide the full per-Waymark schedule with D-D |
| D-F | IDs for Waymarks II to VI and the new categories (lineage, transformation, modifier, mastery) | Approve a pattern first, e.g. `waymark.anchored`, `lineage.bellbound` |

**Rules that touch canon or your 2026-11-21 instruction.**

| # | Decision | Recommendation |
| - | -------- | -------------- |
| D-G | Amend C11 to allow checkpoint persistence of Dissonance (band-level, at 40/65/85/100 and major transitions)? | Yes, if you want relog-proof Dissonance, but as its own task with a rejoin allowance you approve |
| D-H | Persist cooldowns at session close? | Same task as D-G. Only for cooldowns that matter (Verses, transformation); never every cast |
| D-I | Death: what clears, what stays? | Keep current production behavior. Design the rule with D-G and D-H, not before |
| D-J | Dissonance quiet-time decay (1 per 6 s to 40)? | No, unless you want to overturn row 37 and C10 |
| D-K | Burden assignment: default plus mastery alternate (22-part report), or weighted pair (research)? | Keep the 22-part report model until BM-070 is designed; adopt the weighted pair only with D-D |
| D-L | Which Unwanted Company: the repo proposal or the research version? | The research version is more specific; replace the repo proposal if you approve it. Neither is built |
| D-M | Long Way Home trigger: every Close Step (built) or a repeat before 4 s grounded (research)? | Keep built behavior until you approve. The research adds decay rules and a Dissonance link that do not exist yet |

**Numbers and corrections.**

| # | Decision | Recommendation |
| - | -------- | -------------- |
| D-N | The six stat-budget corrections in section 4 | Approve each, or give your own. Also confirm Returned Blow is Might primary |
| D-O | Cooldown disagreements (Hearthless Sun 26 vs 27, Chorus of One 28 vs 29) | Use the 22-part report's values until you say otherwise |
| D-P | Nearness numbers: keep the code values as baseline? | Yes (section 6). Research numbers become candidates |
| D-Q | Attribute formulas and the starting pools (health 100, stamina 100) | Approve only after D-A. Rebalance as a dedicated task |
| D-R | Respec, allocation locations, preset slots, mastery thresholds | Defer; they only matter after D-A |

**Housekeeping.**

| # | Decision | Recommendation |
| - | -------- | -------------- |
| D-S | Add the 22-part report to the repository? | The checklist called this the biggest unblocker. The repo's GitHub visibility is not something I can check from here, so tell me whether it is private first |
| D-T | Fill the missing Cant 11 to 50 fields (section 5) | Do it with the Cants you schedule, a batch at a time |
| D-U | Task numbering: use the repo's 136 numbers; the 22-part report's Part 20 uses its older 96 numbers | Yes. See section 10 |

## 9. Updated implementation order (smallest safe sequence)

Nothing below starts until you approve the decision that gates it. BM-070
stays on hold throughout. Steps before level work change no behavior.

| Step | Work | Gate | Touches | Risk |
| ---- | ---- | ---- | ------- | ---- |
| 0 | Test the current demo and answer D-A to D-F | You | nothing | none |
| 1 | Record approved IDs and the six corrections as data; update `content-registry.md` and `id-proposals.md` | D-F, D-N | docs and `Content.luau` | low |
| 2 | Level and XP as **pure logic with tests only**: the curve, level from total XP, point count. No profile field yet | D-A | new pure module | none (not connected) |
| 3 | Profile schema 5 migration: level, XP, allocations, and removal of unused `burdens.dissonance`. Reuse the existing migration framework and fixtures. Every receipt preserved | D-A, D-Q | `ProfileSchema`, `Migrations`, `Limits` | medium; migration tests are the gate |
| 4 | XP award path **through RewardService and the existing receipt format**. Add an `xp` grant and source kinds. No new remote | D-A | `RewardCatalog`, `Grant` | medium; BM-046/050 tests must still pass |
| 5 | Six attributes and derived stats replacing the four engineering defaults, behind a rebalance pass for Nearness costs and enemy values | D-A, D-Q | `Combat/Attributes`, tests | medium; moves every number sized against 140 stamina |
| 6 | Allocation action (`AllocateAttributes`): server-validated, safe location only, through the existing dispatcher | D-A, D-R | adapters | medium; needs anchors |
| 7 | Waymark rank derived from the existing map; Waymark ceilings and Cant caps as pure checks | D-F | pure module | low |
| 8 | Nearness verification pass against the new model, no Verse rewrite. Verse gating by Waymark through rewards | D-E, D-P | `Loadout`, `Content` | low |
| 9 | Dissonance and cooldown persistence design and implementation | D-G, D-H, D-I | `ProfileSchema`, `CombatService` | high; closes the relog loophole |
| 10 | Burden reconciliation (default, alternate, stacks, Unwanted Company) | D-K, D-L, D-M | `BurdenCatalog`, `BurdenEffects` | medium |
| 11 | Mastery | D-A | new | medium |
| 12 | Awakening and Cant commit | D-B, D-D | new service, receipt-backed | high |
| 13 | Transformation lifecycle proof, then Folded Walker | steps 5 to 9 done | new service | high |
| 14 | Remaining Cants, in batches of 5 to 8, each certified before the next | D-C, D-T | registry and resolvers | content volume |
| 15 | Lineages | after step 14 first batch is stable | new | low risk, large content |

Steps 2 and 7 are the only ones that need no existing code to change. Steps 3
and 9 are the only ones that change what is saved.

## 10. Reconciling the task backlog

The repo uses the 136 numbers of Technical Plan 2.0. The 22-part report's Part
20 uses an older 96-task register, with different numbers for the same work.
Examples: its BM-058 to 061 are the four Nearness Verses (repo: BM-066), its
BM-064 is Lantern Maw (repo: BM-095), its BM-075 is Waymark I (same in both).
**Nothing is renumbered.** Any citation of a task number from the 22-part
report must be read against the 96 register, not the repo's log.

**No completed task is re-marked.** Current status in `docs/task-log.md` is
unchanged: 61 of BM-001 to BM-069 Built, 8 Framework (needing design), and
BM-070 onward not started. The research's child tasks are new and all "not
started".

| Research child family | Parent | Notes |
| --------------------- | ------ | ----- |
| `BM-052/LEVEL`, `/XP`, `/ATTR` | BM-052 (Built on four engineering-default attributes) | BM-052 stays Built. If D-A is approved, the children reopen the parent's content. `/XP` needs BM-050 (reward integrity), already in place |
| `BM-062/C:<cantId>` | BM-062 (Framework) | Compatible. BM-062's "slots" wording conflicts with D-B |
| `BM-065/V`, `BM-069/B`, `BM-102`, `BM-103`, `BM-104`, `BM-105` | as stated | Compatible. Need the missing IDs in section 5 |
| `BM-075/AWAKEN` | BM-075 | Conflict with BM-075's dependency on BM-063 and BM-066 (Nearness first). See D-D |
| `BM-111/W`, `/T`, `/U` | BM-111 | Compatible. BM-111 depends on BM-078 and BM-102 |
| `BM-121/L:<lineageId>` | BM-121 | **Semantic mismatch.** BM-121 is "endgame unlocks and post-campaign progression" and depends on BM-120. The Lineage clue chains need regional quests and bosses that belong to BM-097 to BM-099. Recommend a new child family under BM-099, not BM-121 |
| `BM-129/FORM`, `BM-131/VFX`, `BM-134/CONTENT` | as stated | Compatible |
| BM-064 `CantEquip` | BM-064 | Needs rewording under D-B |
| BM-070 `BurdenChoice` | BM-070 | Needs rewording under D-K. Still on hold |

The gates BM-016/020, BM-046/050, BM-075/078, BM-096, BM-120, BM-130 and
BM-136 are unchanged by anything above, except BM-120 under D-C.

## 11. What stays protected

These are not touched by any step before the gates in section 9:

- Server-authoritative design; no client-authoritative state; no reward or
  state-changing remotes; every request through the dispatcher.
- Profile leases, fences, reward receipts, uncertain-write recovery and
  receipt archiving, and their tests.
- The lifecycle fix: `respawnPlayer` revives, links death to the character,
  and keeps supernatural state in production. The Studio-only demo reset (H)
  stays isolated.
- Nearness as the architectural reference and the Studio demo with its 20-stud
  No Farther.
- The isolation checks (production never mentions the play-test harness).

## 12. What was verified, and what was not

Verified: the XP table against its formula; every stat total, cap shape and
primary/secondary string; the existing code and schema facts quoted above by
reading the files; the 22-part report's statements by reading them.

Not verified: any balance number, any Cant's playability, any claim in the
research about Roblox behavior, art or audio scope, mobile performance, and
anything needing a real DataStore, multiplayer or visual test. Nothing here is
gameplay acceptance.
