## Computing the content id of a state of a git repository (Content-Id §4.1,
## §5): a commit, the index being committed, or the working tree.
##
## What computing an id writes: loose blob and tree objects in the
## repository's object store, and nothing else in the repository. The user's
## index is COPIED to a temporary directory and every index operation runs
## against the copy, with ``GIT_OPTIONAL_LOCKS=0`` so that not even a
## read-only command refreshes the real index in passing. That is the
## promise ``find --staged`` and ``find --worktree`` make: the user's staging
## area is neither read as the tested state nor modified (Content-Id §4.1).
##
## The working-tree recipe is §4.1's, including the two steps that are "not
## optional": the copy is dated one second after the epoch, so that every
## entry is racily clean and git compares every tracked file's CONTENT with
## its indexed blob instead of trusting stat data
## (https://git-scm.com/docs/racy-git), and the filesystem monitor is off for
## the commands that read the copy.
##
## A state with no honest content id (Content-Id §3) is refused with the
## condition and the paths, never answered with an id that omits what the
## tests read.

import std/[os, strutils, tempfiles, times]
import ./[git, content_id, sha256]

type
  StateKind* = enum
    skCommit ## ``<revision>^{tree}``.
    skStaged ## The index being committed (honours ``GIT_INDEX_FILE``).
    skWorktree ## The working tree, as a producer computes it.

  ContentState* = object
    kind*: StateKind
    revision*: string ## ``skCommit`` only.

  NoContentIdCondition* = enum
    ## Content-Id §3: working-tree states with no content id.
    ncUnmerged = "the index has unmerged entries"
    ncAssumeUnchanged = "entries are marked assume-unchanged"
    ncSkipWorktreePresent =
      "entries are marked skip-worktree while their file is present"
    ncSubmoduleModified = "a nested repository has modified content"

  Refusal* = object
    condition*: NoContentIdCondition
    paths*: seq[string]

  ComputeOutcome* = enum
    coComputed ## ``id`` holds the content id.
    coNoContentId ## The state has none (Content-Id §3); see ``refusals``.
    coCannotCompute
      ## The algorithm cannot be computed here (e.g. ``git-tree-sha256`` in
      ## a SHA-1 repository): not a mismatch (Content-Id §5).
    coFailed ## Something went wrong; ``problem`` says what.

  ComputedContentId* = object
    outcome*: ComputeOutcome
    id*: string
    algorithm*: ContentAlgorithm
    toplevel*: string ## The repository's top-level directory, when found.
    refusals*: seq[Refusal]
    problem*: string

const StatDistrustTime* = 1'i64
  ## Seconds since the epoch given to the temporary index before ``git add
  ## --update`` (Content-Id §4.1). ``0`` would mean "unknown" to git, which
  ## then treats no entry as racy.

proc commitState*(revision: string): ContentState =
  ContentState(kind: skCommit, revision: revision)

proc stagedState*(): ContentState =
  ContentState(kind: skStaged)

proc worktreeState*(): ContentState =
  ContentState(kind: skWorktree)

proc failed(problem: string): ComputedContentId =
  ComputedContentId(outcome: coFailed, problem: problem)

proc scopePathProblem*(path: string): string =
  ## Why ``path`` is not a valid scope path (Standard §3.2.1: repo-relative,
  ## ``/``-separated, not beginning with ``./`` or ``/``, not ending in
  ## ``/``), or "" when it is.
  if path.len == 0:
    return "an empty scope path"
  if '\0' in path:
    return "scope path contains NUL"
  if path.startsWith("/") or path.endsWith("/") or '\\' in path:
    return "scope path `" & path & "` is not repo-relative and `/`-separated"
  for part in path.split('/'):
    if part.len == 0 or part == "." or part == "..":
      return "scope path `" & path & "` has an empty, `.` or `..` component"
  ""

proc repositoryTreeAlgorithm*(
    repository: string, gitExe = DefaultGitExe
): tuple[ok: bool, algorithm: ContentAlgorithm, problem: string] =
  ## The ``git-tree-*`` algorithm matching the repository's object format,
  ## the one a producer SHOULD use (Content-Id §4).
  ## ``gitExe`` as for ``git.gitRun``.
  let format = git(repository, ["rev-parse", "--show-object-format"], gitExe = gitExe)
  if not format.ok:
    return (false, caGitTreeSha1, format.failure)
  case singleLine(format.stdout)
  of "sha1":
    (true, caGitTreeSha1, "")
  of "sha256":
    (true, caGitTreeSha256, "")
  else:
    (
      false,
      caGitTreeSha1,
      "git reports object format `" & singleLine(format.stdout) &
        "`, which no content id algorithm is defined over",
    )

