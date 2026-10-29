## Bounding a store root by removing whole content directories
## (Transport §2.5; Tooling §2 ``prune``).
##
## * The newest ``keep`` content directories, by modification time (which
##   writing a file updates), are kept, plus every PROTECTED one — the
##   caller supplies the unscoped and declared scoped HEAD ids in each
##   computed algorithm. Ties are broken by name for deterministic selection.
## * A directory a producer is writing into is never removed: one modified
##   within ``FreshDirectoryAge``, or holding a temporary file younger than
##   ``StaleTemporaryAge`` (a writer creates the directory a moment before it
##   opens its temporary file), is left for a later prune.
## * A directory leaves the store in ONE atomic step: it is renamed, within its
##   parent, to a ``.``-prefixed name, and only then is the renamed tree
##   deleted. Deleting in place is not one step: a writer whose first attempt
##   that deletion defeated would retry into the same, still-present directory,
##   and the deletion would go on to remove the retry's file too.
## * Any ``.``-name directly under ``v1/<algorithm>/`` is the leftover of an
##   interrupted prune: it is deleted, and never counted as content.
##
## Pruning is a matter of disk space, not correctness: nothing here is fatal,
## and every directory it could not remove is reported.

import std/[algorithm, os, strutils, times]
import ./[content_id, layout]

when defined(windows):
  import std/winlean
  import ./windows_owner
else:
  import std/posix except Time
  import ./[posix_at, permissions]

const
  DefaultKeep* = 20 ## The reference policy (Transport §2.5).
  FreshDirectoryAge* = initDuration(seconds = 10)
  StaleTemporaryAge* = initDuration(hours = 1)
    ## A temporary file older than this belongs to a writer that died; without
    ## an age, one crashed run would pin its directory forever.

type
  PruneStage* = enum
    psChosen ## Chosen for removal, nothing changed yet.
    psDetached ## Renamed aside: out of the store, its tree not yet deleted.

  PruneStepHook* = proc(stage: PruneStage, relative: string) {.closure.}
    ## A test seam interleaving a writer with one directory's removal. ``nil``
    ## in production.

  PruneResult* = object
    ok*: bool ## False only when the root could not be pruned at all.
    removed*: seq[string] ## ``v1/<algorithm>/<digest>`` of each removed directory.
    kept*: seq[string] ## Content directories left in place.
    busy*: seq[string] ## Chosen, but being written into: left alone.
    leftovers*: seq[string] ## ``.``-names deleted.
    errors*: seq[string] ## What could not be removed, and why.

