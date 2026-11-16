# Task log

One entry per backlog task from `docs/technical-plan-2.0.md`.

Each task has two separate verdicts:

- **Build** says how far the task's own work has come.
  - **Built** — implemented and tested; the task's own "Done" condition in
    the plan is met.
  - **Framework** — implemented and tested with fixtures or placeholders,
    but the task's "Done" condition needs canonical content or mechanics
    that are not in the repository. Placeholder numbers and assumed shapes
    are temporary and are marked in the code.
  - **Blocked** — cannot start without input.
- **Accepted** says whether the task counts as finished. The plan's rule
  (9.3) is that a task cannot be complete while any hard dependency is
  incomplete, so:
  - **Yes** — built, and every dependency is accepted.
  - **Held by …** — built, with nothing left to do in the task itself, but
    a dependency is not accepted. The tasks named are the nearest open
    ones. When they are accepted, the held task is accepted by re-running
    the checks; no new work is expected.
  - **No: own gap** — the task itself is missing something.

A passing technical test does not make a gameplay feature finished.

Acceptance review 2026-11-16 (second pass): the dependency column of every
task in the plan was checked by script against this table. BM-050 and the
other tasks downstream of an open task had been listed as Done; they are
now Built and Held. Result for BM-001 to BM-069: 6 accepted,
52 built and held, 11 with a gap of their own.

