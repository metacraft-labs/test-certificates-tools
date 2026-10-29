## Propagating certificates through git notes (Transport §3, Tooling §3):
## ``notes publish``, ``notes import``, ``notes push`` and ``notes fetch``.
##
## Certificates attach to the TREE their content id names, in a dedicated
## notes ref (default ``refs/notes/test-certificates/certificates``,
## ``git config testCertificates.notesRef`` per repository). One note blob
## holds every record for that tree, framed per Transport §3.1
## (``note_framing``).
##
## **How the notes ref is read.** Through ``git ls-tree -r -z <notes-commit>``,
## whose paths, with the fanout ``/`` removed, are the annotated object ids;
## this reads any fanout git (or another writer) chose, and works on a commit
## that is not under ``refs/notes/`` (a fetched one). A blob is read with
## ``git cat-file blob``. Every git command keeps stdout and stderr apart
## (``git.gitRun``): a warning git prints while showing a note — a trace, a
## ``safe.directory`` notice — must never land in front of the first
## delimiter, where it would read as a framing fault.
##
## **How it is written.** A note blob is stored with ``hash-object -w
## --stdin`` (standard input implies no filters, so the bytes are kept) and
## attached with ``git notes add -f -C <blob>``, which takes the blob
## verbatim — ``-F``/``-m`` would clean the text up (blank lines, trailing
## whitespace) and rewrite pieces §3.1 says to keep byte for byte — and
## leaves the fanout of the notes tree to git. That runs against a private
## work ref (``refs/notes/test-certificates-work/<unique>``, since ``git
## notes --ref`` only takes names under ``refs/notes/``); the work ref's tree
## is then committed ONCE with ``commit-tree``, with the parents the
## operation calls for, and the notes ref is moved with a compare-and-swap
## ``update-ref <ref> <new> <old>``. A concurrent writer in the same
## repository makes the swap fail and the operation start over from the new
## value, a bounded number of times; nothing is overwritten blind.
##
## **Merging.** When the two sides of a notes ref have diverged, the result
## is a commit with BOTH as parents (so plain git sees the history) whose
## tree holds, for every annotated object, the union of the two sides' notes
## (``note_framing.mergeNotes``), with the remote — published — side as the
## base. ``git notes merge -s union`` is not used: it concatenates the two
## blobs line-wise with a blank line between, so a record present on both
## sides appears twice and a blank line lands inside the record before it,
## which is neither the §3.1 framing nor deduplicated. When one side is an
## ancestor of the other the ref simply moves to the descendant.
##
## **Identity.** ``git notes add`` and ``commit-tree`` need a committer
## identity. The user's own is used; where git has none (``git var
## GIT_COMMITTER_IDENT`` fails, as in a bare CI container), the commits are
## made as ``test-certificates <test-certificates@localhost>`` rather than
## failing.

import std/[algorithm, monotimes, os, random, sequtils, sets, strutils, tables, times]
import ./[git, certificate, content_id, content_state, find, put, roots, scopes]
import ./[note_framing, work_refs]

export note_framing, work_refs

const
  DefaultNotesRef* = "refs/notes/test-certificates/certificates"
    ## Tooling §3's default.
  NotesRefConfigKey* = "testCertificates.notesRef"
  WorkRefPrefix* = "refs/notes/test-certificates-work/"
    ## Private, short-lived refs a write builds its tree in. Never a notes ref.
  FetchRefPrefix* = "refs/test-certificates/fetch/"
    ## Where a fetch lands the remote notes ref before it is merged.
  DefaultAttempts* = 5 ## How many times a push (or a local compare-and-swap) is tried.
  FallbackName = "test-certificates"
  FallbackEmail = "test-certificates@localhost"

type
  NotesRepo* = object ## A repository and the notes ref in effect there.
    ok*: bool
    dir*: string ## Where git commands run.
    algorithm*: ContentAlgorithm ## The repository's ``git-tree-*`` algorithm.
    hexLen*: int ## Hex digits of an object id here.
    notesRef*: string
    identityEnv*: seq[(string, string)]
      ## The fallback committer identity, when the user has none.
    problem*: string

  NoteEntry = object
    path: string ## The path in the notes tree (with fanout).
    blob: string

  NotesTree = Table[string, NoteEntry] ## Annotated object id -> its note.

  PublishedTree* = object ## What ``notes publish`` did for one tree.
    commits*: seq[string] ## The commits (as given, resolved) whose tree it is.
    tree*: string
    scope*: seq[string]
      ## The declared scope (Tooling §3.1) this is the commits' scoped tree
      ## in; empty for the commits' own tree. A tree that is both is reported
      ## once, for the first.
    contentId*: string
    appended*, replaced*, present*: seq[string]
      ## Payload hashes, by what happened to them.
    notPublished*: seq[string] ## Store files that could not be published, and why.
    searchProblems*: seq[string]

  PublishReport* = object
    ok*: bool
    notesRef*: string
    trees*: seq[PublishedTree]
    notesCommit*: string ## The new value of the notes ref; "" when unchanged.
    remarks*: seq[string] ## Worth knowing, not a failure (a fallback identity).
    problems*: seq[string]

  ImportedRecord* = object
    path*: string ## Where it was stored.
    kept*: bool ## The relay rule preserved an existing store copy.

  ImportedTree* = object
    commit*: string
    tree*: string
    scope*: seq[string] ## As ``PublishedTree.scope``.
    contentId*: string
    hasNote*: bool
    stored*: seq[ImportedRecord]
    faults*: seq[string]
      ## Pieces reported and skipped: leading text, pieces that do not parse,
      ## records for another content (misattached), records ``put`` refused.

  ImportReport* = object
    ok*: bool
    notesRef*: string
    trees*: seq[ImportedTree]
    problems*: seq[string]

  SyncOutcome* = enum
    soUpToDate = "up to date" ## Nothing to change.
    soCreated = "created" ## The local ref did not exist and now does.
    soFastForwarded = "fast-forwarded" ## Moved to a descendant.
    soMerged = "merged" ## A union merge commit was made.
    soRemoteAbsent = "the remote has no notes ref" ## Nothing to fetch.
    soNoLocalNotes = "there are no local notes to push" ## Nothing to push.
    soPushed = "pushed"

  SyncReport* = object ## What ``notes fetch`` or ``notes push`` did.
    ok*: bool
    notesRef*: string
    outcome*: SyncOutcome
    attempts*: int ## Push attempts made.
    merges*: int ## Union merges made along the way.
    notesCommit*: string ## The local (and, after a push, remote) ref value.
    remarks*: seq[string]
    problems*: seq[string]

  PushOptions* = object
    attempts*: int ## Push attempts before giving up.
    baseDelayMs*: int
      ## Backoff before the n-th retry: a uniform draw from
      ## ``0 .. baseDelayMs * 2^(n-1)`` milliseconds ("full jitter").
    runHooks*: bool
      ## Let git run the repository's ``pre-push`` hook. True for a push a
      ## user asks for: whatever gate the repository attaches to pushes
      ## applies to this one too. A caller that is ITSELF running inside a
      ## ``pre-push`` hook sets it false (``git push --no-verify``), so the
      ## notes push does not re-enter the hook (Tooling §4).
    timeoutMs*: int
      ## A wall-clock budget, in milliseconds, for everything the push does
      ## over the network: every push attempt, the fetches between them and
      ## the backoff. 0 is no limit. A git command still running when the
      ## budget runs out is stopped (POSIX; see ``git.runProcess``) and the
      ## push reported as failed. A ``pre-push`` hook sets one so that a
      ## remote that does not answer cannot hold the user's push hostage.

