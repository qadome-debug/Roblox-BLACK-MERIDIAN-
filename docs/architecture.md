# Architecture (BM-003)

This document defines who owns what, which modules may depend on which, how
services receive their dependencies, and the server-authority rules every task
must follow. It is enforced in two ways: the dependency checker
(`lune run tools/check-deps.luau`) fails the build on forbidden requires and
cycles, and the composition root in `Bootstrap.server.luau` can only construct
services in an order that has no cycles.

## 1. Trust boundaries

| Boundary                        | Trusted?                  | Rule                                                                                                 |
| ------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------- |
| Client code (`src/client`)      | No                        | Treated as attacker-controlled. It may ask; it never decides.                                        |
| Shared code (`src/shared`)      | No (replicated to client) | Holds types, contracts, catalogs, constants. No secrets, no server-only logic, no mutation authority. |
| Server code (`src/server`)      | Yes                       | Sole authority over gameplay state, rewards, progression, persistence.                               |
| Client → server remote traffic  | No                        | Every message goes through the validation sequence in the plan (section 3.2). Unknown actions denied. |
| Server → client remote traffic  | Presentation only         | Carries no authority. The client may not treat it as proof of anything.                              |
| DataStore / MemoryStore         | Durable but uncertain     | Writes may commit without a response. Fenced leases and receipts, never trust an in-memory copy.      |
| External HTTP, analytics        | Untrusted output channel  | Never a source of gameplay truth. Redacted before leaving the server.                                 |
| Operator tooling                | Restricted                | Role-controlled, logged, idempotent. No arbitrary profile edits (BM-049).                             |

Anything that crosses a boundary from a less trusted side is validated on the
more trusted side. Validation is never delegated to the less trusted side.

## 2. Layers and allowed dependencies

The dependency checker resolves every `require` and enforces this table. A
"require" is any static dependency, including one used only for a type.

| From                 | May require                                         | Must not require                       |
| -------------------- | --------------------------------------------------- | -------------------------------------- |
| `shared/*`           | `shared/*`                                          | `server/*`, `client/*`, `tests/*`      |
| `client/*`           | `client/*`, `shared/*`                              | `server/*`, `tests/*`                  |
| `server/Services/*`  | `server/Services/*` (acyclic), `Persistence`, `Content`, `shared/*` | `server/Network/*`, `client/*`, `tests/*` |
| `server/Network/*`   | `server/Network/*`, `server/Services/*`, `shared/*` | `client/*`, `tests/*`                  |
| `server/Persistence/*` | `server/Persistence/*`, `shared/*`                | `Services`, `Network`, `client/*`      |
| `server/Content/*`   | `server/Content/*`, `shared/*`                      | `Services`, `Network`, `client/*`      |
| `server/Bootstrap`   | anything under `server/*` and `shared/*`            | `client/*`, `tests/*`                  |
| `tests/*`            | anything                                            | —                                      |

Cycles are forbidden everywhere, including among services.

Requires use Roblox instance paths so the checker (and Studio) can resolve
them: `require(script.Parent.X)` for neighbours, or a path from one of the
three roots `ReplicatedStorage.Shared`, `ServerScriptService.Server`,
`StarterPlayer.StarterPlayerScripts.Client`. String requires and other roots
are rejected.

## 3. Service ownership

A service is the single owner of one area of server state. No other module
mutates that state; it asks the owning service.

| Service          | Owns                                                              | Never does                                                   |
| ---------------- | ----------------------------------------------------------------- | ------------------------------------------------------------ |
| ProfileService   | Profile load/save, session leases, fencing, save queue, migrations | Grant rewards; decide gameplay outcomes                      |
| RewardService    | Grant decisions, receipts, pending intents, reconciliation         | Accept a grant amount or source from any client-derived data |
| CombatService    | Health, damage, hit validation, resources, combat state machine    | Trust client hit claims, positions, or timing                |
| CantService      | Cant ownership, equip state, cooldowns                            | Accept Cant IDs that are not in the registry                  |
| VerseService     | Verse execution, costs, effects                                   | Run effects not validated by CantService compatibility        |
| BurdenService    | Burden offers, selection, active modifiers, Dissonance meter      | Let the client set meter values                               |
| QuestService     | Quest graph state, offers, choices, revisions                     | Advance a quest from an event it did not certify              |
| WaymarkService   | Waymark activation, unlock prerequisites                          | Unlock without a ProfileService receipt                       |
| TravelService    | Routes, tickets, readiness, teleport initiation                   | Teleport from a client parameter                              |
| DescentService   | Run lifecycle, encounter state, completion certification          | Accept completion claims from clients                         |
| PartyService     | Roster, leadership, invites                                       | Let a non-leader act as leader                                |
| ContentRegistry  | Canonical IDs and definitions (shared data, server enforcement)   | Accept IDs created at runtime                                 |

