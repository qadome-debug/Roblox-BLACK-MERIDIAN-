# Canonical design information needed

Status: 2026-11-16. Owner of the answers: the game designer.

The repository holds one design source, `docs/technical-plan-2.0.md`. It
defines the engineering tasks and states that the canonical content
inventory is not included. It names Nearness and Waymark I and gives no
mechanic for either, or for any Verse, Dissonance or Burden.

Nothing in this list has been invented. Where the code needed a value to
run, it uses a placeholder that is marked in the file named below, and the
task stays unaccepted in `docs/task-log.md`.

Each entry gives:

- **Needed** — the exact information to supply.
- **Today** — what stands in for it and where.
- **Will change** — the existing systems that must be edited once the
  information arrives.

The entries are ordered by task. Items 1 to 9 block the tasks already
built. Items 10 to 13 block the next tasks and can follow later.

## 1. BM-004 — Content registry

**Needed**

- The full list of canonical names for: regions, quests, Cants, Verses,
  Burdens, Waymarks, bosses and Descents.
- Confirmation of the ID style. Today IDs are lower-case with a category
  prefix, for example `cant-nearness` and `waymark-i`. IDs are permanent
  once players have saved data.
- For each Verse, the Cant it belongs to.

**Today** — `src/shared/Catalogs/Content.luau` registers two IDs: Nearness
and Waymark I.

**Will change**

- `Content.luau` (the list) and `docs/content-registry.md`.
- The Cant, Verse and Burden catalogs refuse to start if a registered ID
  has no definition. Registering a name therefore needs its definition in
  the same change, or a definition marked `provisional`.
- Saved profiles accept the new IDs automatically (BM-022). No migration.

## 2. BM-035 — Reward catalog

**Needed**

- Every reward: name, one-time or repeatable, and where it comes from
  (quest, Waymark, boss, Descent, event).
- What each reward gives: currencies and amounts, items, unlocked Cants,
  Verses or Waymarks.
- The currencies: names and maximum balances.
- The items: names, stackable or unique, stack limits.

**Today** — the production reward catalog is empty. Tests use a fixture
currency called `currency-test`. The grant, receipt and recovery machinery
is complete and does not depend on the answers.

**Will change** — `Content/RewardCatalog.luau` (production list), the
currency caps in `Constants/Limits.luau`, and item definitions for
`Persistence/Inventory.luau`.

## 3. BM-052 to BM-057 — Combat core values

These tasks are built and tested, but their names and numbers were chosen
as engineering defaults. They are not from the design.

**Needed** — confirm or replace:

- The four base attributes. Today: Vigor, Might, Grace, Will.
- The resource pools. Today: health, stamina, posture. Is there a
  separate resource for Cants and Verses?
- The derived stats and their formulas, and the damage and mitigation
  formula.
- Action timings (wind-up, active and recovery frames), stamina costs,
  regeneration delays, guard, parry and posture-break rules.

**Today** — `Combat/Attributes.luau`, `Resources.luau`, `ActionMachine.luau`,
`Damage.luau`, `Defense.luau`.

**Will change** — the constants in those files and their tests. A new
resource pool also changes the own-player replication view, the Cant and
Verse cost schema, and the HUD when it exists.

## 4. BM-062 — Cant registry

**Needed**

- Every Cant, and how each is unlocked.
- How many Cants a player has equipped at once, and the slot names.
- Which Cants cannot be equipped together, if any.

**Today** — `Content/CantCatalog.luau` assumes two slots (primary and
secondary), three unlock kinds (starter, Waymark, quest) and symmetric
exclusions. Only Nearness is defined. Only one slot is saved.

**Will change**

- `CantCatalog.luau` (schema and production list).
- `CantSlot` in `Contracts/Payloads.luau` and the `CantEquip` validator.
- The saved profile: `cants.equipped` is a single ID. More than one slot
  needs a schema version 3 migration.
- `Services/Loadout.luau` and the Cant layer in `Combat/Cants.luau`, which
  hold one Cant per player.

## 5. BM-063 — Nearness

**Needed**

- What Nearness does: effect, who or what it affects, range or area,
  duration, numbers, and what it scales with.
- How the player triggers it: its own input, passive, or only through its
  Verses.
- Cooldown, cost and resource pool.
- When it can be used: while guarding, attacking, moving, staggered.

**Today** — a placeholder kit in `Combat/Cants.luau` (`PRODUCTION_KITS`):
60-step cooldown, 20 stamina, usable when idle or guarding, and an effect
that does nothing except announce the activation. No client request can
activate a Cant.

**Will change**

- The kit and its effect.
- If Nearness has its own input: a new client request (contract,
  validator, adapter, rate class, security tests) or a new `CombatInput`
  kind.
- The own-player replication view, to carry the cooldown.
- The Studio play-test script, which activates Nearness through a test
  shortcut today.

## 6. BM-064 — Cant equipping

**Needed**

- When a player may change Cants: anywhere, only at a Waymark, never in
  combat, never during a Descent.
- Any cooldown or cost for changing.
- How a player first comes to own Nearness (see item 13, BM-106).

**Today** — `Network/Adapters/CantEquip.luau` allows a change whenever the
player is idle and owns the Cant. No flow gives a player a Cant yet.