proc defaultPushOptions*(): PushOptions =
  ## Five attempts, a 100 ms backoff base, hooks run. Measured on one
  ## x86_64-linux host against a local bare remote: eight clones pushing at
  ## once all land within five attempts; twelve sometimes do not.
  PushOptions(attempts: DefaultAttempts, baseDelayMs: 100, runHooks: true)

# ---------------------------------------------------------------------------
# The repository and its notes ref
# ---------------------------------------------------------------------------

proc validNotesRef*(dir, name: string): tuple[ok: bool, problem: string] =
  ## A notes ref this tool will use: a well-formed ref name under
  ## ``refs/notes/`` (``git notes --ref`` would silently prefix anything
  ## else) and not inside the work namespace.
  if not name.startsWith("refs/notes/") or name.len <= "refs/notes/".len:
    return (false, "notes ref `" & name & "` is not under refs/notes/")
  if name.startsWith(WorkRefPrefix) or name & "/" == WorkRefPrefix:
    return (
      false,
      "notes ref `" & name & "` is inside " & WorkRefPrefix &
        ", which this tool uses for its own work",
    )
  let check = git(dir, ["check-ref-format", name])
  if not check.ok:
    return (false, "notes ref `" & name & "` is not a valid ref name")
  (true, "")

proc openNotesRepo*(dir: string, notesRef = ""): NotesRepo =
  ## The repository containing ``dir`` and its notes ref: ``notesRef`` when
  ## given, else ``testCertificates.notesRef``, else the default.
  result.dir = dir
  let gitDir = git(dir, ["rev-parse", "--git-dir"])
  if not gitDir.ok:
    result.problem = "`" & dir & "` is not inside a git repository: " & gitDir.failure
    return
  let format = repositoryTreeAlgorithm(dir)
  if not format.ok:
    result.problem = format.problem
    return
  result.algorithm = format.algorithm
  result.hexLen = DigestLength[format.algorithm]
  var name = notesRef
  if name.len == 0:
    let configured = gitRun(dir, ["config", "--get", NotesRefConfigKey])
    if not configured.started:
      result.problem = configured.failure
      return
    case configured.exitCode
    of 0:
      name = singleLine(configured.stdout)
    of 1:
      name = DefaultNotesRef # Unset.
    else:
      result.problem =
        "could not read " & NotesRefConfigKey & ": " & configured.stderr.strip()
      return
  let valid = validNotesRef(dir, name)
  if not valid.ok:
    result.problem =
      valid.problem & (
        if notesRef.len == 0 and name != DefaultNotesRef:
        " (set by " & NotesRefConfigKey & ")"
        else: ""
      )
    return
  result.notesRef = name
  let ident = gitRun(dir, ["var", "GIT_COMMITTER_IDENT"])
  let authorIdent = gitRun(dir, ["var", "GIT_AUTHOR_IDENT"])
  if not ident.started or ident.exitCode != 0 or authorIdent.exitCode != 0:
    result.identityEnv = @[
      ("GIT_AUTHOR_NAME", FallbackName),
      ("GIT_AUTHOR_EMAIL", FallbackEmail),
      ("GIT_COMMITTER_NAME", FallbackName),
      ("GIT_COMMITTER_EMAIL", FallbackEmail),
    ]
  result.ok = true

proc fallbackIdentityRemark*(): string =
  ## Reported whenever a notes commit was made under the fallback identity.
  "git has no committer identity configured here; the notes commit was made as " &
    FallbackName & " <" & FallbackEmail & ">"

proc isOid(r: NotesRepo, s: string): bool =
  s.len == r.hexLen and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc zeroOid(r: NotesRepo): string =
  repeat('0', r.hexLen)

proc collectStaleWorkRefs(r: NotesRepo) =
  ## Remove the work and fetch refs crashed runs left behind (``work_refs``).
  ## Opportunistic: what cannot be removed now is tried again next time, and
  ## nothing here is a reason for the operation to fail.
  discard cleanStaleWorkRefs(r.dir, [WorkRefPrefix, FetchRefPrefix])