proc isObjectId(s: string, format: ContentAlgorithm): bool =
  parseContentId(formatContentId(format, s)).form == cifWellFormed

proc detectWorktreeConditions(
    toplevel, indexFile: string, scope: openArray[string]
): tuple[ok: bool, refusals: seq[Refusal], problem: string] =
  ## Every Content-Id §3 condition among the in-scope entries of
  ## ``indexFile`` (a copy of the user's index) and the working tree.
  var unmerged, assumeUnchanged, skipPresent, gitlinks: seq[string]
  # `ls-files -s -v`: `<tag> SP <mode> SP <object> SP <stage> TAB <path>`.
  # A lowercase tag is assume-unchanged, `S`/`s` skip-worktree, a non-zero
  # stage unmerged (git-ls-files(1), "-t" and "-v").
  let listing = git(
    toplevel,
    @["--literal-pathspecs", "ls-files", "-z", "-s", "-v", "--"] & @scope,
    indexFile,
  )
  if not listing.ok:
    return (false, @[], listing.failure)
  for record in nulRecords(listing.stdout):
    let tab = record.find('\t')
    let fields = (if tab < 0: @[] else: record[0 ..< tab].split(' '))
    if fields.len != 4 or fields[0].len != 1:
      return (
        false,
        @[],
        "`git ls-files -s -v` printed a record this recipe cannot read: " &
          record.escape(),
      )
    let tag = fields[0][0]
    let mode = fields[1]
    let path = record[tab + 1 ..^ 1]
    if fields[3] != "0":
      if path notin unmerged:
        unmerged.add path
      continue
    if tag in {'a' .. 'z'}:
      assumeUnchanged.add path
    if tag in {'S', 's'}:
      # Absent is how sparse checkout normally leaves a skip-worktree entry,
      # and then the indexed content IS the content; only a present file is
      # one git has been told not to look at.
      let onDisk = toplevel / path
      if fileExists(onDisk) or dirExists(onDisk) or symlinkExists(onDisk):
        skipPresent.add path
    if mode == "160000":
      gitlinks.add path
  # A nested repository is identified by its checked-out commit alone, so
  # modified content inside it cannot be represented. Only `git status`
  # looks inside submodules; `--ignore-submodules=none` overrides any
  # configuration hiding the answer. In a porcelain v2 record the `<sub>`
  # field is `S<c><m><u>`, `m` meaning tracked changes (git-status(1)).
  var modified: seq[string]
  if gitlinks.len > 0:
    let status = git(
      toplevel,
      @[
        "--literal-pathspecs", "status", "--porcelain=v2", "-z", "--untracked-files=no",
        "--ignore-submodules=none", "--no-renames", "--",
      ] & @scope,
      indexFile,
    )
    if not status.ok:
      return (false, @[], status.failure)
    for record in nulRecords(status.stdout):
      if record.startsWith("1 "):
        let fields = record.split(' ', maxsplit = 8)
        if fields.len == 9 and fields[2].len == 4 and fields[2][0] == 'S' and
            fields[2][2] == 'M':
          modified.add fields[8]
  var refusals: seq[Refusal]
  for (condition, paths) in [
    (ncUnmerged, unmerged),
    (ncAssumeUnchanged, assumeUnchanged),
    (ncSkipWorktreePresent, skipPresent),
    (ncSubmoduleModified, modified),
  ]:
    if paths.len > 0:
      refusals.add Refusal(condition: condition, paths: paths)
  (true, refusals, "")

