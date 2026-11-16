# Content registry (BM-004)

Canonical content IDs for Black Meridian live in one checked-in file,
`src/shared/Catalogs/Content.luau`, validated by
`src/shared/Catalogs/ContentRegistry.luau` and served frozen through
`src/shared/Catalogs/Canon.luau`. The server validates every content ID a
client sends with `Canon:resolve(category, value)`; a client can never
introduce an ID.

## Categories

| Category  | Prefix      | Fields beyond `id`, `name`, `launchRequired`           |
| --------- | ----------- | ------------------------------------------------------ |
| chapter   | `chapter-`  | `order` (unique positive integer)                      |
| region    | `region-`   | `waymarkIds`, `travelLinkIds` (regions reachable from here) |
| quest     | `quest-`    | `chapterId`, `regionId`                                |
| cant      | `cant.`     | `starterEligible`, `verseIds`                          |
| verse     | `verse-`    | `cantId`                                               |
| burden    | `burden-`   | —                                                      |
| waymark   | `waymark-`  | `rank`, `regionId` (optional until the region is named) |
| boss      | `boss-`     | `locationId` (a region or a descent)                   |
| descent   | `descent-`  | `entranceRegionId` (optional until the region is named) |

Fields that gameplay systems need later (unlock rules, costs, graph nodes,
modifiers) are added by the task that owns them (BM-062, BM-065, BM-069,
BM-073, BM-083). This registry establishes identity, not behaviour.

## ID rules

- Lowercase ASCII letters, digits, dots, underscores and hyphens. Starts
  and ends with a letter or digit; never two dots in a row.
- Report style, approved 2026-11-16: a Cant is `cant.<name>`
  (`cant.nearness`); a Verse is `<namespace>.<name>` (`near.close_step`),
  where every Verse of one Cant shares a namespace and no two Cants share
  one.
- Other categories still start with their old hyphen prefix until their
  report-style IDs are approved (`docs/id-proposals.md`).
- At most 48 bytes (`Limits.MAX_CANONICAL_ID_BYTES`).
- Unique across all categories, so a receipt or save field holding an ID is
  unambiguous without its category.
- Never renamed, never reused. Retired content keeps its ID with
  `launchRequired = false`.

## What validation rejects

Shape: non-array lists, missing lists, unknown top-level keys, non-table
entries. Identity: malformed IDs, wrong prefix, duplicates (anywhere), bad
names, missing or non-boolean `launchRequired`. Fields: unknown fields,
missing required fields, wrong types, duplicate items in a list. References:
unknown IDs, wrong category, self-reference. Consistency: a Verse's Cant must
list it and vice versa; a Waymark's region must list it and vice versa;
chapter `order` values are unique.

`ContentRegistry.build` errors on any problem, so a server cannot start on
bad data (construction stage 1 in `docs/architecture.md`).

## Current contents

Only items the design has named so far:

- `cant.nearness`, `cant.embers`, `cant.second_voice`,
  `cant.still_water` — the four launch Cants. None is owned at character
  creation; Nearness is acquired in the introductory story.
- `near.close_step`, `near.draw_near`, `near.between_us`,
  `near.no_farther` — the four Nearness Verses.
- `waymark-i` — Waymark I, rank 1. Its region is unset until the first
  playable region's canonical name is supplied.

Everything else waits on the canonical content inventory (see
`docs/task-log.md`, Blockers). When it arrives, entries are added here and
the tests in `src/tests/Content/ContentRegistry.test.luau` keep running
against the real data.

## Cant definitions (BM-062)

Gameplay rules for Cants live in `src/server/Content/CantCatalog.luau`:
unlock rule, legal loadout slots, exclusions and compatible Verses. The
catalog is validated against this registry, so every canonical Cant has
exactly one definition and no definition can name an unknown Cant. Its
`mechanics` field stays `provisional` until the design inventory supplies
the Cant's values.

## Tests

`lune run tools/run-tests.luau --filter ContentRegistry` runs fixtures for
every rejection above plus the real `Content.luau`.
