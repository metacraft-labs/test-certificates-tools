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
    if path.len < LongPathThreshold or path.startsWith(r"\\?\"):
      return path
    let native = path.replace('/', '\\')
    if native.len >= 3 and native[1] == ':' and native[2] == '\\':
      return r"\\?\" & normalizedPath(native)
    if native.startsWith(r"\\") and not native.startsWith(r"\\.\"):
      return r"\\?\UNC\" & normalizedPath(native[2 .. ^1])
    path
  else:
    path
