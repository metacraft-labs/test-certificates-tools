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
