## The ``pre-push`` hook body (Tooling §4): publish notes for every commit a
## push introduces and push the notes ref to the same remote, never failing
## the push it is attached to.
##
## **Input.** git runs a ``pre-push`` hook with two arguments, the remote's
## name and its URL (equal when the push names a URL rather than a configured
## remote), and one line per pushed ref on standard input:
##
## ``<local ref> SP <local object name> SP <remote ref> SP <remote object name> LF``
##
## A deletion has an all-zero local object name (and ``(delete)`` as the
## local ref); a ref the remote does not have yet has an all-zero remote
## object name. See githooks(5), "pre-push":
## https://git-scm.com/docs/githooks#_pre_push
##
## **What a push introduces** (Tooling §4.2). For each pushed ref, the
## commits reachable from the local object and not from what the remote is
## known to have:
##
## * the remote's current object, when this repository has it
##   (``<remote>..<local>``, exactly what git will send for that ref);
## * otherwise — a new branch, or a remote object this clone never fetched —
##   the remote-tracking refs of the remote (``--remotes=<name>``), when the
##   push names a configured remote;
## * and, in every case, the remote objects of the OTHER refs in the same
##   push that this repository has: those are on the remote too.
##
## A push to a URL with no remote-tracking refs and no known remote object
## therefore considers the pushed ref's whole history. That is still cheap,
## in time and in memory: the commits are listed with their trees by one
## ``rev-list`` per pushed ref whose output is processed as it arrives, never
## held whole; with no declared scope a commit is decided on sight (only a
## tree with a content directory in the store is kept), and with declared
## scopes the distinct trees are decided in batches of
## ``DefaultHookBatchTrees`` by one batched scoped-tree walk each. Each ref
## excludes the refs listed before it, so no commit is listed twice and none
## has to be remembered. Publishing costs nothing for content nobody
## certified.
##
## **What is left alone.** A deletion; a ref under ``refs/notes/`` on either
## side — a user's own ``notes push`` runs this hook, and the commits it
## "introduces" are notes commits, which nothing certifies, while pushing the
## notes ref again from inside it would race the very push that started it;
## and an object that is not a commit (a tag of a tree or a blob).
##
## **What is published** (Tooling §3.1). Each introduced commit's own tree
## and its scoped tree in every scope the repository declares
## (``scopes``); an invalid declaration is reported and stops propagation.
##
## **Pushing** (Tooling §4.3). Only when one of those trees has certificates
## in the store, to the remote's NAME when there is one (so its configured push
## URL is used) and otherwise to the URL, through ``pushNotes`` with
## ``runHooks = false`` (``git push --no-verify``) so the hook does not
## re-enter itself, and within a time budget (``HookOptions.push.timeoutMs``,
## always finite) so an unresponsive remote cannot hold the user's push. With no
## certificates to carry, no network operation is made at all.
##
## **Partial clones** (Tooling §4.3). In a partial clone git fetches an object
## it lacks from the promisor remote, from inside commands that look local, and
## nothing about those commands limits the time that takes. Deciding what a push
## introduces, and whether any of it has certificates, therefore runs every
## command with ``git.NoLazyFetch``: with nothing to carry there is no network
## operation at all, and a remote object the clone lacks is simply absent, as
## §4.2 expects. Only once there are certificates to carry may a lazy fetch run,
## to read a note the clone lacks. A git too old to know the variable can fetch
## in any of these commands, so every command of the hook, deciding included,
## runs under one deadline.
##
## **Never failing.** ``prePushHook`` returns a report; nothing in it is a
## reason to refuse the push. ``propagated`` false with ``problems`` says
## certificates did not travel: the receiving gate decides what that means
## (Tooling §4).

import std/[os, sets, strutils, tables]
import ./[git, content_id, layout, roots, notes, scopes]

const
  NotesRefPrefix* = "refs/notes/"
  DefaultHookTimeoutMs* = 60_000
    ## The hook's network time budget unless the caller gives another. There
    ## is no unlimited budget (Tooling §4.3): a non-positive one means this.
  DefaultHookBatchTrees* = 1024
    ## Trees per batched scoped-tree computation (``HookOptions.batchTrees``).
  PrePushHookScript* = """#!/bin/sh
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
"""
    ## The hook ``hook install`` writes. It finds the tool on ``PATH`` at
    ## push time rather than naming the binary that installed it, which may
    ## be a store path that is gone by then.