proc detectUnmerged(
    toplevel, indexFile: string, scope: openArray[string]
): tuple[ok: bool, refusals: seq[Refusal], problem: string] =
  ## The one §3 condition of an index being committed: an unmerged entry has
  ## no single content (and ``git write-tree`` refuses it).
  let listing = git(
    toplevel,
    @["--literal-pathspecs", "ls-files", "-z", "--unmerged", "--"] & @scope,
    indexFile,
  )
  if not listing.ok:
    return (false, @[], listing.failure)
  var paths: seq[string]
  for record in nulRecords(listing.stdout):
    let tab = record.find('\t')
    if tab < 0:
      return (
        false, @[], "`git ls-files --unmerged` printed a record this recipe cannot read"
      )
    let path = record[tab + 1 ..^ 1]
    if path notin paths:
      paths.add path
  if paths.len == 0:
    return (true, @[], "")
  (true, @[Refusal(condition: ncUnmerged, paths: paths)], "")

proc readObjects*(
    toplevel: string, objectIds: openArray[string], kind: string
): tuple[ok: bool, contents: seq[string], problem: string] =
  ## The raw content of each object, in order, each required to be of type
  ## ``kind`` (``blob``, ``tree``). One ``cat-file --batch`` for all of
  ## them on POSIX; one ``cat-file <kind>`` each on Windows (see ``git``).
  if objectIds.len == 0:
    return (true, @[], "")
  when defined(windows):
    for oid in objectIds:
      let one = git(toplevel, ["cat-file", kind, oid])
      if not one.ok:
        return (false, @[], one.failure)
      result.contents.add one.stdout
    result.ok = true
  else:
    # `cat-file --batch`: for each requested id, `<oid> SP <type> SP <size>
    # LF <content> LF` (git-cat-file(1), "BATCH OUTPUT").
    let batch =
      git(toplevel, ["cat-file", "--batch"], input = @objectIds.join("\n") & "\n")
    if not batch.ok:
      return (false, @[], batch.failure)
    var at = 0
    let output = batch.stdout
    for oid in objectIds:
      let lineEnd = output.find('\n', at)
      if lineEnd < 0:
        return (false, @[], "`git cat-file --batch` ended early")
      let header = output[at ..< lineEnd].split(' ')
      if header.len != 3 or header[0] != oid or header[1] != kind:
        return (
          false,
          @[],
          "`git cat-file --batch` answered `" & output[at ..< lineEnd] & "` for " & oid,
        )
      var size: int
      try:
        size = parseInt(header[2])
      except ValueError:
        return (false, @[], "`git cat-file --batch` gave a size that is not a number")
      let start = lineEnd + 1
      if start + size + 1 > output.len or output[start + size] != '\n':
        return (false, @[], "`git cat-file --batch` output is truncated")
      result.contents.add output[start ..< start + size]
      at = start + size + 1
    result.ok = true

proc blobDigests(
    toplevel: string, objectIds: seq[string]
): tuple[ok: bool, digests: seq[string], problem: string] =
  ## The SHA-256 of each blob's content, in order.
  let read = readObjects(toplevel, objectIds, "blob")
  if not read.ok:
    return (false, @[], read.problem)
  for content in read.contents:
    result.digests.add sha256Hex(content)
  result.ok = true

proc manifestOfTree(toplevel, tree: string): tuple[ok: bool, digest, problem: string] =
  ## ``manifest-v1-sha256`` of a tree holding exactly the in-scope entries at
  ## their full paths. Its blobs are the content "as the VCS would record
  ## it" (Content-Id §2).
  let listing = git(toplevel, ["ls-tree", "-r", "-z", "--full-tree", tree])
  if not listing.ok:
    return (false, "", listing.failure)
  var entries: seq[ManifestEntry]
  var blobs: seq[string]
  var blobAt: seq[int]
  for record in nulRecords(listing.stdout):
    # `<mode> SP <type> SP <object> TAB <path>` (git-ls-tree(1)).
    let tab = record.find('\t')
    let fields = (if tab < 0: @[] else: record[0 ..< tab].split(' '))
    if fields.len != 3:
      return (false, "", "`git ls-tree` printed a record this recipe cannot read")
    let path = record[tab + 1 ..^ 1]
    case fields[1]
    of "blob":
      blobAt.add entries.len
      blobs.add fields[2]
      entries.add ManifestEntry(path: path, mode: fields[0])
    of "commit":
      # A gitlink: the nested repository's revision, as git spells it.
      entries.add ManifestEntry(
        path: path, mode: fields[0], contentSha256: sha256Hex(fields[2])
      )
    else:
      return (
        false,
        "",
        "`git ls-tree -r` listed a " & fields[1] &
          " entry, which a manifest has no record for",
      )
  let read = blobDigests(toplevel, blobs)
  if not read.ok:
    return (false, "", read.problem)
  for i, at in blobAt:
    entries[at].contentSha256 = read.digests[i]
  manifestDigest(entries)

