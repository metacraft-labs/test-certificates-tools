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
## therefore considers the pushed ref's whole history. That is still cheap:
## the commits are listed with their trees in ONE ``rev-list``, and only the
## trees that have a content directory in the store are published, so
## publishing costs nothing for content nobody certified.
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
      ## ``DefaultHookTimeoutMs``: the budget is always finite.

  HookReport* = object ## What the hook did. Nothing here fails the push.
    target*: string ## Where the notes ref is pushed: the remote's name, else its URL.
    notesRef*: string
    faults*: seq[string] ## Input lines that could not be read.
    skipped*: seq[string] ## Pushed refs left alone, and why.
    introduced*: seq[string] ## Every commit the push introduces, once each.
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

proc isConfiguredRemote(dir, name: string): bool =
  if name.len == 0:
    return false
  let listed = git(dir, ["remote"])
  listed.ok and name in listed.stdout.splitLines()

proc peeledCommit(dir, oid: string): string =
  ## The commit ``oid`` is or peels to; "" when it is not one or is absent.
  let run = gitRun(dir, ["rev-parse", "--verify", "--quiet", oid & "^{commit}"])
  if run.started and run.exitCode == 0:
    singleLine(run.stdout)
  else:
    ""

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

proc commitsWithTrees(
    dir: string, args: openArray[string]
): tuple[ok: bool, pairs: seq[(string, string)], problem: string] =
  ## ``git rev-list --format=%T <args>``: every selected commit and its tree,
  ## in one command. The output is a ``commit <oid>`` line, then the tree.
  let listed = git(dir, @["rev-list", "--format=%T"] & @args & @["--"])
  if not listed.ok:
    return (false, @[], listed.failure)
  var commit = ""
  for line in listed.stdout.splitLines():
    if line.startsWith("commit "):
      commit = line["commit ".len ..^ 1]
    elif line.len > 0 and commit.len > 0:
      result.pairs.add (commit, line)
      commit = ""
  result.ok = true

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

  let repo = openNotesRepo(dir)
  if not repo.ok:
    result.problems.add repo.problem
    result.propagated = false
    return
  result.notesRef = repo.notesRef
  if result.target.len == 0 or result.target.startsWith("-"):
    result.problems.add "no remote to push the notes to (`" & result.target & "`)"
    result.propagated = false
    return

  # Which refs count, and what the remote is known to have.
  var considered: seq[(PushedRef, string)] # The ref and its local commit.
  var onRemote: seq[string] # Remote objects this repository has.
  for r in parsed.refs:
    if not r.remoteOid.isZero:
      let have = peeledCommit(dir, r.remoteOid)
      if have.len > 0:
        onRemote.add have
  for r in parsed.refs:
    if r.localOid.isZero:
      result.skipped.add r.remoteRef & ": a deletion"
      continue
    if r.localRef.startsWith(NotesRefPrefix) or r.remoteRef.startsWith(NotesRefPrefix):
      result.skipped.add r.remoteRef & ": a notes ref, pushed as it is"
      continue
    let local = peeledCommit(dir, r.localOid)
    if local.len == 0:
      result.skipped.add r.remoteRef & ": " & r.localOid & " is not a commit"
      continue
    considered.add (r, local)
  if considered.len == 0:
    return

  # `--remotes=<name>` is a glob over refs/remotes/; a name that would
  # read as a pattern is not used as one.
  let tracked =
    if isConfiguredRemote(dir, remoteName) and
        not remoteName.contains({'*', '?', '[', '\\'}):
      @["--not", "--remotes=" & remoteName]
    else:
      @[]
  var seenCommits: HashSet[string]
  var byTree = initOrderedTable[string, string]() # tree -> first commit
  for (r, local) in considered:
    # `onRemote` holds this ref's own remote object when this repository
    # has it, so the range is then `<remote>..<local>`.
    var args = @[local]
    for o in onRemote:
      args.add "^" & o
    let remoteHas =
      if r.remoteOid.isZero:
        ""
      else:
        peeledCommit(dir, r.remoteOid)
    if remoteHas.len == 0:
      args.add tracked
    let listed = commitsWithTrees(dir, args)
    if not listed.ok:
      result.problems.add "the commits pushed to " & r.remoteRef &
        " could not be listed: " & listed.problem
      result.propagated = false
      continue
    for (commit, tree) in listed.pairs:
      if not seenCommits.containsOrIncl(commit):
        result.introduced.add commit
        if tree notin byTree:
          byTree[tree] = commit
  if result.introduced.len == 0:
    return

  # The trees certificates are published on (Tooling §3.1): each introduced
  # tree, and its scoped tree in every declared scope. An invalid
  # declaration stops propagation, reported, as `notes publish` stops.
  let declared = declaredScopes(dir)
  if not declared.ok:
    for p in declared.problems:
      result.problems.add "invalid scope declaration: " & p
    result.propagated = false
    return
  var ownTrees: seq[string]
  for tree in byTree.keys:
    ownTrees.add tree
  let scoped = scopedTrees(dir, repo.hexLen, ownTrees, declared.scopes)
  if not scoped.ok:
    result.problems.add scoped.problem
    result.propagated = false
    return

  let stored = storedDigests(roots, repo.algorithm)
  result.problems.add stored.problems
  if stored.problems.len > 0:
    result.propagated = false
  for problem in roots.problems:
    result.remarks.add problem
  if roots.user.len == 0 and roots.system.len == 0:
    result.problems.add "neither store root could be resolved"
    result.propagated = false
    return
  var covered: HashSet[string] # Trees a selected commit already publishes.
  for tree, commit in byTree:
    let trees = @[tree] & scoped.trees[tree]
    var wanted = false
    for t in trees:
      if t in stored.digests and t notin covered:
        wanted = true
    if wanted:
      result.certified.add commit
      for t in trees:
        covered.incl t
  if result.certified.len == 0:
    return

  result.publishRan = true
  result.published = publishNotes(dir, roots, result.certified)
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

  var pushOptions = options.push
  pushOptions.runHooks = false
  if pushOptions.timeoutMs <= 0:
    pushOptions.timeoutMs = DefaultHookTimeoutMs
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