proc refValue(r: NotesRepo, name: string): tuple[ok: bool, oid, problem: string] =
  ## The commit ``name`` points at; "" when the ref does not exist.
  let run = gitRun(r.dir, ["rev-parse", "--verify", "--quiet", name & "^{commit}"])
  if not run.started:
    return (false, "", run.failure)
  if run.exitCode == 0:
    let oid = singleLine(run.stdout)
    if r.isOid(oid):
      return (true, oid, "")
    return (false, "", "git answered `" & oid & "` for " & name)
  # `rev-parse --verify --quiet` exits 1 and prints nothing for a missing
  # ref. A ref that exists but does not name a commit is not "absent".
  let exists = gitRun(r.dir, ["show-ref", "--verify", "--quiet", name])
  if exists.started and exists.exitCode != 0 and run.stderr.strip().len == 0:
    return (true, "", "")
  (false, "", "`" & name & "` cannot be read as a commit: " & run.stderr.strip())

proc readNotesTree(
    r: NotesRepo, commit: string
): tuple[ok: bool, tree: NotesTree, problem: string] =
  ## Every note in the notes commit ``commit``, fanout resolved. Entries that
  ## are not notes (a path that is not an object id) are not returned; a
  ## write starting from ``commit`` keeps them, since git does.
  if commit.len == 0:
    return (true, initTable[string, NoteEntry](), "")
  let listing = git(r.dir, ["ls-tree", "-r", "-z", "--full-tree", commit])
  if not listing.ok:
    return (
      false,
      initTable[string, NoteEntry](),
      "cannot read the notes tree of " & commit & ": " & listing.failure,
    )
  var tree = initTable[string, NoteEntry]()
  for record in nulRecords(listing.stdout):
    let tab = record.find('\t')
    if tab < 0:
      continue
    let fields = record[0 ..< tab].split(' ')
    if fields.len < 3 or fields[1] != "blob":
      continue
    let path = record[tab + 1 ..^ 1]
    let annotated = path.replace("/", "")
    if r.isOid(annotated):
      tree[annotated] = NoteEntry(path: path, blob: fields[2])
  (true, tree, "")

proc readBlob(r: NotesRepo, blob: string): tuple[ok: bool, bytes, problem: string] =
  ## A blob's exact bytes: git's stdout alone.
  let read = git(r.dir, ["cat-file", "blob", blob])
  if not read.ok:
    return (false, "", "cannot read note blob " & blob & ": " & read.failure)
  (true, read.stdout, "")

proc writeBlob(r: NotesRepo, bytes: string): tuple[ok: bool, oid, problem: string] =
  let written = git(r.dir, ["hash-object", "-w", "--stdin"], input = bytes)
  if not written.ok:
    return (false, "", written.failure)
  let oid = singleLine(written.stdout)
  if not r.isOid(oid):
    return (false, "", "git hash-object answered `" & oid & "`")
  (true, oid, "")

proc buildNotesCommit(
    r: NotesRepo,
    base: string,
    changes: openArray[(string, string)],
    parents: openArray[string],
    message: string,
): tuple[ok: bool, commit, problem: string] =
  ## A notes commit whose tree is ``base``'s with each ``(annotated, blob)``
  ## of ``changes`` attached (replacing what was there), and whose parents
  ## are ``parents``. The tree is built by ``git notes add -f -C`` on a work
  ## ref, so git chooses the fanout; the commit is made once, here.
  let work = workRefName(WorkRefPrefix)
  var tree = ""
  try:
    if base.len > 0:
      let start = git(r.dir, ["update-ref", work, base, r.zeroOid])
      if not start.ok:
        return (false, "", start.failure)
    for (annotated, blob) in changes:
      let added = git(
        r.dir,
        ["notes", "--ref", work, "add", "-f", "-C", blob, annotated],
        env = r.identityEnv,
      )
      if not added.ok:
        return (false, "", added.failure)
    let source = if changes.len > 0: work else: base
    if source.len == 0:
      return (false, "", "nothing to commit: no base and no changes")
    let resolved = git(r.dir, ["rev-parse", "--verify", source & "^{tree}"])
    if not resolved.ok:
      return (false, "", resolved.failure)
    tree = singleLine(resolved.stdout)
    if changes.len > 0:
      # The work ref is private, but a cleanup that misjudged it as stale
      # (``work_refs``) would have let `git notes add` start again from
      # nothing. Make sure the tree built is ``base`` plus every change.
      if base.len > 0:
        let descends =
          gitRun(r.dir, ["merge-base", "--is-ancestor", base, work & "^{commit}"])
        if not descends.started or descends.exitCode != 0:
          return (false, "", "the work ref " & work & " lost its base while in use")
      let built = readNotesTree(r, work)
      if not built.ok:
        return (false, "", built.problem)
      for (annotated, blob) in changes:
        if annotated notin built.tree or built.tree[annotated].blob != blob:
          return (
            false,
            "",
            "the work ref " & work & " lost the note on " & annotated & " while in use",
          )
  finally:
    discard git(r.dir, ["update-ref", "-d", work])
  var args = @["commit-tree", tree]
  for p in parents:
    args.add ["-p", p]
  args.add ["-m", message]
  let made = git(r.dir, args, env = r.identityEnv)
  if not made.ok:
    return (false, "", made.failure)
  let commit = singleLine(made.stdout)
  if not r.isOid(commit):
    return (false, "", "git commit-tree answered `" & commit & "`")
  (true, commit, "")