type
  PushedRef* = object ## One line of git's ``pre-push`` input.
    localRef*, localOid*, remoteRef*, remoteOid*: string

  PrePushInput* = object
    refs*: seq[PushedRef]
    faults*: seq[string] ## Lines that could not be read, and why.

  HookOptions* = object
    push*: PushOptions
      ## For the notes push. ``runHooks`` is always forced off, and a
      ## ``timeoutMs`` that is not positive is replaced by
      ## ``DefaultHookTimeoutMs``: the budget is always finite. ``gitExe`` is
      ## the git of the whole hook, not only of its push.
    batchTrees*: int
      ## How many distinct introduced trees are held at once while their
      ## scoped trees are computed; 0 means ``DefaultHookBatchTrees``. It
      ## bounds the memory a push to a URL (whole history considered) takes.

  HookReport* = object ## What the hook did. Nothing here fails the push.
    target*: string ## Where the notes ref is pushed: the remote's name, else its URL.
    notesRef*: string
    faults*: seq[string] ## Input lines that could not be read.
    skipped*: seq[string] ## Pushed refs left alone, and why.
    introducedCount*: int ## How many commits the push introduces.
    certified*: seq[string]
      ## Of those, the commits with a tree — their own, or their scoped tree
      ## in a declared scope (Tooling §3.1) — that has a content directory in
      ## the store and that no earlier commit here shares: what is published.
    published*: PublishReport
    publishRan*: bool
    pushed*: SyncReport
    pushRan*: bool
    propagated*: bool
      ## Everything there was to carry was published and pushed. True when
      ## there was nothing to carry.
    remarks*: seq[string]
    problems*: seq[string]

proc defaultHookOptions*(): HookOptions =
  ## The default push options, with hooks off and a 60 s budget.
  result.push = defaultPushOptions()
  result.push.runHooks = false
  result.push.timeoutMs = DefaultHookTimeoutMs

proc isObjectName(s: string): bool =
  s.len in [40, 64] and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc isZero(oid: string): bool =
  oid.allCharsInSet({'0'})

proc parsePrePushInput*(text: string): PrePushInput =
  ## Git's ``pre-push`` standard input. Blank lines are ignored; a line that
  ## is not four fields with well-formed object names is a fault, reported,
  ## and the other lines still count.
  var n = 0
  for raw in text.split('\n'):
    inc n
    var line = raw
    if line.endsWith("\r"):
      line.setLen(line.len - 1)
    if line.strip().len == 0:
      continue
    let fields = line.splitWhitespace()
    if fields.len != 4:
      result.faults.add "line " & $n &
        " is not `<local ref> <local oid> <remote ref> <remote oid>`: " & line
      continue
    if not fields[1].isObjectName or not fields[3].isObjectName:
      result.faults.add "line " & $n & " has a malformed object name: " & line
      continue
    result.refs.add PushedRef(
      localRef: fields[0],
      localOid: fields[1],
      remoteRef: fields[2],
      remoteOid: fields[3],
    )

proc isConfiguredRemote(context: GitContext, dir, name: string): bool =
  if name.len == 0:
    return false
  let listed = git(context, dir, ["remote"])
  listed.ok and name in listed.stdout.splitLines()

proc peeledCommit(context: GitContext, dir, oid: string): string =
  ## The commit ``oid`` is or peels to; "" when it is not one or is absent from
  ## this repository, which never fetches it. ``context`` has the deadline for a
  ## git too old to know ``NoLazyFetch``: a lookup is otherwise instant, and one
  ## the deadline stops is the answer "absent" (§4.2's table).
  let run =
    gitRun(context, dir, ["rev-parse", "--verify", "--quiet", oid & "^{commit}"])
  if run.started and run.exitCode == 0:
    singleLine(run.stdout)
  else:
    ""

