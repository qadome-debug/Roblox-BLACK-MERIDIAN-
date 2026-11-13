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
