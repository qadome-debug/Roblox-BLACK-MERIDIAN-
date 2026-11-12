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

## Blockers

- **Canonical content inventory.** The established list of Orthea regions,
  quests, Cants, Verses, Burdens, Waymarks, bosses, and Descents is not in
  the repository. Tasks that need real IDs use only the known first-slice
  items (the Nearness Cant, Waymark I) and leave the rest for the inventory.
- **Original 96-task register.** Not available; the 136-task plan is used
  as-is.