proc scopedTreeOf*(
    toplevel, tree: string, scope: openArray[string], indexFile: string
): tuple[ok: bool, tree, problem: string] =
  ## Content-Id §4.1, "Scoped": the tree holding the in-scope entries of
  ## ``tree`` at their FULL paths, selected with literal pathspecs, built in
  ## ``indexFile`` (a path that does not exist yet; it is left behind for
  ## the caller to remove with its directory). ``scope`` is not validated
  ## here: callers check every path with ``scopePathProblem`` first.
  let empty = git(toplevel, ["read-tree", "--empty"], indexFile)
  if not empty.ok:
    return (false, "", empty.failure)
  let listing = git(
    toplevel,
    @["--literal-pathspecs", "ls-tree", "-r", "-z", "--full-tree", tree, "--"] & @scope,
  )
  if not listing.ok:
    return (false, "", listing.failure)
  if listing.stdout.len > 0:
    let info = git(
      toplevel,
      ["update-index", "-z", "--index-info"],
      indexFile,
      input = listing.stdout,
    )
    if not info.ok:
      return (false, "", info.failure)
  let written = git(toplevel, ["write-tree"], indexFile)
  if not written.ok:
    return (false, "", written.failure)
  (true, singleLine(written.stdout), "")

proc computeImpl(
    repository: string,
    state: ContentState,
    requested: ContentAlgorithm,
    repositoryAlgorithm: bool,
    scope: openArray[string],
): ComputedContentId =
  for path in scope:
    let problem = scopePathProblem(path)
    if problem.len > 0:
      return failed(problem)
  if state.kind == skCommit and
      (state.revision.len == 0 or state.revision.startsWith("-")):
    # A leading `-` would be read as an option.
    return failed("`" & state.revision & "` is not a revision")

  let top = git(repository, ["rev-parse", "--show-toplevel"])
  var topPath = singleLine(top.stdout)
  if not top.ok:
    # A committed state needs only objects, so a bare repository can compute
    # it too. Index and worktree states still require a working tree.
    let bare = git(repository, ["rev-parse", "--is-bare-repository"])
    if state.kind != skCommit or not bare.ok or singleLine(bare.stdout) != "true":
      return
        failed("`" & repository & "` is not inside a git working tree: " & top.failure)
    let directory = git(repository, ["rev-parse", "--absolute-git-dir"])
    if not directory.ok:
      return failed(directory.failure)
    topPath = singleLine(directory.stdout)
  # Every later command runs at the top level, so repo-relative scope paths
  # mean the same thing whatever directory the caller is in.
  let toplevel = topPath
  let format = repositoryTreeAlgorithm(toplevel)
  if not format.ok:
    return failed(format.problem)
  let treeAlgorithm = format.algorithm
  let algorithm = if repositoryAlgorithm: treeAlgorithm else: requested
  if algorithm != caManifestV1Sha256 and algorithm != treeAlgorithm:
    return ComputedContentId(
      outcome: coCannotCompute,
      algorithm: algorithm,
      toplevel: toplevel,
      problem:
        $algorithm &
        " cannot be computed in this repository: its object format makes its trees " &
        $treeAlgorithm & " ids",
    )

  var scratch: string
  try:
    scratch = createTempDir("test-certificates-", "-index")
  except OSError as err:
    return failed(
      "could not create a temporary directory for the computation's index: " & err.msg
    )
  try:
    var tree: string
    case state.kind
    of skCommit:
      let resolved =
        git(toplevel, ["rev-parse", "--verify", "--quiet", state.revision & "^{tree}"])
      if not resolved.ok:
        return failed(
          "`" & state.revision & "` does not name a commit or tree in this repository"
        )
      tree = singleLine(resolved.stdout)
    of skStaged, skWorktree:
      # `--git-path index` honours GIT_INDEX_FILE, so "what is tracked" is
      # the index git itself would use here: the one being committed, when
      # this runs inside a commit's hook (Content-Id §5).
      let indexPath =
        git(toplevel, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
      if not indexPath.ok:
        return failed(indexPath.failure)
      let source = singleLine(indexPath.stdout)
      let temporaryIndex = scratch / "index"
      if fileExists(source):
        try:
          copyFile(source, temporaryIndex)
        except OSError as err:
          return failed("could not copy the index to a temporary file: " & err.msg)
      else:
        # No index yet: nothing is tracked, and the content is the empty
        # tree in the repository's own object format.
        let empty = git(toplevel, ["read-tree", "--empty"], temporaryIndex)
        if not empty.ok:
          return failed(empty.failure)
      let detected =
        if state.kind == skWorktree:
          detectWorktreeConditions(toplevel, temporaryIndex, scope)
        else:
          detectUnmerged(toplevel, temporaryIndex, scope)
      if not detected.ok:
        return failed(detected.problem)
      if detected.refusals.len > 0:
        return ComputedContentId(
          outcome: coNoContentId,
          algorithm: algorithm,
          toplevel: toplevel,
          refusals: detected.refusals,
          problem: "this state has no content id (Content-Id §3)",
        )
      if state.kind == skWorktree:
        try:
          setLastModificationTime(temporaryIndex, fromUnix(StatDistrustTime))
        except OSError as err:
          return failed("could not date the temporary index: " & err.msg)
        # No pathspec: since git 2.0 `add --update` without one covers the
        # whole tree (what `-- :/` spells in §4.1), and it stays so under an
        # inherited GIT_LITERAL_PATHSPECS that would make `:/` a file name.
        let update = git(toplevel, ["add", "--update"], temporaryIndex)
        if not update.ok:
          return failed(update.failure)
      # `write-tree` stores its cache-tree back into the index it read,
      # which is the other reason the copy is used for the staged state.
      let written = git(toplevel, ["write-tree"], temporaryIndex)
      if not written.ok:
        return failed(written.failure)
      tree = singleLine(written.stdout)
    if not isObjectId(tree, treeAlgorithm):
      return failed(
        "git returned `" & tree & "` where a " & $treeAlgorithm & " tree id was expected"
      )

    if scope.len > 0:
      let scoped = scopedTreeOf(toplevel, tree, scope, scratch / "scoped-index")
      if not scoped.ok:
        return failed(scoped.problem)
      tree = scoped.tree
      if not isObjectId(tree, treeAlgorithm):
        return failed(
          "git returned `" & tree & "` where a " & $treeAlgorithm &
            " tree id was expected"
        )

    if algorithm == caManifestV1Sha256:
      let manifest = manifestOfTree(toplevel, tree)
      if not manifest.ok:
        return failed(manifest.problem)
      return ComputedContentId(
        outcome: coComputed,
        algorithm: algorithm,
        toplevel: toplevel,
        id: formatContentId(algorithm, manifest.digest),
      )
    ComputedContentId(
      outcome: coComputed,
      algorithm: treeAlgorithm,
      toplevel: toplevel,
      id: formatContentId(treeAlgorithm, tree),
    )
  finally:
    try:
      removeDir(scratch)
    except OSError:
      discard # A leftover temporary directory is not this call's failure.

proc computeContentId*(
    repository: string,
    state: ContentState,
    algorithm: ContentAlgorithm,
    scope: openArray[string] = [],
): ComputedContentId =
  ## The content id of ``state`` in the git repository containing
  ## ``repository``, in ``algorithm``, over ``scope`` (empty: the whole
  ## repository). Content-Id §4 and §5.
  computeImpl(repository, state, algorithm, false, scope)

proc computeContentId*(
    repository: string, state: ContentState, scope: openArray[string] = []
): ComputedContentId =
  ## As above, in the ``git-tree-*`` algorithm matching the repository's
  ## object format: the one a producer SHOULD use (Content-Id §4).
  computeImpl(repository, state, caGitTreeSha1, true, scope)

proc headTree*(repository: string): tuple[ok: bool, id: string] =
  ## The content id of ``HEAD^{tree}`` (unscoped, the repository's own
  ## ``git-tree-*`` algorithm), which a prune never removes (Transport §2.5).
  let computed = computeContentId(repository, commitState("HEAD"))
  if computed.outcome == coComputed:
    (true, computed.id)
  else:
    (false, "")

type HeadContentIds* = object
  ## Protection computed before any destructive store operation. An empty
  ## successful result means there is no repository or HEAD to protect.
  ok*: bool
  ids*: seq[string]
  tree*: string
    ## The frozen ``HEAD^{tree}`` object id every id was computed from; ""
    ## when there is no repository or HEAD to protect.
  problem*: string

proc addTreeContentIds*(
    protection: var HeadContentIds, repository: string, scopes: openArray[seq[string]]
): bool =
  ## Adds to ``protection.ids`` the content ids of ``protection.tree`` in
  ## each of ``scopes`` (``@[]`` for unscoped), in both computable
  ## algorithms, each id once. On failure sets ``problem`` and returns
  ## false; the ids added so far must then not be used.
  for scope in scopes:
    let native = computeContentId(repository, commitState(protection.tree), scope)
    let manifest = computeContentId(
      repository, commitState(protection.tree), caManifestV1Sha256, scope
    )
    for computed in [native, manifest]:
      if computed.outcome != coComputed:
        protection.problem = "cannot protect HEAD content: " & computed.problem
        return false
      if computed.id notin protection.ids:
        protection.ids.add computed.id
  true

proc headContentIds*(
    repository: string, scopes: seq[seq[string]] = @[]
): HeadContentIds =
  ## Both computable algorithms for one frozen HEAD tree, unscoped and in
  ## every explicitly declared scope. Never infers scopes from store files.
  for scope in scopes:
    if scope.len == 0:
      return HeadContentIds(problem: "an explicit scope needs at least one path")
    for path in scope:
      let problem = scopePathProblem(path)
      if problem.len > 0:
        return HeadContentIds(problem: problem)
  # Git has no distinct exit status for ordinary non-repository discovery.
  # Accept only its specific, locale-stable discovery diagnostic as absence;
  # missing executables, bad cwd, ownership refusals and damaged metadata
  # cannot authorize an unprotected prune.
  let directory =
    gitRun(repository, ["rev-parse", "--git-dir"], env = [("LC_ALL", "C")])
  if not directory.started:
    return HeadContentIds(problem: "cannot discover repository: " & directory.failure)
  if directory.exitCode != 0:
    let absent =
      directory.stderr.startsWith(
        "fatal: not a git repository (or any of the parent directories)"
      ) or
      directory.stderr.startsWith(
        "fatal: not a git repository (or any parent up to mount point"
      )
    if not absent:
      return HeadContentIds(
        problem: "cannot discover repository: " & directory.stderr.strip()
      )
    # Git also reports ordinary absence when HEAD is missing or malformed.
    # Repository metadata is evidence that discovery failed, not permission to
    # discard HEAD protection. Check ancestors too, for calls in subdirectories
    # and in bare repositories whose HEAD can no longer identify them to Git.
    var ancestor = absolutePath(repository)
    while true:
      let marker = ancestor / ".git"
      if fileExists(marker) or dirExists(marker) or symlinkExists(marker) or
          (dirExists(ancestor / "objects") and dirExists(ancestor / "refs")):
        return HeadContentIds(
          problem: "cannot discover repository with existing metadata: " & ancestor
        )
      let parent = parentDir(ancestor)
      if parent.len == 0 or parent == ancestor:
        break
      ancestor = parent
    if scopes.len > 0:
      return
        HeadContentIds(problem: "cannot protect explicit scopes outside a repository")
    return HeadContentIds(ok: true)
  let resolved = git(repository, ["rev-parse", "--verify", "--quiet", "HEAD^{tree}"])
  if not resolved.ok:
    # Only a genuinely unborn symbolic HEAD permits an empty protection set.
    # A damaged or unreadable existing HEAD must not authorize deletion.
    let symbolic = git(repository, ["symbolic-ref", "-q", "HEAD"])
    if symbolic.ok:
      let present = gitRun(
        repository, ["show-ref", "--verify", "--quiet", singleLine(symbolic.stdout)]
      )
      if present.started and present.exitCode == 1 and scopes.len == 0:
        return HeadContentIds(ok: true)
    return HeadContentIds(problem: "cannot resolve HEAD tree: " & resolved.failure)
  result.tree = singleLine(resolved.stdout)
  var allScopes: seq[seq[string]] = @[@[]]
  allScopes.add scopes
  if not addTreeContentIds(result, repository, allScopes):
    return HeadContentIds(problem: result.problem)
  result.ok = true
