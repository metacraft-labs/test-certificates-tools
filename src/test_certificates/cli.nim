## The ``test-certificates`` command line, as a library procedure.
##
## ``runCli`` parses the arguments, calls the library operation of the same
## name, prints what it returned and answers an exit status. It never
## terminates the process itself; ``src/test_certificates_cli.nim`` is the
## executable's three-line ``main``. Keeping it here lets the tests drive the
## real command line in-process as well as through the built binary.
##
## Output conventions: results that a script consumes (store roots, record
## paths, candidate paths, removed directories) go to standard output, one per
## line; the report of what was searched, kept or refused goes to standard
## error.
##
## Exit statuses:
##
## * ``find``: 0 candidates found, 1 a completed empty search, 2 the content
##   id could not be computed, 3 an incomplete empty search (a root could not
##   be read or resolved), 64 usage error (Tooling §2);
## * every other command, `notes` included: 0 success, 1 an operation
##   failed, 2 usage error. A note piece that is reported and skipped (Transport
##   §3.1) is not a failure.
## * ``hook pre-push``: always 0, whatever happened (Tooling §4: it never
##   fails the push it is attached to); what could not be propagated is
##   reported on standard error.

import std/[os, sequtils, strutils]
import ./[roots, put, find, prune, content_state, notes, hook, scopes]

const
  Version* = block:
    ## Single-sourced from the nimble file, read at compile time.
    var v = ""
    for line in staticRead("../../test_certificates.nimble").splitLines:
      if line.startsWith("version") and '"' in line:
        v = line.split('"')[1]
    doAssert v.len > 0, "no version in test_certificates.nimble"
    v
  Usage* = """
Usage:
  test-certificates store-root
  test-certificates put [--system <user>] <file>...|-
  test-certificates find (--content <id> | --commit <rev> | --staged | --worktree)
                         [--paths <path>...] [--algorithm <algorithm>]
  test-certificates prune [--keep <n>] [--system <user>] [--paths <path>...]...
  test-certificates notes publish <commit>|<range>...
  test-certificates notes import [<commit>|<range>...]
  test-certificates notes (push|fetch) <remote>
  test-certificates hook pre-push <remote-name> <remote-url>
  test-certificates hook install [--print]
  test-certificates --help | --version

Commands:
  store-root  Print the resolved user root and system root.
  put         Write certificates atomically into the user root, or with
              --system <user> (a uid, or a SID on Windows) into that user's
              system partition. `-` reads one certificate from standard input.
  find        Print the candidate certificates stored for a state's content
              id, from both roots. Exit 0 found, 1 complete empty search,
              2 uncomputable id, 3 incomplete empty search, 64 usage error.
  prune       Remove content directories beyond the newest n (default 20),
              protecting HEAD in native git-tree and manifest algorithms,
              unscoped, in each scope declared by a --paths group and in
              each scope the repository declares.
  notes       Carry certificates in git notes on each commit's tree, and on
              its scoped tree in every scope the repository declares
              (git config testCertificatesScope.<name>.path, one path per
              value, one section per scope), in the notes ref (git config
              testCertificates.notesRef, default
              refs/notes/test-certificates/certificates):
                publish  add the store's certificates to the local notes
                import   copy noted certificates into the user root
                         (default HEAD)
                push     push the notes ref; on a race, fetch, merge the
                         union of both sides and retry
                fetch    fetch the remote notes ref and merge the union
  hook        pre-push: a complete pre-push hook body (git passes the
              arguments and standard input); publishes and pushes notes for
              the commits the push introduces and ALWAYS exits 0.
              TEST_CERTIFICATES_HOOK=off skips it; TEST_CERTIFICATES_HOOK_TIMEOUT
              (whole seconds, at least 1, default 60) bounds its network time.
              install: write it as this repository's pre-push hook, unless
              one exists; --print shows the hook instead.
"""

type CliIo* = object
  ## Where ``runCli`` reads and writes. The executable passes the process's
  ## standard streams.
  input*: File
  output*: File
  errors*: File

