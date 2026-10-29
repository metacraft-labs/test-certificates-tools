# Architecture

The package implements the local certificate store of the test-certificate
standard ([Transport §2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#2-the-local-certificate-store-required)),
its git-notes carrier (Transport §3, §3.1) and the content-id computations a
lookup needs
([Content-Id §4, §5](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Content-Id.md)).
Read those two documents before changing anything here; the comments cite
them by section.

## Modules

| Module            | Responsibility                                                                                                                                                                                                                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sha256`          | FIPS 180-4 SHA-256, streaming. The standard library has none and the package takes no dependencies.                                                                                                                                                                                                           |
| `toml`            | A strict TOML 1.0 reader. Accepts every rendering the conformance suite uses; refuses redefinitions and malformed text. Numbers and date-times are kept raw.                                                                                                                                                  |
| `content_id`      | Content-id form (Content-Id §1), never repaired; `manifest-v1-sha256` over explicit entries (§4.2).                                                                                                                                                                                                           |
| `certificate`     | Parse a record, rebuild its canonical payload (Canonical-Payload §2–§4), name it (Transport §2.2), tell signed from unsigned.                                                                                                                                                                                 |
| `git`             | Run git with stdout and stderr apart, servicing stdin and both outputs together so a large `cat-file --batch` cannot deadlock; output streamed to a sink on request; a time limit that stops the child and everything it started. No shell.                                                                   |
| `windows_process` | The Windows half of `git.runProcess`: `CreateProcessW` with an explicit handle list, a kill-on-close Job Object, overlapped named pipes and a deadline, MSVC argument quoting.                                                                                                                                |
| `work_refs`       | The names of the private work and fetch refs (host, pid, time), and the cleanup of those a crashed run left behind.                                                                                                                                                                                           |
| `content_state`   | The content id of a commit, the index being committed, or the working tree, in a temporary index (Content-Id §4.1, §5), with the §3 refusals.                                                                                                                                                                 |
| `roots`           | Root resolution (Transport §2.1) as a pure function of platform, environment and account; the uid or the Windows SID of this process.                                                                                                                                                                         |
| `layout`          | The naming conventions writers, readers and pruners share.                                                                                                                                                                                                                                                    |
| `put`             | The atomic writer (Transport §2.3), including the system-root no-follow writer and the retry after a prune.                                                                                                                                                                                                   |
| `find`            | Reading both roots (Transport §2.4) and the search report (§5).                                                                                                                                                                                                                                               |
| `prune`           | Rename-aside pruning (Transport §2.5).                                                                                                                                                                                                                                                                        |
| `note_framing`    | The note blob of Transport §3.1: split on delimiter lines, render byte for byte, the writer rule (`addRecord`), the union of two blobs (`mergeNotes`). No git.                                                                                                                                                |
| `scopes`          | The scopes a repository declares (Tooling §3.1) and the scoped trees of many trees at once: a batched tree walk finds the entries at each scope path, and each distinct in-scope content gets one scoped tree by `content_state`'s recipe. `pruneProtection`: HEAD's ids for prune, declared scopes included. |
| `notes`           | The notes carrier (Transport §3, Tooling §3): `publish`, `import`, `push`, `fetch`, the notes ref and its configuration, the union merge of two notes commits.                                                                                                                                                |
| `hook`            | The `pre-push` hook body (Tooling §4): git's hook input, the commits a push introduces, publish (declared scopes included) and push with hooks off and a finite time budget; `hook install`.                                                                                                                  |
| `cli`             | The command line as a library procedure (`runCli`); `src/test_certificates_cli.nim` is the three-line executable.                                                                                                                                                                                             |

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
  (Tooling §1), so it applies Transport §2.3's relay rule: a signed incoming
  copy upgrades an unsigned stored copy, while an existing signed copy stays.
  A block with only one of `algorithm`/`value` is refused.
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

**Serializing writers.** Every writer locks the root's persistent `.write-lock`
file before inspecting an existing certificate and holds it through the atomic
rename. POSIX uses `openat` with `O_NOFOLLOW` and `flock(LOCK_EX)`; Windows
uses `CreateFileW` with sharing disabled, waiting on a sharing violation. The
file is never unlinked: all waiters must continue naming the same lock object.
Closing the descriptor or process death releases ownership. Signers in other
implementations follow the same protocol, so a relay cannot inspect an unsigned
copy and then overwrite a signature another writer has just published.

**Long paths on Windows.** A record's path is long by construction (a
64-digit digest directory, a 64-digit payload hash and, while written, a
temporary suffix), and under a root that is not unusually deep it passes
MAX_PATH (260), where the plain Win32 calls fail. The writer, the reader and
the pruner pass such paths through `layout.extendedPath`, which gives an
absolute path of 240 characters or more the `\\?\` extended-length prefix.

**Store permission boundaries.** POSIX writers and pruners compare the
opened root's owner with their effective uid. System operations additionally
resolve the recipient's real primary and supplementary groups and check its
read, traverse and nonwrite access on each opened directory. Extended access
and default ACLs are refused explicitly; mode bits alone cannot establish the
policy they implement. Created entries receive the partition's group with
`fchown` and its permission bits with `fchmod`, independently of umask.

`put --system` opens the root and descendants with `O_NOFOLLOW`, checks the
persistent writer lock is regular, producer-owned and not recipient-writable,
and creates its temporary file with `O_EXCL | O_NOFOLLOW`. Existing nonregular
records are reported and left unchanged. System pruning anchors enumeration
and deletion in held descriptors, preflights nested directories, and unlinks
symbolic-link entries without traversing them. This includes interrupted-prune
leftovers and trees detached during the current prune. Windows user-root owner
checks compare the opened directory's owner SID with the effective token's
user SID or its default owner (`TokenOwner`): a member of Administrators
running elevated creates objects owned by `BUILTIN\Administrators` by
default, and refusing those would refuse the account's own store;
system writes and pruning remain unsupported there.

## The notes carrier

**Reading** a notes ref never goes through `git notes show`. The notes
commit's tree is listed with `git ls-tree -r -z`, the fanout `/` removed from
each path gives the annotated object, and the blob is read with `git cat-file
blob`, stdout only. This reads any fanout, works on a fetched commit that is
not under `refs/notes/`, and keeps every byte git prints on stderr (a trace,
a `safe.directory` notice) out of the note text, where it would sit before
the first delimiter and read as a framing fault.

**Writing** stores the new blob with `hash-object -w --stdin` and attaches it
with `git notes add -f -C <blob>` on a private work ref
(`refs/notes/test-certificates-work/<host>-<pid>-<n>-<time>`; `git notes
--ref` accepts only names under `refs/notes/`). `-C` takes the blob verbatim, where `-F`
and `-m` would strip blank lines and trailing whitespace, and git chooses the
fanout. The work ref's tree is committed once with `commit-tree` and the
notes ref moved with a compare-and-swap `update-ref <ref> <new> <old>`; the
work ref is deleted whatever happens. Before the commit, the tree built is
checked to be the base plus every change (the base an ancestor of the work
ref, each change's blob in its tree), so a work ref lost while in use
fails the write instead of publishing a tree missing notes. Without a committer identity (`git var
GIT_COMMITTER_IDENT` fails, as in a bare container) the commits are made as
`test-certificates <test-certificates@localhost>`, and the report carries a
remark saying so. Failing instead would make the tool unusable exactly where
notes are pushed unattended, and a notes commit's identity is not evidence of
anything (Transport §3: a note is worth its signature); inventing it silently
would hide a misconfiguration, so it is reported.

**Leftover private refs.** A run that is killed cannot delete its work ref
(or the `refs/test-certificates/fetch/` ref a fetch lands on). `publish`,
`push` and `fetch` therefore start by deleting stale ones (`work_refs`): a
ref older than an hour, or one made on this host by a process that no longer
exists and older than a minute — the grace keeps a ref out of reach where the
process table cannot be trusted to say so, such as containers sharing a host
name and a repository but not a pid namespace. A name this tool did not
make is never deleted, this process's refs are never taken by the second
rule, and each deletion is a compare-and-delete (`update-ref -d <ref>
<oid>`). Liveness is `kill(pid, 0)` on POSIX and `OpenProcess` on Windows.

**The union merge.** `git notes merge -s union` is not used: it concatenates
the two blobs with a blank line between, so a record both sides carry appears
twice and a blank line lands inside the record before the join — neither
deduplicated nor §3.1 framing (`-s cat_sort_uniq` sorts lines, which
destroys records outright). Instead, for every annotated object present on
both sides with different blobs, `mergeNotes(remote, local)` keeps the
remote (published) blob as it is and appends what the local one adds: a
payload the remote lacks, an unparsable piece it lacks, leading text it lacks
as whole lines (joined after its own, since leading text is never parsed;
leading text already present is not joined again, so repeated merges do not
grow it). A signed local
copy replaces an unsigned remote one in place; of two differently signed
copies the remote's is kept, because a merge has made neither signature and
cannot verify either, and keeping the published copy stops two clones from
trading the record back and forth. Ordering is therefore deterministic —
the remote's pieces in its order, then the local additions in local order —
and merging the same local side again changes nothing. Leading-block
containment requires a contiguous sequence of whole lines; corrupt-piece
equality ignores at most one final LF. Inserting a leading block or replacing
a record before another delimiter supplies and reports a missing LF so the
delimiter remains on its own line. Exact merge bytes and diagnostic categories
are pinned by the standard's `notes/merge-*` vectors. The merged tree is
built on the remote commit and committed with both commits as parents. When
one side is an ancestor of the other the ref is moved, not merged.

**Races.** In one repository, publishers and merges serialize on the
compare-and-swap and start over when they lose it (five attempts). Between
clones, `notes push` pushes the exact commit it read, never with force. When
the push is refused, the remote ref is read again (`git ls-remote`): if it
now holds a commit the pushed one does not contain, the push lost a race,
and it fetches, merges, backs off and retries, five attempts in all. The
server's reason text decides nothing — a server in another locale or with
its own wording (a hook that says anything at all) is handled alike. A
refusal while the remote ref holds nothing or an ancestor of the pushed
commit (the push would have been a fast-forward) is a refusal of the update
itself — a hook, a permission — or a concurrent update that held the ref's
lock and had not landed when the ref was read. The first such refusal is
tried once more; a second against the same remote value is reported. The
backoff comes BEFORE the fetch, so the merge pushed next is as fresh as it
can be, and is "full jitter" (a uniform draw over a doubling window whose
base is 100 ms or the duration of the round just lost, whichever is longer):
with a fixed delay plus a little noise, pushers that lost one round raced
again in lockstep and exactly one won per round, so eight concurrent clones
always left three failing; with a window shorter than a round, the draws
still overlap, which on Windows — where starting each `git` is slow and a
round takes several times the base — left one of six clones failing in every
run. Measured on x86_64-linux against a local bare remote: eight clones all
land within five attempts; twelve sometimes do not. A clone that gives up
says so; its records are in its local ref and land with its next push.

## The pre-push hook

**What a push introduces** is computed per pushed ref as `<remote>..<local>`
when the clone has the remote's object, and otherwise as what the remote's
remote-tracking refs do not reach; the other refs' remote objects in the same
push are excluded too, since they are on the remote. One `git rev-list
--format=%T --stdin` per pushed ref lists the commits with their trees (the
revisions on standard input, so a push of many refs cannot outgrow a command
line), and only trees with a content directory in either root are published:
listing `v1/<algorithm>/` once is cheaper than a `find` per commit.

A push to a URL considers the ref's whole history, so nothing here may grow
with it. The `rev-list` output is streamed (`runProcess(onStdout)`) and
parsed as it arrives. With no declared scope each commit is decided on sight
against the stored digests; with declared scopes the distinct trees are
decided in batches (`HookOptions.batchTrees`, default 1024), one batched
scoped-tree walk each, which selects exactly what one batch would: a tree not
wanted once is not wanted later, since the set of trees already covered only
grows. No set of commits seen is kept either: the refs whose ranges use the
remote-tracking refs are listed after those that do not, and each ref
excludes every ref listed before it — its exclusions are then a superset of
each earlier ref's, so it lists exactly the commits no earlier ref listed.
What remains held is the store's digests, the trees selected and one batch.
`t_hook` pushes a 50 000-commit history to a URL and checks that the
allocator's high-water mark does not move (holding the listing moved it by
13 MB), and that batches of 7 choose what one batch chooses. Nothing is
pushed when nothing was certified, so a push with no certificates makes no
network operation.

**Refs under `refs/notes/` are ignored.** A user's `notes push` runs the
`pre-push` hook; without this the hook would publish nothing (no certificate
names a notes tree) and then push the notes ref itself, racing the push that
started it.

**Never failing** is enforced at the command line: `hook pre-push` answers 0
on every path, including a usage error and an unexpected exception or
defect, and reads its standard input to the end first so git never sees a
broken pipe. The hook `hook install` writes does not `exec` the tool: it
ignores the tool's status and drains what is left of the input, so even a
crash that no handler sees (a signal) lets the push go on.

**The time budget.** `PushOptions.timeoutMs` bounds everything `pushNotes`
does over the network; `git.runProcess(timeoutMs)` stops a git that outlives
it together with everything it started, and does not wait for its pipes to
close, because a remote helper (`ssh`, or `sleep` behind the tests' `ext::`
remote) that survived the stop could hold them open. A process that had
already exited when the time ran out keeps its own answer. The hook's
budget is always finite (Tooling §4.3): `prePushHook` replaces a non-positive
one with `DefaultHookTimeoutMs`.

- **POSIX.** A timed child starts a session of its own (`setsid` between
  `fork` and `execve`), so its pid is the id of a process group holding it
  and every helper it starts that does not leave on purpose (a daemon calls
  `setsid` itself and is left alone). A stop is SIGTERM to the group, then
  SIGKILL a second later; whatever of the group outlives its `git` gets
  SIGKILL too, since it holds the pipes past the budget. While the child
  runs, SIGINT, SIGTERM and SIGHUP — those the calling thread does not
  already block — are blocked in that thread and polled for every 100 ms
  (`poll` is not woken by a blocked signal); one that arrives is sent to the
  group, the group is stopped as above, and the original mask is restored,
  which delivers the signal to take its usual effect. So a Ctrl-C at the
  terminal — which reaches the foreground group (git, the hook, this tool)
  but not the child's own session — never leaves the hook's `git push` and
  its `ssh` running unseen. The process-wide signal dispositions are never
  touched: they belong to the program linking the library. On Linux the
  child also has `PR_SET_PDEATHSIG` = SIGKILL, for a death no handler sees.
  Being outside the terminal's session has a second effect, chosen
  deliberately: a helper that prompts on `/dev/tty` (`ssh` asking for a
  passphrase) fails at once. In a background process group of the same
  session it would instead be stopped by SIGTTIN and wait, unseen, for the
  budget to run out; `GIT_TERMINAL_PROMPT=0` already forbids git's own
  prompts everywhere. An untimed child stays in this process's group and
  session, exactly as before: terminal signals reach it directly and it may
  prompt.
- **Windows** (`windows_process`). The child is created suspended, assigned
  to a fresh Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, and then
  resumed, so everything it starts is in the job (a process that asks for
  `CREATE_BREAKAWAY_FROM_JOB` may leave: that is a daemon designed to outlive
  its parent). A stop is `TerminateJobObject`. Kill-on-close covers this
  process dying mid-run; a run that ends normally lifts it before closing
  the handle, so a daemon the child left running on purpose survives, as on
  POSIX.
  Its three pipes are named pipes, overlapped on this side, serviced by one
  thread with `WaitForMultipleObjects` and the deadline: every completed
  operation is handled on each wake, so a chatty stdout cannot starve
  stderr into a full pipe, and in-flight operations are cancelled
  (`CancelIoEx`) and waited for before their buffers are released. The
  child shares this process's console, so a console Ctrl-C reaches it
  directly. Should assigning the job fail (a parent job that forbids
  breakaway before Windows 8), the run goes on and a stop ends `git` alone.

**Starting processes.** `git.runProcess` starts its child itself rather than
through Nim's `osproc.startProcess`, on every platform.

- **POSIX** (`fork` and `execve`). `startProcess` creates its pipes without
  close-on-exec and `dup2`s them onto 0–2 without closing the originals, so
  every child holds a second copy of each pipe end above 2 and passes it to
  everything it starts. A process that detaches and redirects its standard
  streams — an `ssh` control master, a `credential-cache` daemon, the
  `sleep` behind the tests' `ext::` remote — then still holds the caller's
  pipes, and a caller that reads them to the end (the hook capturing `git
push`, or a dispatcher capturing the hook) waits for it to exit. Here
  every pipe end is close-on-exec, and the child closes every other
  descriptor from 3 up before `execve` (`close_range(2)` on Linux 5.9 and
  later; otherwise one `close` per descriptor below the `RLIMIT_NOFILE` soft
  limit, at most 65536), so only 0–2 reach it, whatever the program linking
  the library has open without close-on-exec. `posix_spawn` is not used
  because starting the child in another directory needs
  `posix_spawn_file_actions_addchdir_np`, which the glibc 2.28 the release
  binaries are linked against lacks.
- **Windows.** `startProcess` makes its pipes inheritable and starts the
  child with every inheritable handle of the process, its anonymous pipes
  can only be read blocking (so no wait can be bounded), and it stops `git`
  but not its helpers. Here the child gets `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`
  naming exactly its three standard handles; the command line is quoted by
  the Microsoft C runtime's rules
  ([Parsing C command-line arguments](https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments));
  the executable is looked up on `PATH` (`.exe`, `.com`) and never in the
  current directory, which `CreateProcessW` would search first; and the
  environment block is sorted as `CreateProcessW` requires.

`tests/t_process.nim` runs the same cases on both: the inherited handle or
descriptor (with `startProcess` as the positive control), argument quoting,
a detached grandchild that must not hold the run open, a timed-out child
whose grandchild must be gone, the output sink; on POSIX also an interrupt
delivered while a timed child runs.

**Streaming output.** `runProcess(onStdout = …)` hands standard output to a
sink as it arrives instead of collecting it; the sink can stop the child.
The hook lists the commits a push introduces this way (see below).

## Tests

`just test` builds the executable and runs every `tests/t_*.nim`. Tests use
the real filesystem, real git repositories and the built executable; there
are no mocks. Where a race must be exercised deterministically, the library's
test seams (`PutStepHook`, `PruneStepHook`, `pruneRoot(now = …)`) choose the
interleaving and the real code does the rest. Each test file's header says
what it covers.

On Linux, the permission tests need a distinct `nobody` account, `setfacl` and
`setpriv`, and root over a second account. The test binary gets that without
sudo where it can (see its header): it re-executes itself under `unshare
--user --map-root-user --map-users=auto --map-groups=auto`, which makes it
root over this account's subordinate uid and gid ranges (`newuidmap`,
`/etc/subuid`), `nobody` included, so ownership and permission checks are
the real kernel's; where unprivileged user namespaces are unavailable it
re-executes itself under `sudo -n`, and with neither it fails, naming what
it tried. Recipient processes run under `setpriv` with the recipient's ids
and no supplementary groups. Fixture setup creates foreign-owned roots and a root-owned partition whose
group is the recipient's group. Separate recipient processes prove that
records remain readable under umask `077` and that writes and deletion are
denied. All elevated filesystem operations are confined to temporary test
directories, which are removed afterwards. The suite fails if it cannot
establish these real account and permission controls.

The conformance test reads the specification's `store/`, `content/`,
`payload/` and `notes/` vectors from a checkout of
[test-certificates-spec](https://github.com/metacraft-labs/test-certificates-spec)
— the sibling directory `../test-certificates-spec`, or
`$TEST_CERTIFICATES_SPEC_DIR` — at the commit `tests/spec-vectors.pin` names,
read from git's object store so the checkout's own revision does not matter.
Moving the pin is a deliberate change made together with whatever the new
vectors require. Negative controls corrupt one vector per group and require
the same checkers to report it.

The notes tests (`t_notes.nim`) run real clones against a real bare remote in
a scratch directory, with an empty global git configuration, and race
several `notes push` processes against one another.

The hook tests (`t_hook.nim`) drive real `git push` commands with a hook
that counts its runs and then execs the built binary, so recursion is
observed, not inferred. Remote failures are real: a bare remote whose
`update` hook refuses `refs/notes/*`, a path that is not a repository, and
git's `ext::` transport running `sleep` for a remote that never answers.

A missing prerequisite (the binary, git, the specification checkout or the
pinned commit) fails the suite; nothing is skipped silently. The only skips
are POSIX-only cases on Windows, each marked in its test with the reason;
the two files with no Windows case at all (`t_permissions`,
`t_permission_paths`: system-store writes and pruning are unsupported there)
say so when they run. `scripts/windows/test.ps1` runs the suite on Windows,
which has no Nix dev shell, as CI's Windows leg does.