**Will change** — the adapter rules and its tests; the items under BM-062
if there is more than one slot.

## 7. BM-065 and BM-066 — Verse catalog and the Nearness Verses

**Needed**, for each Verse the vertical slice requires:

- Name, and the Cant it belongs to.
- Effect: damage, healing, buff, movement or other, with numbers and
  scaling.
- Target: self, enemy, ally, a point on the ground or a direction; range
  and area.
- Cast time, and what cancels a cast (moving, other actions).
- Cooldown and cost.
- How it is unlocked, and any order between Verses.

And for Verses in general:

- Whether being hit interrupts a cast, and what is lost when it does.
- Whether a player chooses a limited set of Verses to carry.

**Today** — `Content/VerseCatalog.luau` assumes up to three resource costs,
whole-step cast and cooldown times, and prerequisites made of same-Cant
Verses plus an optional Waymark or quest. The production catalog is empty.
`Combat/Verses.luau` interrupts a cast on hit, stagger or death and keeps
the cost and cooldown spent; that rule is an assumption.

**Will change**

- `Content.luau` (Verse IDs) and `VerseCatalog.luau` (production list).
- A new server module for the Verse effects, wired through
  `CombatService`.
- `VerseCast` payload and validator if a Verse targets a point or a
  direction. Today the target is an opaque combatant reference.
- The interruption rule in `Combat/Verses.luau`.
- Profile writes for Verse unlocks, and a migration plus a new request if
  players carry a chosen set.
- The own-player replication view (cast state and cooldowns).

BM-067 (cast pipeline) needs no further information. It is accepted by
re-running its tests and the Studio play-test with the real Verses.

## 8. BM-068 — Dissonance

**Needed**

- What raises Dissonance and by how much.
- The maximum, and whether and how it falls or resets (time, rest,
  Waymark, death).
- The thresholds or states, their names, and what each does to the player.
- The Dissonance actions: name, requirement, what it consumes, effect,
  cooldown.
- Whether it is saved between sessions, and how it relates to Burdens.
- Whether other players can see it.

**Today** — `Combat/Dissonance.luau` (`PROVISIONAL_TUNING`): maximum 100,
thresholds at 25, 50, 75 and 100, decay of 0.25 per step after 90 quiet
steps. `CombatService` adds 10 per resolved Verse. There are no actions.
The meter is not saved, although the profile has a `burdens.dissonance`
field, and the architecture document assigns ownership to a future
BurdenService.

**Will change**

- The tuning, the rise rule and the action list.
- Per-state effects on the player, through attribute modifiers or new
  hooks.
- Saving and restoring the meter through `ProfileService`.
- The own-player replication view (meter and state).
- Ownership may move from the combat layer to BurdenService.

## 9. BM-069 — Burden registry

**Needed**, for each Burden:

- Name and what it does: stat changes, or rule changes that are not stats.
- How it is acquired.
- Whether it stacks, and the maximum.
- Which Burdens cannot be held together.
- Whether it is permanent, and how it is removed if not.

**Today** — `Content/BurdenCatalog.luau` assumes four acquisition sources
(Descent, boss, quest, Waymark), 1 to 5 stacks, and consequences made only
of bounded stat modifiers. The production catalog is empty.

**Will change**

- `Content.luau` (Burden IDs) and `BurdenCatalog.luau`.
- Effect hooks, if a Burden does more than change stats.
- The saved profile: `burdens.active` is a plain list of IDs. Stacking
  needs counts, which is a migration.

## 10. BM-070 and BM-071 — Burden offers and effects (next tasks, on hold)

**Needed**

- When a Burden is offered, how many options, whether the player can
  decline, and whether an offer expires.
- The limit on active Burdens. The profile schema allows 8.
- Removal rules, and what happens to Burdens on death or at the end of a
  Descent.
- How a Burden that lowers a maximum treats the current value.

**Will change** — a new `BurdenChoice` validator and adapter, a
server-side offer store, and Burden application in the combat attributes.

## 11. BM-072 — Combat balance harness

**Needed** — the initial balance targets the plan calls "documented
functional and balance acceptance thresholds": for example time to defeat
a standard enemy, hits a player survives, and the stamina economy.

## 12. BM-073 to BM-078 — Quests and Waymark I

**Needed**

- The first region and its quests: objectives, order and branches.
- Waymark I: requirements, unlock sequence and permanent rewards.

**Will change** — new quest and Waymark systems, plus reward catalog
entries (item 2).

## 13. BM-106 — Starting Cant

**Needed** — whether every player starts with Nearness or chooses from a
set, and whether that choice is permanent.

**Today** — no player can own a Cant in normal play. The Studio play-test
grants Nearness through a test shortcut.

## Testing that needs a staging place

These are not design questions. They need a published staging place and
the owner's approval, and none has been done:

- Real DataStores: profile load, save, lease handoff between servers.
- A real leave-and-rejoin, and a teleport between two servers.
- More than one client: replication to other players, loot ownership.
- Visual review: animations, effects, HUD. None exist yet.

No place has been published and no production data has been touched.
Publishing, enabling Studio access to API services, or opening production
DataStores will not be done without asking first.
