## The private, short-lived refs a notes operation works in, and the cleanup
## of those a crashed run left behind.
##
## A notes write builds its tree on a work ref
## (``refs/notes/test-certificates-work/<name>``) and a fetch lands the remote
## notes ref on a temporary one (``refs/test-certificates/fetch/<name>``).
## Each operation deletes its own ref whatever happens, but a process that is
## killed (a signal, a power cut) cannot, and the ref stays: invisible to the
## user, harmless, but never collected by anything else.
##
## **Names.** ``<host>-<pid>-<n>-<seconds><nanoseconds>``: the host name
## (letters and digits only, anything else turned into ``_``), the process id,
## a per-process counter and the creation time (``layout.uniqueSuffix``).
## That says who made the ref and when, which is what a cleanup needs.
##
## **Which refs are stale** (``isStale``), checked opportunistically at the
## start of every ``notes publish``, ``fetch`` and ``push``:
##
## * older than ``StaleWorkRefSeconds`` (an hour) — no operation holds its ref
##   that long; or
## * made on THIS host by a process that no longer exists, and older than
##   ``DeadOwnerGraceSeconds``. The grace keeps a ref out of reach when the
##   process table cannot be trusted to say so: a repository shared between
##   containers that share a host name but not a process id namespace.
##
## A ref of this process is never taken by the second rule, a name that cannot
## be read is never taken at all, and the deletion is a compare-and-delete
## (``update-ref -d <ref> <oid>``): a ref that moved since it was listed is
## in use and stays. Should a live operation lose its work ref anyway, it
## notices (``notes.buildNotesCommit`` checks the tree it built) and fails
## rather than publishing a tree missing notes.

import std/[os, strutils, times]
import ./[git, layout]

when defined(windows):
  proc wrOpenProcess(
    access: uint32, inherit: int32, pid: uint32
  ): int {.stdcall, dynlib: "kernel32", importc: "OpenProcess".}

  proc wrWaitForSingleObject(
    h: int, ms: uint32
  ): uint32 {.stdcall, dynlib: "kernel32", importc: "WaitForSingleObject".}

  proc wrCloseHandle(
    h: int
  ): int32 {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}

  proc wrGetLastError(): uint32 {.stdcall, dynlib: "kernel32", importc: "GetLastError".}
else:
  import std/posix except Time

const
  StaleWorkRefSeconds* = 3600 ## Any work ref older than this is stale.
  DeadOwnerGraceSeconds* = 60
    ## A ref of a process that no longer exists on this host is stale once
    ## this old.

type WorkRefOwner* = object ## What a work ref's name says about who made it.
  parsed*: bool ## False: not a name this tool makes; never deleted.
  host*: string ## "" for names made before the host was recorded.
  pid*: int
  created*: Time

proc hostTag*(): string =
  ## This host's name in the form a ref name carries.
  var name = ""
  when defined(windows):
    name = getEnv("COMPUTERNAME")
  else:
    var buffer: array[256, char]
    if gethostname(cast[cstring](addr buffer[0]), buffer.len) == 0:
      buffer[^1] = '\0'
      name = $cast[cstring](addr buffer[0])
  for c in name:
    if result.len >= 64:
      break
    result.add(if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}: c else: '_')
  if result.len == 0:
    result = "unknown"

proc workRefName*(prefix: string): string =
  ## A fresh name under ``prefix``.
  prefix & hostTag() & "-" & uniqueSuffix()

proc parseWorkRefName*(leaf: string): WorkRefOwner =
  ## Read the part of a work ref's name after its prefix. Names without the
  ## host (``<pid>-<n>-<time>``) are read too, with ``host`` "".
  if '/' in leaf:
    return
  let fields = leaf.split('-')
  if fields.len notin [3, 4]:
    return
  let stamp = fields[^1]
  if stamp.len <= 9 or not stamp.allCharsInSet({'0' .. '9'}) or
      not fields[^3].allCharsInSet({'0' .. '9'}) or fields[^3].len == 0 or
      fields[^3].len > 10:
    return
  try:
    result.pid = parseInt(fields[^3])
    let seconds = parseBiggestInt(stamp[0 ..< stamp.len - 9])
    let nanos = parseInt(stamp[stamp.len - 9 .. ^1])
    result.created = initTime(seconds, nanos)
  except ValueError:
    return
  if fields.len == 4:
    result.host = fields[0]
  result.parsed = true

proc processExists*(pid: int): bool =
  ## Whether a process with this id exists on this host. When that cannot
  ## be told, it is assumed to exist.
  if pid <= 0:
    return true
  when defined(windows):
    const Synchronize = 0x0010_0000'u32
    const ErrorInvalidParameter = 87'u32
    let h = wrOpenProcess(Synchronize, 0, uint32(pid))
    if h == 0:
      # No such process is ERROR_INVALID_PARAMETER; anything else (access
      # denied) means it is there.
      return wrGetLastError() != ErrorInvalidParameter
    defer:
      discard wrCloseHandle(h)
    # A process that has exited but whose handle someone still holds is
    # signalled: it is gone.
    wrWaitForSingleObject(h, 0) != 0
  else:
    if kill(Pid(pid), 0) == 0:
      return true
    errno != ESRCH

proc isStale*(owner: WorkRefOwner, now: Time): bool =
  ## See the module comment.
  if not owner.parsed:
    return false
  let age = (now - owner.created).inSeconds
  if age > StaleWorkRefSeconds:
    return true
  owner.host.len > 0 and owner.host == hostTag() and owner.pid != getCurrentProcessId() and
    age > DeadOwnerGraceSeconds and not processExists(owner.pid)

proc cleanStaleWorkRefs*(
    dir: string, prefixes: openArray[string], now = getTime(), gitExe = DefaultGitExe
): tuple[removed, problems: seq[string]] =
  ## Delete the stale refs under ``prefixes`` (each ending in ``/``) in the
  ## repository at ``dir``, each only if it still holds the object it was
  ## listed with. Answers what was removed and what could not be.
  ## ``gitExe`` as for ``git.gitRun``.
  if prefixes.len == 0:
    return
  var args = @["for-each-ref", "--format=%(refname)%00%(objectname)"]
  args.add prefixes
  # Refs only: no object is needed, so none may be fetched for this.
  let listed = git(dir, args, env = [NoLazyFetch], gitExe = gitExe)
  if not listed.ok:
    result.problems.add listed.failure
    return
  for line in listed.stdout.splitLines():
    let nul = line.find('\0')
    if nul < 0:
      continue
    let name = line[0 ..< nul]
    let oid = line[nul + 1 .. ^1]
    var leaf = ""
    for p in prefixes:
      if name.startsWith(p):
        leaf = name[p.len .. ^1]
    if leaf.len == 0 or not parseWorkRefName(leaf).isStale(now):
      continue
    let deleted =
      gitRun(dir, ["update-ref", "-d", name, oid], env = [NoLazyFetch], gitExe = gitExe)
    if deleted.started and deleted.exitCode == 0:
      result.removed.add name
    elif deleted.started:
      result.problems.add "could not delete " & name & ": " & deleted.stderr.strip()
    else:
      result.problems.add deleted.failure