proc swapRef(
    r: NotesRepo, newValue, oldValue, message: string
): tuple[swapped: bool, problem: string] =
  ## Move the notes ref to ``newValue`` only if it still holds ``oldValue``
  ## ("" meaning it must not exist). ``swapped`` false with no problem means
  ## another writer moved it first.
  let expected = if oldValue.len == 0: r.zeroOid else: oldValue
  let run = gitRun(r.dir, ["update-ref", "-m", message, r.notesRef, newValue, expected])
  if not run.started:
    return (false, run.failure)
  if run.exitCode == 0:
    return (true, "")
  let now = refValue(r, r.notesRef)
  if now.ok and now.oid != oldValue:
    return (false, "") # Lost the race; the caller starts over.
  (false, "could not update " & r.notesRef & ": " & run.stderr.strip())

proc isAncestor(
    r: NotesRepo, ancestor, descendant: string
): tuple[ok, answer: bool, problem: string] =
  let run = gitRun(r.dir, ["merge-base", "--is-ancestor", ancestor, descendant])
  if not run.started:
    return (false, false, run.failure)
  case run.exitCode
  of 0:
    (true, true, "")
  of 1:
    (true, false, "")
  else:
    (false, false, "git merge-base --is-ancestor failed: " & run.stderr.strip())

# ---------------------------------------------------------------------------
# Revisions
# ---------------------------------------------------------------------------

proc isRange(rev: string): bool =
  ".." in rev or rev.endsWith("^!") or rev.endsWith("^@") or "^-" in rev

proc resolveCommits*(
    dir: string, revisions: openArray[string]
): tuple[ok: bool, commits: seq[string], problem: string] =
  ## The commits ``revisions`` name, in order, each once. A revision with
  ## ``..``, ``^!``, ``^@`` or ``^-`` is a range (``git rev-list``); any
  ## other names one commit.
  var seen: HashSet[string]
  var commits: seq[string]
  for rev in revisions:
    if rev.len == 0 or rev.startsWith("-"):
      return (false, @[], "`" & rev & "` is not a revision")
    var found: seq[string]
    if isRange(rev):
      let listed = git(dir, ["rev-list", rev, "--"])
      if not listed.ok:
        return
          (false, @[], "`" & rev & "` is not a revision range here: " & listed.failure)
      found = listed.stdout.splitLines().filterIt(it.len > 0)
    else:
      let one = git(dir, ["rev-parse", "--verify", "--quiet", rev & "^{commit}"])
      if not one.ok:
        return (false, @[], "`" & rev & "` does not name a commit here")
      found = @[singleLine(one.stdout)]
    for c in found:
      if not seen.containsOrIncl(c):
        commits.add c
  (true, commits, "")

proc treeOf(r: NotesRepo, commit: string): tuple[ok: bool, tree, problem: string] =
  let resolved = git(r.dir, ["rev-parse", "--verify", "--quiet", commit & "^{tree}"])
  let tree = singleLine(resolved.stdout)
  if not resolved.ok or not r.isOid(tree):
    return (false, "", "the tree of " & commit & " cannot be resolved")
  (true, tree, "")

type CommitTree = tuple[commit, tree: string, scope: seq[string]]

proc treesOfCommits(
    r: NotesRepo, commits: openArray[string]
): tuple[ok: bool, trees: seq[CommitTree], problems: seq[string]] =
  ## Every tree of every commit (Tooling §3.1): its own tree, then its scoped
  ## tree in each scope the repository declares, commit by commit. A
  ## declaration that is invalid fails the whole call, before anything is
  ## written: publishing the rest would hide the error.
  let declared = declaredScopes(r.dir)
  if not declared.ok:
    for p in declared.problems:
      result.problems.add "invalid scope declaration: " & p
    return
  var own: seq[string]
  for commit in commits:
    let t = treeOf(r, commit)
    if not t.ok:
      result.problems.add t.problem
      return
    own.add t.tree
  let scoped = scopedTrees(r.dir, r.hexLen, own, declared.scopes)
  if not scoped.ok:
    result.problems.add scoped.problem
    return
  for i, commit in commits:
    result.trees.add (commit, own[i], newSeq[string]())
    for j, s in declared.scopes:
      result.trees.add (commit, scoped.trees[own[i]][j], s.paths)
  result.ok = true

# ---------------------------------------------------------------------------
# notes publish
# ---------------------------------------------------------------------------