proc whyNotPeelable(context: GitContext, dir, oid: string): string =
  ## ``oid`` did not peel to a commit: "" when that is because it is not one
  ## (§4.1 skips it), and otherwise why that cannot be told, because the object
  ## or what it tags is absent here. Skipping that entry silently could drop
  ## commits the push introduces. A tag's header states what it tags, so a tag
  ## of a blob the clone lacks is still known not to be a commit.
  const MaxTagChain = 32
  var at = oid
  for _ in 1 .. MaxTagChain:
    if context.deadline.expired:
      return "the time budget ran out before " & at & " could be examined"
    let kind = git(context, dir, ["cat-file", "-t", at])
    if not kind.ok:
      return at & " is not in this repository"
    case singleLine(kind.stdout)
    of "tag":
      discard
    of "tree", "blob":
      return ""
    else:
      # It is a commit, so the lookup that failed did not fail for the reason
      # §4.1 skips an entry for, and skipping it would drop what it introduces.
      return at & " is a commit that could not be looked up"
    let tag = git(context, dir, ["cat-file", "tag", at])
    if not tag.ok:
      return at & " cannot be read: " & tag.failure
    var target, targetType: string
    for line in tag.stdout.splitLines():
      if line.len == 0:
        break # The headers end at the first empty line.
      if line.startsWith("object "):
        target = line["object ".len ..^ 1]
      elif line.startsWith("type "):
        targetType = line["type ".len ..^ 1]
    case targetType
    of "tree", "blob":
      return ""
    of "commit":
      return "the commit " & target & " that it tags is not in this repository"
    of "tag":
      at = target
    else:
      return "the tag " & at & " cannot be parsed"
  "its chain of tags is longer than " & $MaxTagChain

proc storedDigests(
    roots: StoreRoots, algorithm: ContentAlgorithm
): tuple[digests: HashSet[string], problems: seq[string]] =
  ## The content directories under ``v1/<algorithm>/`` in both roots. A root
  ## that is absent holds nothing; one that cannot be read is reported.
  for (label, root) in [("user", roots.user), ("system", roots.system)]:
    if root.len == 0:
      continue
    let dir = root / toNative(LayoutVersion & "/" & $algorithm)
    if not dirExists(dir):
      continue
    try:
      for kind, path in walkDir(dir, checkDir = true):
        if kind notin {pcDir, pcLinkToDir}:
          continue
        let name = path.extractFilename
        if not name.startsWith("."):
          result.digests.incl name
    except OSError as err:
      result.problems.add "the " & label & " store " & dir & " could not be read: " &
        err.msg

type Selection = ref object
  ## The certified commits, chosen while the introduced commits stream past
  ## (``prePushHook``). What it holds is bounded by the trees that have
  ## certificates and by one batch, never by the history.
  dir: string
  context: GitContext ## How every command of the deciding stage runs.
  hexLen: int
  batchTrees: int
  scopes: seq[DeclaredScope]
  stored: HashSet[string] ## Content directories in the store.
  covered: HashSet[string] ## Trees a selected commit already publishes.
  batch: OrderedTable[string, string] ## Tree -> its first commit, this batch.
  certified: seq[string]
  count: int ## Introduced commits seen.
  problem: string ## Why selection stopped; "" while it goes on.
  partial: string ## An output line not yet complete.
  commit: string ## The commit whose tree line comes next.

proc choose(s: Selection, tree, commit: string, scoped: openArray[string]) =
  ## Select ``commit`` when ``tree`` or one of its ``scoped`` trees has
  ## certificates that no commit selected earlier publishes.
  var wanted = tree in s.stored and tree notin s.covered
  for t in scoped:
    if t in s.stored and t notin s.covered:
      wanted = true
  if wanted:
    s.certified.add commit
    s.covered.incl tree
    for t in scoped:
      s.covered.incl t

proc flush(s: Selection): bool =
  ## Decide the batch: one batched tree walk computes the scoped trees of all
  ## its trees (``scopes.scopedTrees``). False, with ``problem``, on failure.
  if s.batch.len == 0:
    return true
  var trees: seq[string]
  for tree in s.batch.keys:
    trees.add tree
  let scoped = scopedTrees(s.dir, s.hexLen, trees, s.scopes, s.context)
  if not scoped.ok:
    s.problem = scoped.problem
    return false
  for tree, commit in s.batch:
    s.choose(tree, commit, scoped.trees[tree])
  s.batch.clear()
  true

