# Continuous integration (BM-010)

## What runs

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request. It installs Rokit at a pinned version with a verified checksum,
installs the tools pinned in `rokit.toml`, and runs
`lune run tools/check-all.luau`, which is the same command developers run
before committing. The steps, in order:

| Step                      | Command                                                | Fails when                                   |
| ------------------------- | ------------------------------------------------------ | -------------------------------------------- |
| format                    | `stylua --check src tools`                             | any file is not formatted                    |
| lint                      | `selene src tools`                                     | any lint error or warning                    |
| sourcemap                 | `rojo sourcemap tests.project.json`                    | project file is invalid                      |
| typecheck src             | `luau-lsp analyze --platform roblox ... src`           | any strict-mode type error                   |
| typecheck tools           | `luau-lsp analyze --platform standard tools/...`       | any type error in the Lune scripts           |
| deps self-test            | `lune run tools/check-deps.luau --self-test`           | the checker misses a planted cycle/violation |
| deps                      | `lune run tools/check-deps.luau`                       | forbidden layer dependency or cycle          |
| contracts                 | `lune run tools/check-contracts.luau`                  | `any` in Types or Contracts                  |
| test isolation            | `lune run tools/check-tests.luau`                      | a test names a live service or wall clock    |
| tests                     | `lune run tools/run-tests.luau`                        | any test fails                               |
| failing fixture           | `lune run tools/run-tests.luau --root tools/fixtures/tests/failing` | the runner does NOT fail (negative fixture) |
| build                     | `rojo build default.project.json`                      | the place cannot be built                    |

The built place is uploaded as a workflow artifact for seven days so a
reviewer can open exactly what CI built.

## Security

- The workflow declares `permissions: contents: read` and checks out with
  `persist-credentials: false`. It has no secrets, environment credentials,
  or tokens beyond the read-only default, so nothing can appear in logs and
  nothing can publish to Roblox or write to a DataStore.
- Tools are installed from pinned releases. Rokit's archive is checksum
  verified; the tools it installs are pinned to exact versions in
  `rokit.toml`.
- `concurrency` cancels superseded runs of the same branch.

## Required branch protection (manual, once)

CI can only block a merge if GitHub is told to require it. On the
repository: Settings → Branches → Add rule for `main`:

1. Require a pull request before merging.
2. Require status checks to pass before merging, and select `checks`.
3. Require branches to be up to date before merging.
4. Do not allow bypassing the above settings.

Until this is done, the workflow runs and reports, but a failing check does
not stop a merge. Record the date it was enabled in `docs/task-log.md`.

## Passing and failing fixtures

- Passing: the repository itself on every green commit.
- Failing: `tools/fixtures/tests/failing` (a test that errors), and the
  dependency fixtures under `tools/fixtures/deps` (cycle, layer violations,
  unresolved requires). `check-all` runs both and requires the first to make
  the test runner exit non-zero and the second to be caught by the checker's
  self-test. Change a fixture to pass and CI goes red.

## Running locally

```bash
lune run tools/check-all.luau
```

Add `--quick` to skip the Rojo build. Rokit's shims must be on PATH
(`rokit self-install` does this; open a new terminal afterwards).