proc publishNotes*(
    dir: string,
    roots: StoreRoots,
    revisions: openArray[string],
    notesRef = "",
    attempts = DefaultAttempts,
): PublishReport =
  ## Tooling §3 ``notes publish``: for each commit, the store's certificates
  ## for each of its trees — ``<commit>^{tree}`` and its scoped tree in every
  ## declared scope (Tooling §3.1) — from both roots (Transport §2.4) are
  ## added to the note on that tree in the LOCAL notes ref, in §3.1 record
  ## form, by the §3.1 writer rule (``addRecord``). Publishing twice adds
  ## nothing; every piece already in a note is kept. An invalid scope
  ## declaration is reported and nothing is written.
  let r = openNotesRepo(dir, notesRef)
  if not r.ok:
    result.problems.add r.problem
    return
  result.notesRef = r.notesRef
  collectStaleWorkRefs(r)
  let resolved = resolveCommits(dir, revisions)
  if not resolved.ok:
    result.problems.add resolved.problem
    return
  if resolved.commits.len == 0:
    result.problems.add "the revisions select no commits"
    result.ok = true
    return
  let all = treesOfCommits(r, resolved.commits)
  if not all.ok:
    result.problems.add all.problems
    return
  # Group by tree: one note serves every commit with that tree.
  var order: seq[string]
  var byTree = initTable[string, int]()
  var records = initTable[string, seq[NotePiece]]()
  for (commit, tree, scope) in all.trees:
    if tree in byTree:
      if commit notin result.trees[byTree[tree]].commits:
        result.trees[byTree[tree]].commits.add commit
      continue
    byTree[tree] = result.trees.len
    order.add tree
    var published = PublishedTree(
      commits: @[commit],
      tree: tree,
      scope: scope,
      contentId: formatContentId(r.algorithm, tree),
    )
    let found = findById(roots, published.contentId)
    published.searchProblems = found.problems
    var pieces: seq[NotePiece]
    for c in found.candidates:
      if not c.parsed:
        published.notPublished.add c.path & ": " & c.note
        continue
      var bytes: string
      try:
        bytes = readFile(c.path)
      except CatchableError as err:
        published.notPublished.add c.path & ": could not be read: " & err.msg
        continue
      let parsed = parseCertificate(bytes)
      if not parsed.ok:
        published.notPublished.add c.path & ": " & parsed.problem
        continue
      let record = canonicalRecord(parsed.certificate)
      if not record.ok:
        published.notPublished.add c.path & ": " & record.problem
        continue
      let piece = recordPiece(record.payload)
      if piece.kind != pkRecord:
        published.notPublished.add c.path &
          ": its canonical record does not parse back: " & piece.problem
        continue
      pieces.add piece
    records[tree] = pieces
    result.trees.add published

  for attempt in 1 .. max(attempts, 1):
    let current = refValue(r, r.notesRef)
    if not current.ok:
      result.problems.add current.problem
      return
    let notes = readNotesTree(r, current.oid)
    if not notes.ok:
      result.problems.add notes.problem
      return
    var changes: seq[(string, string)]
    for i, tree in order:
      result.trees[i].appended.setLen(0)
      result.trees[i].replaced.setLen(0)
      result.trees[i].present.setLen(0)
      if records[tree].len == 0:
        continue
      var existing = ""
      if tree in notes.tree:
        let blob = readBlob(r, notes.tree[tree].blob)
        if not blob.ok:
          # A note that cannot be read is never overwritten.
          result.problems.add blob.problem
          return
        existing = blob.bytes
      var pieces = splitNote(existing)
      for record in records[tree]:
        case addRecord(pieces, record)
        of aoAppended:
          result.trees[i].appended.add record.payloadSha256
        of aoReplaced:
          result.trees[i].replaced.add record.payloadSha256
        of aoPresent:
          result.trees[i].present.add record.payloadSha256
      let blob = renderNote(pieces)
      if blob != existing:
        let written = writeBlob(r, blob)
        if not written.ok:
          result.problems.add written.problem
          return
        changes.add (tree, written.oid)
    if changes.len == 0:
      result.ok = true
      return
    let parents =
      if current.oid.len > 0:
        @[current.oid]
      else:
        @[]
    let built = buildNotesCommit(
      r, current.oid, changes, parents, "test-certificates notes publish"
    )
    if not built.ok:
      result.problems.add built.problem
      return
    let swapped =
      swapRef(r, built.commit, current.oid, "test-certificates notes publish")
    if swapped.swapped:
      result.notesCommit = built.commit
      if r.identityEnv.len > 0:
        result.remarks.add fallbackIdentityRemark()
      result.ok = true
      return
    if swapped.problem.len > 0:
      result.problems.add swapped.problem
      return
  result.problems.add r.notesRef &
    " kept moving under concurrent writers; gave up after " & $attempts & " attempts"

# ---------------------------------------------------------------------------
# notes import
# ---------------------------------------------------------------------------

proc importNotes*(
    dir: string,
    userRoot: string,
    revisions: openArray[string] = ["HEAD"],
    notesRef = "",
): ImportReport =
  ## Tooling §3 ``notes import``: the records in the notes on each commit's
  ## trees — its own and its scoped tree in every declared scope (Tooling
  ## §3.1) — written into ``userRoot`` through ``putCertificate`` (Transport
  ## §2.3). An invalid scope declaration is reported and nothing is stored. A piece that is leading text, does not parse, names another
  ## content (misattached, Transport §3) or is refused by ``put`` is reported
  ## in its tree's ``faults`` and never stops the others.
  let r = openNotesRepo(dir, notesRef)
  if not r.ok:
    result.problems.add r.problem
    return
  result.notesRef = r.notesRef
  if userRoot.len == 0:
    result.problems.add "no user root to import into"
    return
  let revs =
    if revisions.len == 0:
      @["HEAD"]
    else:
      @revisions
  let resolved = resolveCommits(dir, revs)
  if not resolved.ok:
    result.problems.add resolved.problem
    return
  let all = treesOfCommits(r, resolved.commits)
  if not all.ok:
    result.problems.add all.problems
    return
  let current = refValue(r, r.notesRef)
  if not current.ok:
    result.problems.add current.problem
    return
  let notes = readNotesTree(r, current.oid)
  if not notes.ok:
    result.problems.add notes.problem
    return
  var failed = false
  var done: HashSet[string]
  for (commit, tree, scope) in all.trees:
    if done.containsOrIncl(tree):
      continue
    var imported = ImportedTree(
      commit: commit,
      tree: tree,
      scope: scope,
      contentId: formatContentId(r.algorithm, tree),
    )
    if tree notin notes.tree:
      result.trees.add imported
      continue
    imported.hasNote = true
    let blob = readBlob(r, notes.tree[tree].blob)
    if not blob.ok:
      result.problems.add blob.problem
      failed = true
      result.trees.add imported
      continue
    var n = 0
    for piece in splitNote(blob.bytes):
      case piece.kind
      of pkLeading:
        imported.faults.add "leading text: " & piece.problem
      of pkUnparsed:
        inc n
        imported.faults.add "record " & $n & " does not parse: " & piece.problem
      of pkRecord:
        inc n
        if piece.certificate.content != imported.contentId:
          imported.faults.add "record " & $n & " is for content `" &
            piece.certificate.content &
            "`, not the tree it is attached to: misattached, ignored (Transport §3)"
          continue
        let stored = putCertificate(userRoot, piece.body)
        if stored.ok:
          imported.stored.add ImportedRecord(path: stored.path, kept: stored.kept)
        else:
          imported.faults.add "record " & $n & " was not stored: " & stored.problem
          failed = true
    result.trees.add imported
  result.ok = not failed