proc take(s: Selection, commit, tree: string): bool =
  ## One introduced commit and its tree, in ``rev-list`` order. A tree seen
  ## again later in the same batch belongs to its first commit; across
  ## batches ``covered`` gives the same answer, since a tree not wanted once
  ## is not wanted later either.
  inc s.count
  if s.scopes.len == 0:
    # No scoped trees to compute: decide at once, hold nothing.
    s.choose(tree, commit, [])
    return true
  if tree notin s.batch:
    s.batch[tree] = commit
  if s.batch.len >= s.batchTrees:
    return s.flush()
  true

proc feed(s: Selection, data: openArray[char]): bool =
  ## ``git rev-list --format=%T`` output, as it arrives: a ``commit <oid>``
  ## line, then the tree. False stops the listing.
  for c in data:
    if c != '\n':
      s.partial.add c
      continue
    let line = move s.partial
    s.partial = ""
    if line.startsWith("commit "):
      s.commit = line["commit ".len ..^ 1]
    elif line.len > 0 and s.commit.len > 0:
      let commit = move s.commit
      s.commit = ""
      if not s.take(commit, line):
        return false
  true

proc revisionLines(revisions: openArray[string]): string =
  for r in revisions:
    result.add r & "\n"

proc listInto(
    s: Selection, revisions, options: openArray[string]
): tuple[ok: bool, problem: string] =
  ## Stream ``git rev-list --format=%T <options>`` into the selection, with
  ## ``revisions`` given on standard input: one per pushed ref and per
  ## exclusion, they could outgrow a command line (32767 characters on
  ## Windows) in a push of many refs.
  let sink: OutputSink = proc(data: openArray[char]): bool =
    s.feed(data)
  let run = gitRun(
    s.context,
    s.dir,
    @["rev-list", "--format=%T", "--stdin"] & @options,
    input = revisionLines(revisions),
    onStdout = sink,
  )
  if s.problem.len > 0:
    return (false, s.problem)
  if not run.started:
    return (false, run.failure)
  if run.exitCode != 0:
    return (
      false, "`git rev-list` failed (exit " & $run.exitCode & "): " & run.stderr.strip()
    )
  (true, "")

