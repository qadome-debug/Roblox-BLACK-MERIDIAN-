# Implementation plan — BM-062 to BM-069

Status: 2026-11-16. A plan, not a record of work done. No gameplay code
has been changed. It follows `docs/design-integration-checklist.md`;
"C" numbers are confirmed canon there, "A" numbers are open approvals,
and "row" numbers are checklist rows.

Order agreed with the designer: Nearness and its four Verses, then
Dissonance, then the first Burden, then BM-070.

## 1. Rules that do not change

**Design**

- Only confirmed canon is implemented as canon. A value that is not
  established stays out of the production definitions. It is never filled
  with a number from the code or from the older documents.
- A Verse, Burden or Cant enters the production catalog only when every
  field it needs is approved. Until then the systems are built and tested
  with test fixtures that cannot reach production.

**Security** (plan sections 2 and 9.3; nothing here is relaxed)

- Every client request goes through the dispatcher: envelope, session
  epoch, rate limit, replay check, strict validator, adapter.
- The client sends intent. An aim point, a target and a client time are
  hints. The server decides range, line of sight, destination, cooldown,
  cost and result.
- No request grants a reward or sets state directly. Ownership of Cants
  and Verses changes only through `RewardService` with a receipt.
- The reward receipt and archive protections from BM-047 stay as they
  are. No test bypasses them.
- Tests and the Studio harness never touch real DataStores. The harness
  stays excluded from production by `tools/check-production.luau`.
- Every new request gets abuse tests: malformed payload, spam, forged
  target, replay, wrong state.

**Acceptance**

Each task has two separate gates.

| Gate | Meaning | Evidence |
| ---- | ------- | -------- |
| Technical | The code does what the approved specification says | Headless tests, `check-all`, scripted Studio play-test |
| Gameplay | The feature is right in play | Designer review on screen with real content, plus the staging tests below |

Staging tests still required before any task here is finally accepted:
real DataStores, a real leave-and-rejoin, more than one client, and a
visual review. None can be done in an unpublished place.

## 2. Stages

| Stage | Work | Waits on |
| ----- | ---- | -------- |
| 0 | Agree the checklist and this plan | Designer |
| 1 | IDs and registry entries for all confirmed names | A1 |
| 2 | Cant registry; Cant becomes a discipline without its own activation | A2, A3 |
| 3 | Verse catalog changes; cast request with aim; world query, server movement and timed-effect layers, tested with fixtures | Nothing (rows 20, 57–61) |
| 4 | The four Nearness Verses, one at a time as each is fully specified | A4, A5, A6 |
| 5 | Dissonance bands, gain and recovery | Bands: nothing. Rest: A7, A8 |
| 6 | Burden model and Unwanted Company | A10, A11 |
| 7 | One profile migration for every approved shape change | A3, A10 |
| 8 | Client input and replication for Verses, Dissonance and Burden | Stages 4 to 6 |
| 9 | Play-test script update, on-screen review, task log | Stages 1 to 8 |
| 10 | BM-070 | Stage 9 and A11 |

Stage 3 and the Dissonance bands in stage 5 can start as soon as stage 0
is agreed. Each stage is committed, pushed and must pass CI.

## 3. Stage 1 — IDs and registry (BM-004)

Waits on A1.

**If the report's IDs are adopted exactly** (recommended, because the
report is the primary reference and no player data exists yet):

- `shared/Catalogs/ContentRegistry.luau`: `ID_PATTERN` accepts `.` and
  `_`. The fixed `cant-`, `verse-` prefixes are replaced by the report's
  scheme for each category, as given in the answer to A1.
- `Content/RewardCatalog.luau`: the receipt segment pattern accepts the
  same characters. `:` stays the separator, so receipts stay unambiguous.
- `Network/Validators/Schema.luau` follows the registry pattern; no
  separate change.
- The two existing IDs, `cant-nearness` and `waymark-i`, are renamed to
  the report's IDs across source and tests. No migration is needed
  because no place has been published.

**Entries added to `shared/Catalogs/Content.luau`:**

- Cants: Nearness, Embers, Second Voice, Still Water (C1).
- Verses: `near.close_step`, `near.draw_near`, `near.between_us`,
  `near.no_farther`, each belonging to Nearness (C3–C6).
- Burdens: Unwanted Company, Long Way Home, each belonging to Nearness
  (C7, C8).
- Region Ash Quay, Descent Lantern Vault, boss Lantern Maw (C12–C14).
- The first Waymark is named "Waymark I — Branded" (C16).