proc say(f: File, line: string) =
  f.writeLine(line)

proc usageError(io: CliIo, msg: string, status = 2): int =
  io.errors.say "test-certificates: " & msg
  io.errors.say "Run `test-certificates --help` for usage."
  status

proc reportProblems(io: CliIo, problems: openArray[string]) =
  for p in problems:
    io.errors.say "note: " & p

# ---------------------------------------------------------------------------
# store-root
# ---------------------------------------------------------------------------

proc storeRootCommand(io: CliIo, args: seq[string]): int =
  if args.len > 0:
    return usageError(io, "store-root takes no arguments")
  let r = nativeRoots()
  io.output.say "user: " & (if r.user.len > 0: r.user else: "(unresolved)")
  io.output.say "system: " & (if r.system.len > 0: r.system else: "(unresolved)")
  reportProblems(io, r.problems)
  if r.user.len > 0: 0 else: 1

# ---------------------------------------------------------------------------
# put
# ---------------------------------------------------------------------------

proc putCommand(io: CliIo, args: seq[string]): int =
  var system = ""
  var files: seq[string]
  var i = 0
  var optionsDone = false
  while i < args.len:
    let a = args[i]
    if not optionsDone and a == "--":
      optionsDone = true
    elif not optionsDone and a == "--system":
      if i + 1 >= args.len:
        return usageError(io, "--system needs a user (a uid, or a SID on Windows)")
      inc i
      system = args[i]
    elif not optionsDone and a.startsWith("--system="):
      system = a["--system=".len ..^ 1]
    elif not optionsDone and a.startsWith("-") and a != "-":
      return usageError(io, "put: unknown option " & a)
    else:
      files.add a
    inc i
  if files.len == 0:
    return usageError(io, "put needs at least one file, or `-` for standard input")
  if files.count("-") > 1:
    return usageError(io, "standard input (`-`) can be read only once")
  var root: string
  if system.len > 0:
    let partition = systemPartition(hostPlatform(), nativeEnvironment(), system)
    if partition.path.len == 0:
      io.errors.say "test-certificates: " & partition.problems.join("; ")
      return 1
    root = partition.path
  else:
    let r = nativeRoots()
    if r.user.len == 0:
      io.errors.say "test-certificates: " & r.problems.join("; ")
      return 1
    root = r.user
  result = 0
  for f in files:
    let outcome =
      if f == "-":
        # The client half of a daemon's delivery: the daemon returned the
        # certificate, the client (running as the user) pipes it here.
        var r: PutResult
        try:
          r = putCertificate(root, io.input.readAll(), system = system.len > 0)
          if not r.ok:
            r.problem = "<stdin>: " & r.problem
        except IOError as err:
          r = PutResult(problem: "could not read standard input: " & err.msg)
        r
      else:
        putFile(root, f, system = system.len > 0)
    if outcome.ok:
      io.output.say outcome.path
      if outcome.kept:
        io.errors.say "note: " & outcome.path &
          " already existed; the relay rule preserves it (Transport §2.3)"
      if outcome.retried:
        io.errors.say "note: " & outcome.path &
          " was written on a retry after a concurrent prune"
    else:
      io.errors.say "test-certificates: " & outcome.problem
      result = 1

# ---------------------------------------------------------------------------
# find
# ---------------------------------------------------------------------------

proc describeState(q: FindQuery): string =
  if q.byContent:
    return "given"
  result =
    case q.state.kind
    of skCommit:
      "computed from commit " & q.state.revision
    of skStaged:
      "computed from the index being committed"
    of skWorktree:
      "computed from the working tree"
  if q.paths.len > 0:
    result.add ", scoped to " & q.paths.join(", ")