proc prePushHook*(
    dir, remoteName, remoteUrl, input: string,
    roots: StoreRoots,
    options = defaultHookOptions(),
): HookReport =
  ## Tooling §4 ``hook pre-push``, as a library call: ``input`` is the
  ## hook's standard input, ``remoteName`` and ``remoteUrl`` its two
  ## arguments. Publishes notes for every commit the push introduces whose
  ## tree has certificates in the store, then pushes the notes ref to the
  ## same remote with hooks off. Never raises; see the module comment.
  result.target = if remoteName.len > 0: remoteName else: remoteUrl
  let parsed = parsePrePushInput(input)
  result.faults = parsed.faults
  result.propagated = true

  # One git throughout (`PushOptions.gitExe`): a caller that resolved its own
  # does not get a mixture of it and whichever `git` is first on `PATH`.
  let gitExe = options.push.gitExe
  let repo = openNotesRepo(dir, gitExe = gitExe)
  if not repo.ok:
    result.problems.add repo.problem
    result.propagated = false
    return
  result.notesRef = repo.notesRef
  if result.target.len == 0 or result.target.startsWith("-"):
    result.problems.add "no remote to push the notes to (`" & result.target & "`)"
    result.propagated = false
    return

  let budgetMs =
    if options.push.timeoutMs > 0: options.push.timeoutMs else: DefaultHookTimeoutMs
  # One budget for the whole hook, deciding included, so that what the user
  # waits for is what the documentation says. Starting a second one for the
  # publish and the push would allow twice the budget whenever a git that ignores
  # `NoLazyFetch` had spent the first on a promisor that does not answer. The
  # price is a walk of a very long history (a push to a URL considers all of
  # it) that outlasts the budget: reported like any other expiry, and the push
  # goes on.
  let budget = deadlineIn(budgetMs)
  let deciding = GitContext(gitExe: gitExe, env: @[NoLazyFetch], deadline: budget)

  # Which refs count, and what the remote is known to have.
  var considered: seq[(PushedRef, string)] # The ref and its local commit.
  var onRemote: seq[string] # Remote objects this repository has.
  var remoteCommit = initTable[string, string]()
    # Each remote object's commit, "" when absent: looked up once, so that the
    # two uses of the answer below cannot disagree.
  for r in parsed.refs:
    if not r.remoteOid.isZero and r.remoteOid notin remoteCommit:
      let have = peeledCommit(deciding, dir, r.remoteOid)
      remoteCommit[r.remoteOid] = have
      if have.len > 0:
        onRemote.add have
  for r in parsed.refs:
    if r.localOid.isZero:
      result.skipped.add r.remoteRef & ": a deletion"
      continue
    if r.localRef.startsWith(NotesRefPrefix) or r.remoteRef.startsWith(NotesRefPrefix):
      result.skipped.add r.remoteRef & ": a notes ref, pushed as it is"
      continue
    let local = peeledCommit(deciding, dir, r.localOid)
    if local.len == 0:
      let why = whyNotPeelable(deciding, dir, r.localOid)
      if why.len > 0:
        result.problems.add "what the push to " & r.remoteRef &
          " introduces cannot be told: " & why
        result.propagated = false
      else:
        result.skipped.add r.remoteRef & ": " & r.localOid & " is not a commit"
      continue
    considered.add (r, local)
  if considered.len == 0:
    return

  # `--remotes=<name>` is a glob over refs/remotes/; a name that would
  # read as a pattern is not used as one.
  let tracked =
    if isConfiguredRemote(deciding, dir, remoteName) and
        not remoteName.contains({'*', '?', '[', '\\'}):
      @["--not", "--remotes=" & remoteName]
    else:
      @[]
  # The refs whose remote object this repository lacks are bounded by the
  # remote-tracking refs as well. They come after the others, so that each
  # ref can exclude every earlier ref's commits outright (an earlier ref's
  # exclusions are then always a subset of its own) and no commit is listed
  # twice — without remembering the commits already seen, which for a push
  # to a URL would be the whole history.
  var ordered: seq[(PushedRef, string, bool)]
    # The ref, its commit, bounded by tracking refs.
  for wantTracked in [false, true]:
    for (r, local) in considered:
      let remoteHas = remoteCommit.getOrDefault(r.remoteOid)
      let usesTracked = remoteHas.len == 0 and tracked.len > 0
      if usesTracked == wantTracked:
        ordered.add (r, local, usesTracked)

  # What deciding needs, read once: the declared scopes (Tooling §3.1; an
  # invalid declaration stops propagation, reported, as `notes publish`
  # stops) and the content directories in the store.
  let declared = declaredScopes(dir, deciding)
  let stored = storedDigests(roots, repo.algorithm)
  let selection = Selection(
    dir: dir,
    context: deciding,
    hexLen: repo.hexLen,
    batchTrees:
      if options.batchTrees > 0: options.batchTrees else: DefaultHookBatchTrees,
    scopes: declared.scopes,
    stored: stored.digests,
  )
  var prepared = false
  for i, (r, local, usesTracked) in ordered:
    # `onRemote` holds this ref's own remote object when this repository
    # has it, so the range is then `<remote>..<local>`.
    var revisions = @[local]
    for o in onRemote:
      revisions.add "^" & o
    for j in 0 ..< i:
      revisions.add "^" & ordered[j][1]
    let listOptions =
      if usesTracked:
        tracked
      else:
        @[]
    if not prepared:
      # Only now is it known that there may be something to carry, so a
      # push with nothing to consider reports nothing about the setup.
      let anything = git(
        deciding,
        dir,
        @["rev-list", "--max-count=1", "--stdin"] & listOptions,
        input = revisionLines(revisions),
      )
      if anything.ok and anything.stdout.strip().len == 0:
        continue
      prepared = true
      if not declared.ok:
        for p in declared.problems:
          result.problems.add "invalid scope declaration: " & p
        result.propagated = false
        return
      result.problems.add stored.problems
      if stored.problems.len > 0:
        result.propagated = false
      for problem in roots.problems:
        result.remarks.add problem
      if roots.user.len == 0 and roots.system.len == 0:
        result.problems.add "neither store root could be resolved"
        result.propagated = false
        return
    let listed = selection.listInto(revisions, listOptions)
    if not listed.ok and selection.problem.len > 0:
      # Computing scoped trees failed: as before, propagation stops.
      result.introducedCount = selection.count
      result.problems.add selection.problem
      result.propagated = false
      return
    if not listed.ok:
      result.problems.add "the commits pushed to " & r.remoteRef &
        " could not be listed: " & listed.problem
      result.propagated = false
      if budget.expired:
        break
      continue
  if not selection.flush():
    result.introducedCount = selection.count
    result.problems.add selection.problem
    result.propagated = false
    return
  result.introducedCount = selection.count
  result.certified = selection.certified
  if result.certified.len == 0:
    return

  # From here there is something to carry, and the network may be used: what
  # is left of the budget covers the publish (which may have to fetch a note
  # this clone lacks) and the push alike.
  template stopWhenOutOfTime(what: string) =
    if budget.expired:
      result.problems.add what & ": the time budget of " & $budgetMs & " ms ran out"
      result.propagated = false
      return

  stopWhenOutOfTime("the notes were not published")
  result.publishRan = true
  result.published =
    publishNotes(dir, roots, result.certified, deadline = budget, gitExe = gitExe)
  result.remarks.add result.published.remarks
  for t in result.published.trees:
    for p in t.searchProblems:
      result.remarks.add p
    for p in t.notPublished:
      result.remarks.add "not published: " & p
  if not result.published.ok:
    result.problems.add result.published.problems
    result.propagated = false
    # The certificates already in the local notes ref may still be pushed.

  stopWhenOutOfTime("the notes were not pushed")
  var pushOptions = options.push
  pushOptions.runHooks = false
  pushOptions.timeoutMs = budget.remainingMs
  result.pushRan = true
  result.pushed = pushNotes(dir, result.target, options = pushOptions)
  result.remarks.add result.pushed.remarks
  if not result.pushed.ok:
    result.problems.add result.pushed.problems
    result.propagated = false