**Tests:** registry counts and references; a rejected ID for each
malformed shape under the new pattern; receipt IDs built from the new IDs
stay unique and within length limits.

## 4. BM-062 — Cant registry

**Definitions** (`Content/CantCatalog.luau`)

- Nearness: canonical. Unlock rule: granted by the introductory
  storyline (C15). The quest that grants it comes from A9.
- Embers, Second Voice, Still Water: registered by name only. A new
  unlock kind, `undetermined`, never unlocks and is allowed only on a
  definition marked `provisional`. This registers the names without
  inventing how they are acquired (A12).
- Slots, exclusions and change rules follow A3. If a player has one Cant
  at a time, the `secondary` slot is removed from the catalog and the
  contract instead of being left as an unused assumption.

**Server validation:** unchanged. Unknown, unowned and provisional Cants
are refused.

**Tests:** all four Cants validate; a provisional Cant can never be
unlocked or equipped; Verse lists match the registry.

**Technical gate:** every established Cant has a typed definition.
**Gameplay gate:** open until Embers, Second Voice and Still Water are
specified (A12).

## 5. BM-063 — Nearness

Waits on A2. See checklist section 4.

**If A2 confirms Cants act only through Verses:**

- `Combat/Cants.luau`: remove `activate`, `cooldownRemaining`, the `Kit`
  type and `PRODUCTION_KITS`. The layer keeps `equip`, `equipped` and
  `forget`.
- `Services/CombatService.luau`: remove the `cantKits` dependency.
- `Combat/Replication.luau`: remove the `cant_activated` cue.
- `tests/Playtest`: remove the `activateCant` shortcut and its checks.
- `tests/Unit/Cants.test.luau`: reduced to the equip rules.

**If A2 says a Cant does have its own ability:** that ability is
specified first, then built with its own validated client request. The
placeholder is not promoted.

**Technical gate:** Nearness can be owned and equipped, its four Verses
work (BM-066) and its Burden applies (BM-069).
**Gameplay gate:** Nearness works through the vertical slice in play.

## 6. BM-064 — Cant equipping and acquisition

**Acquisition** (C15, A9)

- One permanent reward in `Content/RewardCatalog.luau`, sourced from the
  introductory quest, unlocking Nearness and the Verses that come with
  it. It is granted through `RewardService`, so it has a receipt and
  cannot be granted twice.
- Nothing in normal play can grant it until the quest system exists
  (BM-073 to BM-075). Until then the Studio harness shortcut remains the
  only way to own Nearness, and it stays labelled as a harness shortcut.

**Server validation:** change rules from A3 are added to
`Network/Adapters/CantEquip.luau`.

**Persistence:** none if one Cant is equipped at a time. Otherwise the
migration in section 11.

**Tests:** the reward grants Nearness and the player can equip it in the
same session without rejoining; each rule from A3; the existing forgery,
duplicate and invalid-slot cases.

**Technical gate:** only eligible Cants can be equipped.
**Gameplay gate:** a new player acquires Nearness by playing the
introduction.

## 7. BM-065 — Verse catalog

Needs no approval for the schema; needs A4 to A7 for each definition.

**Schema changes** (`Content/VerseCatalog.luau`)

| Field | Change | Reason |
| ----- | ------ | ------ |
| `cooldownSeconds` | Replaces `cooldownSteps` | The design gives seconds (C3–C6) |
| `castSeconds` | Replaces `castSteps` | Same; value from A5 |
| `targeting` | New: none, combatant, point or direction | Row 57 |
| `range` | New, bounded | A6 |
| `dissonance` | New, per Verse | Replaces the global placeholder of 10 (A7) |
| `effect` | New: the name of a server effect, never a function | Definitions stay plain data |
| `params` | New: bounded finite numbers read by the effect | No number is hard-coded in effect code |

Seconds are converted to whole steps when the cast layer attaches, using
the simulation's step length, so 7 seconds is 420 steps at 60 steps per
second and stays 7 seconds at any other rate.

**Definitions:** a Nearness Verse is added to production when its cost
(A4), cast rules (A5), details (A6) and Dissonance gain (A7) are all
approved. The four cooldowns are already confirmed: 7, 11, 16 and 24
seconds.

**Tests:** bad seconds, unknown targeting, out-of-bound range and
parameters; the conversion at two step lengths; unknown effect names;
the existing reference and cycle checks.