# ---------------------------------------------------------------------------
# notes fetch / push
# ---------------------------------------------------------------------------

proc fetchRemoteRef(
    r: NotesRepo, remote: string, deadline = Deadline()
): tuple[ok, present: bool, oid, problem: string] =
  ## The remote's notes ref, fetched into a private ref (whose objects stay
  ## after the ref is deleted). ``present`` false: the remote has none.
  let temporary = workRefName(FetchRefPrefix)
  try:
    let fetched = gitRun(
      r.dir,
      [
        "fetch",
        "--quiet",
        "--no-tags",
        "--no-write-fetch-head",
        "--no-recurse-submodules",
        "--no-prune",
        "--end-of-options",
        remote,
        "+" & r.notesRef & ":" & temporary,
      ],
      timeoutMs = deadline.remainingMs,
    )
    if not fetched.started:
      return (false, false, "", fetched.failure)
    if fetched.exitCode != 0:
      # Tell "the remote has no such ref" from every other failure by asking
      # for exactly that ref: `ls-remote --exit-code` answers 2 for no match.
      let listed = gitRun(
        r.dir,
        ["ls-remote", "--exit-code", "--refs", "--end-of-options", remote, r.notesRef],
        timeoutMs = deadline.remainingMs,
      )
      if listed.started and listed.exitCode == 2:
        return (true, false, "", "")
      return (
        false,
        false,
        "",
        "could not fetch " & r.notesRef & " from " & remote & ": " &
          fetched.stderr.strip(),
      )
    let value = refValue(r, temporary)
    if not value.ok or value.oid.len == 0:
      return (
        false,
        false,
        "",
        "the fetched " & r.notesRef & " cannot be read: " & value.problem,
      )
    (true, true, value.oid, "")
  finally:
    discard gitRun(r.dir, ["update-ref", "-d", temporary])

proc mergeNotesCommits(
    r: NotesRepo, local, remote: string
): tuple[ok: bool, commit: string, remarks: seq[string], problem: string] =
  ## A commit with parents ``local`` and ``remote`` whose notes are the union
  ## of both, built on ``remote``'s tree (the published side is the base of
  ## every per-object merge).
  let ours = readNotesTree(r, local)
  if not ours.ok:
    return (false, "", @[], ours.problem)
  let theirs = readNotesTree(r, remote)
  if not theirs.ok:
    return (false, "", @[], theirs.problem)
  var keys = toSeq(ours.tree.keys)
  keys.sort()
  var changes: seq[(string, string)]
  var remarks: seq[string]
  for annotated in keys:
    let mine = ours.tree[annotated]
    if annotated notin theirs.tree:
      changes.add (annotated, mine.blob)
      continue
    let other = theirs.tree[annotated]
    if other.blob == mine.blob:
      continue
    let baseBytes = readBlob(r, other.blob)
    if not baseBytes.ok:
      return (false, "", @[], baseBytes.problem)
    let otherBytes = readBlob(r, mine.blob)
    if not otherBytes.ok:
      return (false, "", @[], otherBytes.problem)
    let merged = mergeNotes(baseBytes.bytes, otherBytes.bytes)
    for remark in merged.remarks:
      remarks.add "note on " & annotated & ": " & remark
    if merged.changed:
      let written = writeBlob(r, merged.blob)
      if not written.ok:
        return (false, "", @[], written.problem)
      changes.add (annotated, written.oid)
  let built = buildNotesCommit(
    r,
    remote,
    changes,
    [local, remote],
    "test-certificates: union of local and remote certificate notes",
  )
  if not built.ok:
    return (false, "", @[], built.problem)
  (true, built.commit, remarks, "")

proc integrate(
    r: NotesRepo, remote: string, report: var SyncReport, attempts: int
): bool =
  ## Bring the local notes ref up to ``remote`` (a fetched commit): create,
  ## fast-forward, keep (when local is ahead) or union-merge, with a
  ## compare-and-swap that starts over when a local writer moved the ref.
  for attempt in 1 .. max(attempts, 1):
    let current = refValue(r, r.notesRef)
    if not current.ok:
      report.problems.add current.problem
      return false
    var target = ""
    if current.oid.len == 0:
      target = remote
      report.outcome = soCreated
    elif current.oid == remote:
      report.outcome = soUpToDate
      report.notesCommit = current.oid
      return true
    else:
      let behind = isAncestor(r, current.oid, remote)
      if not behind.ok:
        report.problems.add behind.problem
        return false
      if behind.answer:
        target = remote
        report.outcome = soFastForwarded
      else:
        let ahead = isAncestor(r, remote, current.oid)
        if not ahead.ok:
          report.problems.add ahead.problem
          return false
        if ahead.answer:
          report.outcome = soUpToDate
          report.notesCommit = current.oid
          return true
        let merged = mergeNotesCommits(r, current.oid, remote)
        if not merged.ok:
          report.problems.add merged.problem
          return false
        report.remarks.add merged.remarks
        target = merged.commit
        report.outcome = soMerged
    let swapped =
      swapRef(r, target, current.oid, "test-certificates notes: " & $report.outcome)
    if swapped.swapped:
      if report.outcome == soMerged:
        inc report.merges
        if r.identityEnv.len > 0 and fallbackIdentityRemark() notin report.remarks:
          report.remarks.add fallbackIdentityRemark()
      report.notesCommit = target
      return true
    if swapped.problem.len > 0:
      report.problems.add swapped.problem
      return false
  report.problems.add r.notesRef & " kept moving under concurrent local writers"
  false

