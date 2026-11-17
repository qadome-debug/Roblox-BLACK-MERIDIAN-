# Machine ID proposals

Status: 2026-11-16. **All six IDs approved and registered** (the designer
chose `waymark.branded`). `waymark-i` was migrated by schema v4. The
proposal below is kept as the record. One inference to confirm:
`boss.lantern_maw` has `descent.lantern_vault` as its location because the
schema requires one and Lantern Maw is the first boss.

These items are established by the design, but the 22-part report's
machine IDs for them are not available. The IDs below are **proposals**,
built by extending the pattern of the approved IDs (`cant.nearness`,
`near.close_step`): a lower-case category word, a dot, and the name in
lower case with underscores. If the report defines different IDs, the
report wins.

Nothing below is registered. Each item is registered when its ID is
approved.

| Item | Category | Proposed ID | ID in the code today |
| ---- | -------- | ----------- | -------------------- |
| Ash Quay | region | `region.ash_quay` | none |
| Lantern Vault | descent | `descent.lantern_vault` | none |
| Lantern Maw | boss | `boss.lantern_maw` | none |
| Waymark I — Branded | waymark | `waymark.branded` | `waymark-i` |
| Unwanted Company | burden | `burden.unwanted_company` | none |
| Long Way Home | burden | `burden.long_way_home` | none |

Notes:

- **Waymark I.** An alternative is `waymark.1`, which sorts and compares
  by rank. `waymark.branded` follows the name. Either works.
- **Burdens.** An alternative is to put Burdens in the Cant's namespace,
  like the Verses: `near.unwanted_company`. That keeps everything of
  Nearness together, but makes a Burden ID look like a Verse ID. The
  proposal keeps them apart.
- The older November 1 blueprint happens to use the same region, Descent
  and boss style. That is not the source of these proposals, and it does
  not make them canon.

## What changes when they are approved

- `shared/Catalogs/ContentRegistry.luau`: the prefix of each category
  moves to the dotted style, as `cant.` did.
- `shared/Catalogs/Content.luau`: the six entries are added.
- `Content/BurdenCatalog.luau`: the two Nearness Burdens are defined, as
  provisional until their values are approved (decision sheet, section 7).
- **Waymark I is a rename**, because `waymark-i` already exists. Saved
  profiles key Waymark progress by ID, and reward receipts may contain the
  ID. The rename gets its own profile migration, like the Cant rename in
  schema v3, so saved data is never renamed silently. No place has been
  published, so no player data exists yet and the migration is cheap now.