type HookInstall* = object
  ok*: bool
  path*: string ## The hook file.
  alreadyInstalled*: bool ## It was there, byte for byte.
  problem*: string

proc installPrePushHook*(dir: string): HookInstall =
  ## Write ``PrePushHookScript`` as the repository's ``pre-push`` hook, in the
  ## hooks directory git uses (``core.hooksPath`` included). An existing hook
  ## is never replaced: a project that already has one calls ``hook
  ## pre-push`` from it (Tooling §4).
  let hooks = git(dir, ["rev-parse", "--path-format=absolute", "--git-path", "hooks"])
  if not hooks.ok:
    return HookInstall(problem: hooks.failure)
  let hooksDir = singleLine(hooks.stdout)
  result.path = hooksDir / "pre-push"
  if fileExists(result.path) or symlinkExists(result.path):
    var current = ""
    try:
      current = readFile(result.path)
    except IOError, OSError:
      discard
    if current == PrePushHookScript:
      result.ok = true
      result.alreadyInstalled = true
      return
    result.problem =
      result.path &
      " already exists; call `test-certificates hook pre-push \"$@\"` from it instead (see `test-certificates hook install --print`)"
    return
  try:
    createDir(hooksDir)
    let temporary = hooksDir / temporaryName("pre-push")
    writeFile(temporary, PrePushHookScript)
    setFilePermissions(
      temporary,
      {
        fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
        fpOthersExec,
      },
    )
    if fileExists(result.path) or symlinkExists(result.path):
      removeFile(temporary)
      result.problem = result.path & " appeared while installing; left as it is"
      return
    moveFile(temporary, result.path)
  except CatchableError as err:
    result.problem = "could not write " & result.path & ": " & err.msg
    return
  result.ok = true
