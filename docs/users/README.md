# User guide

`test-certificates` implements the local certificate store of the
test-certificate standard
([Transport §2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#2-the-local-certificate-store-required))
and its git-notes carrier (Transport §3), with a `pre-push` hook that carries
certificates with every push, as specified for the reference tooling
([Tooling §2–§5](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md)).
Every command is a thin wrapper over a library call of the same name; both
are described here.

- [Installation](#installation)
- [The store](#the-store)
- [Commands](#commands): `store-root`, `put`, `find`, `prune`, `notes`, `hook`
- [Carrying certificates with every push](#carrying-certificates-with-every-push)
- [Troubleshooting](#troubleshooting)
- [Environment](#environment)

## Installation

The tool is one executable, `test-certificates`, with no runtime dependency
beyond the C library. It needs `git` on `PATH` for everything except
`store-root`, `put`, `find --content` and `prune` outside a repository.

| Route            | How                                                                                                                                                                                                                                                                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Nix              | `nix profile install github:metacraft-labs/test-certificates-tools`, or run it once with `nix run github:metacraft-labs/test-certificates-tools -- --help`. In a flake: the input's `packages.<system>.default` (also `.test-certificates`).                                                               |
| Release archives | From a [GitHub release](https://github.com/metacraft-labs/test-certificates-tools/releases), once one is published: `test-certificates-<version>-<os>-<arch>.tar.gz` (Linux x86_64 also as `.deb` and `.rpm`, Windows x86_64 as `.zip`), with a signed checksum manifest. Unpack and put `bin/` on `PATH`. |
| From source      | Nim 2.2 or later: `nim c -d:release -o:test-certificates src/test_certificates_cli.nim`, or `nimble install`.                                                                                                                                                                                              |
| Reprobuild       | `uses: "test-certificates"` in a `repro.nim`, through the package catalog's interface of that name; or, for the Nim library, `uses: "test_certificates"` with this repository developed beside yours.                                                                                                      |

As a Nim library, put `src/` on the module path (or `nimble install`) and
`import test_certificates`.

## The store

```
<root>/v1/<algorithm>/<digest>/<payload-hash>.toml
```

`<algorithm>:<digest>` is the certificate's content id, split at its first
`:`; `<payload-hash>` is the SHA-256 of the certificate's canonical payload,
rebuilt from its parsed fields. Algorithm identifiers contain 1–64 lowercase
ASCII letters, digits or hyphens; `con`, `prn`, `aux`, `nul`, `com1`–`com9`
and `lpt1`–`lpt9` are forbidden. Names outside this grammar are malformed on
every platform.
`put` and `find --content` accept well-formed ids in unknown algorithms
verbatim, without computing the algorithm. A user has two roots:

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
- When the name already exists, a **signed** relay (one with a non-empty
  `[certificate.signature]` block) replaces an unsigned copy only. It preserves
  an existing signed copy; an **unsigned** relay keeps either. `put` neither
  makes nor verifies signatures. A stored record that cannot be read, parsed
  or matched to its name is reported and left unchanged.
- A user root created by `put` is readable and writable by its owner only.
  An existing user root must belong to the effective account running `put`
  or `prune`; foreign roots are refused without changing their permissions.
- With `--system`, the installer's partition must already exist and belong to
  the producer. Its recipient must be a distinct account that can read and
  traverse it but cannot write it. Existing directories below the partition
  and the writer lock are checked before use; symbolic links are never followed.
  Created directories inherit the partition's group and permission bits;
  records inherit the group and bits with execute removed, even under a
  restrictive umask. Extended or default ACL policies are explicitly refused
  because this release cannot preserve them safely. `prune --system` applies
  the same preconditions before deleting. `--system` is unsupported on Windows.
- Refused, and nothing written: input that is not TOML, a schema other than
  `test-certificate.v1`, a malformed `content`, a missing required field,
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

| Exit | Meaning                                                                                                                                                                                                                                                                                                                     |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | Candidates found, even if the other root could not be read or resolved (still reported).                                                                                                                                                                                                                                    |
| 1    | No candidates found; both roots searched without root resolution or directory reading failures. Missing roots and missing or empty content directories count as completed empty searches.                                                                                                                                   |
| 2    | The content id could not be computed: not a git repository, an unknown revision or algorithm, an algorithm this repository cannot compute, a malformed `--content`, or a state with no content id (unmerged entries, `assume-unchanged`, present `skip-worktree` entries, a modified submodule). Neither root was searched. |
| 3    | No candidates found and a root could not be read or resolved, including unreadable intermediate or content directories. Discovery was incomplete.                                                                                                                                                                           |
| 64   | Usage error: missing or multiple state flags, unknown arguments, missing option operands (including empty `--paths`), or `--paths` / `--algorithm` with `--content`.                                                                                                                                                        |

Syntax is checked first, before computing an id or searching. After an id is
obtained, candidates take precedence over an unreadable or unresolved root;
otherwise an incomplete search takes precedence over absence.

Library: `find(roots, FindQuery): FindReport` and `findById(roots, id)`;
the report's `outcome` distinguishes `foFound`, `foNone`, `foUncomputable`
and `foIncomplete`. `computeContentId(repository, state, [algorithm,] scope)` computes an id on
its own.

### `prune`

```
test-certificates prune [--keep <n>] [--system <user>] [--paths <path>...]...
```

Removes content directories beyond the newest `n` (default 20, by
modification time) from the user root, or from a system partition when run
by its owner. Protects the unscoped content of `HEAD` in the repository's
native `git-tree-*` algorithm and in `manifest-v1-sha256`, plus both ids for
each explicitly declared scope. Each `--paths` group is one scope: for example,
`--paths src lib --paths tests` declares `["src", "lib"]` and `["tests"]`,
without implicitly declaring `["src"]` or `["lib"]`. Paths are literal and
repository-relative; `--` within a group makes its remaining paths literal
arguments, including names starting with `-`. Every scope the repository
declares for its certificates (`testCertificatesScope.<name>.path`, see
[`notes`](#notes)) is protected too, exactly as if given as a `--paths`
group. Scopes are never inferred from stored certificates. Protection is additional to the newest `n`, even at zero.

All ids use one fixed `HEAD` tree, including in bare repositories; staged and
working-tree changes do not affect them. Outside a repository or on an unborn
branch there is no automatic protection, and the declared scopes are not
read. Explicit scopes without `HEAD`, an invalid scope declaration, or a
failure computing an id for an existing `HEAD`, abort before any deletion,
including leftover cleanup. Never removes a directory a producer is writing into. Each directory is renamed
aside to a `.`-prefixed name before it is deleted, so a writer racing the
prune retries safely; leftovers of an interrupted prune are deleted and never
count as content. Prints each removed directory. Exit 0, or 1 when something
could not be removed (reported), 2 on a usage error.

Library: `pruneProtection(repository, scopes): HeadContentIds` computes the
complete protection set, declared scopes included (check `ok` before
pruning; `headContentIds` is the same without the declared scopes), then
`pruneRoot(root, keep, protectedIds, system = false): PruneResult` applies it.

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

**Declared scopes.** A scoped certificate is keyed by its _scoped_ tree —
the tree holding only the in-scope entries, at their full paths
([Content-Id §4.1](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Content-Id.md#41-git-tree-sha1-and-git-tree-sha256))
— and nobody can find it without knowing the scope. So the repository
declares its scopes in git configuration, one section per scope and one
literal path per `path` value
([Tooling §3.1](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md#31-declared-scopes)):

```ini
[testCertificatesScope "db"]
    path = Cargo.lock
    path = src/db-backend
[testCertificatesScope "docs"]
    path = docs
```

```sh
git config --add testCertificatesScope.db.path Cargo.lock
git config --add testCertificatesScope.db.path src/db-backend
```

That declares two scopes, `["Cargo.lock", "src/db-backend"]` and `["docs"]`
— each section is one scope, exactly like one `--paths` group of `find` — and
never `["src/db-backend"]` alone. Paths are literal (no globbing, no
splitting) and must be scope paths: repo-relative, `/`-separated, no leading
or trailing `/`, no empty, `.` or `..` component. The section name only
appears in reports. A malformed path, a `path` with no value, or any other key
under `testCertificatesScope` makes the declaration invalid: `notes publish`
and `notes import` then report it and do nothing, and the hook reports it and
lets the push go. git reads no configuration from the working tree; to keep
the declaration under version control, commit it as a file and have each
clone include it, e.g. `git config include.path ../.test-certificates-scopes`.

A certificate for a scope that is not declared stays in the local store
(`find --paths` finds it) and never travels.

Every note holds its records in the framing of
[Transport §3.1](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#31-multiple-records-in-one-note):
each record in canonical form (its canonical payload, then, when signed, a
blank line and the signature table), preceded by the line
`# --- test-certificate ---`.

**`notes publish`** adds the store's certificates (both roots) for each of a
commit's trees — `<commit>^{tree}`, and its scoped tree in every declared
scope — to the note on that tree, in the **local** ref only. A revision containing `..` or `^-`, or ending in `^!` or `^@`, is a range; any
other names one commit. Publishing is idempotent: a record is identified by
its payload hash, and a payload already in the note is not added again. A
signed copy replaces an unsigned record of the same payload in place only
when no signed copy is already present; an unsigned copy never replaces anything. Everything else in the note — other
frameworks' records, records this tool cannot parse, text before the first
delimiter — is kept byte for byte. A store file that does not parse is
reported and not published. Standard output lists `<content-id>
<payload-hash>` for every record added or replaced.

**`notes import`** copies the records in the notes on each commit's trees
(its own and, for every declared scope, its scoped tree; default `HEAD`) into
the user root, as `put` would. Text before the first
delimiter, a piece that does not parse, and a record whose `content` names
another tree (misattached) are reported on standard error and skipped; the
other records are still imported. Standard output lists the stored paths.

**`notes push`** pushes the local ref without force. When the remote ref has
moved, it fetches it, merges the **union** of both sides' records into the
local ref, and tries again — five attempts in all, with backoff. A lost race
is told by reading the remote ref again, never from the server's wording; a
refusal while the remote ref has not moved (a server hook, a permission) is
tried once more and then reported. **`notes
fetch`** fetches the remote ref and merges it into the local one the same
way. The merge never lets one side win: for every annotated tree, the result
keeps the remote pieces in their order, then appends missing local records and
unparsable pieces in local order. A signed copy upgrades an unsigned match;
when signed copies differ, the remote's copy is kept and the conflict reported.
Existing duplicate payloads are preserved. Different leading blocks join once,
and a supplied LF is reported when needed to preserve a delimiter boundary. When one side already contains the other
the ref just moves forward. A merge is an ordinary two-parent commit, so
`git log <ref>` shows both histories. Both print the resulting ref value on
standard output.

Notes are not pushed or fetched by git by default; these commands are how
they move. Neither ever prompts for credentials: a remote that needs them
and cannot get them fails, and says so. `notes push` runs the repository's
`pre-push` hook like any push (a caller that is itself a `pre-push` hook
turns that off through the library, `PushOptions.runHooks`, so it does not
re-enter the hook). When that hook is `hook pre-push`, it sees only the notes
ref and does nothing. `PushOptions.timeoutMs` bounds a push's network time
from the library; the command sets no limit. A program that embeds the library
and resolved a git of its own passes it as `PushOptions.gitExe` (and
`fetchNotes(gitExe = …)`), so the push runs that git rather than the first
`git` on `PATH`; the command uses `PATH`.

`publish`, `push` and `fetch` make commits on the notes ref. They are made
with git's configured identity. Where git has none — a CI container, say —
they are made as `test-certificates <test-certificates@localhost>` and a
`note:` line on standard error says so. A notes commit's author carries no
weight: what a certificate is worth is its signature (Transport §3).

While they run they keep private refs under
`refs/notes/test-certificates-work/` and `refs/test-certificates/fetch/`, and
delete them when done. A run that is killed cannot; the next `publish`,
`push` or `fetch` in the repository deletes what such a run left behind: a
ref older than an hour, or one made on this host by a process that no longer
exists (and older than a minute). Each name records the host, process and
time that made it.

Exit 0 on success, 1 when an operation failed (reported), 2 on a usage
error. A note piece that is reported and skipped is not a failure.

Library: `publishNotes(dir, roots, revisions): PublishReport`,
`importNotes(dir, userRoot, revisions): ImportReport`,
`pushNotes(dir, remote): SyncReport`, `fetchNotes(dir, remote): SyncReport`;
the framing itself is `splitNote`, `renderNote`, `addRecord` and
`mergeNotes`; the declaration is `declaredScopes(dir): ScopeDeclaration` and
the scoped trees of many trees at once `scopedTrees(dir, hexLen, trees,
scopes): ScopedTrees`. `PublishedTree.scope` and `ImportedTree.scope` say
which declared scope a tree is for (empty for a commit's own tree).

### `hook`

```
test-certificates hook pre-push <remote-name> <remote-url>
test-certificates hook install [--print]
```

**`hook pre-push`** is a complete `pre-push` hook body
([Tooling §4](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md#4-hooks)).
git runs a `pre-push` hook with the remote's name and URL as its two
arguments and one line per pushed ref on standard input
([githooks(5)](https://git-scm.com/docs/githooks#_pre_push)); this command
takes exactly that. For the commits the push introduces it publishes the
store's certificates into the local notes ref (as `notes publish` would) and
pushes the notes ref to the same remote (as `notes push` would, union merge
and retries included), then lets the push go on.

- **It never fails the push.** It exits 0 whatever happens. A certificate that
  could not be propagated — the remote refused the notes ref, the remote
  could not be reached, the store could not be read — is reported on standard
  error as a `warning:`, with the command that retries it; the receiving gate
  decides what missing certificates mean.
- **What a push introduces**
  ([Tooling §4.2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md#42-the-commits-a-push-introduces)),
  per pushed ref: the commits between the remote's current value and the
  pushed one, when this clone has the remote's value; otherwise (a new branch,
  or a remote value this clone never fetched) the commits no remote-tracking
  ref of that remote reaches. In every case, what the remote values of the
  other refs in the same push reach is left out too. A push to a URL with no
  configured remote has no remote-tracking refs, so the pushed ref's whole
  history is considered. Only trees with certificates in the store are
  published, so that costs one `git rev-list`, plus one tree walk per
  component of the deepest declared scope path and a few commands per
  distinct in-scope content.
- **What it publishes:** each introduced commit's tree and its scoped tree in
  every declared scope, as `notes publish` would.
- **Left alone:** deletions; refs under `refs/notes/` (so your own `notes
push`, or `git push origin refs/notes/…`, runs the hook without it pushing
  anything a second time); a tag of a tree or a blob. An annotated tag of a
  commit counts as that commit.
- **When there is nothing to carry** — no introduced commit has certificates
  in the store — it makes no network operation at all and says so in one
  line.
- **Where the notes go:** to the remote's name when the push names a
  configured remote (so its push URL is used), otherwise to the URL.
- **Its own push runs no hook** (`git push --no-verify`), so it does not
  re-enter itself. The library call is `prePushHook`, which passes
  `PushOptions.runHooks = false` to `pushNotes`.
- **Bounded time.** Its network operations — every push attempt, the fetches,
  merges and backoff between them, and reading a note a partial clone lacks —
  share a budget of 60 seconds;
  `TEST_CERTIFICATES_HOOK_TIMEOUT` (whole seconds, at least 1) changes it.
  There is no unlimited setting
  ([Tooling §4.3](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md#43-publishing-pushing-and-the-time-budget)):
  any other value is reported and the default used. A `git` still running
  when the budget is spent is stopped together with everything it started
  (`ssh`, a credential helper), reported, and the push goes on: on Linux and
  macOS its process group gets SIGTERM, then SIGKILL; on Windows its job
  object is terminated. On Linux and macOS, `git` and its helpers run without
  a controlling terminal there, so an `ssh` that would ask for a passphrase on the
  terminal fails at once (use an agent) instead of waiting unseen for the
  budget to run out. Interrupting the push (Ctrl-C) stops them as well.
- **Partial clones.** Deciding what a push introduces fetches nothing. A remote
  object the clone lacks counts as unknown, so the remote-tracking refs stand in
  for it, and with no certificates to carry the hook touches no remote. This
  relies on `GIT_NO_LAZY_FETCH`. With a git that ignores it (2.38.5 does; 2.42.2
  and 2.53.0 do not) a lookup can start a fetch, which the budget then stops. In a `tree:0` clone
  with declared scopes, a tree the clone lacks is reported as a warning: fetch
  that tree, or use `blob:none`, for scoped certificates to travel.
- **Opting out of one push:** `TEST_CERTIFICATES_HOOK=off git push …` (also
  `0`, `false`, `no`). The hook says it skipped propagation. `git push
--no-verify` skips every `pre-push` hook, this one included.

What it prints, on standard error, prefixed `test-certificates:`:

```
test-certificates: 2 certified tree(s) among 3 pushed commit(s): 3 certificate(s) added to refs/notes/test-certificates/certificates; pushed to origin
test-certificates: no stored certificates for the 1 commit(s) this push introduces; nothing to propagate
test-certificates: warning: pushing refs/notes/test-certificates/certificates to origin was refused: [remote rejected] (hook declined)
test-certificates: warning: certificates were NOT fully propagated; the push continues. Retry with `test-certificates notes push origin`.
```

**`hook install`** writes the hook below as the repository's `pre-push`
(in the directory git uses for hooks, `core.hooksPath` included) and prints
its path. It never replaces an existing hook: when one is there it fails and
says so — call the body from that hook instead (next section). Installing
twice is a no-op. `--print` prints the hook and writes nothing.

```sh
#!/bin/sh
# pre-push: carry test certificates with every push, as git notes.
# Installed by `test-certificates hook install`. It never fails the push:
# a certificate that could not be propagated is reported, and the push goes on.
if command -v test-certificates >/dev/null 2>&1; then
  test-certificates hook pre-push "$@"
else
  echo "test-certificates: not on PATH; certificates were not propagated" >&2
fi
# Whatever happened above, even a crash: read what is left of the pushed
# refs, so git never writes to a closed pipe, and let the push go on.
cat >/dev/null
exit 0
```

It finds the tool on `PATH` when the push runs, rather than naming the binary
that installed it, which may have been a Nix store path collected since.

Library: `prePushHook(dir, remoteName, remoteUrl, input, roots, options):
HookReport` (`introducedCount` is how many commits the push introduces;
`certified` lists those whose certificates were carried), `parsePrePushInput(text)`, `installPrePushHook(dir)`,
`PrePushHookScript`.

## Carrying certificates with every push

A repository needs the hook body to run on every push, and the receiving side
needs to fetch the notes.

**No `pre-push` hook yet:** `test-certificates hook install`.

**An existing `pre-push` hook.** The pushed refs arrive on standard input,
which can be read once, so the hook keeps a copy and hands it to each body.
Add, before anything else in the hook reads standard input:

```sh
refs="$(mktemp)"; trap 'rm -f "$refs"' EXIT
cat >"$refs"
test-certificates hook pre-push "$@" <"$refs"   # never fails; no `|| exit`
# ... the rest of the hook reads "$refs" instead of standard input:
my-other-check "$@" <"$refs" || exit 1
```

**A hook dispatcher that already copies standard input** for the bodies it
chains — Reprobuild's managed dispatcher does: it runs an executable
`.git/hooks/pre-push.repro-local`, then its own body, each with the arguments
and a replay of standard input — needs only a body that calls this one. With
no `pre-push.repro-local` yet:

```sh
test-certificates hook install --print >.git/hooks/pre-push.repro-local
chmod +x .git/hooks/pre-push.repro-local
```

When `pre-push.repro-local` exists (a pre-commit shim, say), add the copy and
the call to it as for any existing hook above.

**Frameworks that hide standard input.** The pre-commit framework runs
`pre-push` stage hooks without git's standard input (it passes the refs in
`PRE_COMMIT_*` variables instead), so `hook pre-push` cannot be one of its
hooks. Chain it ahead of the framework's shim as above.

**The receiving side.** A gate, CI job or reviewer fetches the notes and
looks up the content in front of it:

```sh
test-certificates notes fetch origin
test-certificates notes import <commit>...   # into the user store
test-certificates find --commit <commit>     # the candidates, for the verifier
```

or reads the notes ref directly (Transport §3) without the tool.

## Troubleshooting

"No certificates" is the symptom of every propagation failure, so first find
out which side is missing what. `find` reports what it searched on standard
error: the content id, both roots, and each directory with `listed`, `absent`
or `unreadable`.

| Symptom                                                               | Look at                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The hook says `no stored certificates for the N commit(s)`            | Run `test-certificates find --commit <commit>` in the same environment. `absent` under the user root you expected means the producer wrote elsewhere: a different `TEST_CERTIFICATES_DIR`, `XDG_STATE_HOME` or user than the push runs with. A content id that differs from the producer's means it certified another state (uncommitted changes, a scope). |
| The hook printed nothing at all                                       | It was not run (`git config core.hooksPath`, the hook's executable bit, `git push --no-verify`), or the push introduced no commits (everything was already on the remote, a deletion, a notes ref).                                                                                                                                                         |
| The hook warned that certificates were not propagated                 | The warning names the failure. The local notes ref holds what was published; `test-certificates notes push <remote>` retries. A remote that refuses `refs/notes/*` (a server-side hook, branch protection on all refs) needs that permission.                                                                                                               |
| The receiving side's `find --commit` says `absent`                    | Did the notes travel? `git ls-remote <remote> 'refs/notes/*'` on the remote; `test-certificates notes fetch <remote>` then `notes import <commit>` before `find`. Notes are never fetched by a plain `git fetch` or `git clone`.                                                                                                                            |
| `notes import` reports `no note` for a commit whose push carried some | Both sides must use the same notes ref: `git config testCertificates.notesRef` (default `refs/notes/test-certificates/certificates`).                                                                                                                                                                                                                       |
| A scoped certificate never reaches the receiving side                 | Its scope must be declared (`git config --get-regexp '^testcertificatesscope'`) on the pushing side to be published, and on the importing side to be imported. Each section is one scope: `src` and `lib` in one section is not the scope `src`.                                                                                                            |
| `find` reports `unreadable`                                           | A permission problem, reported rather than read as "nothing found": fix the directory's permissions.                                                                                                                                                                                                                                                        |
| The push takes as long as the time budget                             | The remote does not answer the notes push. Lower `TEST_CERTIFICATES_HOOK_TIMEOUT`, or opt out of the push with `TEST_CERTIFICATES_HOOK=off`.                                                                                                                                                                                                                |
| `could not read trees for the declared scopes` in a partial clone     | The clone was made with a `tree:0` filter and lacks a tree the scope needs. The hook does not fetch to find out whether there is anything to carry. Use a `blob:none` clone, or fetch the trees first.                                                                                                                                                      |

## Environment

| Variable                                                | Effect                                                                                 |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `TEST_CERTIFICATES_DIR`                                 | The user root, when absolute.                                                          |
| `TEST_CERTIFICATES_SYSTEM_DIR`                          | The directory holding every user's system partition, when absolute.                    |
| `XDG_STATE_HOME`, `HOME`, `LOCALAPPDATA`, `ProgramData` | Platform defaults, as above.                                                           |
| `GIT_INDEX_FILE`                                        | Honoured by `find --staged` (as git sets it during a commit).                          |
| `TEST_CERTIFICATES_HOOK`                                | `off` (`0`, `false`, `no`): `hook pre-push` propagates nothing and says so.            |
| `TEST_CERTIFICATES_HOOK_TIMEOUT`                        | Whole seconds, at least 1, the hook's network operations may take in all (default 60). |