proc findCommand(io: CliIo, args: seq[string]): int =
  var query: FindQuery
  var stateGiven = 0
  var paths: seq[string]
  var algorithm = ""
  var i = 0
  proc value(name: string): string =
    if i + 1 >= args.len or args[i + 1].startsWith("--"):
      return ""
    inc i
    args[i]

  while i < args.len:
    let a = args[i]
    case a
    of "--content":
      let v = value(a)
      if v.len == 0:
        return usageError(io, "--content needs a content id", 64)
      query = FindQuery(byContent: true, contentId: v)
      inc stateGiven
    of "--commit":
      let v = value(a)
      if v.len == 0:
        return usageError(io, "--commit needs a revision", 64)
      query = FindQuery(byContent: false, state: commitState(v))
      inc stateGiven
    of "--staged":
      query = FindQuery(byContent: false, state: stagedState())
      inc stateGiven
    of "--worktree":
      query = FindQuery(byContent: false, state: worktreeState())
      inc stateGiven
    of "--algorithm":
      algorithm = value(a)
      if algorithm.len == 0:
        return usageError(io, "--algorithm needs an algorithm", 64)
    of "--paths":
      # `--paths a b c`: every following argument up to the next option.
      # A path that itself begins with `--` is passed after `--`.
      let before = paths.len
      inc i
      while i < args.len and not args[i].startsWith("--"):
        paths.add args[i]
        inc i
      if i < args.len and args[i] == "--":
        inc i
        while i < args.len:
          paths.add args[i]
          inc i
      if paths.len == before:
        return usageError(io, "--paths needs at least one path", 64)
      continue
    else:
      return usageError(io, "find: unknown argument " & a, 64)
    inc i
  if stateGiven != 1:
    return usageError(
      io, "find needs exactly one of --content, --commit, --staged, --worktree", 64
    )
  if query.byContent and (paths.len > 0 or algorithm.len > 0):
    return usageError(
      io,
      "--paths and --algorithm do not apply to --content: the id already " &
        "names its algorithm and scope",
      64,
    )
  if not query.byContent:
    query.repository = getCurrentDir()
    query.paths = paths
    query.algorithm = algorithm
  let roots = nativeRoots()
  let report = find(roots, query)
  # The report of what was searched (Transport §5), on standard error.
  if report.contentId.len > 0:
    io.errors.say "content id: " & report.contentId & " (" & describeState(query) & ")"
  for s in report.searches:
    var line =
      "searched " & s.label & " root " & (
        if s.root.len > 0: s.root else: "(unresolved)"
      )
    if s.directory.len > 0:
      line.add ": " & s.directory
    line.add " [" & $s.status & "]"
    if s.problem.len > 0:
      line.add ": " & s.problem
    io.errors.say line
  for k in report.skipped:
    io.errors.say "skipped " & k.path & ": " & k.reason
  for c in report.candidates:
    if c.note.len > 0:
      io.errors.say "note: " & c.path & " " & c.note
  reportProblems(io, report.problems)
  for c in report.candidates:
    io.output.say c.path
  case report.outcome
  of foFound:
    io.errors.say $report.candidates.len & " candidate(s) found"
    0
  of foNone:
    io.errors.say "no certificates found"
    1
  of foIncomplete:
    io.errors.say "no certificates found; search incomplete (a root could not be read or resolved)"
    3
  of foUncomputable:
    io.errors.say "the content id could not be computed; nothing was looked up"
    2

# ---------------------------------------------------------------------------
# prune
# ---------------------------------------------------------------------------

