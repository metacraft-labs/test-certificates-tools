# User guide

`test-certificates` implements the local certificate store of the
test-certificate standard
([Transport §2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#2-the-local-certificate-store-required))
as specified for the reference tooling
([Tooling §2, §5](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md)).
Every command is a thin wrapper over a library call of the same name; both
are described here.

## The store

```
<root>/v1/<algorithm>/<digest>/<payload-hash>.toml
```

`<algorithm>:<digest>` is the certificate's content id, split at its first
`:`; `<payload-hash>` is the SHA-256 of the certificate's canonical payload,
rebuilt from its parsed fields. A user has two roots:

| Root   | Resolved from                                                                                                                                                                                                                                              |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| user   | `$TEST_CERTIFICATES_DIR` if absolute; else `$XDG_STATE_HOME/test-certificates` or `~/.local/state/test-certificates` (Linux and other Unix-likes), `~/Library/Application Support/test-certificates` (macOS), `%LOCALAPPDATA%\test-certificates` (Windows) |
| system | `$TEST_CERTIFICATES_SYSTEM_DIR/<user>` if absolute; else `/var/lib/test-certificates/<uid>`, `/Library/Application Support/test-certificates/<uid>`, `%ProgramData%\test-certificates\<SID>`                                                               |

A relative value of any of these variables is ignored, and `store-root`
says so. The system root belongs to a privileged producer (a signing daemon
running under its own account); the user can read it but not write it.

## Commands

### `store-root`

```
test-certificates store-root
```

Prints `user: <path>` and `system: <path>` (or `(unresolved)`), and on
standard error any variable that was ignored and why. Exit 0, or 1 when the
user root cannot be resolved.

Library: `nativeRoots(): StoreRoots`, or `resolveRoots(platform, env,
account)` to resolve for any platform and environment.

### `put`

```
test-certificates put [--system <user>] <file>... | -
```

Parses each file as a certificate, requires a well-formed `content`, and
writes it atomically under its name in the user root — or, with `--system
<user>` (a uid; a SID on Windows), in that user's system partition. `-`
reads one certificate from standard input: the client half of a daemon's
delivery pipes what the daemon returned into `put -`. Prints each resulting
path. Exit 0 when every file was written, 1 otherwise (the others are still
written).

- The file stored is the input, byte for byte.
- When the name already exists, a **signed** certificate (one with a
  non-empty `[certificate.signature]` block) replaces it; an **unsigned** one
  keeps it, since the existing file is the same claim or the same claim
  signed. `put` does not verify signatures.
- A user root created by `put` is readable and writable by its owner only.
- With `--system`, the partition must already exist (its installer creates
  it, with permissions that let its user read it), must be owned by the
  account running `put`, and no symbolic link below it is ever followed: a
  planted link fails the write. Directories and files created there take the
  partition's permission bits. `--system` is not supported on Windows in
  this release, and says so rather than writing.
- Refused, and nothing written: input that is not TOML, a schema other than
  `test-certificate.v1`, a malformed `content` (or one whose algorithm
  cannot be a directory name on every platform), a missing required field,
  a record with no target or no command, a field the schema does not define
  (an earlier-draft record's `commit`/`clean`, for instance), and a
  signature block with only one of `algorithm` and `value`.

Library: `putCertificate(root, bytes, system = false): PutResult`,
`putFile(root, path, system = false): PutResult`.

### `find`

```
test-certificates find (--content <id> | --commit <rev> | --staged | --worktree)
                       [--paths <path>...] [--algorithm <algorithm>]
```

Prints the paths of the candidate certificates stored for a content id, from
both roots. With `--commit`, `--staged` or `--worktree` the id is computed
first, in the current directory's repository:

| State            | Content id of                                                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| `--commit <rev>` | `<rev>^{tree}`                                                                                       |
| `--staged`       | the index being committed (`git write-tree`; honours the `GIT_INDEX_FILE` git sets in a commit hook) |
| `--worktree`     | every tracked file as it is in the working tree, as a producer computes it                           |

`--paths` scopes the id to those repo-relative paths (a directory scopes its
subtree; paths are literal, never patterns). `--algorithm` is
`git-tree-sha1`, `git-tree-sha256` or `manifest-v1-sha256`; the default is
the repository's own `git-tree-*`.

Computing an id never reads or modifies your staging area: the index is
copied to a temporary file and every git command runs against the copy. It
re-reads every tracked file rather than trusting timestamps, so an edit made
in the same second as the last `git add` is seen.

Standard error reports the content id, both roots and the directories
searched (`listed`, `absent`, `unreadable`), and any file skipped:

- a copy byte-identical to one already found under the same name in the
  other root (a differing copy — say, one signed and one not — is returned
  too);
- a record whose own `content` is not the id it was filed under.

A file that does not parse is still returned, with a note: whether it counts
is your verifier's decision. An unreadable root is reported and the other
root still searched.

| Exit | Meaning                                                                                                                                                                                                                                                                                                                                        |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | candidates found                                                                                                                                                                                                                                                                                                                               |
| 1    | none found                                                                                                                                                                                                                                                                                                                                     |
| 2    | the content id could not be computed — not a git repository, an unknown revision, an algorithm this repository cannot compute (`git-tree-sha256` in a SHA-1 repository), a malformed `--content`, a state with no content id (unmerged entries, `assume-unchanged` or present `skip-worktree` entries, a modified submodule), or a usage error |

Library: `find(roots, FindQuery): FindReport` and `findById(roots, id)`;
`computeContentId(repository, state, [algorithm,] scope)` computes an id on
its own.

### `prune`

```
test-certificates prune [--keep <n>] [--system <user>]
```

Removes content directories beyond the newest `n` (default 20, by
modification time) from the user root, or from a system partition when run
by its owner. Never removes the directory for the current repository's
`HEAD^{tree}`, nor one a producer is writing into. Each directory is renamed
aside to a `.`-prefixed name before it is deleted, so a writer racing the
prune retries safely; leftovers of an interrupted prune are deleted and never
count as content. Prints each removed directory. Exit 0, or 1 when something
could not be removed (reported), 2 on a usage error.

Library: `pruneRoot(root, keep, protectedIds, system = false): PruneResult`.

## Environment

| Variable                                                | Effect                                                              |
| ------------------------------------------------------- | ------------------------------------------------------------------- |
| `TEST_CERTIFICATES_DIR`                                 | The user root, when absolute.                                       |
| `TEST_CERTIFICATES_SYSTEM_DIR`                          | The directory holding every user's system partition, when absolute. |
| `XDG_STATE_HOME`, `HOME`, `LOCALAPPDATA`, `ProgramData` | Platform defaults, as above.                                        |
| `GIT_INDEX_FILE`                                        | Honoured by `find --staged` (as git sets it during a commit).       |
