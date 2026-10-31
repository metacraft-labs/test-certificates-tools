## The scopes a repository declares (Tooling §3.1), and the scoped trees of
## commits in them — what ``notes publish``, ``notes import`` and the
## ``pre-push`` hook carry besides each commit's own tree.
##
## **The declaration** is git configuration, one section per scope, one
## literal path per ``path`` value:
##
## .. code-block:: ini
##   [testCertificatesScope "db"]
##     path = Cargo.lock
##     path = src/db-backend
##
## It is read with ``git config -z --get-regexp``, so every file git reads for
## the repository counts, includes too. git canonicalises the key it prints:
## the section and the variable name lowercased, the section name (the
## subsection, in git's terms) kept as written
## (https://git-scm.com/docs/git-config#Documentation/git-config.txt---get-regexp).
## With ``-z`` each entry is ``<key> LF <value> NUL``, or ``<key> NUL`` for a
## key with no ``=`` at all (git-config(1), "-z").
##
## **The scoped trees** are Content-Id §4.1's: the in-scope entries of a
## commit's tree at their full paths. Computing that for every commit a push
## introduces would cost several git commands per commit and scope, so it is
## computed once per distinct in-scope CONTENT. That content is fixed by the
## entry (mode and object id) found at each scope path: a directory's entry
## names a tree object whose recursive listing is exactly what ``ls-tree -r``
## selects beneath that path, a file's entry is the one entry selected, and
## an absent path selects nothing. Those entries are found by walking the
## trees one path component at a time, reading every tree a round needs with
## ONE ``cat-file --batch`` (a round per component of the deepest path), and
## each distinct set of entries is then turned into its scoped tree by the
## same recipe ``find --paths`` uses (``content_state.scopedTreeOf``).

import std/[algorithm, os, sets, strutils, tables, tempfiles]
import ./[git, content_id, content_state]

const
  ScopeSection* = "testCertificatesScope" ## Tooling §3.1's section name.
  ScopeKeyPrefix = "testcertificatesscope." ## As git prints it: lowercased.
  ScopePathVariable = ".path"

type
  DeclaredScope* = object
    names*: seq[string] ## The sections that declare it (the same set of paths).
    paths*: seq[string] ## In byte order, each once.

  ScopeDeclaration* = object
    ok*: bool
    scopes*: seq[DeclaredScope] ## In the order their first section appears.
    problems*: seq[string] ## Why the declaration is invalid.

  ScopedTrees* = object
    ok*: bool
    trees*: Table[string, seq[string]]
      ## For each tree asked about, its scoped tree in each scope, in the
      ## order of the scopes given.
    problem*: string

proc scopeLabel*(paths: openArray[string]): string =
  ## A scope as reports show it: ``["src", "lib"]``.
  var quoted: seq[string]
  for p in paths:
    quoted.add "\"" & p & "\""
  "[" & quoted.join(", ") & "]"

proc declaredScopes*(dir: string, context = GitContext()): ScopeDeclaration =
  ## The scopes the repository containing ``dir`` declares (Tooling §3.1).
  ## No declaration is a valid, empty one. A path that is not a scope path,
  ## a value-less ``path``, or any other key under the section makes the
  ## whole declaration invalid: every such problem is reported.
  let listed =
    gitRun(context, dir, ["config", "-z", "--get-regexp", "^testcertificatesscope\\."])
  if not listed.started:
    result.problems.add "could not read the declared scopes: " & listed.failure
    return
  case listed.exitCode
  of 0:
    discard
  of 1:
    # No matching key: nothing declared.
    result.ok = true
    return
  else:
    result.problems.add "could not read the declared scopes: " & listed.stderr.strip()
    return
  var order: seq[string] # Section names, first appearance first.
  var paths = initTable[string, seq[string]]()
  for entry in nulRecords(listed.stdout):
    let lf = entry.find('\n')
    let key =
      if lf < 0:
        entry
      else:
        entry[0 ..< lf]
    let isPath =
      key.len > ScopeKeyPrefix.len + ScopePathVariable.len and
      key.startsWith(ScopeKeyPrefix) and key.endsWith(ScopePathVariable)
    if not isPath:
      result.problems.add "`" & key & "` is not a scope declaration: only " &
        ScopeSection & ".<name>.path is"
      continue
    let name = key[ScopeKeyPrefix.len ..< key.len - ScopePathVariable.len]
    if lf < 0:
      result.problems.add ScopeSection & "." & name & ".path has no value"
      continue
    let path = entry[lf + 1 ..^ 1]
    let problem = scopePathProblem(path)
    if problem.len > 0:
      result.problems.add ScopeSection & "." & name & ".path: " & problem
      continue
    if name notin paths:
      order.add name
      paths[name] = @[]
    if path notin paths[name]:
      paths[name].add path
  if result.problems.len > 0:
    return
  var bySet = initTable[seq[string], int]()
  for name in order:
    var set = paths[name]
    set.sort(byteOrder)
    if set in bySet:
      result.scopes[bySet[set]].names.add name
    else:
      bySet[set] = result.scopes.len
      result.scopes.add DeclaredScope(names: @[name], paths: set)
  result.ok = true