proc pruneCommand(io: CliIo, args: seq[string]): int =
  var keep = DefaultKeep
  var system = ""
  var scopes: seq[seq[string]]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--keep" or a.startsWith("--keep="):
      var v = ""
      if a == "--keep":
        if i + 1 >= args.len:
          return usageError(io, "--keep needs a number")
        inc i
        v = args[i]
      else:
        v = a["--keep=".len ..^ 1]
      try:
        keep = parseInt(v)
      except ValueError:
        return usageError(io, "--keep needs a non-negative number, not `" & v & "`")
      if keep < 0:
        return usageError(io, "--keep needs a non-negative number, not `" & v & "`")
    elif a == "--paths":
      var scope: seq[string]
      inc i
      while i < args.len and not args[i].startsWith("--"):
        scope.add args[i]
        inc i
      if i < args.len and args[i] == "--":
        inc i
        while i < args.len:
          scope.add args[i]
          inc i
      if scope.len == 0:
        return usageError(io, "--paths needs at least one path")
      for path in scope:
        let problem = scopePathProblem(path)
        if problem.len > 0:
          return usageError(io, problem)
      scopes.add scope
      continue
    elif a == "--system":
      if i + 1 >= args.len:
        return usageError(io, "--system needs a user (a uid, or a SID on Windows)")
      inc i
      system = args[i]
    elif a.startsWith("--system="):
      system = a["--system=".len ..^ 1]
    else:
      return usageError(io, "prune: unknown argument " & a)
    inc i
  var root: string
  if system.len > 0:
    let partition = systemPartition(hostPlatform(), nativeEnvironment(), system)
    if partition.path.len == 0:
      io.errors.say "test-certificates: " & partition.problems.join("; ")
      return 1
    root = partition.path
  else:
    let r = nativeRoots()
    if r.user.len == 0:
      io.errors.say "test-certificates: " & r.problems.join("; ")
      return 1
    root = r.user
  # Resolve every protection before pruneRoot can rename or delete anything.
  let protection = pruneProtection(getCurrentDir(), scopes)
  if not protection.ok:
    io.errors.say "test-certificates: " & protection.problem
    return 1
  let protectedIds = protection.ids
  for id in protectedIds:
    io.errors.say "keeping the content of HEAD^{tree}: " & id
  let r = pruneRoot(root, keep, protectedIds, system = system.len > 0)
  for d in r.removed:
    io.output.say d
  for d in r.busy:
    io.errors.say "note: " & d & " is being written into; left for a later prune"
  for d in r.leftovers:
    io.errors.say "note: deleted the leftover " & d
  for e in r.errors:
    io.errors.say "test-certificates: " & e
  io.errors.say "pruned " & root & ": removed " & $r.removed.len & ", kept " &
    $r.kept.len
  if r.ok and r.errors.len == 0: 0 else: 1

# ---------------------------------------------------------------------------
# notes
# ---------------------------------------------------------------------------

proc reportSync(io: CliIo, verb: string, r: SyncReport): int =
  for remark in r.remarks:
    io.errors.say "note: " & remark
  for p in r.problems:
    io.errors.say "test-certificates: " & p
  if not r.ok:
    return 1
  var line = r.notesRef & ": " & $r.outcome
  if verb == "push":
    line.add " after " & $r.attempts & " attempt(s)"
  if r.merges > 0:
    line.add ", " & $r.merges & " union merge(s)"
  io.errors.say line
  if r.notesCommit.len > 0:
    io.output.say r.notesCommit
  0

proc scopeNote(scope: seq[string]): string =
  ## How a report line says which declared scope a tree is for.
  if scope.len == 0:
    ""
  else:
    " in scope " & scopeLabel(scope)