| Task   | Build | Accepted | Date       | Evidence |
| ------ | ----- | -------- | ---------- | -------- |
| BM-001 | Built | Yes | 2026-11-12 | `rojo build` clean; both bootstraps printed in a Studio playtest |
| BM-002 | Built | Yes | 2026-11-12 | Clean Rokit install on Windows; format, lint, type check, build all pass |
| BM-003 | Built | Yes | 2026-11-12 | `docs/architecture.md`; `tools/check-deps.luau` self-test passes on clean, cycle, layer and unresolved fixtures; repo check passes |
| BM-004 | Framework | No: own gap | 2026-11-12 | NOT ACCEPTED: the registry holds 2 canonical IDs (Nearness, Waymark I); the rest of the inventory is missing. `ContentRegistry` validates and freezes `Content.luau`; 25 tests cover duplicate, invalid, missing-reference, wrong-category, type and consistency fixtures. Only Nearness and Waymark I are registered pending the inventory |
| BM-005 | Built | Held by BM-004 | 2026-11-12 | `Contracts/{Actions,Protocol,Payloads}`, `Types/Profile`, `Constants/Limits` type-check in strict mode; `tools/check-contracts.luau` finds no `any`; 6 contract tests pass |
| BM-006 | Built | Yes | 2026-11-12 | `server/Config` builds frozen config per environment; 9 tests cover invalid config, production override refusal, and every experimental flag defaulting off in every environment |
| BM-007 | Built | Yes | 2026-11-12 | `shared/Sim/{Clock,Rng,FixedStep}`; 13 tests including a seeded simulation replayed to an identical trace and a pinned known sequence |
| BM-008 | Built | Yes | 2026-11-12 | `server/Logging/{Logger,Redact,Telemetry}`; 13 tests cover event schema, secret-key redaction, table/profile dropping, bounds, context binding, sink isolation and telemetry counts |
| BM-009 | Built | Held by BM-004 | 2026-11-12 | `tests/Support/{Suite,Assert,FakeDataStoreService}` with fault injection; 11 harness tests; `tools/check-tests.luau` forbids live services in tests; failing fixture makes the runner exit 1 |
| BM-010 | Built | No: own gap; waits on BM-004 | 2026-11-12 | `.github/workflows/ci.yml` runs `tools/check-all.luau` (12 steps, all pass locally) with pinned, checksum-verified tools and no secrets. *Branch protection requiring the `checks` job must be enabled on GitHub by the repository owner (docs/ci.md); until then a red check does not block a merge |
| BM-011 | Built | Held by BM-004 | 2026-11-12 | `Network/Remotes` creates only the six allowlisted RemoteEvents; `audit` finds stray, misplaced, duplicate and wrong-class remotes (5 tests); `tools/check-remotes.luau` forbids remote creation elsewhere |
| BM-012 | Built | Held by BM-004 | 2026-11-12 | `Network/Envelope` parses the versioned envelope with bounded payload structure and per-class size limits; 12 tests plus a 6000-case fuzz run never throws or accepts a malformed envelope |
| BM-013 | Built | Held by BM-004 | 2026-11-12 | `Network/Validators/Schema` strict object validator; QuestChoice, TravelReady and ClientHello validators; boundary tests plus 13,500 fuzz cases with no crash and no malformed acceptance |
| BM-014 | Built | Held by BM-004 | 2026-11-12 | `Network/Auth` contexts take identity from the Player object and session; `requireOwner`/`requirePermission`/`requireMember` deny with UNAUTHORIZED and log security events (4 tests) |
| BM-015 | Built | Held by BM-004 | 2026-11-12 | `Network/RateLimiter` per-player class and envelope token buckets; 7 tests cover burst, refill, sustained flood, envelope cap, no-cost rejection and cross-player fairness |
| BM-016 | Built | Held by BM-004 | 2026-11-12 | `Network/Replay` sequence tracking, request-ID fingerprint dedup, bounded 10-minute result cache; 7 tests cover duplicate, in-flight, conflict, stale, reordered, expiry, cap and cross-session cases |
| BM-017 | Built | Held by BM-004 | 2026-11-12 | `Network/Session` per-Player sessions with initial and rotated epochs, hello timeout, once-only handshake; 7 tests including reconnect and cross-player epoch rejection |
| BM-018 | Built | Held by BM-004 | 2026-11-12 | `Network/Dispatcher` runs the nine-step sequence with default deny; `Adapters/ClientHello`; 14 dispatcher tests cover every rejection class, caching, isolation and registration rules |
| BM-019 | Built | Held by BM-004 | 2026-11-12 | `Network/Rejections` fixed client-safe messages, abuse classification, category-correct logging and telemetry counts (3 tests) |
| BM-020 | Built | Held by BM-004, BM-010 | 2026-11-12 | Gate record `docs/gates/BM-020.md`; 147 tests, `check-all` green; handshake verified end to end in a Studio playtest (`docs/reviews/2026-11-12-playtest.md`). The gate is technically passed; it is not accepted while BM-004 and BM-010 are open |
| BM-021 | Built | Held by BM-004 | 2026-11-12 | `Persistence/ProfileSchema.default()` builds the typed v1 profile; `validate()` checks every stored field (11 tests with valid and invalid fixtures) |
| BM-022 | Built | Held by BM-004 | 2026-11-12 | `ProfileSchema.validate()` enforces every `Limits.PROFILE` bound (max and max+1 tested) and rejects unknown quest/cant/verse/burden/waymark/descent/chapter IDs via `Canon` |
| BM-023 | Built | Held by BM-004 | 2026-11-12 | `Persistence/Migrations` version-dispatch chain, deep-copies input, refuses future schemas and gaps, idempotent on current profiles (8 tests with a fake v1→v3 chain) |
| BM-024 | Built | Held by BM-004 | 2026-11-12 | `Persistence/ProfileSize` deterministic JSON measurement with 128/192 KiB soft/hard verdicts; oversized candidate rejected while the existing profile is untouched (5 tests) |
| BM-025 | Built | Held by BM-004 | 2026-11-12 | `Persistence/Lease` atomic acquire with owner, expiry and fencing generation; two-server simultaneous acquisition yields one owner (11 lease tests) |
| BM-026 | Built | Held by BM-004 | 2026-11-12 | Renewal by owner and fence only; expired takeover gets a higher fence; stale owner renew → lost; lost-response renew → uncertain then settled |
| BM-027 | Built | Held by BM-004 | 2026-11-12 | Conditional release by owner (expired in place, fence kept), non-owner release refused, teleport handoff race: arriving server waits for release or expiry |
| BM-028 | Built | Held by BM-004 | 2026-11-12 | `Persistence/ProfileLoader` ready / readOnly / failed states with bounded backoff; outages never fabricate a default; corrupt, newer-schema and non-table records are quarantined untouched (10 tests) |
| BM-029 | Built | Held by BM-004 | 2026-11-12 | `Persistence/SaveQueue` per-key ordered coalescing into one lease-guarded UpdateAsync, bounded queue that refuses rather than drops, exponential backoff, uncertain writes kept queued, schema/size rejections leave the store untouched (8 tests). Changed 2026-11-16: a mutation that raises is dropped alone and the rest of its batch is written (it used to take the whole batch with it); the queue reports each saved batch so the live profile follows the store (1 new test) |
| BM-030 | Built | Held by BM-004 | 2026-11-14 | `Persistence/ProfileStore.mutate` is the only profile write: lease guard, optional expected revision, ordered batch, schema and size checks inside one UpdateAsync; `tools/check-persistence.luau` forbids DataStore writes elsewhere (6 tests) |
| BM-031 | Built | Held by BM-004 | 2026-11-14 | Thrown writes classified uncertain, never rolled back; `ProfileStore.inspect` and `SaveQueue.reconcile` settle an operation by reading under its original ID, else re-apply idempotently (lost-response and timeout cases tested) |
| BM-032 | Built | Held by BM-004 | 2026-11-14 | Loader quarantines invalid, corrupt and newer-schema records read-only and untouched; `Persistence/Repair.attempt` fills missing containers and resets a bad lease with an audit report, never touching progression or unknown IDs (5 tests) |
| BM-033 | Built | Held by BM-004 | 2026-11-14 | `Persistence/Inventory` pure add/remove for stackables and instances with merge, stack cap, 200-stack capacity, unique instance IDs; invariants verified after an encode round trip (6 tests) |
| BM-034 | Built | Held by BM-004 | 2026-11-14 | `Persistence/Balances` integer add/spend with per-currency caps, single-grant ceiling, no negatives, bounded currency count, `canAfford` (5 tests) |
| BM-035 | Framework | No: own gap; waits on BM-004 | 2026-11-14 | NOT ACCEPTED: the production reward catalog is empty pending the inventory. `Content/RewardCatalog` validates definitions (ids, kinds, sources, grant bounds, canonical unlocks) and derives deterministic permanent/seasonal receipt IDs (3 tests); production catalog empty pending the inventory |
| BM-036 | Built | Held by BM-004, BM-035 | 2026-11-14 | `Receipts.permanentGrant` writes receipt and grant in one transform; duplicates within and across sessions are no-ops; capacity fails closed with nothing pruned |
| BM-037 | Built | Held by BM-004, BM-035 | 2026-11-14 | `Receipts.seasonalGrant` with a retention policy: duplicate, closed-season and future-season grants refused; ledger prunes only closed seasons under pressure, then fails closed |
| BM-038 | Built | Held by BM-004, BM-035 | 2026-11-14 | `Receipts.recordIntent` durable pending intents (max 32, fail closed); an intent survives a simulated crash and is fulfilled by the next owner, which clears it in the same write |
| BM-039 | Built | Held by BM-004, BM-035 | 2026-11-14 | `Persistence/Grant.apply` all-or-nothing currencies, items, deterministic instances and unlocks; a failing grant leaves no receipt and no partial change (8 receipt tests) |
| BM-040 | Built | Held by BM-004, BM-035 | 2026-11-14 | `RewardService.compensate`: operator, case and reason required; receipt derived from the case ID so repeats are no-ops; every attempt logged and counted |
| BM-041 | Built | Held by BM-004, BM-035 | 2026-11-14 | `RewardService.recoverPending` re-issues grants for pending intents under their original IDs; crash-after-intent recovered by the next owner without duplication |
| BM-042 | Built | Held by BM-004, BM-035 | 2026-11-14 | `RewardService.recordRunResult` writes a durable run record (never rewritten) with traceable receipt IDs per player and slot, then grants seasonally; replay yields duplicates only |
| BM-043 | Built | Held by BM-004, BM-035 | 2026-11-14 | Telemetry events `reward_granted`, `reward_duplicate`, `reward_refused`, `reward_recovered`, `reward_compensation`, `descent_run_recorded` carry reward, receipt, source and player; logs carry correlation and player IDs |
| BM-044 | Built | Held by BM-004, BM-035 | 2026-11-14 | `tests/Persistence/FaultMatrix` injects error, timeout, lost-response and budget faults at each grant write boundary, across a crash-and-takeover, on lease acquire/renew and on corrupt reads; every case converges to one payment and single ownership (11 cases) |
| BM-045 | Built | Held by BM-004, BM-035 | 2026-11-14 | `Services/RewardService` is the single facade: catalog lookup, source check, deterministic receipt, intent-then-grant flow, duplicate detection before any write (7 tests) |
| BM-046 | Built | Held by BM-004, BM-035 | 2026-11-14 | `RewardService.reconcile` settles uncertain writes by reading, retries stale intents under the same IDs, escalates intents past the window or with vanished rewards |
| BM-047 | Built | Held by BM-004, BM-035 | 2026-11-14 | `Persistence/ReceiptCapacity`: warn/critical gauges with telemetry; archive migration moves the oldest half of permanent receipts to a confirmed archive record before a lease-guarded profile update (schema v2 `receipts.archives`); grants consult archives; exhaustion with nothing archivable fails closed (5 tests). Audited 2026-11-16, 5 defects fixed: an unreadable archive, a stale per-server cache, pending-intent recovery and a leftover intent could each pay an archived receipt twice, and an orphan record after a crash blocked archiving for good. The grant write now refuses to pay unless the archived view covers every archive the stored profile lists; orphan records are adopted (7 new service-level tests in `ReceiptArchive.test`, 5 of which fail on the old code) |
| BM-048 | Built | Held by BM-004, BM-035 | 2026-11-14 | `tests/Persistence/Stress`: 3 seeds x 120 attempts x 3 players with random faults, server crashes, stale-owner writes and replayed sources; balances equal receipts, no pending intents, no fenced-out grant, every receipt traces to a real request |
| BM-049 | Built | Held by BM-004, BM-035 | 2026-11-14 | `Operations/Recovery`: role-checked inspect, retryIntent, clearIntent, compensate and repair; every action audited as a security event with operator, role and case; idempotent; writes refused while the player is online (7 tests) |
| BM-050 | Built | Held by BM-004, BM-035 | 2026-11-15 | `Services/ProfileService` wires leases, loader, queue, rewards and capacity into the player lifecycle with the session gate; Bootstrap stage 2 and 5 wired; 6 integration tests; gate record `docs/gates/BM-050.md`; Studio playtest: server up, handshake OK, profile load degrades to `failed` (unpublished place) with 5 retries and no fabricated data. Changed 2026-11-16: the live profile now follows every saved mutation, so a granted reward is visible without a rejoin. The gate is technically passed; it is not accepted while BM-004 and BM-035 are open |
| BM-051 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Services/CharacterService` + `shared/Sim/Vec3`: server-owned None→Alive→Dead lifecycle, rig adapter, cached per-tick samples, implausible-move flagging (last plausible position stays authoritative, telemetry counted), server teleports, flat-distance range checks (5 tests) |
| BM-052 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Combat/Attributes`: four server-owned base attributes (ints 1..99), eight derived stats from fixed formulas, validated add/mul modifiers (order-independent: adds, then muls, then round to 1/100, then cap); `check-deps` gains the Combat layer rule (3 tests). NOTE: the attribute names, formulas and all combat numbers in BM-052 to BM-057 are engineering defaults, not design; see `docs/design-requests.md` item 3 |
| BM-053 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Combat/Resources`: health/stamina/posture never below zero or above cap; spend-before-act with same-step competition; per-pool regen delays (stamina 1s, posture 2s); posture break at zero and recovery past half; clamp after cap changes; validate (4 tests) |
| BM-054 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Combat/ActionMachine` (Idle/Attacking/Dodging/Guarding/Parrying/Hit/Staggered/Dead; Windup→Active→Recovery in whole steps; fixed transition table with cancel windows; held guard + Release) and `Combat/Simulation` (FixedStep loop, id-ordered combatants, sequence-ordered intents, stale/duplicate/flood rejection, costs checked before start, per-step regen, event log, death transition, `onActive` hook for hit resolution) (7 tests) |
| BM-055 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Combat/Hitboxes`: hits found only by the server during Active frames; reach/arc/height/team/alive/line-of-sight/layer-veto filtering; one hit per target per swing (actionId); intent `target` is never evidence; `candidates` for targeting; hit events in the sim log (6 tests) |
| BM-056 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Combat/Damage`: raw = attackPower × action scale, defense mitigation raw×100/(100+D), hook chain for defensive outcomes (never above raw), per-hit cap 1000, dodge Active frames invulnerable (veto fed to Hitboxes), hit stun interrupts the target (cancels its swing), death via the simulation, dead never hit (7 tests) |
| BM-057 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Combat/Defense` hook on the damage pipeline: parry Active frames negate the hit, stagger the attacker and cost it posture; guards in the front arc reduce damage, pay posture + stamina and break (full damage, long stagger) at zero; back attacks bypass; recovering parries are punished; `Simulation:step` now runs three passes (advance all, intents, hits) so id order never favours a side (7 tests) |
| BM-058 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Combat/Ai`: per-enemy brain Idle→Chase→Attack→Return with aggro range, injectable navigator (straight-line default), repath interval, path-failure budget, leash, home reset (full resources), attack scheduling with cooldown + seeded jitter, all through the sim intent API; loot ownership tallied from server-resolved damage (8 tests) |
| BM-059 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Combat/Targeting`: server-granted lock-on (exists, alive, hostile, in range, in sight), nearest-first `cycle`, per-step re-validation with grace period, drops on death/removal/clear, engagement from server-resolved damage with timeout, `engage` for other systems; hits never consult the lock (6 tests) |
| BM-060 | Built | Held by BM-004, BM-010 | 2026-11-15 | `Contracts/CombatReplication` (public view: state/phase/actionId/health fraction; own view adds exact resources, lock, engagement, `ackSequence`), `Combat/Replication` (change tracking, incremental deltas, full resync after the history window or a future revision, bounded public cues, private rejections only to the owner), `Services/CombatService` (owns the stack, player↔combatant mapping, server-sampled poses, per-step hooks, replication through injected remotes), client `CombatState` (applies deltas/cues, prediction reconciled by the ack) (4 + 3 tests) |
| BM-061 | Built | Held by BM-004, BM-010 | 2026-11-15 | `CombatInput` contract (kinds Attack/Dodge/Guard/Parry/Release/Lock/Unlock/CycleTarget, bounded sequence, optional opaque target), strict validator, adapter forwarding to CombatService (NOT_READY without a combatant, REJECTED with the simulation's fixed reason); Bootstrap stage 3 wires CharacterService (Roblox rig adapter) and CombatService (remote sender, server-sampled poses, heartbeat tick, join/leave); security tests: malformed payloads, stale sequences, spam vs the combat rate class, forged targets, no combatant (6 tests) |
| BM-062 | Framework | No: own gap; waits on BM-004 | 2026-11-15 | NOT ACCEPTED: only Nearness is defined; slot count and unlock kinds are assumptions, not canon. Server `CantCatalog`: typed definitions (unlock rule starter/waymark/quest, legal slots primary/secondary, symmetric exclusions, compatible Verse IDs, mechanics canonical/provisional), validated against the canonical registry (no fabricated or missing Cants, Verse lists must match, unlock refs canonical, starter flag consistent); `resolve`, `isUnlocked` from server facts, `canSlot`, `isVerseCompatible`, `checkLoadout`; production catalog defines Nearness only, mechanics provisional pending the design inventory (10 tests) |
| BM-063 | Framework | No: own gap; waits on BM-004, BM-010, BM-062 | 2026-11-15 | NOT ACCEPTED: PLACEHOLDER kit (invented cooldown and cost, effect only announces activation); no client request activates a Cant. Server Cant activation layer in the combat simulation: equip (server-owned, catalog-checked, not mid-action), activate gated by equipped Cant, alive, allowed combat state, step-counted cooldown that survives swapping, atomic resource cost; validated kits; `cant_activated` public cue; wired into CombatService (`service.cants`, forgotten on leave). Nearness kit is provisional: placeholder numbers and an effect that only announces activation, because its canonical mechanics are not in the repository (8 tests). Blocked: Nearness mechanics |
| BM-064 | Framework | No: own gap; waits on BM-004, BM-010, BM-062, BM-063 | 2026-11-15 | NOT ACCEPTED: depends on BM-063; only the primary slot is saved; no flow lets a player own a Cant yet (starter selection is BM-106). Verified technically in Studio 2026-11-16. `CantEquip` contract and strict validator (slot enum, optional registry Cant ID); adapter checks catalog, ownership from `cants.unlocked` (UNAUTHORIZED, security log), slot legality, duplicate/empty equips, busy combatant, then mirrors into the combat Cant layer and saves `cants.equipped` through new `ProfileService:profileFor/mutate` (schema-checked, queued, rolled back on refusal); only the primary slot is backed until a profile migration adds a second; registered in Bootstrap (7 security tests + 1 ProfileService test) |
| BM-065 | Framework | No: own gap; waits on BM-004, BM-062 | 2026-11-15 | NOT ACCEPTED: no canonical Verse is defined; cost, timing and prerequisite shapes are assumptions. Server `VerseCatalog`: typed definitions (Cant, up to three distinct pool costs bounded to (0, 1000], integer cast/cooldown steps with caps, prerequisites of same-Cant Verses plus optional Waymark/quest, mechanics flag) validated against the registry (no fabricated or missing Verses, registry Cant must match, canonical prerequisite refs, no self-requirement or cycles); `resolve`, `forCant`, `isCompatible`, `prerequisitesMet` from server facts; production list empty until canonical Verse names arrive (6 tests) |
| BM-066 | Blocked | No: own gap; waits on BM-063, BM-065 | 2026-11-15 | Needs the canonical Nearness Verse names and mechanics; the Verse catalog, cast pipeline and adapter are ready to take them |
| BM-067 | Framework | No: own gap; waits on BM-004, BM-010, BM-065, BM-066 | 2026-11-15 | NOT ACCEPTED: depends on BM-066 (blocked); with real content only refusals run, the successful cast is tested with fixture Verses only. Server Verse cast pipeline in the combat simulation (alive, not mid-action, one cast at a time, catalog-defined, compatible with the equipped Cant, per-Verse step cooldown, all-or-nothing costs, target hint verified for existence/self/liveness/range; cast time, interruption by Hit/Staggered/Dead with costs and cooldown kept, fizzle on lost target, server-only effects; public cues); `VerseCast` contract, validator and adapter (catalog check, profile unlock check as UNAUTHORIZED, combatant); CombatService takes injected Cant/Verse catalogs, kits and effects; shared test content fixtures (7 security tests) |
| BM-068 | Framework | No: own gap; waits on BM-004, BM-010, BM-067 | 2026-11-15 | NOT ACCEPTED: PLACEHOLDER thresholds, rise-on-Verse and decay are assumptions; no canonical action; the saved `burdens.dissonance` field is not used. Server Dissonance layer: per-combatant meter raised only by the server (resolved Verses via a pipeline hook), clamped, numbered levels at ascending thresholds with one event per change, decay after a quiet period, validated tuning; data-driven actions (min level, consume/add, step cooldown, server effect); `DissonanceAction` contract/validator (action name only, no meter values) and adapter; public cues; deterministic-replay test (6 tests). Tuning is provisional and the production action list is empty: canonical thresholds, rates and actions are not in the repository. Own-view meter replication is still to add |
| BM-069 | Framework | No: own gap; waits on BM-004, BM-062 | 2026-11-15 | NOT ACCEPTED: no canonical Burden is defined; sources, stacking and modifier-only consequences are assumptions. Server `BurdenCatalog`: typed definitions (acquisition sources descent/boss/quest/waymark, symmetric canonical incompatibilities, maxStacks 1..5, up to four derived-stat modifiers with add within half the stat cap and mul in 0.5..1.5, mechanics flag) validated against the registry; `resolve`, `compatible(held, candidate)`, `modifiersFor(stacks)` clamped to maxStacks and attribute limits; production list empty until canonical Burdens arrive; Burdens added to the shared test fixtures (5 tests) |

## What holds acceptance

Four open items hold everything else. Closing them accepts the held tasks
without new work in those tasks.

| Open item | What is missing | Who | What it holds |
| --------- | --------------- | --- | ------------- |
| BM-004 | The canonical content inventory. The registry and its validation are built; it holds 2 IDs | Designer | Every task that depends on content IDs, directly or through an earlier task: BM-005, BM-009 and everything after BM-010 |
| BM-010 | Branch protection requiring the `checks` job on `main` | Repository owner, in GitHub settings (`docs/ci.md`) | The BM-020 security gate and every task that depends on it |
| BM-035 | The production reward catalog. The catalog rules and receipt IDs are built | Designer | BM-036 to BM-050, including the reward gate |
| BM-062 to BM-069 | Cant, Verse, Dissonance and Burden content and mechanics | Designer | Each other, and BM-070 onward |

The exact information needed for each is in `docs/design-requests.md`.

## Design reconciliation 2026-11-16

The designer supplied confirmed details from the original 22-part report:
the four launch Cants, the four Nearness Verses with IDs and cooldowns,
the two Nearness Burdens, the Dissonance bands, and the starting
progression. No gameplay code was changed in response; statuses in the
table above are unchanged.

- `docs/design-integration-checklist.md` records the confirmed canon,
  matches 62 specifications to their task and code module, and lists 13
  approvals still needed. Values that are not established are marked as
  needing approval; no placeholder was promoted.
- `docs/implementation-plan-bm-062-069.md` gives the planned changes for
  BM-062 to BM-069: definitions, effects, client input, validation,
  persistence and tests, with a technical gate and a gameplay gate for
  each task.
- The 22-part report is not in the repository and was not found on the
  development computer. Two older "Codex blueprint" packages were found.
  They conflict with the report on Verse names, cooldowns, Burden names,
  Dissonance structure and how Nearness is acquired. Nothing was taken
  from them; the conflicts are listed in the checklist.

Findings that change how existing tasks are read:

| Task | Finding |
| ---- | ------- |
| BM-004 | The report writes IDs as `near.close_step`. The registry accepts only hyphenated IDs with a category prefix. A decision is needed before anything is registered |
| BM-063 | The standalone Cant activation in `Combat/Cants.luau` has no support in the confirmed design, where a Cant is a discipline used through its Verses. Proposed for removal, pending approval |
| BM-065 | The design gives cooldowns in seconds; the catalog stores steps. The confirmed cooldowns are 7, 11, 16 and 24 seconds |
| BM-068 | Confirmed bands start at 40, 65, 85 and 100. The code's placeholder thresholds (25, 50, 75, 100) and its decay-everywhere rule are wrong against the design. Dissonance must not be saved; the unused profile field will be removed |
| BM-069 | Burdens belong to a Cant, with a default and an alternate mastery Burden. The catalog's acquisition sources, stacking and stat-only effects are unsupported assumptions |
| BM-070 | The plan's "Burden offers" may not fit a default Burden that comes with the Cant. A decision is needed before BM-070 starts |

## Review 2026-11-16 (second pass)

### BM-047 receipt archive audit

The archive migration was re-read against four failure cases: a crash, a
failed archive write, a reconnect, and grants arriving at the same time.
Five defects were found and fixed. None could be reached in play today,
because the production reward catalog is empty and no profile is near the
1024-receipt budget, but each would have been reachable later.

| Defect | Effect before the fix | Fix |
| ------ | --------------------- | --- |
| An unreadable archive record was treated as "not granted" | A reward whose receipt had been archived could be paid again while the archive store was failing | The grant write refuses to pay unless the archived view covers every archive the stored profile lists. The reward stays owed (pending intent) and is settled when the archive can be read |
| The archived set was cached per server and never re-checked | A player who archived on another server and came back was checked against a stale set: double payment | The view is compared with the profile's archive list on every use and reloaded when it is behind |
| Recovery of a pending intent built its grant without the archived set | A recovered intent for an archived receipt paid again | Recovery passes the view, and waits when it cannot be loaded |
| A leftover intent for an already-paid receipt was never cleared | The intent stayed forever and was retried on every join | The grant write clears the intent without paying |
| A crash between the archive write and the profile write left an orphan record | The next attempt chose a different set of receipts, never matched the record, and archiving failed for good. The ledger would fill and new permanent rewards would stop | An existing record is adopted: exactly the receipts it holds are moved |

Two related changes:

- The save queue used to drop a whole batch when one mutation raised. A
  failing grant could take an unrelated queued mutation, including another
  reward's intent, down with it. Only the failing mutation is dropped now.
- The in-memory profile now follows every saved mutation. Before, a reward
  granted during a session was saved but not visible to gameplay checks
  (for example Cant ownership) until the player rejoined.

Tests added: `Persistence/ReceiptArchive.test.luau` (7 cases through the
reward service: crash after the archive write, stale owner fenced out, lost
response, unreadable archive, reconnect through another server, grants in
the same write as the archive, the same receipt queued twice, leftover
intent), one queue case and extended service and capacity cases. Five of
the seven archive cases fail on the previous code.

Limits that remain, by design: if an archive record is lost or damaged for
good, permanent grants for that profile stay pending and are reported for
an operator; the code will not guess. An archive record under the expected
key that does not match the profile is reported as a conflict and is not
used.

### Play-test tool isolation

The Studio play-test harness can grant Cants, set resources and read
server state. It is kept out of production builds by five independent
conditions, now checked on every run by `tools/check-production.luau`:

1. `default.project.json` mounts nothing from `src/tests`, creates no
   remotes and sets no play-test attributes; the built instance tree holds
   no test or play-test instance (103 instances checked).
2. Production source mentions the harness only in the two Bootstrap
   scripts (81 files checked).
3. The server Bootstrap looks the harness up only inside its
   `environment == "studio"` block, and "studio" is only returned behind
   `RunService:IsStudio()`. Every non-Studio server is treated as
   production.
4. The client Bootstrap looks its driver up only behind `IsStudio()`.
5. The harness itself refuses to run outside Studio (`stores` and
   `start`).

The control RemoteFunction exists only in `playtest.project.json`. The
game never creates it, and the remote audit forbids creating remotes
anywhere but `Network/Remotes.luau`. `check-all` also runs the audit
against the play-test project and requires it to fail, which proves the
audit can tell the two builds apart.

### Visual play-test in Studio

Run on screen this time (play mode, one server, one client):

- The avatar spawns on the baseplate, the default camera follows it, and
  the character walks and jumps (position confirmed changing).
- The scripted run passed 52 of 52 again, with the rebuilt code.
- There is nothing of the game to look at yet: no HUD, no health or
  stamina display, no animations or effects for combat, Cants or
  Dissonance, and enemies exist only in the simulation with no body in the
  world. The only on-screen element is the play-test result overlay, which
  is test scaffolding.

## Play-test 2026-11-16 (first pass)

Full record: `docs/reviews/2026-11-16-playtest.md`.

- Roblox Studio, play-test build with in-memory stores: 52 of 52 scripted
  checks passed. No script errors and no ERROR-level game events.
- Roblox Studio, no DataStore (unpublished place): 10 of 10 checks passed;
  the server stays up and every gameplay request is `NOT_READY`.
- Bug fixed: the saved equipped Cant was not restored into combat after a
  rejoin (`Services/Loadout`, 3 reconnect tests).

## Test results

- `check-all`: 16 steps pass locally (format, lint, type checks, layer
  rules, contracts, remotes, persistence writes, test isolation,
  production isolation, 402 tests, failing fixture, build).
- CI runs the same command on every push.

## Testing gaps kept open

None of these can be done in an unpublished place. They need a separate
staging place and the owner's approval. No place has been published and no
production data has been read or written.

- Real DataStores: profile load and save, lease handoff, receipt archive
  records.
- A real leave-and-rejoin, and a teleport between two servers.
- More than one client: replication to other players, loot ownership.
- A successful Verse cast, cast interruption, and Dissonance raised by a
  Verse, with real content. These run headless with fixture Verses only.
- Visual review of gameplay. Nothing visual exists yet.

## Known gaps that are later tasks, not bugs

- No client request activates a Cant, and no flow lets a player own one
  (BM-106).
- Combat death is not linked to the Roblox character, and there is no
  respawn request (BM-079).
- The client has no input bindings or HUD; it only receives state.
- `CombatInput` does not check an equipped weapon (BM-080).
- The own-player view does not carry Cant cooldowns or the Dissonance
  meter.
- Enemies have no body in the world.
- Receipt archiving runs when a player joins, not during a session. A
  ledger that fills mid-session fails closed (grants stay pending) until
  the next join.

## Blockers

- **Design approvals.** `docs/design-integration-checklist.md`, section
  6, lists 13 questions (A1 to A13). A1 to A8 are needed to finish
  Nearness, its Verses and Dissonance; A10 and A11 for the first Burden.
  BM-070 stays on hold until BM-062 to BM-069 are finished.
- **The 22-part report.** It is the primary design reference and is not
  in the repository. Adding it would answer most open questions directly.
- **Branch protection (BM-010).** Needs the repository owner to require
  the `checks` status on `main` in GitHub settings; steps in `docs/ci.md`.
- **Original 96-task register.** Not available; the 136-task plan is used
  as-is.

## Design information needed

For BM-004 and BM-062 to BM-069 the live document is
`docs/design-integration-checklist.md`. The remaining items are in
`docs/design-requests.md`. The table below is the first-pass summary and
is kept for reference:

| Item | Tasks | Needed |
| ---- | ----- | ------ |
| 1 | BM-004 | Canonical names for regions, quests, Cants, Verses, Burdens, Waymarks, bosses, Descents |
| 2 | BM-035 | Rewards, currencies and items |
| 3 | BM-052 to BM-057 | Confirm or replace attribute names, resource pools, formulas and timings |
| 4 | BM-062 | All Cants, unlock rules, slot count, exclusions |
| 5 | BM-063 | What Nearness does, how it is triggered, cooldown, cost |
| 6 | BM-064 | When Cants can be changed |
| 7 | BM-065, BM-066 | Each Nearness Verse: effect, target, timing, cost, unlock; interruption rule |
| 8 | BM-068 | Dissonance: sources, thresholds, effects, actions, saving |
| 9 | BM-069 | Each Burden: effect, acquisition, stacking, conflicts, removal |
| 10 | BM-070, BM-071 | Burden offers, limits and removal |
| 11 | BM-072 | Balance targets |
| 12 | BM-073 to BM-078 | First region quests and Waymark I |
| 13 | BM-106 | Starting Cant rule |
