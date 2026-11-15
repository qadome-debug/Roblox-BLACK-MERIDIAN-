# Task log

One entry per backlog task from `docs/technical-plan-2.0.md`. A task is
listed as done only when its tests and acceptance conditions passed, not
when its code compiled.

| Task   | Status | Date       | Evidence                                                                 |
| ------ | ------ | ---------- | ------------------------------------------------------------------------ |
| BM-001 | Done   | 2026-11-12 | `rojo build` clean; both bootstraps printed in a Studio playtest         |
| BM-002 | Done   | 2026-11-12 | Clean Rokit install on Windows; format, lint, type check, build all pass |
| BM-003 | Done   | 2026-11-12 | `docs/architecture.md`; `tools/check-deps.luau` self-test passes on clean, cycle, layer and unresolved fixtures; repo check passes |
| BM-004 | Done   | 2026-11-12 | `ContentRegistry` validates and freezes `Content.luau`; 25 tests cover duplicate, invalid, missing-reference, wrong-category, type and consistency fixtures. Only Nearness and Waymark I are registered pending the inventory |
| BM-005 | Done   | 2026-11-12 | `Contracts/{Actions,Protocol,Payloads}`, `Types/Profile`, `Constants/Limits` type-check in strict mode; `tools/check-contracts.luau` finds no `any`; 6 contract tests pass |
| BM-006 | Done   | 2026-11-12 | `server/Config` builds frozen config per environment; 9 tests cover invalid config, production override refusal, and every experimental flag defaulting off in every environment |
| BM-007 | Done   | 2026-11-12 | `shared/Sim/{Clock,Rng,FixedStep}`; 13 tests including a seeded simulation replayed to an identical trace and a pinned known sequence |
| BM-008 | Done   | 2026-11-12 | `server/Logging/{Logger,Redact,Telemetry}`; 13 tests cover event schema, secret-key redaction, table/profile dropping, bounds, context binding, sink isolation and telemetry counts |
| BM-009 | Done   | 2026-11-12 | `tests/Support/{Suite,Assert,FakeDataStoreService}` with fault injection; 11 harness tests; `tools/check-tests.luau` forbids live services in tests; failing fixture makes the runner exit 1 |
| BM-010 | Done*  | 2026-11-12 | `.github/workflows/ci.yml` runs `tools/check-all.luau` (12 steps, all pass locally) with pinned, checksum-verified tools and no secrets. *Branch protection requiring the `checks` job must be enabled on GitHub by the repository owner (docs/ci.md); until then a red check does not block a merge |

| BM-011 | Done   | 2026-11-12 | `Network/Remotes` creates only the six allowlisted RemoteEvents; `audit` finds stray, misplaced, duplicate and wrong-class remotes (5 tests); `tools/check-remotes.luau` forbids remote creation elsewhere |
| BM-012 | Done   | 2026-11-12 | `Network/Envelope` parses the versioned envelope with bounded payload structure and per-class size limits; 12 tests plus a 6000-case fuzz run never throws or accepts a malformed envelope |
| BM-013 | Done   | 2026-11-12 | `Network/Validators/Schema` strict object validator; QuestChoice, TravelReady and ClientHello validators; boundary tests plus 13,500 fuzz cases with no crash and no malformed acceptance |