proc notesCommand(io: CliIo, args: seq[string]): int =
  if args.len == 0:
    return usageError(io, "notes needs a subcommand: publish, import, push or fetch")
  let rest = args[1 ..^ 1]
  for a in rest:
    if a.startsWith("-"):
      return usageError(io, "notes " & args[0] & ": unknown option " & a)
  case args[0]
  of "publish":
    if rest.len == 0:
      return usageError(io, "notes publish needs at least one commit or range")
    let report = publishNotes(getCurrentDir(), nativeRoots(), rest)
    for t in report.trees:
      for p in t.searchProblems:
        io.errors.say "note: " & p
      for p in t.notPublished:
        io.errors.say "note: not published: " & p
      for h in t.appended:
        io.output.say t.contentId & " " & h
      for h in t.replaced:
        io.output.say t.contentId & " " & h
      io.errors.say t.contentId & scopeNote(t.scope) & " (" & t.commits.join(", ") &
        "): " & $t.appended.len & " appended, " & $t.replaced.len &
        " replaced by a signed copy, " & $t.present.len & " already present"
    for remark in report.remarks:
      io.errors.say "note: " & remark
    for p in report.problems:
      io.errors.say "test-certificates: " & p
    if not report.ok:
      return 1
    if report.notesCommit.len > 0:
      io.errors.say report.notesRef & " updated to " & report.notesCommit &
        " (local only; `test-certificates notes push <remote>` publishes it)"
    else:
      io.errors.say report.notesRef & " unchanged"
    0
  of "import":
    let roots = nativeRoots()
    let report = importNotes(getCurrentDir(), roots.user, rest)
    for t in report.trees:
      for s in t.stored:
        io.output.say s.path
      for f in t.faults:
        io.errors.say "note: " & t.contentId & ": " & f
      if not t.hasNote:
        io.errors.say t.contentId & scopeNote(t.scope) & " (" & t.commit & "): no note"
      else:
        var kept = 0
        for s in t.stored:
          if s.kept:
            inc kept
        io.errors.say t.contentId & scopeNote(t.scope) & " (" & t.commit & "): " &
          $t.stored.len & " record(s) stored (" & $kept & " kept an existing file), " &
          $t.faults.len & " skipped"
    reportProblems(io, roots.problems)
    for p in report.problems:
      io.errors.say "test-certificates: " & p
    if report.ok: 0 else: 1
  of "push", "fetch":
    if rest.len != 1:
      return usageError(io, "notes " & args[0] & " needs exactly one remote")
    if args[0] == "push":
      reportSync(io, "push", pushNotes(getCurrentDir(), rest[0]))
    else:
      reportSync(io, "fetch", fetchNotes(getCurrentDir(), rest[0]))
  else:
    usageError(io, "unknown notes subcommand " & args[0])

# ---------------------------------------------------------------------------
# hook
# ---------------------------------------------------------------------------

const
  HookSwitchVariable* = "TEST_CERTIFICATES_HOOK"
    ## ``off`` (or ``0``, ``false``, ``no``) turns ``hook pre-push`` into a
    ## no-op that says so.
  HookTimeoutVariable* = "TEST_CERTIFICATES_HOOK_TIMEOUT"
    ## Whole seconds the hook's network operations may take in all, at least
    ## 1. There is no "no limit" value (Tooling §4.3).
  DefaultHookTimeoutSeconds* = DefaultHookTimeoutMs div 1000

proc hookSay(io: CliIo, line: string) =
  io.errors.say "test-certificates: " & line

