# Black Meridian — status report (2026-11-18)

## In one paragraph

The technical foundation (networking, saving, rewards, combat core) is
built and tested. The four Nearness Verses, Dissonance and one Burden work
on the server and can be tried in a Studio demo with placeholder visuals.
There is no real game world, story, quests, art, audio or other Cants yet.
Nothing has been published and no production data has been touched.

## Task counts (docs/task-log.md, BM-001 to BM-069)

- 61 tasks Built, 8 Framework (needs design). BM-070 onward not started.
- "Built" means the code and tests pass. It does not mean the designer has
  accepted it as gameplay. Real DataStore, multiplayer and visual tests are
  still outstanding for every area.
- Checks: 17 automatic steps pass (format, lint, types, contracts, security,
  persistence, isolation, 441 tests, build). GitHub CI is green.

## What exists

| Area | Tasks | State |
| ---- | ----- | ----- |
| Tooling, config, logging, CI | BM-001 to 010 | Built. Branch protection on GitHub still needs the owner (BM-010) |
| Secure networking: validated requests, rate limits, replay protection, sessions | BM-011 to 020 | Built, security-tested |
| Saving: profiles, leases, migrations, inventory, balances | BM-021 to 034 | Built, tested with a fake DataStore. Real DataStore never run |
| Rewards and receipts, crash recovery, receipt archiving | BM-035 to 050 | Built and hardened. Reward catalog content not provided (BM-035) |
| Combat core: character, stats, actions, hits, damage, defence, enemy AI, lock-on, replication | BM-051 to 061 | Built. Numbers are engineering defaults, not canon |
| Cants and Verses | BM-062 to 067 | Nearness Verses built (BM-066, 067). Other Cants have no Verses |
| Dissonance | BM-068 | Meter, bands, sources, recovery, safe rupture built. Band effects are not |
| Burdens | BM-069 | Long Way Home works. Unwanted Company has no effect yet |
| Content IDs | BM-004 | 4 Cants, 4 Verses, Ash Quay, Lantern Vault, Lantern Maw, Waymark I, 2 Burdens |

## What is playable now

Only the Nearness demo, in Roblox Studio (not in a published game):

- File: `BlackMeridianDemo.rbxl`, rebuilt with
  `rojo build playtest-demo.project.json -o BlackMeridianDemo.rbxl`. Press Play.
- Keys: Q Close Step, E Draw Near, R Between Us, F No Farther, G enemies
  flee, H reset. The cursor aims.
- Arena with a wall, an invisible boundary, pillars, four normal enemies, one
  elite and one boss (boss cannot be pulled or tethered).
- HUD: stamina, Dissonance meter with bands, cooldowns, last result.
- Every cast goes through the real server-checked request path.
- Limits: enemies are passive training dummies, visuals are plain parts,
  there is no animation or sound, aiming uses the mouse only. The latest
  fix (enemies that killed the player) has not yet been re-run in Studio.

## What is not playable or not built

- No real world: no Ash Quay, Lantern Vault, Lantern Maw fight, camps, anchors.
- No story, quests, chapters, Waymarks beyond the ID, no UI beyond the demo HUD.
- No Embers, Second Voice or Still Water Verses (no designs given).
- Unwanted Company effect (proposal in `docs/unwanted-company-proposal.md`),
  Dissonance band effects, relics, consumables, Long Way Home mastery trial,
  Cant swapping at anchors.
- No art, animation, audio, real effects. No gamepad or touch input.
- No multiplayer test, no real-DataStore test, no performance test.
- Known gap: Verse cooldowns reset when a player rejoins.

## Safety and process

- All state is server-authoritative; no reward or state-changing remotes.
- The Studio test tools and demo are blocked from production builds by an
  automatic check.
- Nothing published, no production DataStore access.

## Open decisions for you

1. Designs for the other three Cants' Verses (or approve proposals).
2. Approve or change the Unwanted Company proposal.
3. Mastery trial for Long Way Home; what each Dissonance band does.
4. Confirm `boss.lantern_maw` is in `descent.lantern_vault`.
5. Turn on branch protection on GitHub (BM-010).
6. Test the demo and tell me what to change. BM-070 stays on hold until then.