| BM-014 | Done   | 2026-11-12 | `Network/Auth` contexts take identity from the Player object and session; `requireOwner`/`requirePermission`/`requireMember` deny with UNAUTHORIZED and log security events (4 tests) |
| BM-015 | Done   | 2026-11-12 | `Network/RateLimiter` per-player class and envelope token buckets; 7 tests cover burst, refill, sustained flood, envelope cap, no-cost rejection and cross-player fairness |
| BM-016 | Done   | 2026-11-12 | `Network/Replay` sequence tracking, request-ID fingerprint dedup, bounded 10-minute result cache; 7 tests cover duplicate, in-flight, conflict, stale, reordered, expiry, cap and cross-session cases |
| BM-017 | Done   | 2026-11-12 | `Network/Session` per-Player sessions with initial and rotated epochs, hello timeout, once-only handshake; 7 tests including reconnect and cross-player epoch rejection |
| BM-018 | Done   | 2026-11-12 | `Network/Dispatcher` runs the nine-step sequence with default deny; `Adapters/ClientHello`; 14 dispatcher tests cover every rejection class, caching, isolation and registration rules |
| BM-019 | Done   | 2026-11-12 | `Network/Rejections` fixed client-safe messages, abuse classification, category-correct logging and telemetry counts (3 tests) |
| BM-020 | Done   | 2026-11-12 | Gate record `docs/gates/BM-020.md`; 147 tests, `check-all` green; handshake verified end to end in a Studio playtest (`docs/reviews/2026-11-12-playtest.md`) |
| BM-021 | Done   | 2026-11-12 | `Persistence/ProfileSchema.default()` builds the typed v1 profile; `validate()` checks every stored field (11 tests with valid and invalid fixtures) |
| BM-022 | Done   | 2026-11-12 | `ProfileSchema.validate()` enforces every `Limits.PROFILE` bound (max and max+1 tested) and rejects unknown quest/cant/verse/burden/waymark/descent/chapter IDs via `Canon` |
| BM-023 | Done   | 2026-11-12 | `Persistence/Migrations` version-dispatch chain, deep-copies input, refuses future schemas and gaps, idempotent on current profiles (8 tests with a fake v1→v3 chain) |
| BM-024 | Done   | 2026-11-12 | `Persistence/ProfileSize` deterministic JSON measurement with 128/192 KiB soft/hard verdicts; oversized candidate rejected while the existing profile is untouched (5 tests) |
| BM-025 | Done   | 2026-11-12 | `Persistence/Lease` atomic acquire with owner, expiry and fencing generation; two-server simultaneous acquisition yields one owner (11 lease tests) |
| BM-026 | Done   | 2026-11-12 | Renewal by owner and fence only; expired takeover gets a higher fence; stale owner renew → lost; lost-response renew → uncertain then settled |
| BM-027 | Done   | 2026-11-12 | Conditional release by owner (expired in place, fence kept), non-owner release refused, teleport handoff race: arriving server waits for release or expiry |
| BM-028 | Done   | 2026-11-12 | `Persistence/ProfileLoader` ready / readOnly / failed states with bounded backoff; outages never fabricate a default; corrupt, newer-schema and non-table records are quarantined untouched (10 tests) |
| BM-029 | Done   | 2026-11-12 | `Persistence/SaveQueue` per-key ordered coalescing into one lease-guarded UpdateAsync, bounded queue that refuses rather than drops, exponential backoff, uncertain writes kept queued, schema/size rejections leave the store untouched (8 tests) |
| BM-030 | Done   | 2026-11-14 | `Persistence/ProfileStore.mutate` is the only profile write: lease guard, optional expected revision, ordered batch, schema and size checks inside one UpdateAsync; `tools/check-persistence.luau` forbids DataStore writes elsewhere (6 tests) |
| BM-031 | Done   | 2026-11-14 | Thrown writes classified uncertain, never rolled back; `ProfileStore.inspect` and `SaveQueue.reconcile` settle an operation by reading under its original ID, else re-apply idempotently (lost-response and timeout cases tested) |
| BM-032 | Done   | 2026-11-14 | Loader quarantines invalid, corrupt and newer-schema records read-only and untouched; `Persistence/Repair.attempt` fills missing containers and resets a bad lease with an audit report, never touching progression or unknown IDs (5 tests) |
| BM-033 | Done   | 2026-11-14 | `Persistence/Inventory` pure add/remove for stackables and instances with merge, stack cap, 200-stack capacity, unique instance IDs; invariants verified after an encode round trip (6 tests) |
| BM-034 | Done   | 2026-11-14 | `Persistence/Balances` integer add/spend with per-currency caps, single-grant ceiling, no negatives, bounded currency count, `canAfford` (5 tests) |
| BM-035 | Done   | 2026-11-14 | `Content/RewardCatalog` validates definitions (ids, kinds, sources, grant bounds, canonical unlocks) and derives deterministic permanent/seasonal receipt IDs (3 tests); production catalog empty pending the inventory |
| BM-036 | Done   | 2026-11-14 | `Receipts.permanentGrant` writes receipt and grant in one transform; duplicates within and across sessions are no-ops; capacity fails closed with nothing pruned |
| BM-037 | Done   | 2026-11-14 | `Receipts.seasonalGrant` with a retention policy: duplicate, closed-season and future-season grants refused; ledger prunes only closed seasons under pressure, then fails closed |
| BM-038 | Done   | 2026-11-14 | `Receipts.recordIntent` durable pending intents (max 32, fail closed); an intent survives a simulated crash and is fulfilled by the next owner, which clears it in the same write |
| BM-039 | Done   | 2026-11-14 | `Persistence/Grant.apply` all-or-nothing currencies, items, deterministic instances and unlocks; a failing grant leaves no receipt and no partial change (8 receipt tests) |
| BM-040 | Done   | 2026-11-14 | `RewardService.compensate`: operator, case and reason required; receipt derived from the case ID so repeats are no-ops; every attempt logged and counted |
| BM-041 | Done   | 2026-11-14 | `RewardService.recoverPending` re-issues grants for pending intents under their original IDs; crash-after-intent recovered by the next owner without duplication |
| BM-042 | Done   | 2026-11-14 | `RewardService.recordRunResult` writes a durable run record (never rewritten) with traceable receipt IDs per player and slot, then grants seasonally; replay yields duplicates only |
| BM-043 | Done   | 2026-11-14 | Telemetry events `reward_granted`, `reward_duplicate`, `reward_refused`, `reward_recovered`, `reward_compensation`, `descent_run_recorded` carry reward, receipt, source and player; logs carry correlation and player IDs |
| BM-045 | Done   | 2026-11-14 | `Services/RewardService` is the single facade: catalog lookup, source check, deterministic receipt, intent-then-grant flow, duplicate detection before any write (7 tests) |
| BM-046 | Done   | 2026-11-14 | `RewardService.reconcile` settles uncertain writes by reading, retries stale intents under the same IDs, escalates intents past the window or with vanished rewards |
| BM-044 | Done   | 2026-11-14 | `tests/Persistence/FaultMatrix` injects error, timeout, lost-response and budget faults at each grant write boundary, across a crash-and-takeover, on lease acquire/renew and on corrupt reads; every case converges to one payment and single ownership (11 cases) |
| BM-047 | Done   | 2026-11-14 | `Persistence/ReceiptCapacity`: warn/critical gauges with telemetry; archive migration moves the oldest half of permanent receipts to a confirmed archive record before a lease-guarded profile update (schema v2 `receipts.archives`); grants consult archives; exhaustion with nothing archivable fails closed (5 tests) |
| BM-048 | Done   | 2026-11-14 | `tests/Persistence/Stress`: 3 seeds x 120 attempts x 3 players with random faults, server crashes, stale-owner writes and replayed sources; balances equal receipts, no pending intents, no fenced-out grant, every receipt traces to a real request |
| BM-049 | Done   | 2026-11-14 | `Operations/Recovery`: role-checked inspect, retryIntent, clearIntent, compensate and repair; every action audited as a security event with operator, role and case; idempotent; writes refused while the player is online (7 tests) |
| BM-050 | Done   | 2026-11-15 | `Services/ProfileService` wires leases, loader, queue, rewards and capacity into the player lifecycle with the session gate; Bootstrap stage 2 and 5 wired; 6 integration tests; gate record `docs/gates/BM-050.md`; Studio playtest: server up, handshake OK, profile load degrades to `failed` (unpublished place) with 5 retries and no fabricated data |
| BM-051 | Done   | 2026-11-15 | `Services/CharacterService` + `shared/Sim/Vec3`: server-owned None→Alive→Dead lifecycle, rig adapter, cached per-tick samples, implausible-move flagging (last plausible position stays authoritative, telemetry counted), server teleports, flat-distance range checks (5 tests) |
| BM-052 | Done   | 2026-11-15 | `Combat/Attributes`: four server-owned base attributes (ints 1..99), eight derived stats from fixed formulas, validated add/mul modifiers (order-independent: adds, then muls, then round to 1/100, then cap); `check-deps` gains the Combat layer rule (3 tests) |
| BM-053 | Done   | 2026-11-15 | `Combat/Resources`: health/stamina/posture never below zero or above cap; spend-before-act with same-step competition; per-pool regen delays (stamina 1s, posture 2s); posture break at zero and recovery past half; clamp after cap changes; validate (4 tests) |
| BM-054 | Done   | 2026-11-15 | `Combat/ActionMachine` (Idle/Attacking/Dodging/Guarding/Parrying/Hit/Staggered/Dead; Windup→Active→Recovery in whole steps; fixed transition table with cancel windows; held guard + Release) and `Combat/Simulation` (FixedStep loop, id-ordered combatants, sequence-ordered intents, stale/duplicate/flood rejection, costs checked before start, per-step regen, event log, death transition, `onActive` hook for hit resolution) (7 tests) |

## Blockers

- **Branch protection (BM-010).** Needs the repository owner to require the
  `checks` status on `main` in GitHub settings; steps in `docs/ci.md`. The
  workflow itself has not yet run on GitHub because the repository has not
  been pushed from this machine.

- **Canonical content inventory.** The established list of Orthea regions,
  quests, Cants, Verses, Burdens, Waymarks, bosses, and Descents is not in
  the repository. Tasks that need real IDs use only the known first-slice
  items (the Nearness Cant, Waymark I) and leave the rest for the inventory.
- **Original 96-task register.** Not available; the 136-task plan is used
  as-is.