proc prePushCommand(io: CliIo, args: seq[string]): int =
  ## Tooling §4. Every path answers 0: the hook never fails the push. Its
  ## standard input is always read to the end, so git never sees a broken
  ## pipe from a hook that stopped listening.
  result = 0
  var input = ""
  try:
    input = io.input.readAll()
  except IOError as err:
    hookSay io, "warning: could not read the pushed refs: " & err.msg
  let switch = getEnv(HookSwitchVariable).strip().toLowerAscii()
  if switch in ["off", "0", "false", "no"]:
    hookSay io,
      HookSwitchVariable & "=" & getEnv(HookSwitchVariable) &
        ": certificates were not propagated with this push"
    return
  if args.len != 2:
    hookSay io,
      "warning: `hook pre-push` takes the remote's name and URL, as git passes " &
        "them; got " & $args.len & " argument(s). Certificates were not propagated."
    return
  var options = defaultHookOptions()
  let timeoutText = getEnv(HookTimeoutVariable).strip()
  if timeoutText.len > 0:
    try:
      let seconds = parseInt(timeoutText)
      if seconds < 1 or seconds > high(int32) div 1000:
        raise newException(ValueError, "out of range")
      options.push.timeoutMs = seconds * 1000
    except ValueError:
      hookSay io,
        "note: ignored " & HookTimeoutVariable & "=" & timeoutText &
          " (not a whole number of seconds, at least 1); using " &
          $DefaultHookTimeoutSeconds
  let report =
    prePushHook(getCurrentDir(), args[0], args[1], input, nativeRoots(), options)
  for f in report.faults:
    hookSay io, "note: ignored pre-push input " & f
  for r in report.remarks:
    hookSay io, "note: " & r
  if report.publishRan or report.pushRan:
    var appended, replaced: int
    for t in report.published.trees:
      appended += t.appended.len
      replaced += t.replaced.len
    var line =
      $report.certified.len & " certified tree(s) among " & $report.introducedCount &
      " pushed commit(s): " & $appended & " certificate(s) added to " & report.notesRef
    if replaced > 0:
      line.add ", " & $replaced & " replaced by a signed copy"
    if report.pushRan and report.pushed.ok:
      line.add "; " & $report.pushed.outcome & " to " & report.target
    hookSay io, line
  elif report.introducedCount > 0 and report.problems.len == 0:
    hookSay io,
      "no stored certificates for the " & $report.introducedCount &
        " commit(s) this push introduces; nothing to propagate"
  if report.problems.len > 0:
    for p in report.problems:
      hookSay io, "warning: " & p
    hookSay io,
      "warning: certificates were NOT fully propagated; the push continues. " &
        "Retry with `test-certificates notes push " & report.target & "`."

proc hookCommand(io: CliIo, args: seq[string]): int =
  if args.len == 0:
    return usageError(io, "hook needs a subcommand: pre-push or install")
  let rest = args[1 ..^ 1]
  case args[0]
  of "pre-push":
    # Not even a defect (an index out of range, a nil access) fails the
    # push: `runCli` catches only `CatchableError`, and a `Defect` that
    # escaped would end the process with status 1. The input has been read
    # by then (`prePushCommand` reads it first). A crash that is not an
    # exception (a signal) is left to the installed hook, which ignores the
    # status (see `PrePushHookScript`).
    try:
      prePushCommand(io, rest)
    except Exception as err: # Defect included, deliberately
      try:
        hookSay io,
          "warning: internal error: " & err.msg &
            "; certificates were not propagated, and the push continues"
      except Exception:
        discard
      0
  of "install":
    if rest == @["--print"]:
      io.output.write PrePushHookScript
      return 0
    if rest.len > 0:
      return usageError(io, "hook install takes only --print")
    let installed = installPrePushHook(getCurrentDir())
    if not installed.ok:
      io.errors.say "test-certificates: " & installed.problem
      return 1
    io.output.say installed.path
    if installed.alreadyInstalled:
      io.errors.say "already installed"
    0
  else:
    usageError(io, "unknown hook subcommand " & args[0])

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc runCli*(args: openArray[string], io: CliIo): int =
  ## Run one ``test-certificates`` invocation and answer its exit status.
  if args.len == 0:
    io.errors.write Usage
    return 2
  let rest = @args[1 ..^ 1]
  try:
    case args[0]
    of "store-root":
      storeRootCommand(io, rest)
    of "put":
      putCommand(io, rest)
    of "find":
      findCommand(io, rest)
    of "prune":
      pruneCommand(io, rest)
    of "notes":
      notesCommand(io, rest)
    of "hook":
      hookCommand(io, rest)
    of "--help", "-h", "help":
      io.output.write Usage
      0
    of "--version":
      io.output.say "test-certificates " & Version
      0
    else:
      usageError(io, "unknown command " & args[0])
  except CatchableError as err:
    # The library returns its errors; this catches only the unexpected (an
    # I/O error writing the report, say), so the process still answers a
    # status instead of a stack trace.
    io.errors.say "test-certificates: internal error: " & err.msg
    # Not even an unexpected error fails a push (Tooling §4).
    if args.len >= 2 and args[0] == "hook" and args[1] == "pre-push": 0 else: 1
