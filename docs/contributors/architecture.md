# Architecture

The package implements the local certificate store of the test-certificate
standard ([Transport §2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#2-the-local-certificate-store-required)),
its git-notes carrier (Transport §3, §3.1) and the content-id computations a
lookup needs
([Content-Id §4, §5](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Content-Id.md)).
Read those two documents before changing anything here; the comments cite
them by section.

## Modules

| Module          | Responsibility                                                                                                                                                 |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sha256`        | FIPS 180-4 SHA-256, streaming. The standard library has none and the package takes no dependencies.                                                            |
| `toml`          | A strict TOML 1.0 reader. Accepts every rendering the conformance suite uses; refuses redefinitions and malformed text. Numbers and date-times are kept raw.   |
| `content_id`    | Content-id form (Content-Id §1), never repaired; `manifest-v1-sha256` over explicit entries (§4.2).                                                            |
| `certificate`   | Parse a record, rebuild its canonical payload (Canonical-Payload §2–§4), name it (Transport §2.2), tell signed from unsigned.                                  |
| `git`           | Run git with stdout and stderr apart, servicing stdin and both outputs together so a large `cat-file --batch` cannot deadlock. No shell.                       |
| `content_state` | The content id of a commit, the index being committed, or the working tree, in a temporary index (Content-Id §4.1, §5), with the §3 refusals.                  |
| `roots`         | Root resolution (Transport §2.1) as a pure function of platform, environment and account; the uid or the Windows SID of this process.                          |
| `layout`        | The naming conventions writers, readers and pruners share.                                                                                                     |
| `put`           | The atomic writer (Transport §2.3), including the system-root no-follow writer and the retry after a prune.                                                    |
| `find`          | Reading both roots (Transport §2.4) and the search report (§5).                                                                                                |
| `prune`         | Rename-aside pruning (Transport §2.5).                                                                                                                         |
| `note_framing`  | The note blob of Transport §3.1: split on delimiter lines, render byte for byte, the writer rule (`addRecord`), the union of two blobs (`mergeNotes`). No git. |
| `notes`         | The notes carrier (Transport §3, Tooling §3): `publish`, `import`, `push`, `fetch`, the notes ref and its configuration, the union merge of two notes commits. |
| `cli`           | The command line as a library procedure (`runCli`); `src/test_certificates_cli.nim` is the three-line executable.                                              |

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

**The system root.** On POSIX, `put --system` opens the partition with
`O_NOFOLLOW`, checks it is owned by the writing account, and opens every
component below it with `openat(…, O_NOFOLLOW | O_DIRECTORY)`. The temporary
file is created with `O_EXCL | O_NOFOLLOW` and renamed with `renameat`.
An existing nonregular file, including a symbolic link, is reported and left
unchanged. Windows lacks the
primitives used here, so `--system` is refused there; reading the system
root (`find`) works everywhere, with the account's SID from its token.

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
(`refs/notes/test-certificates-work/<unique>`; `git notes --ref` accepts
only names under `refs/notes/`). `-C` takes the blob verbatim, where `-F`
and `-m` would strip blank lines and trailing whitespace, and git chooses the
fanout. The work ref's tree is committed once with `commit-tree` and the
notes ref moved with a compare-and-swap `update-ref <ref> <new> <old>`; the
work ref is deleted whatever happens. Without a committer identity (`git var
GIT_COMMITTER_IDENT` fails, as in a bare container) the commits are made as
`test-certificates <test-certificates@localhost>`, and the report carries a
remark saying so. Failing instead would make the tool unusable exactly where
notes are pushed unattended, and a notes commit's identity is not evidence of
anything (Transport §3: a note is worth its signature); inventing it silently
would hide a misconfiguration, so it is reported.

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
and merging the same local side again changes nothing. The merged tree is
built on the remote commit and committed with both commits as parents. When
one side is an ancestor of the other the ref is moved, not merged.

**Races.** In one repository, publishers and merges serialize on the
compare-and-swap and start over when they lose it (five attempts). Between
clones, `notes push` pushes the exact commit it read, never with force; a
rejection that means the remote moved — `[rejected] (fetch first)`, or a
`[remote rejected]` lock failure such as `reference already exists`, which is
what two pushes that both create the ref get — leads to fetch, merge, back
off and retry, five attempts in all. The backoff comes BEFORE the fetch, so
the merge pushed next is as fresh as it can be, and is "full jitter" (a
uniform draw over a doubling window, 100 ms base): with a fixed delay plus a
little noise, pushers that lost one round raced again in lockstep and exactly
one won per round, so eight concurrent clones always left three failing.
Measured on x86_64-linux against a local bare remote: eight clones all land
within five attempts; twelve sometimes do not. Any other rejection (a hook, a
permission) is reported at once. The push runs with `LC_ALL=C` because the
reason after `[remote rejected]` is read; the `--porcelain` flag column
alone does not tell a lost race from a refusal.

## Tests

`just test` builds the executable and runs every `tests/t_*.nim`. Tests use
the real filesystem, real git repositories and the built executable; there
are no mocks. Where a race must be exercised deterministically, the library's
test seams (`PutStepHook`, `PruneStepHook`, `pruneRoot(now = …)`) choose the
interleaving and the real code does the rest. Each test file's header says
what it covers.

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

A missing prerequisite (the binary, git, the specification checkout or the
pinned commit) fails the suite; nothing is skipped silently. The only skips
are POSIX-only cases on Windows, each marked in its test.
