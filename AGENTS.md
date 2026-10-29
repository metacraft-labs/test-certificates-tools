# AGENTS.md

Helper tooling for the test-certificate standard: the local certificate store
(`store-root`, `put`, `find`, `prune`) and its git-notes carrier (`notes
publish`, `import`, `push`, `fetch`, and the `hook pre-push` body that runs
them on every push) as a Nim library (`test_certificates`) and the
`test-certificates` command over it.

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
just lint      # nph --check, nim check (incl. Windows and macOS cross-checks), nixfmt --check
just format    # nph, nixfmt
nix build .#default
nix flake check
```

Releases are cut from `stable` by a `v<version>` tag; see
[docs/contributors/releasing.md](./docs/contributors/releasing.md).

The tests use `ssh-keygen` from the dev shell for real signing controls and
need a checkout of `test-certificates-spec` beside this one (or
`TEST_CERTIFICATES_SPEC_DIR`) containing the commit in
`tests/spec-vectors.pin`.

The Linux permission tests (`t_permissions`) need a distinct `nobody` account
and root over it, which they get WITHOUT sudo where they can: the test binary
re-executes itself in a user namespace (`unshare` from the dev shell) where
it is root over this account's subordinate ids (`/etc/subuid`,
`/etc/subgid`, `newuidmap`). Only where unprivileged user namespaces are
unavailable (Ubuntu 24.04's AppArmor restriction, as on GitHub's runners)
do they fall back to `sudo -n`; with neither, they fail and say what is
missing. `setfacl` and `setpriv` come from the dev shell. Fixtures touch only
temporary directories.

On Windows there is no dev shell: `scripts/windows/test.ps1` builds and runs
the suite with nim 2.2, a MinGW-w64 gcc and Git for Windows on `PATH`.

## Layout

| Path                            | Contents                                                                                                 |
| ------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `src/test_certificates.nim`     | The library's umbrella module.                                                                           |
| `src/test_certificates/`        | One module per concern; see [docs/contributors/architecture.md](./docs/contributors/architecture.md).    |
| `src/test_certificates_cli.nim` | The executable: hands its arguments to `cli.runCli`.                                                     |
| `tests/`                        | `t_*.nim` test files, `helpers.nim`, `process_helper.nim` (a child for `t_process`), `spec-vectors.pin`. |
| `scripts/release/`              | The release build (`build.sh`, `build.ps1`) and the archive smoke check, run by the release workflow.    |
| `scripts/windows/test.ps1`      | The test suite on Windows (no Nix there), run by CI's Windows leg.                                       |
| `docs/users/`                   | The user guide.                                                                                          |
| `docs/contributors/`            | Design, races, testing approach.                                                                         |

## Rules that are easy to break

- Library code returns errors in its result objects. No `quit`, no raising
  to the caller, no logging.
- Never write the user's index. Every git command goes through `git.git`,
  which sets `GIT_OPTIONAL_LOCKS=0`; index work happens in a temporary copy.
- A store name is derived from the canonical payload rebuilt from parsed
  fields, never from the file's bytes.
- Tests use the real filesystem, real git and the built binary. Justify any
  mock in the test file's header; a missing prerequisite fails, never skips.
