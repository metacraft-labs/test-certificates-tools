## Finding the candidate certificates stored for a content id, in both roots
## (Transport §2.4, §5; Tooling §2 ``find``).
##
## ``find`` returns CANDIDATES. It does not verify anything (Tooling §1): a
## framework's verifier judges what it returns. What it does decide is only
## what Transport §2.4 asks of every reader:
##
## * both roots are listed; a missing root or directory, or an empty one,
##   means "no certificates found", never an error;
## * a root that exists but cannot be read is REPORTED, and the other root is
##   still searched;
## * a name found in both roots is one payload, but the two copies need not
##   be the same certificate (one may be signed): a copy byte-identical to one
##   already taken is skipped, any other copy is a candidate too, so neither
##   hides one that would have counted;
## * a record whose own ``content`` is not the id it was found under is
##   reported and ignored. A file that cannot be parsed is still a candidate
##   (and noted): whether it counts is the verifier's call, and dropping it
##   here would turn "unverifiable" into "not found".
##
## The report says what was searched, so "nothing found" can be told apart
## from "looked in the wrong place" (Transport §5).

import std/[algorithm, os, strutils]
import ./[content_id, content_state, certificate, layout, roots]

when not defined(windows):
  import std/posix

type
  RootStatus* = enum
    rsListed = "listed" ## The content directory was listed (possibly empty).
    rsAbsent = "absent" ## No such root or directory: nothing found.
    rsUnreadable = "unreadable" ## It exists and could not be read.
    rsUnresolved = "unresolved" ## The root itself could not be resolved.

  RootSearch* = object
    label*: string ## ``user`` or ``system``.
    root*: string
    directory*: string ## The content directory looked in.
    status*: RootStatus
    problem*: string

  Candidate* = object
    path*: string
    label*: string ## Which root it was found in.
    parsed*: bool ## Whether it parsed as a certificate.
    signed*: bool ## When parsed: whether it carries a signature block.
    note*: string ## Why it is noteworthy (e.g. it did not parse).

  Skipped* = object
    path*: string
    reason*: string

  FindReport* = object
    contentId*: string ## The id looked up; "" when it could not be computed.
    computed*: ComputedContentId ## How the id was obtained, for a state query.
    searches*: seq[RootSearch]
    candidates*: seq[Candidate]
    skipped*: seq[Skipped]
      ## Byte-identical duplicates and records whose content does not match.
    problems*: seq[string] ## Root resolution problems, unreadable files.

  FindOutcome* = enum
    foFound ## At least one candidate (exit 0).
    foNone ## None found in a completed search (exit 1).
    foUncomputable ## The content id could not be computed (exit 2).
    foIncomplete ## None found, but a root could not be read or resolved (exit 3).

proc outcome*(r: FindReport): FindOutcome =
  if r.contentId.len == 0:
    foUncomputable
  elif r.candidates.len > 0:
    foFound
  else:
    # A candidate is useful even if its peer root was inaccessible. With none,
    # distinguish absence from a search that could not cover both roots.
    for search in r.searches:
      if search.status in {rsUnreadable, rsUnresolved}:
        return foIncomplete
    foNone

proc accessState(path: string): tuple[exists, denied: bool, problem: string] =
  ## Whether ``path`` exists, telling "absent" from "cannot be looked at".
  when defined(windows):
    (dirExists(path) or fileExists(path), false, "")
  else:
    var st: Stat
    if stat(path.cstring, st) == 0:
      return (true, false, "")
    let e = errno
    if e == ENOENT or e == ENOTDIR:
      return (false, false, "")
    (false, true, "'" & path & "' cannot be examined: " & $strerror(e))

