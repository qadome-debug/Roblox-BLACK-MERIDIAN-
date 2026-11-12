# Task log

One entry per backlog task from `docs/technical-plan-2.0.md`. A task is
listed as done only when its tests and acceptance conditions passed, not
when its code compiled.

| Task   | Status | Date       | Evidence                                                                 |
| ------ | ------ | ---------- | ------------------------------------------------------------------------ |
| BM-001 | Done   | 2026-11-12 | `rojo build` clean; both bootstraps printed in a Studio playtest         |
| BM-002 | Done   | 2026-11-12 | Clean Rokit install on Windows; format, lint, type check, build all pass |
| BM-003 | Done   | 2026-11-12 | `docs/architecture.md`; `tools/check-deps.luau` self-test passes on clean, cycle, layer and unresolved fixtures; repo check passes |

## Blockers

- **Canonical content inventory.** The established list of Orthea regions,
  quests, Cants, Verses, Burdens, Waymarks, bosses, and Descents is not in
  the repository. Tasks that need real IDs use only the known first-slice
  items (the Nearness Cant, Waymark I) and leave the rest for the inventory.
- **Original 96-task register.** Not available; the 136-task plan is used
  as-is.