proc renameAside(path, aside: string): tuple[ok: bool, problem: string] =
  ## ONE rename of a directory within its parent, and nothing else.
  ## ``std/os.moveDir`` falls back to copy-and-delete when the rename is
  ## refused, which is neither atomic nor wanted (Windows refuses exactly when
  ## a writer holds a file open inside).
  when defined(windows):
    if moveFileExW(newWideCString(path), newWideCString(aside), 0'i32) == 0:
      return (false, osErrorMsg(osLastError()))
  else:
    if c_rename(path.cstring, aside.cstring) != 0:
      return (false, $strerror(errno))
  (true, "")

proc beingWritten(dir: string, now: Time, noFollow = false): bool =
  ## Whether a producer may be writing into ``dir`` right now. Anything that
  ## cannot be established counts as "yes": removing a directory in use is
  ## worse than keeping one a little longer.
  try:
    if now - getLastModificationTime(dir) < FreshDirectoryAge:
      return true
  except OSError:
    return true
  try:
    # The extended form, so a temporary record's path past MAX_PATH can still
    # be dated: an undatable one would count as a write forever.
    for kind, path in walkDir(extendedTreePath(dir), checkDir = true):
      if isTemporaryName(path.extractFilename):
        if noFollow and kind in {pcLinkToDir, pcLinkToFile}:
          continue # A symbolic link is not a writer's temporary record.
        try:
          if now - getFileInfo(path, followSymlink = not noFollow).lastWriteTime <
              StaleTemporaryAge:
            return true
        except OSError:
          return true # renamed into place a moment ago: a write as well
  except OSError:
    return true
  false

when not defined(windows):
  proc descriptorPath(fd: cint): string =
    when defined(linux):
      "/proc/self/fd/" & $fd
    else:
      "/dev/fd/" & $fd

  proc inspectSystemTree(fd: cint, shown: string, policy: StorePolicy): string =
    ## Preflight every directory, including interrupted-prune leftovers,
    ## before detaching it. Links are entries to unlink, never to traverse.
    result = checkAccess(fd, shown, policy)
    if result.len > 0:
      return
    try:
      for kind, path in walkDir(descriptorPath(fd), checkDir = true):
        if kind == pcDir:
          let child = openat(
            fd,
            path.lastPathPart.cstring,
            O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW,
          )
          if child < 0:
            return "could not inspect system tree without following links"
          let problem = inspectSystemTree(child, shown / path.lastPathPart, policy)
          discard posix.close(child)
          if problem.len > 0:
            return problem
    except OSError as err:
      return "could not inspect the system tree: " & err.msg

  proc removeSystemTree(fd: cint, policy: StorePolicy): string =
    ## Delete only through held directory descriptors. In particular, an
    ## unlinked symbolic-link entry never becomes a traversal during cleanup.
    result = checkAccess(fd, descriptorPath(fd), policy)
    if result.len > 0:
      return
    try:
      for kind, path in walkDir(descriptorPath(fd), checkDir = true):
        let name = path.lastPathPart
        if kind == pcDir:
          let child =
            openat(fd, name.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW)
          if child < 0:
            return "could not open system cleanup directory"
          let problem = removeSystemTree(child, policy)
          var held, named: Stat
          let same =
            fstat(child, held) == 0 and
            fstatat(fd, name.cstring, named, AT_SYMLINK_NOFOLLOW) == 0 and
            held.st_dev == named.st_dev and held.st_ino == named.st_ino
          discard posix.close(child)
          if problem.len > 0:
            return problem
          if not same:
            return "system cleanup directory changed during deletion"
          if unlinkat(fd, name.cstring, AT_REMOVEDIR) != 0:
            return "could not remove system cleanup directory: " & $strerror(errno)
        elif unlinkat(fd, name.cstring, 0) != 0:
          return "could not unlink a system cleanup entry: " & $strerror(errno)
    except OSError as err:
      return "could not list system cleanup directory: " & err.msg

  proc deleteHeldSystemTree(fd: cint, path: string, policy: StorePolicy): string =
    ## Keep the object selected for deletion across the rename and cleanup.
    var held, named: Stat
    if fstat(fd, held) != 0 or lstat(path.cstring, named) != 0 or
        held.st_dev != named.st_dev or held.st_ino != named.st_ino:
      return "detached system tree changed before cleanup"
    result = removeSystemTree(fd, policy)
    if result.len > 0:
      return
    if lstat(path.cstring, named) != 0 or held.st_dev != named.st_dev or
        held.st_ino != named.st_ino:
      return "detached system tree changed during cleanup"
    if rmdir(path.cstring) != 0:
      return "could not remove detached system tree: " & $strerror(errno)

  proc deleteSystemPath(path: string, policy: StorePolicy): string =
    let fd =
      posix.open(path.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW)
    if fd < 0:
      return "could not open detached system tree"
    defer:
      discard posix.close(fd)
    deleteHeldSystemTree(fd, path, policy)

proc pruneRoot*(
    root: string,
    keep = DefaultKeep,
    protectedIds: openArray[string] = [],
    system = false,
    onStep: PruneStepHook = nil,
    now = getTime(),
): PruneResult =
  ## Prune one root. ``protectedIds`` are content ids whose directories are
  ## never removed. ``now`` is the clock the being-written guards compare
  ## with (a test seam; the default is the real clock).
  if keep < 0:
    result.errors.add "--keep must not be negative"
    return
  if root.len == 0:
    result.errors.add "no store root to prune"
    return
  var anchoredRoot = root
  when defined(windows):
    if system:
      result.errors.add "`prune --system` is not supported on this platform"
      return
    if dirExists(root):
      let problem = checkUserRootOwner(root)
      if problem.len > 0:
        result.errors.add problem
        return
  else:
    var heldFds: seq[cint]
    defer:
      for fd in heldFds:
        discard posix.close(fd)
    var policy: StorePolicy
    if system or dirExists(root):
      let flags =
        O_RDONLY or O_DIRECTORY or O_CLOEXEC or (if system: O_NOFOLLOW else: 0)
      let fd = posix.open(root.cstring, flags)
      if fd < 0:
        result.errors.add "could not open the store root without following a symbolic link: " &
          $strerror(errno)
        return
      heldFds.add fd
      let checked =
        if system:
          systemPolicy(fd, root)
        else:
          (policy: StorePolicy(), problem: checkOwner(fd, root))
      if checked.problem.len > 0:
        result.errors.add checked.problem
        return
      policy = checked.policy
      # Paths through an opened descriptor keep the root anchored if another
      # producer renames it. Each system descendant is opened and checked in
      # turn before it is enumerated or mutated.
      when defined(linux):
        anchoredRoot = "/proc/self/fd/" & $fd
      elif defined(macosx):
        anchoredRoot = "/dev/fd/" & $fd
      else:
        if system:
          result.errors.add "system pruning needs descriptor-anchored paths on this platform"
          return

  var heldLayout = anchoredRoot / LayoutVersion
  when not defined(windows):
    if system:
      let fd = posix.open(
        heldLayout.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW
      )
      if fd < 0:
        if errno == ENOENT:
          result.ok = true
          return
        result.errors.add "could not open layout without following a symbolic link: " &
          $strerror(errno)
        return
      heldFds.add fd
      let problem = checkAccess(fd, root / LayoutVersion, policy)
      if problem.len > 0:
        result.errors.add problem
        return
      heldLayout = anchoredRoot.parentDir / $fd
  var protectedDirs: seq[string]
  for id in protectedIds:
    let parsed = parseContentId(id)
    if parsed.form != cifMalformed:
      protectedDirs.add contentDirRelative(parsed.algorithmName, parsed.digest)
  let layout = heldLayout
  result.ok = true
  if not dirExists(layout):
    return # an empty or missing store: nothing to do
  var dirs: seq[tuple[relative, parent: string, mtime: Time]]
  try:
    for algorithmKind, algorithmPath in walkDir(layout, checkDir = true):
      if system and algorithmKind in {pcLinkToDir, pcLinkToFile}:
        result.ok = false
        result.errors.add "refusing to follow the symbolic link at '" & algorithmPath &
          "'"
        return
      if algorithmKind != pcDir or algorithmPath.extractFilename.startsWith("."):
        continue
      var heldAlgorithm = algorithmPath
      when not defined(windows):
        if system:
          let fd = posix.open(
            algorithmPath.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW
          )
          if fd < 0:
            result.ok = false
            result.errors.add "could not open algorithm without following a symbolic link: " &
              $strerror(errno)
            return
          heldFds.add fd
          let problem = checkAccess(fd, algorithmPath, policy)
          if problem.len > 0:
            result.ok = false
            result.errors.add problem
            return
          heldAlgorithm = anchoredRoot.parentDir / $fd
      for digestKind, digestPath in walkDir(heldAlgorithm, checkDir = true):
        let name = digestPath.extractFilename
        when not defined(windows):
          if system and digestKind == pcDir:
            let fd = posix.open(
              digestPath.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW
            )
            if fd < 0:
              result.ok = false
              result.errors.add "could not inspect system content directory"
              return
            let problem = inspectSystemTree(fd, digestPath, policy)
            discard posix.close(fd)
            if problem.len > 0:
              result.ok = false
              result.errors.add problem
              return
        if name.startsWith("."):
          # Never a content directory; any pruner may delete it.
          if digestKind == pcDir:
            try:
              when not defined(windows):
                if system:
                  let problem = deleteSystemPath(digestPath, policy)
                  if problem.len > 0:
                    raise newException(OSError, problem)
                else:
                  removeDir(digestPath)
              else:
                removeDir(extendedTreePath(digestPath))
              result.leftovers.add root / LayoutVersion / algorithmPath.extractFilename /
                name
            except OSError as err:
              if dirExists(digestPath):
                result.errors.add "'" & digestPath & "' could not be removed: " & err.msg
          continue
        if digestKind != pcDir:
          continue
        try:
          dirs.add (
            LayoutVersion & "/" & algorithmPath.extractFilename & "/" & name,
            heldAlgorithm,
            getLastModificationTime(digestPath),
          )
        except OSError:
          continue # gone already
  except OSError as err:
    result.ok = false
    result.errors.add "the store at '" & layout & "' could not be listed: " & err.msg
    return
  dirs.sort(
    proc(a, b: tuple[relative, parent: string, mtime: Time]): int =
      if a.mtime != b.mtime:
        return (if a.mtime > b.mtime: -1 else: 1)
      -cmp(a.relative, b.relative)
  )
  for i, entry in dirs:
    if i < keep or entry.relative in protectedDirs:
      result.kept.add entry.relative
      continue
    let path = entry.parent / entry.relative.extractFilename
    if beingWritten(path, now, noFollow = system):
      result.busy.add entry.relative
      continue
    if onStep != nil:
      onStep(psChosen, entry.relative)
    when not defined(windows):
      var selectionFd = cint(-1)
      defer:
        if selectionFd >= 0:
          discard posix.close(selectionFd)
      if system:
        # The selection hook stands for concurrent activity. Reopen and check
        # afterwards, then retain that exact object across detach and cleanup.
        selectionFd =
          posix.open(path.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW)
        if selectionFd < 0:
          result.ok = false
          result.errors.add "selected system directory changed before detaching"
          return
        let problem = inspectSystemTree(selectionFd, path, policy)
        if problem.len > 0:
          result.ok = false
          result.errors.add problem
          return
        var held, named: Stat
        if fstat(selectionFd, held) != 0 or lstat(path.cstring, named) != 0 or
            held.st_dev != named.st_dev or held.st_ino != named.st_ino:
          result.ok = false
          result.errors.add "selected system directory changed before detaching"
          return
    let aside = path.parentDir / removalName(path.extractFilename)
    let renamed = renameAside(path, aside)
    if not renamed.ok:
      if dirExists(path):
        result.errors.add "'" & path & "' could not be removed: " & renamed.problem
      continue # else another prune took it
    result.removed.add entry.relative
    if onStep != nil:
      onStep(psDetached, entry.relative)
    try:
      when not defined(windows):
        if system:
          let problem = deleteHeldSystemTree(selectionFd, aside, policy)
          if problem.len > 0:
            raise newException(OSError, problem)
        else:
          removeDir(aside)
      else:
        removeDir(extendedTreePath(aside))
    except OSError as err:
      result.errors.add "'" & aside &
        "' could not be removed (a later prune deletes it): " & err.msg
