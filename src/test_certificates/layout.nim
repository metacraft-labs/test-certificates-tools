## The store layout (Transport §2.2) and the naming conventions the writers,
## readers and pruners share.
##
## ``<root>/v1/<algorithm>/<digest>/<payload-hash>.toml``
##
## * a READER takes only names ending in ``.toml`` that do not begin with ``.``
##   (Transport §2.4);
## * a WRITER's temporary file begins with ``.`` and does not end in ``.toml``
##   (Transport §2.3 step 2), so no reader ever lists it;
## * a PRUNER renames a content directory aside to a ``.``-prefixed name
##   before deleting it (Transport §2.5), and any ``.``-name under
##   ``v1/<algorithm>/`` is a leftover that any pruner may delete.

import std/[os, strutils, times, atomics]

when defined(windows):
  import std/widestrs

const
  LayoutVersion* = "v1"
  RecordSuffix* = ".toml"
  TemporaryMarker* = ".tmp-"
    ## Part of every temporary name, after the leading ``.`` and the final
    ## name: ``.<final>.tmp-<pid>-<n>-<ns>``.
  RemovalMarker* = ".removing-"
    ## Part of the name a content directory is renamed to while a prune
    ## deletes it: ``.<digest>.removing-<pid>-<n>``.

proc isRecordName*(name: string): bool =
  ## A file a reader evaluates.
  name.len > RecordSuffix.len and name.endsWith(RecordSuffix) and
    not name.startsWith(".")

proc contentDirRelative*(algorithm, digest: string): string =
  ## ``v1/<algorithm>/<digest>``, ``/``-separated.
  LayoutVersion & "/" & algorithm & "/" & digest

proc toNative*(relative: string): string =
  ## A ``/``-separated store path in the host's separator.
  relative.replace('/', DirSep)

var nameCounter: Atomic[int]

proc uniqueSuffix*(): string =
  ## Unique across processes (pid) and calls within one (counter), and across
  ## a pid being reused after a crash (the clock).
  let now = getTime()
  $getCurrentProcessId() & "-" & $(nameCounter.fetchAdd(1) + 1) & "-" & $now.toUnix() &
    align($now.nanosecond, 9, '0')

proc temporaryName*(finalName: string): string =
  ## A same-directory temporary name for ``finalName``.
  "." & finalName & TemporaryMarker & uniqueSuffix()

proc removalName*(digest: string): string =
  ## The name a pruner renames ``digest``'s directory to.
  "." & digest & RemovalMarker & uniqueSuffix()

proc isTemporaryName*(name: string): bool =
  name.startsWith(".") and TemporaryMarker in name

const LongPathThreshold = 240
  ## Below MAX_PATH (260) with room for what Windows appends internally.

proc extendedTreePath*(dir: string): string =
  ## ``dir`` in the extended-length form whatever its own length (see
  ## ``extendedPath`` for the forms), for an operation that descends into it:
  ## removing or listing a directory. The paths such an operation builds
  ## beneath ``dir`` are longer than ``dir`` itself, so ``dir`` fitting under
  ## MAX_PATH says nothing about them. A content directory renamed aside for
  ## removal is the case in point: under an ordinary root the directory fits
  ## and the record inside it does not, and ``std/os.removeFile`` reports the
  ## resulting "path not found" as success, so the directory is left non-empty.
  ## A path that is relative, or already extended, is returned unchanged, and
  ## so is every path on POSIX.
  when defined(windows):
    if dir.startsWith(r"\\?\"):
      return dir
    let native = dir.replace('/', '\\')
    if native.len >= 3 and native[1] == ':' and native[2] == '\\':
      return r"\\?\" & normalizedPath(native)
    if native.startsWith(r"\\") and not native.startsWith(r"\\.\"):
      return r"\\?\UNC\" & normalizedPath(native[2 .. ^1])
    dir
  else:
    dir

proc extendedPath*(path: string): string =
  ## ``path`` in a form every file API accepts at any length. On Windows a
  ## record's path is long by construction (``<root>\v1\<algorithm>\`` with a
  ## 64-digit digest, then a 64-digit payload hash and, while it is written,
  ## a temporary suffix) and can pass MAX_PATH (260 characters) under a root
  ## that is not even unusually deep, where the plain Win32 calls fail. An
  ## absolute drive path that long gets the extended-length prefix ``\\?\``
  ## (with ``/`` turned into ``\`` and ``.`` and ``..`` resolved, since that
  ## form passes the path to the file system as it is); a UNC path gets
  ## ``\\?\UNC\``. Anything else, and every path on POSIX, is returned
  ## unchanged.
  ## https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
  when defined(windows):
    if path.len < LongPathThreshold:
      return path
  extendedTreePath(path)

when defined(windows):
  proc createDirectoryW(
    path: WideCString, security: pointer
  ): int32 {.stdcall, dynlib: "kernel32", importc: "CreateDirectoryW".}

  const ErrorAlreadyExists = OSErrorCode(183)

  proc volumeEnd(extended: string): int =
    ## The index just past the volume part of an extended-length path:
    ## ``\\?\C:\`` or ``\\?\UNC\server\share\``. Nothing at or above it is a
    ## directory this tool creates. -1 if ``extended`` has neither form.
    if extended.startsWith(r"\\?\UNC\"):
      # Skip the server and share names, the first two components.
      var seps = 0
      for i in len(r"\\?\UNC\") ..< extended.len:
        if extended[i] == '\\':
          inc seps
          if seps == 2:
            return i + 1
      return extended.len # the share itself: nothing below it to create
    let drive = len(r"\\?\C:\")
    if extended.len >= drive and extended[5] == ':' and extended[6] == '\\':
      return drive
    -1

proc createDirTree*(dir: string) =
  ## Create ``dir`` and its missing ancestors, at any length. On Windows a
  ## content directory is ``<root>\v1\<algorithm>\<digest>``, 84 characters
  ## below the root for SHA-256, and ``CreateDirectoryW`` refuses a plain path
  ## past 248 characters (MAX_PATH less room for an 8.3 name), so a deep user
  ## root could hold no record even though the record paths themselves are
  ## written in the extended-length form. ``std/os.createDir`` walks a path's
  ## components and does not understand the ``\\?\`` prefix, so this walks
  ## them itself, creating each missing one in that form. A path that has no
  ## extended form (a relative one), and every path on POSIX, goes to
  ## ``createDir``. Raises ``OSError`` naming the component that could not be
  ## created; one created concurrently by another writer is not an error.
  ## https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createdirectoryw
  when defined(windows):
    var target = extendedTreePath(dir)
    let floor = volumeEnd(target)
    if floor < 0:
      createDir(dir)
      return
    while target.len > floor and target[^1] == '\\':
      target.setLen(target.len - 1)
    var i = floor
    while i < target.len:
      var stop = target.find('\\', i)
      if stop < 0:
        stop = target.len
      let component = target[0 ..< stop]
      if not dirExists(component):
        if createDirectoryW(newWideCString(component), nil) == 0:
          let code = osLastError()
          if code != ErrorAlreadyExists or not dirExists(component):
            raiseOSError(code, component)
      i = stop + 1
  else:
    createDir(dir)