**Technical gate:** every canonical Verse definition validates.
**Gameplay gate:** follows BM-066.

## 8. BM-066 and BM-067 — The four Nearness Verses and the cast pipeline

### 8.1 Engine work, no approval needed (stage 3)

| Piece | Where | What it does |
| ----- | ----- | ------------ |
| Aim in the request | `Contracts/Payloads.luau`, `Validators/VerseCast.luau` | Optional aim vector. Rejected unless every component is a finite number inside a fixed bound. Extra fields rejected as today |
| World query port | New `Combat/World.luau` type, injected into `CombatService`; Roblox implementation wired in `Bootstrap.server.luau`; a fake in tests | "Is this spot open?" and "is this line clear?" |
| Server movement | `Services/CharacterService.luau`, `Combat/Simulation.luau`, `Combat/Ai.luau` | Moves a player or enemy by server decision. The movement check accepts exactly the displacement the server authorised and still flags anything beyond it |
| Timed effects | New `Combat/Effects.luau` | Effects with an owner, targets and an end step; advanced once per step in a fixed order; hard caps per owner and in total; removed when the owner dies or leaves |
| Effect table | New `Combat/VerseEffects.luau` | Maps an effect name to its server code. Reads numbers only from the definition's `params` |
| Cast layer | `Combat/Verses.luau` | Uses seconds, aim, per-Verse Dissonance, and the interruption rule from A5 |

### 8.2 Gameplay effects (stage 4)

Confirmed behaviour is in bold. Everything else in each row waits on A6.

| Verse | Effect | Still needed |
| ----- | ------ | ------------ |
| Close Step | **Shortens the path to a valid destination and lunges toward it. 7 s.** The server picks the destination from the aim, checks it with the world query, and moves the caster | How the destination is chosen, range, what is valid, lunge speed, protection during the lunge |
| Draw Near | **Pulls eligible enemies or objects toward an anchor. 11 s.** The server selects eligible targets and moves them | The anchor, eligibility, range, distance and speed, the objects. Pullable objects do not exist yet; that part waits for world content |
| Between Us | **Creates a temporary adjacency tether. 16 s.** A timed effect between two parties | Who is tethered, duration, what the tether enforces, how it breaks |
| No Farther | **Creates a zone that compresses escape distance. 24 s.** A timed zone effect | Shape, size, placement, duration, the exact compression rule, who is affected |

Costs come from A4, cast and interruption rules from A5, damage and boss
reactions from A6.

### 8.3 Client input (stage 8)

- New client module for Verse input: four bindings and an aim taken from
  the camera. Default keys are an engineering choice and can be changed.
- It sends `VerseCast` through the existing `Net` controller. It shows
  cooldowns from the server's view of the player.
- `Contracts/CombatReplication.luau`: the own-player view gains Verse
  cooldowns and cast state; the public view gains active zones and
  tethers so other clients can draw them.

### 8.4 Server validation

Existing checks stay: unlocked in the profile, compatible with the
equipped Cant, alive, state, cooldown, all-or-nothing cost, target exists
and is in range. Added: aim bounds, destination validity through the
world query, target eligibility per Verse, effect caps.

### 8.5 Persistence

Verse unlocks are already saved in `cants.verses` and written only by
rewards. Cooldowns and active effects are not saved.

Engineering note for review: a player could leave and rejoin to clear a
cooldown. The planned answer is to keep cooldowns on the server for a
short time after a player leaves and restore them on return.

### 8.6 Tests

- Per Verse: success; exact cooldown in steps; cost spent once;
  interruption per A5; fizzle when the target is lost.
- Destination: inside a wall, out of range, not a number, enormous
  values.
- Eligibility: dead, allied, out of sight, resistant targets.
- Tether and zone: lifetime, end on owner death or leave, caps.
- Abuse: cast spam against the rate limit, forged target, incompatible
  Cant, Verse not unlocked, replayed request.
- Movement: a server move is not flagged; a client adding distance on top
  of it is.
- Determinism: the same seed and inputs replay to the same trace.
- Studio: the scripted play-test casts all four against a harness enemy.

**Technical gate (BM-066, BM-067):** the four Verses resolve as
specified and invalid casts produce no effect.
**Gameplay gate:** playable and balanced to initial targets, reviewed on
screen. Needs visuals, which do not exist yet.

## 9. BM-068 — Dissonance

### 9.1 From confirmed canon, no approval needed

`Combat/Dissonance.luau`:

