# User guide

`test-certificates` implements the local certificate store of the
test-certificate standard
([Transport §2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#2-the-local-certificate-store-required))
and its git-notes carrier (Transport §3), as specified for the reference
tooling ([Tooling §2, §3, §5](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md)).
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

### `notes`

```
test-certificates notes publish <commit>|<range>...
test-certificates notes import [<commit>|<range>...]
test-certificates notes push <remote>
test-certificates notes fetch <remote>
```

The store does not leave the machine. These commands carry certificates in a
git notes ref, attached to the **tree** each commit's content id names
([Transport §3](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#3-git-notes-recommended-for-pushing)),
so they travel with a push to a receiving-side gate, a reviewer or CI.

The ref is `refs/notes/test-certificates/certificates`, or what
`git config testCertificates.notesRef <ref>` sets for the repository. It must
be a valid ref name under `refs/notes/`; anything else is refused.

Every note holds its records in the framing of
[Transport §3.1](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#31-multiple-records-in-one-note):
each record in canonical form (its canonical payload, then, when signed, a
blank line and the signature table), preceded by the line
`# --- test-certificate ---`.

**`notes publish`** adds the store's certificates (both roots) for each
commit's `<commit>^{tree}` to the note on that tree, in the **local** ref
only. A revision containing `..` or `^-`, or ending in `^!` or `^@`, is a range; any
other names one commit. Publishing is idempotent: a record is identified by
its payload hash, and a payload already in the note is not added again. A
signed copy replaces an unsigned record of the same payload in place; an
unsigned copy never replaces anything. Everything else in the note — other
frameworks' records, records this tool cannot parse, text before the first
delimiter — is kept byte for byte. A store file that does not parse is
reported and not published. Standard output lists `<content-id>
<payload-hash>` for every record added or replaced.

**`notes import`** copies the records in the notes on each commit's tree
(default `HEAD`) into the user root, as `put` would. Text before the first
delimiter, a piece that does not parse, and a record whose `content` names
another tree (misattached) are reported on standard error and skipped; the
other records are still imported. Standard output lists the stored paths.

**`notes push`** pushes the local ref without force. When the remote ref has
moved, it fetches it, merges the **union** of both sides' records into the
local ref, and tries again — five attempts in all, with backoff. **`notes
fetch`** fetches the remote ref and merges it into the local one the same
way. The merge never lets one side win: for every annotated tree, the result
holds every record of both sides, each payload once (a signed copy replaces
an unsigned one; of two differently signed copies, the remote's is kept), and
every piece neither side can parse. When one side already contains the other
the ref just moves forward. A merge is an ordinary two-parent commit, so
`git log <ref>` shows both histories. Both print the resulting ref value on
standard output.

Notes are not pushed or fetched by git by default; these commands are how
they move. Neither ever prompts for credentials: a remote that needs them
and cannot get them fails, and says so. `notes push` runs the repository's
`pre-push` hook like any push (a caller that is itself a `pre-push` hook
turns that off through the library, `PushOptions.runHooks`, so it does not
re-enter the hook).

`publish`, `push` and `fetch` make commits on the notes ref. They are made
with git's configured identity. Where git has none — a CI container, say —
they are made as `test-certificates <test-certificates@localhost>` and a
`note:` line on standard error says so. A notes commit's author carries no
weight: what a certificate is worth is its signature (Transport §3).

Exit 0 on success, 1 when an operation failed (reported), 2 on a usage
error. A note piece that is reported and skipped is not a failure.

Library: `publishNotes(dir, roots, revisions): PublishReport`,
`importNotes(dir, userRoot, revisions): ImportReport`,
`pushNotes(dir, remote): SyncReport`, `fetchNotes(dir, remote): SyncReport`;
the framing itself is `splitNote`, `renderNote`, `addRecord` and
`mergeNotes`.

## Environment

| Variable                                                | Effect                                                              |
| ------------------------------------------------------- | ------------------------------------------------------------------- |
| `TEST_CERTIFICATES_DIR`                                 | The user root, when absolute.                                       |
| `TEST_CERTIFICATES_SYSTEM_DIR`                          | The directory holding every user's system partition, when absolute. |
| `XDG_STATE_HOME`, `HOME`, `LOCALAPPDATA`, `ProgramData` | Platform defaults, as above.                                        |
| `GIT_INDEX_FILE`                                        | Honoured by `find --staged` (as git sets it during a commit).       |
