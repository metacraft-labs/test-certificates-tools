# AGENTS.md

Helper tooling for the test-certificate standard: the local certificate store
(`store-root`, `put`, `find`, `prune`) as a Nim library (`test_certificates`)
and the `test-certificates` command over it.

## Repository class and branches

- A **product** repository: mainline `dev`, default branch `stable`. Feature
  work lands on `agents` by a fast-forward push and reaches `dev` through a
  promotion pull request. No CI runs on `agents`; run the gates below
  locally before pushing.
- It is **public**. Commit messages, file content and links must never name
  or cite private repositories, plans, milestones, internal issue ids or local
  paths.
- The specification it implements is
  [test-certificates-spec](https://github.com/metacraft-labs/test-certificates-spec).
  A behaviour the specification does not settle is raised there, not decided
  here silently.

## Commands

Inside the dev shell (`nix develop`, or direnv):

```sh
just build     # build/bin/test-certificates
just test      # builds, then runs every tests/t_*.nim
just lint      # nph --check, nim check (incl. a Windows cross-check), nixfmt --check
just format    # nph, nixfmt
nix build .#default
```

The tests need a checkout of `test-certificates-spec` beside this one (or
`TEST_CERTIFICATES_SPEC_DIR`) containing the commit in
`tests/spec-vectors.pin`.

## Layout

| Path                            | Contents                                                                                              |
| ------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `src/test_certificates.nim`     | The library's umbrella module.                                                                        |
| `src/test_certificates/`        | One module per concern; see [docs/contributors/architecture.md](./docs/contributors/architecture.md). |
| `src/test_certificates_cli.nim` | The executable: hands its arguments to `cli.runCli`.                                                  |
| `tests/`                        | `t_*.nim` test files, `helpers.nim`, `spec-vectors.pin`.                                              |
| `docs/users/`                   | The user guide.                                                                                       |
| `docs/contributors/`            | Design, races, testing approach.                                                                      |

## Rules that are easy to break

- Library code returns errors in its result objects. No `quit`, no raising
  to the caller, no logging.
- Never write the user's index. Every git command goes through `git.git`,
  which sets `GIT_OPTIONAL_LOCKS=0`; index work happens in a temporary copy.
- A store name is derived from the canonical payload rebuilt from parsed
  fields, never from the file's bytes.
- Tests use the real filesystem, real git and the built binary. Justify any
  mock in the test file's header; a missing prerequisite fails, never skips.
