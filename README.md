# Black Meridian

Roblox / Luau project for Black Meridian. The repository currently holds the
foundation (BM-001) and the pinned toolchain (BM-002). No gameplay, remotes,
or persistence exist yet.

## How the pieces fit

Code lives as files in `src/`. **Rojo** turns those files into a Roblox place,
and **Roblox Studio** is where the place runs and gets play-tested. The other
tools check the code before it runs.

| Tool     | Version | What it does                                        |
| -------- | ------- | --------------------------------------------------- |
| Rokit    | 1.2.0   | Installs the exact tool versions in `rokit.toml`    |
| Rojo     | 7.7.1   | Builds the place file and live-syncs into Studio    |
| StyLua   | 2.6.0   | Formats Luau code                                   |
| Selene   | 0.32.0  | Lints Luau code for mistakes                        |
| luau-lsp | 1.70.1  | Type-checks Luau code (strict mode)                 |
| Lune     | 0.11.1  | Runs Luau scripts and tests outside Studio          |

## Installation

1. Install [Rokit](https://github.com/rojo-rbx/rokit/releases/tag/v1.2.0):
   download the archive for your platform, extract it, and run
   `rokit self-install`. Open a new terminal afterwards so `rokit` is on PATH.
2. In this folder, install the pinned tools:

   ```bash
   rokit install
   ```

   Rokit asks you to trust each tool the first time. Only the five tools
   listed in `rokit.toml` are approved.
3. Install the Rojo plugin into Roblox Studio (once per machine):

   ```bash
   rojo plugin install
   ```

Tool versions change only through a reviewed commit to `rokit.toml`. Do not
add tools or packages that have not been reviewed.

## Build and run

Build a place file and open it in Studio:

```bash
rojo build default.project.json --output BlackMeridian.rbxl
```

Or, for day-to-day work, live-sync into an open Studio session:

```bash
rojo serve default.project.json
```

Then click **Connect** in the Rojo plugin inside Studio. File changes appear
in Studio without rebuilding.

Pressing Play must show both lines in the Output window, with no errors:

```
[BlackMeridian] INFO lifecycle server_bootstrap_loaded correlationId=... environment=studio readOnly=false scope=studio
[BlackMeridian] Client bootstrap loaded
```

## Checks

Run all four before committing. Each must exit with no errors.

Formatting:

```bash
stylua --check src
```

(`stylua src` rewrites files to the correct format.)

Linting:

```bash
selene src
```

Type checking, which needs a fresh sourcemap first:

```bash
rojo sourcemap default.project.json --output sourcemap.json
```

```bash
luau-lsp analyze --platform roblox --sourcemap sourcemap.json --definitions "@roblox=globalTypes.d.luau" --base-luaurc .luaurc src
```

Module dependencies (layer rules and cycles, see `docs/architecture.md`):

```bash
lune run tools/check-deps.luau
```

Contract hygiene (no `any` in `src/shared/Types` or `src/shared/Contracts`):

```bash
lune run tools/check-contracts.luau
```

Build:

```bash
rojo build default.project.json --output BlackMeridian.rbxl
```

Scripts under `tools/` are type-checked separately, because they run in Lune
rather than Roblox:

```bash
luau-lsp analyze --platform standard tools/check-deps.luau tools/check-contracts.luau tools/run-tests.luau tools/host
```

Tests:

```bash
lune run tools/run-tests.luau
```

Tests live in `src/tests/**/*.test.luau` and run under Lune, outside Studio.
`tools/host/` builds a virtual instance tree from `src/` so test code and the
modules it requires use the same instance paths they use in Roblox. Only pure
Luau logic runs this way; code that needs engine APIs is tested in Studio.
The fuller harness (fakes, fault injection) is BM-009; wiring every check into
CI is BM-010.

## Documents

| File                          | Purpose                                                        |
| ----------------------------- | -------------------------------------------------------------- |
| `docs/technical-plan-2.0.md`  | The 136-task engineering plan this repository follows          |
| `docs/architecture.md`        | Service ownership, layer rules, dependency injection, authority |
| `docs/task-log.md`            | Which tasks are done, with evidence, and current blockers       |
| `docs/content-registry.md`    | Canonical content ID rules and what the registry validates     |

## Configuration files

| File                   | Purpose                                                   |
| ---------------------- | --------------------------------------------------------- |
| `default.project.json` | Rojo mapping from `src/` to the place                     |
| `rokit.toml`           | Pinned tool versions                                      |
| `stylua.toml`          | Formatting rules (tabs, 100 columns, double quotes)       |
| `selene.toml`          | Lint rules; uses the Roblox standard library              |
| `roblox.yml`           | Pinned Roblox API snapshot for Selene (generated; commit) |
| `globalTypes.d.luau`   | Pinned Roblox type definitions for luau-lsp (commit)      |
| `.luaurc`              | Strict type checking for every file                       |
| `.gitattributes`       | LF line endings everywhere so format checks agree         |
| `tools/.luaurc`        | Lune type aliases for scripts in `tools/`                 |
| `tools/typedefs/lune/` | Lune 0.11.1 type definitions (generated by `lune setup`)  |

Both snapshots are committed so checks give the same answer on every machine
and work offline. Refresh them deliberately, in their own commit:

- `roblox.yml`: run `selene update-roblox-std`.
- `globalTypes.d.luau`: when the luau-lsp version in `rokit.toml` changes,
  replace it with `scripts/globalTypes.d.luau` from the matching luau-lsp
  release tag. The current copy is from tag `1.70.1`.

## Layout

| Path on disk  | Location in the place                       | Replicated to clients |
| ------------- | ------------------------------------------- | --------------------- |
| `src/shared/` | `ReplicatedStorage.Shared`                  | Yes                   |
| `src/server/` | `ServerScriptService.Server`                | No                    |
| `src/client/` | `StarterPlayer.StarterPlayerScripts.Client` | Yes                   |
| `src/tests/`  | Not mapped (the test harness is BM-009)     | No                    |

```
default.project.json
src/
  shared/
    Contracts/      request, response, and state contracts
    Types/          shared Luau types
    Catalogs/       canonical content definitions
    Constants/
  server/
    Bootstrap.server.luau
    Network/
      Validators/   payload validators
      Adapters/     one secure adapter per client request
    Services/       Profile, Reward, Combat, Cant, Verse, Burden, Quest,
                    Waymark, Travel, Descent
    Persistence/    leases, save queue, migrations
    Content/        server-side content registries
  client/
    Bootstrap.client.luau
    Controllers/
    UI/
  tests/
    Unit/  Integration/  Security/  Persistence/  Content/
```

`RequestDispatcher.luau` will live directly in `src/server/Network/`, and each
service is a single module in `src/server/Services/` named after it (for
example `ProfileService.luau`). Those files are created by the tasks that own
them, not as empty stubs here. Empty folders carry a `.gitkeep` so git keeps
them; Rojo ignores those files.

## Rules that already apply

- The server is the only authority over gameplay state. The client presents
  and submits intentions.
- Server-only code stays under `src/server/`. Nothing privileged goes in
  `src/shared/` or `src/client/`, because both replicate to every player.
- No remote may grant rewards or set progression directly.
- No production DataStore access from development or test code.
- No external packages without review.