Services that are not yet built do not get placeholder files. Each is created
by the task that owns it.

## 4. Module shape and dependency injection

Every service is one ModuleScript in `src/server/Services/` that returns a
table with:

```luau
--!strict
export type Deps = { ... }        -- what this service needs, by interface type
export type Service = { ... }     -- what this service offers
local M = {}
function M.new(deps: Deps): Service ... end
return M
```

Rules:

1. **Constructor injection only.** A service receives every collaborator
   (other services, clock, RNG, logger, DataStore wrapper, config) through
   `new(deps)`. It never reaches for a global, a singleton, or `game:GetService`
   for something a dependency could provide. Roblox services it genuinely needs
   (`Players`, `RunService`) are also passed in, so tests can substitute them.
2. **No work in `new`.** Construction wires fields only. Anything that yields,
   connects events, or touches a DataStore happens in `start()`, called by the
   composition root after every service exists.
3. **Interfaces, not implementations.** `Deps` fields are typed with the
   collaborator's exported `Service` type, so tests can pass fakes that satisfy
   the same type.
4. **One composition root.** `Bootstrap.server.luau` is the only place that
   calls `new` on services and the only place that knows the full graph. It
   constructs in the order below; a service can only be handed services that
   already exist, which makes a dependency cycle impossible to write.
5. **No mutable module-level state.** Everything lives on the instance returned
   by `new`, so two test cases never share state.
6. **Adapters are thin.** A request adapter in `src/server/Network/Adapters/`
   validates and authorizes, then calls exactly one service method. It owns no
   state of its own.

## 5. Server construction order

Matches the plan's initialization order (section 2.3). Each stage may only
depend on earlier stages.

| Stage | Modules                                                                 | Failure behaviour                                               |
| ----- | ----------------------------------------------------------------------- | --------------------------------------------------------------- |
| 1     | Config and feature flags, ContentRegistry validation, logger, clock, RNG | Abort server start; log the reason. Nothing else loads.         |
| 2     | ProfileService (leases, save queue), RewardService                       | Abort server start. No fabricated profiles.                     |
| 3     | Combat, Cant, Verse, Burden, Quest, Waymark, Travel, Descent, Party      | Abort server start.                                             |
| 4     | Validators, adapters, RequestDispatcher, remotes created                 | Abort; remotes must not exist half-wired.                       |
| 5     | `Players.PlayerAdded` handling, per-player session activation            | Per player: non-mutating loading/error state, never empty data. |

Within stage 3, order is: Combat → Cant → Verse → Burden → Quest → Waymark →
Party → Travel → Descent. Later services may depend on earlier ones, not the
reverse. A new service is added to this list by the task that creates it.

## 6. Server-authority rules

1. The server obtains player identity from the `Player` object delivered by
   the engine. A `userId` field inside a payload is ignored.
2. Clients submit intentions through the single `ActionRequest` ingress. There
   is no other gameplay remote from client to server.
3. The server decides position, timing, hits, damage, costs, cooldowns,
   eligibility, and rewards from its own state. Client-reported values of
   these are hints for presentation at most.
4. Every state mutation goes through the owning service. Adapters, other
   services, and operator tools do not write another service's state.
5. Every durable mutation runs inside an atomic `UpdateAsync` that verifies
   the session lease and fence. A server without a valid lease stops writing.
6. Rewards and permanent progression are applied only by RewardService with a
   receipt. The same receipt can never pay twice.
7. Server-to-client messages carry presentation state. The client never sends
   them back as proof.
8. Unknown actions, unknown IDs, extra fields, and out-of-range values are
   rejected before any service runs.
9. Feature flags are read on the server. The client is told which features
   are on; it cannot turn one on.
10. Logs never contain secrets, full profiles, or more player data than the
    event needs.

## 7. Testing seams

Because every collaborator is injected, a test constructs a service with:

- a deterministic clock and seeded RNG (BM-007),
- an in-memory DataStore fake that can be told to time out, commit without
  responding, or reject (BM-009),
- fake sibling services typed to the same interfaces,
- a recording logger (BM-008).

Tests may never touch a real DataStore. The DataStore wrapper is injected and
the real implementation is only constructed in `Bootstrap.server.luau`.

## 8. Change control

- Adding a service, adapter, or remote means updating the tables in this
  document in the same change.
- `lune run tools/check-deps.luau` must pass in CI (BM-010). It also has a
  self-test (`--self-test`) with fixtures for each failure class.
- A request type not in the plan's registry (section 3.3) is not added
  without a backlog task, a validator, and abuse tests.