proc searchRoot(
    label, root, algorithm, digest: string
): tuple[search: RootSearch, files: seq[string]] =
  result.search = RootSearch(label: label, root: root)
  if root.len == 0:
    result.search.status = rsUnresolved
    result.search.problem = "the " & label & " root could not be resolved"
    return
  let relative = contentDirRelative(algorithm, digest)
  let dir = root / toNative(relative)
  result.search.directory = dir
  # Walk down from the root: an unreadable directory on the way makes
  # everything below it LOOK absent, and must be reported as unreadable.
  var probe = root
  let rootState = accessState(root)
  if rootState.denied:
    result.search.status = rsUnreadable
    result.search.problem = rootState.problem
    return
  if not rootState.exists:
    result.search.status = rsAbsent
    return
  for part in relative.split('/'):
    try:
      for _ in walkDir(probe, checkDir = true):
        break
    except OSError as err:
      result.search.status = rsUnreadable
      result.search.problem = "'" & probe & "' could not be read: " & err.msg
      return
    let next = probe / part
    let state = accessState(next)
    if state.denied:
      result.search.status = rsUnreadable
      result.search.problem = state.problem
      return
    if not state.exists:
      result.search.status = rsAbsent
      return
    probe = next
  var names: seq[string]
  try:
    for kind, path in walkDir(dir, checkDir = true):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      if isRecordName(path.extractFilename):
        names.add path
  except OSError as err:
    result.search.status = rsUnreadable
    result.search.problem = "'" & dir & "' could not be listed: " & err.msg
    return
  names.sort()
  result.search.status = rsListed
  result.files = names

proc findById*(roots: StoreRoots, contentId: string): FindReport =
  ## The candidates stored for ``contentId`` in both roots. The id is used as
  ## given (a keyed lookup): it must be well-formed, or well-formed in an
  ## algorithm outside Content-Id §4 with a name usable as a directory.
  result.problems = roots.problems
  let dir = contentDirOf(contentId)
  if not dir.ok:
    result.problems.add dir.problem
    return
  result.contentId = contentId
  var seen: seq[tuple[name, bytes: string]]
  for (label, root) in [("user", roots.user), ("system", roots.system)]:
    let (search, files) = searchRoot(label, root, dir.algorithm, dir.digest)
    result.searches.add search
    for path in files:
      var bytes: string
      try:
        bytes = readFile(path)
      except CatchableError as err:
        result.problems.add "'" & path & "' could not be read: " & err.msg
        continue
      let name = path.extractFilename
      var duplicate = false
      for s in seen:
        if s.name == name and s.bytes == bytes:
          duplicate = true
          break
      if duplicate:
        result.skipped.add Skipped(
          path: path,
          reason: "byte-identical to the copy already found under the same name",
        )
        continue
      var candidate = Candidate(path: path, label: label)
      let parsed = parseCertificate(bytes)
      if parsed.ok:
        if parsed.certificate.content != contentId:
          result.skipped.add Skipped(
            path: path,
            reason:
              "its content `" & parsed.certificate.content &
              "` is not the id of the directory " &
              "it was found in; ignored (Transport §2.4)",
          )
          continue
        candidate.parsed = true
        candidate.signed = parsed.certificate.isSigned
      else:
        candidate.note =
          "does not parse as a certificate (" & parsed.problem &
          "); returned for the verifier to report"
      seen.add (name, bytes)
      result.candidates.add candidate

type FindQuery* = object
  ## What to look up: an explicit content id, or a state of a repository
  ## whose content id is computed first (Content-Id §5).
  case byContent*: bool
  of true:
    contentId*: string
  of false:
    repository*: string ## A directory inside the working tree.
    state*: ContentState
    algorithm*: string ## "" means the repository's ``git-tree-*``.
    paths*: seq[string] ## The scope; empty for the whole repository.

proc find*(roots: StoreRoots, query: FindQuery): FindReport =
  ## Tooling §2 ``find``: compute the content id if a state was given, then
  ## look it up in both roots.
  if query.byContent:
    let parsed = parseContentId(query.contentId)
    if parsed.form == cifMalformed:
      result.problems = roots.problems
      result.problems.add "content id `" & query.contentId & "` is malformed: " &
        parsed.problem & " (Content-Id §1)"
      return
    return findById(roots, query.contentId)
  var computed: ComputedContentId
  if query.algorithm.len == 0:
    computed = computeContentId(query.repository, query.state, query.paths)
  else:
    let (known, algorithm) = lookupAlgorithm(query.algorithm)
    if not known:
      result.problems = roots.problems
      result.problems.add "`" & query.algorithm &
        "` is not an algorithm this tool computes (Content-Id §4)"
      return
    computed = computeContentId(query.repository, query.state, algorithm, query.paths)
  if computed.outcome != coComputed:
    result.problems = roots.problems
    result.computed = computed
    var problem = computed.problem
    for refusal in computed.refusals:
      problem.add "; " & $refusal.condition & ": " & refusal.paths.join(", ")
    result.problems.add problem
    return
  result = findById(roots, computed.id)
  result.computed = computed