- Maximum 100. Bands start at 0, 40, 65, 85 and 100 (C9), named Stable,
  Noticeable instability, Enemy and environmental reactions, Fractured
  event risk and Controlled rupture.
- The placeholder thresholds 25, 50, 75 are removed.
- The time-based decay that runs everywhere is removed. Recovery runs
  only while a "stable area" check passes (C10). The check is injected;
  what it tests comes from A7.
- Not saved (C11). A player's meter is not written to the profile.

### 9.2 Waits on A7 and A8

| Item | Where | Ask |
| ---- | ----- | --- |
| Gain per source | Verse definitions, `CombatService.luau` | A7 |
| Recovery rate and what a stable area is | `Dissonance.luau`; the area flag itself arrives with the world tasks | A7 |
| What each band does | `Dissonance.luau`, `Combat/Ai.luau`, later world systems | A8 |
| Player Dissonance actions | `PRODUCTION_ACTIONS` stays empty unless the design names them. The `DissonanceAction` request already refuses anything undefined | A8 |
| Value on rejoin | `CombatService.luau` | A8 |
| Visibility to others | `Combat/Replication.luau` | A8 |

### 9.3 Client, validation, persistence

- **Client:** the own-player view gains the value and band.
- **Validation:** unchanged. A client can never send a meter value.
- **Persistence:** none. The unused `burdens.dissonance` profile field
  stays at zero and is removed in the migration in section 11.
- **Documentation:** `docs/architecture.md` assigns Dissonance to a
  future BurdenService. It is corrected to match the design once A8 and
  A11 are answered.

### 9.4 Tests

- Each boundary exactly: 39 and 40, 64 and 65, 84 and 85, 99 and 100.
- Clamped at 0 and 100; one event per band change.
- Recovery only while the stable-area check passes.
- Nothing about Dissonance is written to the profile across leave and
  rejoin.
- Deterministic replay; the existing forged-value cases.

**Technical gate:** transitions are deterministic and match the bands.
**Gameplay gate:** each band's effect is felt in play (A8).

## 10. BM-069 — Burdens and the first Burden

Waits on A10 and A11.

**Schema** (`shared/Catalogs/ContentRegistry.luau`,
`Content/BurdenCatalog.luau`)

- A Burden names its Cant and its role: default or mastery (C7, C8).
- Validation: the Cant exists; a canonical Cant has exactly one default
  Burden.
- The assumed fields (acquisition sources, 1 to 5 stacks, stat-only
  modifiers) are removed unless A11 keeps them.
- Effects are named, as for Verses, with bounded parameters.

**Definitions:** Unwanted Company (default) and Long Way Home (mastery)
are added when A10 says what they do.

**Gameplay effects:** new `Combat/BurdenEffects.luau`. The active Burden
is resolved on the server from the equipped Cant and the profile, and
applied when the Cant is equipped. Unwanted Company is built first.

**Client input:** none for a default Burden. Choosing the mastery Burden
needs a request; whether that is the plan's `BurdenChoice` (BM-070) is
A11.

**Server validation:** the Burden belongs to the equipped Cant; the
mastery Burden is refused until the profile shows mastery.

**Persistence:** which Burden is active per Cant, in the migration in
section 11.

**Tests:** catalog integrity; the default applies on equip and after a
rejoin; the mastery Burden is refused without mastery; each effect per
A10; no client can pick a Burden it does not own.

**Technical gate:** all established Burdens are represented.
**Gameplay gate:** Unwanted Company changes how Nearness is played, as
designed.

## 11. Stage 7 — One profile migration

Schema version 3, written once, when A3 and A10 are answered:

- `cants.equipped` in the shape A3 requires (unchanged if one Cant).
- `burdens.active` records the active Burden per Cant (A10).
- `burdens.dissonance` is removed (C11).

It follows the existing migration rules: version dispatch, no data loss,
receipts untouched, tested with fixtures of every earlier version.

## 12. Stage 9 — Play-test and records

- The scripted Studio play-test drops the Cant activation checks and adds
  casts of the four Verses, band crossings and the default Burden.
- An on-screen review with the designer. Temporary shapes will stand in
  for effects that have no art, and will be labelled temporary.
- `docs/task-log.md` is updated per task with both gates.

## 13. What is not in this plan

- Embers, Second Voice and Still Water beyond registering their names.
- The quest, Waymark and Descent systems that deliver Nearness in normal
  play (BM-073 onward).
- Art, animation, sound and HUD.
- Staging tests on real DataStores and with several players.