proc fetchNotes*(dir, remote: string, notesRef = ""): SyncReport =
  ## Tooling §3 ``notes fetch``: the remote's notes ref, merged into the
  ## local one as a union (never one side's).
  let r = openNotesRepo(dir, notesRef)
  if not r.ok:
    result.problems.add r.problem
    return
  result.notesRef = r.notesRef
  collectStaleWorkRefs(r)
  if remote.len == 0 or remote.startsWith("-"):
    result.problems.add "`" & remote & "` is not a remote"
    return
  let fetched = fetchRemoteRef(r, remote)
  if not fetched.ok:
    result.problems.add fetched.problem
    return
  if not fetched.present:
    result.outcome = soRemoteAbsent
    let current = refValue(r, r.notesRef)
    result.notesCommit = current.oid
    result.ok = true
    return
  result.ok = integrate(r, fetched.oid, result, DefaultAttempts)

type PushVerdict = enum
  pvAccepted
  pvUpToDate
  pvRejected
    ## The remote refused the update. Whether that was a lost race is decided
    ## by reading the remote ref again (``classifyRejection``), never from
    ## the reason the server gives.
  pvFailed

proc pushOnce(
    r: NotesRepo, remote, commit: string, runHooks: bool, deadline = Deadline()
): tuple[verdict: PushVerdict, detail: string] =
  ## Push ``commit`` to the remote notes ref without force, and classify the
  ## answer by the flag column of ``--porcelain`` (one ``<flag> TAB
  ## <from>:<to> TAB <summary>`` line per ref on stdout; git-push(1),
  ## "OUTPUT"), which is locale-independent. The summary and stderr are only
  ## carried along, for the report: a server's reason text is in its own
  ## wording and locale, so nothing is decided by it. The push runs with
  ## ``LC_ALL=C`` (and ``LANGUAGE`` cleared, which GNU gettext consults before
  ## ``LC_ALL``) so that at least the local part of a report reads the same
  ## everywhere.
  var args = @[
    "push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no", "--no-signed"
  ]
  if not runHooks:
    args.add "--no-verify"
  args.add ["--end-of-options", remote, commit & ":" & r.notesRef]
  let run = gitRun(
    r.dir,
    args,
    env = [("LC_ALL", "C"), ("LANGUAGE", "")],
    timeoutMs = deadline.remainingMs,
  )
  if not run.started:
    return (pvFailed, run.failure)
  for line in run.stdout.splitLines():
    let fields = line.split('\t')
    if fields.len < 3 or fields[0].len != 1:
      continue
    if not fields[1].endsWith(":" & r.notesRef):
      continue
    case fields[0][0]
    of ' ', '*', '+':
      return (pvAccepted, fields[2])
    of '=':
      return (pvUpToDate, fields[2])
    of '!':
      return (
        pvRejected,
        fields[2] & (if run.stderr.strip().len > 0: ": " & run.stderr.strip()
        else: ""),
      )
    else:
      return (pvFailed, line)
  if run.exitCode == 0:
    return (pvAccepted, "")
  (pvFailed, run.stderr.strip())

proc remoteRefValue(
    r: NotesRepo, remote: string, deadline = Deadline()
): tuple[ok, present: bool, oid, problem: string] =
  ## The remote's notes ref as the remote has it now, by ``git ls-remote``
  ## (which fetches nothing). ``present`` false: the remote has none.
  let listed = gitRun(
    r.dir,
    ["ls-remote", "--refs", "--end-of-options", remote, r.notesRef],
    timeoutMs = deadline.remainingMs,
  )
  if not listed.started:
    return (false, false, "", listed.failure)
  if listed.exitCode != 0:
    return (
      false,
      false,
      "",
      "could not list " & r.notesRef & " on " & remote & ": " & listed.stderr.strip(),
    )
  for line in listed.stdout.splitLines():
    let fields = line.split('\t')
    if fields.len == 2 and fields[1] == r.notesRef and r.isOid(fields[0]):
      return (true, true, fields[0], "")
  (true, false, "", "")

type Rejection = enum
  rjLostRace ## The remote ref moved to a value the pushed commit lacks.
  rjAlreadyThere ## The remote ref already holds the pushed commit.
  rjUnexplained ## The remote ref did not move past what was pushed.
  rjUnknown ## The remote ref could not be read.

proc classifyRejection(
    r: NotesRepo, remote, pushed: string, deadline = Deadline()
): tuple[kind: Rejection, remoteOid, problem: string] =
  ## Why a non-forced push of ``pushed`` was refused, told from what the
  ## remote ref holds NOW rather than from the server's text: a ref that
  ## holds a commit ``pushed`` does not contain (one this repository does
  ## not have at all, or one that is not an ancestor of ``pushed``) moved
  ## under the push, which is a lost race; any other value — absent, or an
  ## ancestor of ``pushed``, so that the push would have been a fast-forward
  ## — means the update itself was refused (a hook, a permission, a
  ## protected ref), or that a concurrent update holding the ref's lock has
  ## not landed yet. The caller tells those two apart by trying again.
  let now = remoteRefValue(r, remote, deadline)
  if not now.ok:
    return (rjUnknown, "", now.problem)
  if not now.present:
    return (rjUnexplained, "", "")
  if now.oid == pushed:
    return (rjAlreadyThere, now.oid, "")
  let have = gitRun(r.dir, ["cat-file", "-e", now.oid & "^{commit}"])
  if not have.started:
    return (rjUnknown, now.oid, have.failure)
  if have.exitCode != 0:
    return (rjLostRace, now.oid, "")
  let contained = isAncestor(r, now.oid, pushed)
  if not contained.ok:
    return (rjUnknown, now.oid, contained.problem)
  if contained.answer:
    (rjUnexplained, now.oid, "")
  else:
    (rjLostRace, now.oid, "")