type TreeEntry = tuple[mode, oid: string]

proc parseTree(
    raw: string, hexLen: int
): tuple[ok: bool, entries: Table[string, TreeEntry]] =
  ## A raw tree object: ``<mode> SP <name> NUL <binary object id>``, repeated.
  const hexDigits = "0123456789abcdef"
  let idLen = hexLen div 2
  var at = 0
  while at < raw.len:
    let space = raw.find(' ', at)
    if space < 0:
      return
    let nul = raw.find('\0', space + 1)
    if nul < 0 or nul + idLen >= raw.len:
      return
    var oid = newStringOfCap(hexLen)
    for i in nul + 1 .. nul + idLen:
      let b = uint8(raw[i])
      oid.add hexDigits[int(b shr 4)]
      oid.add hexDigits[int(b and 0x0f)]
    result.entries[raw[space + 1 ..< nul]] = (raw[at ..< space], oid)
    at = nul + idLen + 1
  result.ok = true

proc scopedTrees*(
    dir: string,
    hexLen: int,
    trees: openArray[string],
    scopes: openArray[DeclaredScope],
    context = GitContext(),
): ScopedTrees =
  ## For each tree in ``trees``, its scoped tree in each of ``scopes``
  ## (Content-Id §4.1). ``hexLen`` is the length of an object id here. See
  ## the module comment for how the work is shared between trees. Every command
  ## runs as ``context`` says: with ``git.NoLazyFetch``, a tree a partial clone
  ## lacks is a reported failure.
  result.ok = true
  if scopes.len == 0 or trees.len == 0:
    for t in trees:
      result.trees[t] = @[]
    return

  # Every command runs at the top level (or, in a bare repository, in the
  # git directory), where `update-index` reads full paths as full paths.
  var toplevel = ""
  let top = git(context, dir, ["rev-parse", "--show-toplevel"])
  if top.ok:
    toplevel = singleLine(top.stdout)
  else:
    let bare = git(context, dir, ["rev-parse", "--is-bare-repository"])
    let gitDir = git(context, dir, ["rev-parse", "--absolute-git-dir"])
    if not bare.ok or singleLine(bare.stdout) != "true" or not gitDir.ok:
      return ScopedTrees(
        problem: "`" & dir & "` is not inside a git repository: " & top.failure
      )
    toplevel = singleLine(gitDir.stdout)

  # Every distinct path, split into components (scope paths are validated:
  # no empty, `.` or `..` component, no leading or trailing `/`).
  var pathIndex = initTable[string, int]()
  var components: seq[seq[string]]
  for s in scopes:
    for p in s.paths:
      if p notin pathIndex:
        pathIndex[p] = components.len
        components.add p.split('/')

  # Walk: a pending lookup is (root, path, the tree it has reached, the
  # component to find in it). A round reads every tree not read yet.
  type Pending = tuple[root, path: int, at: string, depth: int]
  var roots: seq[string]
  var rootIndex = initTable[string, int]()
  for t in trees:
    if t notin rootIndex:
      rootIndex[t] = roots.len
      roots.add t
  var found = initTable[(int, int), TreeEntry]() # (root, path) -> entry.
  var parsed = initTable[string, Table[string, TreeEntry]]()
  var pending: seq[Pending]
  for r in 0 ..< roots.len:
    for p in 0 ..< components.len:
      pending.add (r, p, roots[r], 0)
  while pending.len > 0:
    var wanted: seq[string]
    var asked: HashSet[string]
    for item in pending:
      if item.at notin parsed and not asked.containsOrIncl(item.at):
        wanted.add item.at
    let read = readObjects(toplevel, wanted, "tree", context)
    if not read.ok:
      return ScopedTrees(
        problem: "could not read trees for the declared scopes: " & read.problem
      )
    for i, oid in wanted:
      let tree = parseTree(read.contents[i], hexLen)
      if not tree.ok:
        return ScopedTrees(problem: "tree " & oid & " could not be parsed")
      parsed[oid] = tree.entries
    var next: seq[Pending]
    for item in pending:
      let name = components[item.path][item.depth]
      let entries = parsed[item.at]
      if name notin entries:
        continue # Absent: the path selects nothing.
      let entry = entries[name]
      if item.depth == components[item.path].high:
        found[(item.root, item.path)] = entry
      elif entry.mode == "40000":
        next.add (item.root, item.path, entry.oid, item.depth + 1)
      # Otherwise a file or a gitlink stands where a directory would have to
      # be: the path selects nothing, as `ls-tree` finds nothing beneath it.
    pending = next

  # One scoped tree per distinct in-scope content.
  var scratch: string
  try:
    scratch = createTempDir("test-certificates-", "-scopes")
  except OSError as err:
    return ScopedTrees(
      problem: "could not create a temporary directory for scoped trees: " & err.msg
    )
  defer:
    try:
      removeDir(scratch)
    except OSError:
      discard # A leftover temporary directory is not this call's failure.
  var byContent = initTable[string, string]()
  var n = 0
  for r, root in roots:
    var perScope: seq[string]
    for s in scopes:
      # Two NUL-terminated fields per path, the path and the entry found at
      # it (empty when absent). Neither can contain a NUL, so two keys are
      # equal only for the same paths with the same entries. (A key built
      # from ``scopeLabel`` would not be: ``["a\", \"b", "c"]`` and
      # ``["a", "b\", \"c"]`` print alike.)
      var key = ""
      for p in s.paths:
        let at = (r, pathIndex[p])
        key.add p & '\0'
        if at in found:
          key.add found[at].mode & " " & found[at].oid
        key.add '\0'
      if key notin byContent:
        inc n
        let built =
          scopedTreeOf(toplevel, root, s.paths, scratch / ("index-" & $n), context)
        if not built.ok:
          return ScopedTrees(
            problem:
              "the scoped tree of " & root & " in " & scopeLabel(s.paths) &
              " could not be computed: " & built.problem
          )
        byContent[key] = built.tree
      perScope.add byContent[key]
    result.trees[root] = perScope

proc pruneProtection*(
    repository: string, explicit: seq[seq[string]] = @[]
): HeadContentIds =
  ## What ``prune`` keeps for ``repository`` (Tooling §2, Transport §2.5):
  ## ``headContentIds`` for the unscoped state and every ``explicit`` scope,
  ## plus every scope the repository declares (Tooling §3.1), all computed
  ## from the same frozen ``HEAD`` tree in both algorithms. With no
  ## repository or no ``HEAD`` there is nothing to protect and the
  ## declaration is not read (outside a repository git would read only the
  ## user's and the system's configuration). An invalid declaration is a
  ## failure: pruning must then remove nothing.
  result = headContentIds(repository, explicit)
  if not result.ok or result.tree.len == 0:
    return
  let declared = declaredScopes(repository)
  if not declared.ok:
    return HeadContentIds(
      problem: "invalid scope declaration: " & declared.problems.join("; ")
    )
  var more: seq[seq[string]]
  for s in declared.scopes:
    more.add s.paths
  if not addTreeContentIds(result, repository, more):
    return HeadContentIds(problem: result.problem)
