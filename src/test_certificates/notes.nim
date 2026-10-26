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

import std/[algorithm, os, random, sequtils, sets, strutils, tables, times]
import ./[git, certificate, content_id, content_state, find, put, roots, layout]
import ./note_framing

export note_framing

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
    kept*: bool ## An unsigned copy found the name taken and kept the file there.

  ImportedTree* = object
    commit*: string
    tree*: string
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
  let work = WorkRefPrefix & uniqueSuffix()
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
  ## for ``<commit>^{tree}`` (both roots, Transport §2.4) are added to the
  ## note on that tree in the LOCAL notes ref, in §3.1 record form, by the
  ## §3.1 writer rule (``addRecord``). Publishing twice adds nothing; every
  ## piece already in a note is kept.
  let r = openNotesRepo(dir, notesRef)
  if not r.ok:
    result.problems.add r.problem
    return
  result.notesRef = r.notesRef
  let resolved = resolveCommits(dir, revisions)
  if not resolved.ok:
    result.problems.add resolved.problem
    return
  if resolved.commits.len == 0:
    result.problems.add "the revisions select no commits"
    result.ok = true
    return
  # Group by tree: one note serves every commit with that tree.
  var order: seq[string]
  var byTree = initTable[string, int]()
  var records = initTable[string, seq[NotePiece]]()
  for commit in resolved.commits:
    let t = treeOf(r, commit)
    if not t.ok:
      result.problems.add t.problem
      return
    if t.tree in byTree:
      result.trees[byTree[t.tree]].commits.add commit
      continue
    byTree[t.tree] = result.trees.len
    order.add t.tree
    var published = PublishedTree(
      commits: @[commit], tree: t.tree, contentId: formatContentId(r.algorithm, t.tree)
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
    records[t.tree] = pieces
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
  ## tree, written into ``userRoot`` through ``putCertificate`` (Transport
  ## §2.3). A piece that is leading text, does not parse, names another
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
  for commit in resolved.commits:
    let t = treeOf(r, commit)
    if not t.ok:
      result.problems.add t.problem
      failed = true
      continue
    if done.containsOrIncl(t.tree):
      continue
    var imported = ImportedTree(
      commit: commit, tree: t.tree, contentId: formatContentId(r.algorithm, t.tree)
    )
    if t.tree notin notes.tree:
      result.trees.add imported
      continue
    imported.hasNote = true
    let blob = readBlob(r, notes.tree[t.tree].blob)
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
    r: NotesRepo, remote: string
): tuple[ok, present: bool, oid, problem: string] =
  ## The remote's notes ref, fetched into a private ref (whose objects stay
  ## after the ref is deleted). ``present`` false: the remote has none.
  let temporary = FetchRefPrefix & uniqueSuffix()
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
    )
    if not fetched.started:
      return (false, false, "", fetched.failure)
    if fetched.exitCode != 0:
      # Tell "the remote has no such ref" from every other failure by asking
      # for exactly that ref: `ls-remote --exit-code` answers 2 for no match.
      let listed = gitRun(
        r.dir,
        ["ls-remote", "--exit-code", "--refs", "--end-of-options", remote, r.notesRef],
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
  pvRejectedStale ## The remote ref moved: fetch, merge, retry.
  pvFailed

proc pushOnce(
    r: NotesRepo, remote, commit: string, runHooks: bool
): tuple[verdict: PushVerdict, detail: string] =
  ## Push ``commit`` to the remote notes ref without force, and classify the
  ## answer from ``--porcelain`` (one ``<flag> TAB <from>:<to> TAB
  ## <summary>`` line per ref on stdout; git-push(1), "OUTPUT").
  ##
  ## The flag column is locale-independent; the bracketed summary and the
  ## reason after it are read too, so the push runs with ``LC_ALL=C`` (and
  ## ``LANGUAGE`` cleared, which GNU gettext consults before ``LC_ALL``):
  ## the local git, and a ``receive-pack`` it starts for a local or ``file://``
  ## remote, then answer in English whatever the user's locale. A remote
  ## server's own reason text is beyond reach; a reason this does not
  ## recognise is reported as a failure, never retried blind.
  var args = @[
    "push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no", "--no-signed"
  ]
  if not runHooks:
    args.add "--no-verify"
  args.add ["--end-of-options", remote, commit & ":" & r.notesRef]
  let run = gitRun(r.dir, args, env = [("LC_ALL", "C"), ("LANGUAGE", "")])
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
      let summary = fields[2]
      # `[rejected]`: the client saw the remote ref move. `[remote
      # rejected]` with a lock failure: the remote saw it move while
      # updating, which is what two pushes that both CREATE the ref get
      # (measured: "reference already exists"), and what a push losing the
      # ref lock or its compare-and-swap gets ("cannot lock ref", "failed to
      # lock", "incorrect old value provided"). Both are a
      # lost race, retried. Any other remote rejection (a hook, a
      # permission) is not.
      if summary.startsWith("[rejected]") and (
        "fetch first" in summary or "non-fast-forward" in summary or
        "stale info" in summary
      ):
        return (pvRejectedStale, summary)
      if summary.startsWith("[remote rejected]") and (
        "reference already exists" in summary or "cannot lock ref" in summary or
        "failed to lock" in summary or "failed to update ref" in summary or
        "incorrect old value" in summary
      ):
        return (pvRejectedStale, summary)
      return (
        pvFailed,
        summary & (if run.stderr.strip().len > 0: ": " & run.stderr.strip()
        else: ""),
      )
    else:
      return (pvFailed, line)
  if run.exitCode == 0:
    return (pvAccepted, "")
  (pvFailed, run.stderr.strip())

proc pushNotes*(
    dir, remote: string, notesRef = "", options = defaultPushOptions()
): SyncReport =
  ## Tooling §3 ``notes push``: push the local notes ref. When the remote ref
  ## has moved, fetch it, union-merge it into the local ref and try again,
  ## with exponential backoff and jitter, ``options.attempts`` times in all.
  let r = openNotesRepo(dir, notesRef)
  if not r.ok:
    result.problems.add r.problem
    return
  result.notesRef = r.notesRef
  if remote.len == 0 or remote.startsWith("-"):
    result.problems.add "`" & remote & "` is not a remote"
    return
  var rng = initRand(
    getTime().toUnix() * 1_000_000_000 + getTime().nanosecond + getCurrentProcessId()
  )
  let attempts = max(options.attempts, 1)
  for attempt in 1 .. attempts:
    result.attempts = attempt
    let current = refValue(r, r.notesRef)
    if not current.ok:
      result.problems.add current.problem
      return
    if current.oid.len == 0:
      result.outcome = soNoLocalNotes
      result.ok = true
      return
    let pushed = pushOnce(r, remote, current.oid, options.runHooks)
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
    of pvRejectedStale:
      result.remarks.add "attempt " & $attempt & ": the remote " & r.notesRef &
        " moved (" & pushed.detail & "); fetching and merging"
      if attempt == attempts:
        break
      # Back off BEFORE fetching, so the merge pushed next is as fresh as it
      # can be. "Full jitter" (a uniform draw over the whole, doubling
      # window) rather than a fixed delay plus a little noise: pushers that
      # lost the same round would otherwise sleep alike and race again in
      # lockstep, one winning per round.
      if options.baseDelayMs > 0:
        sleep(rng.rand(options.baseDelayMs * (1 shl (attempt - 1))))
      let fetched = fetchRemoteRef(r, remote)
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
