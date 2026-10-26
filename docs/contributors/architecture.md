# Architecture

The package implements the local certificate store of the test-certificate
standard ([Transport §2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#2-the-local-certificate-store-required))
and the content-id computations a lookup needs
([Content-Id §4, §5](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Content-Id.md)).
Read those two documents before changing anything here; the comments cite
them by section.

## Modules

| Module          | Responsibility                                                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `sha256`        | FIPS 180-4 SHA-256, streaming. The standard library has none and the package takes no dependencies.                                                          |
| `toml`          | A strict TOML 1.0 reader. Accepts every rendering the conformance suite uses; refuses redefinitions and malformed text. Numbers and date-times are kept raw. |
| `content_id`    | Content-id form (Content-Id §1), never repaired; `manifest-v1-sha256` over explicit entries (§4.2).                                                          |
| `certificate`   | Parse a record, rebuild its canonical payload (Canonical-Payload §2–§4), name it (Transport §2.2), tell signed from unsigned.                                |
| `git`           | Run git with stdout and stderr apart, servicing stdin and both outputs together so a large `cat-file --batch` cannot deadlock. No shell.                     |
| `content_state` | The content id of a commit, the index being committed, or the working tree, in a temporary index (Content-Id §4.1, §5), with the §3 refusals.                |
| `roots`         | Root resolution (Transport §2.1) as a pure function of platform, environment and account; the uid or the Windows SID of this process.                        |
| `layout`        | The naming conventions writers, readers and pruners share.                                                                                                   |
| `put`           | The atomic writer (Transport §2.3), including the system-root no-follow writer and the retry after a prune.                                                  |
| `find`          | Reading both roots (Transport §2.4) and the search report (§5).                                                                                              |
| `prune`         | Rename-aside pruning (Transport §2.5).                                                                                                                       |
| `cli`           | The command line as a library procedure (`runCli`); `src/test_certificates_cli.nim` is the three-line executable.                                            |

Every operation returns a result object carrying its error; nothing raises to
the caller, calls `quit`, or logs.

## Decisions worth knowing

- **The name comes from the payload, never the file.** `put` parses the record
  and rebuilds the canonical payload from the parsed fields, so a CRLF file,
  a reordered one or one with literal strings lands on the same name as its
  canonical rendering. The file stored is the input, byte for byte.
- **Unknown fields are refused, not dropped.** A key the schema does not
  define inside `[certificate]`, `[certificate.vcs]` or a command would, if
  dropped, name the record by a payload its producer never computed.
- **"Signed" means a non-empty signature block.** The tool does not verify
  (Tooling §1), so the replacement rule of Transport §2.3 is applied to what
  the block claims. A block with only one of `algorithm`/`value` is refused.
- **Temporary index, epoch-dated.** The working-tree id is computed in a copy
  of the index whose modification time is set to 1 s after the epoch, with
  `core.fsmonitor=false`, so every entry is racily clean and git compares
  content, not stat data. All git commands run with `GIT_OPTIONAL_LOCKS=0`,
  so not even `git status` refreshes the user's real index.
- **Scoping follows the spec's recipe literally**: `ls-tree -r --full-tree`
  with `--literal-pathspecs` piped into `update-index --index-info` on an
  empty index. Full paths are kept; `lit*` names a directory, not a pattern.

## The races

**Concurrent publishers.** Each writes a uniquely named temporary file in the
target directory (`.<name>.tmp-<pid>-<n>-<ns>`, never ending in `.toml`),
flushes it with `fsync`, and renames it onto the final name. Two publishers
either write different names or the same payload under the same name.

**A writer and a pruner.** The pruner takes a directory out of the store by
renaming it aside (one atomic step) before deleting the renamed tree; it
skips directories modified within 10 s or holding a temporary file younger
than an hour. A writer that loses its directory anyway notices in one of two
ways — its temporary file vanished before the rename, or after the rename
the path no longer leads to the directory it holds open — and recreates the
directory and retries once. The retry's directory postdates the rename aside,
so that prune cannot reach it.

**The system root.** On POSIX, `put --system` opens the partition with
`O_NOFOLLOW`, checks it is owned by the writing account, and opens every
component below it with `openat(…, O_NOFOLLOW | O_DIRECTORY)`. The temporary
file is created with `O_EXCL | O_NOFOLLOW` and renamed with `renameat`, which
replaces a planted link rather than following it. Windows lacks the
primitives used here, so `--system` is refused there; reading the system
root (`find`) works everywhere, with the account's SID from its token.

## Tests

`just test` builds the executable and runs every `tests/t_*.nim`. Tests use
the real filesystem, real git repositories and the built executable; there
are no mocks. Where a race must be exercised deterministically, the library's
test seams (`PutStepHook`, `PruneStepHook`, `pruneRoot(now = …)`) choose the
interleaving and the real code does the rest. Each test file's header says
what it covers.

The conformance test reads the specification's `store/`, `content/` and
`payload/` vectors from a checkout of
[test-certificates-spec](https://github.com/metacraft-labs/test-certificates-spec)
— the sibling directory `../test-certificates-spec`, or
`$TEST_CERTIFICATES_SPEC_DIR` — at the commit `tests/spec-vectors.pin` names,
read from git's object store so the checkout's own revision does not matter.
Moving the pin is a deliberate change made together with whatever the new
vectors require. Negative controls corrupt one vector per group and require
the same checkers to report it.

A missing prerequisite (the binary, git, the specification checkout or the
pinned commit) fails the suite; nothing is skipped silently. The only skips
are POSIX-only cases on Windows, each marked in its test.