proc pushNotes*(
    dir, remote: string, notesRef = "", options = defaultPushOptions()
): SyncReport =
  ## Tooling §3 ``notes push``: push the local notes ref. When the remote ref
  ## has moved, fetch it, union-merge it into the local ref and try again,
  ## with exponential backoff and jitter, ``options.attempts`` times in all.
  ## With ``options.timeoutMs``, all of it is bounded by that budget.
  ##
  ## A refused push is a lost race when, read again right after, the remote
  ## ref holds a commit the pushed one does not contain
  ## (``classifyRejection``); the server's reason text decides nothing, so a
  ## server in another locale or with its own wording is handled alike. A
  ## refusal while the remote ref has not moved past what was pushed is tried
  ## once more and then reported as a failure.
  let r = openNotesRepo(dir, notesRef)
  if not r.ok:
    result.problems.add r.problem
    return
  result.notesRef = r.notesRef
  collectStaleWorkRefs(r)
  if remote.len == 0 or remote.startsWith("-"):
    result.problems.add "`" & remote & "` is not a remote"
    return
  var rng = initRand(
    getTime().toUnix() * 1_000_000_000 + getTime().nanosecond + getCurrentProcessId()
  )
  let attempts = max(options.attempts, 1)
  let deadline = deadlineIn(options.timeoutMs)
  template outOfTime(): bool =
    if deadline.expired:
      result.problems.add "pushing " & r.notesRef & " to " & remote &
        " gave up: its time budget of " & $options.timeoutMs & " ms ran out"
      true
    else:
      false

  # When the current round (fetch, merge, push) began; see the backoff below.
  var roundStart = getMonoTime()
  # The remote value a refusal that was not a lost race was last seen
  # against; see `rjUnexplained`.
  var refusedAt = ""
  for attempt in 1 .. attempts:
    result.attempts = attempt
    if outOfTime():
      return
    let current = refValue(r, r.notesRef)
    if not current.ok:
      result.problems.add current.problem
      return
    if current.oid.len == 0:
      result.outcome = soNoLocalNotes
      result.ok = true
      return
    let pushed = pushOnce(r, remote, current.oid, options.runHooks, deadline)
    case pushed.verdict
    of pvAccepted:
      result.outcome = soPushed
      result.notesCommit = current.oid
      result.ok = true
      return
    of pvUpToDate:
      result.outcome = soUpToDate
      result.notesCommit = current.oid
      result.ok = true
      return
    of pvFailed:
      result.problems.add "pushing " & r.notesRef & " to " & remote & " failed: " &
        pushed.detail
      return
    of pvRejected:
      let why = classifyRejection(r, remote, current.oid, deadline)
      case why.kind
      of rjAlreadyThere:
        # Another writer pushed this very commit meanwhile.
        result.outcome = soUpToDate
        result.notesCommit = current.oid
        result.ok = true
        return
      of rjUnknown:
        result.problems.add "pushing " & r.notesRef & " to " & remote & " was refused (" &
          pushed.detail & "), and whether the remote ref moved could not be told: " &
          why.problem
        return
      of rjUnexplained:
        # Refused although the push would have been a fast-forward of what
        # the remote holds. A refusal of the update itself (a hook, a
        # permission) repeats against the same value; a concurrent update
        # that held the ref's lock and had not landed when the remote was
        # read does not. So the first such refusal is tried once more, and a
        # second one against the same remote value is the answer.
        let at = if why.remoteOid.len > 0: why.remoteOid else: "(absent)"
        if refusedAt == at or attempt == attempts:
          result.problems.add "pushing " & r.notesRef & " to " & remote &
            " was refused: " & pushed.detail
          return
        refusedAt = at
        result.remarks.add "attempt " & $attempt & ": the remote refused " & r.notesRef &
          " without it having moved (" & pushed.detail & "); trying once more"
      of rjLostRace:
        refusedAt = ""
        result.remarks.add "attempt " & $attempt & ": the remote " & r.notesRef &
          " moved (" & pushed.detail & "); fetching and merging"
        if attempt == attempts:
          break
      # Back off BEFORE fetching, so the merge pushed next is as fresh as it
      # can be. "Full jitter" (a uniform draw over the whole, doubling
      # window) rather than a fixed delay plus a little noise: pushers that
      # lost the same round would otherwise sleep alike and race again in
      # lockstep, one winning per round. The window is never shorter than
      # the round just lost took: draws spread over less than one round
      # still overlap. Where starting a process is slow (Windows), a round
      # takes several times the 100 ms base, and six clones then still
      # failed within five attempts; measured on x86_64-linux a round is
      # well under the base, so the base decides there.
      if options.baseDelayMs > 0:
        let roundMs = int((getMonoTime() - roundStart).inMilliseconds)
        let window = max(options.baseDelayMs, roundMs) * (1 shl (attempt - 1))
        var pause = rng.rand(window)
        if deadline.limited:
          pause = min(pause, deadline.remainingMs)
        sleep(pause)
      if outOfTime():
        return
      roundStart = getMonoTime()
      let fetched = fetchRemoteRef(r, remote, deadline)
      if not fetched.ok:
        result.problems.add fetched.problem
        return
      if fetched.present:
        var merged = SyncReport()
        if not integrate(r, fetched.oid, merged, DefaultAttempts):
          result.problems.add merged.problems
          return
        result.merges += merged.merges
        result.remarks.add merged.remarks
  result.problems.add "the remote " & r.notesRef & " kept moving; gave up after " &
    $attempts & " attempts"
