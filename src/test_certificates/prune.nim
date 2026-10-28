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
else:
  import std/posix except Time
  import ./posix_at

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

proc beingWritten(dir: string, now: Time): bool =
  ## Whether a producer may be writing into ``dir`` right now. Anything that
  ## cannot be established counts as "yes": removing a directory in use is
  ## worse than keeping one a little longer.
  try:
    if now - getLastModificationTime(dir) < FreshDirectoryAge:
      return true
  except OSError:
    return true
  try:
    for kind, path in walkDir(dir, checkDir = true):
      if isTemporaryName(path.extractFilename):
        try:
          if now - getLastModificationTime(path) < StaleTemporaryAge:
            return true
        except OSError:
          return true # renamed into place a moment ago: a write as well
  except OSError:
    return true
  false

proc checkSystemPartition(root: string): string =
  ## ``prune --system`` is run by the partition's owner (Transport §2.5: a
  ## privileged producer prunes the partitions it writes). Refuse a partition
  ## it does not own, and symbolic links down to ``v1/<algorithm>``, so the
  ## deletion can only ever reach the partition's own tree.
  when defined(windows):
    "`prune --system` is not supported on this platform"
  else:
    var st: Stat
    if lstat(root.cstring, st) != 0:
      return
        "the system partition '" & root & "' cannot be examined: " & $strerror(errno)
    if S_ISLNK(st.st_mode):
      return
        "refusing to follow the symbolic link at the system partition '" & root & "'"
    if not S_ISDIR(st.st_mode):
      return "the system partition '" & root & "' is not a directory"
    if st.st_uid != geteuid():
      return
        "the system partition '" & root & "' is owned by uid " & $st.st_uid &
        ", not by this account (uid " & $geteuid() & "); only its owner prunes it"
    let layout = root / LayoutVersion
    if lstat(layout.cstring, st) == 0 and S_ISLNK(st.st_mode):
      return "refusing to follow the symbolic link at '" & layout & "'"
    if dirExists(layout):
      for kind, path in walkDir(layout):
        if kind == pcLinkToDir or kind == pcLinkToFile:
          return "refusing to follow the symbolic link at '" & path & "'"
    ""

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
  if system:
    let problem = checkSystemPartition(root)
    if problem.len > 0:
      result.errors.add problem
      return
  var protectedDirs: seq[string]
  for id in protectedIds:
    let parsed = parseContentId(id)
    if parsed.form != cifMalformed:
      protectedDirs.add contentDirRelative(parsed.algorithmName, parsed.digest)
  let layout = root / LayoutVersion
  result.ok = true
  if not dirExists(layout):
    return # an empty or missing store: nothing to do
  var dirs: seq[tuple[relative: string, mtime: Time]]
  try:
    for algorithmKind, algorithmPath in walkDir(layout, checkDir = true):
      if algorithmKind != pcDir or algorithmPath.extractFilename.startsWith("."):
        continue
      for digestKind, digestPath in walkDir(algorithmPath, checkDir = true):
        let name = digestPath.extractFilename
        if name.startsWith("."):
          # Never a content directory; any pruner may delete it.
          if digestKind == pcDir:
            try:
              removeDir(digestPath)
              result.leftovers.add digestPath
            except OSError as err:
              if dirExists(digestPath):
                result.errors.add "'" & digestPath & "' could not be removed: " & err.msg
          continue
        if digestKind != pcDir:
          continue
        try:
          dirs.add (
            LayoutVersion & "/" & algorithmPath.extractFilename & "/" & name,
            getLastModificationTime(digestPath),
          )
        except OSError:
          continue # gone already
  except OSError as err:
    result.ok = false
    result.errors.add "the store at '" & layout & "' could not be listed: " & err.msg
    return
  dirs.sort(
    proc(a, b: tuple[relative: string, mtime: Time]): int =
      if a.mtime != b.mtime:
        return (if a.mtime > b.mtime: -1 else: 1)
      -cmp(a.relative, b.relative)
  )
  for i, entry in dirs:
    if i < keep or entry.relative in protectedDirs:
      result.kept.add entry.relative
      continue
    let path = root / toNative(entry.relative)
    if beingWritten(path, now):
      result.busy.add entry.relative
      continue
    if onStep != nil:
      onStep(psChosen, entry.relative)
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
      removeDir(aside)
    except OSError as err:
      result.errors.add "'" & aside &
        "' could not be removed (a later prune deletes it): " & err.msg
