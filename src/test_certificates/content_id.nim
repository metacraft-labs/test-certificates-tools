## Content identifiers: their form, and the VCS-independent algorithm.
##
## A content id is ``<algorithm>:<digest>`` (Content-Id §1). This module
## classifies one without ever repairing it, splits it into the two store
## directory components (Transport §2.2), and computes
## ``manifest-v1-sha256`` over an explicit list of entries (Content-Id §4.2).
## Computing an id from a git repository is ``content_state``'s job.
##
## Specification: Content-Id.md of the test-certificates specification,
## https://github.com/metacraft-labs/test-certificates-spec

import std/[algorithm, strutils]
import ./sha256

type
  ContentAlgorithm* = enum
    ## The algorithms Content-Id §4 defines; the string value is the
    ## identifier, compared by exact string equality.
    caGitTreeSha1 = "git-tree-sha1"
    caGitTreeSha256 = "git-tree-sha256"
    caManifestV1Sha256 = "manifest-v1-sha256"

  ContentIdForm* = enum
    cifWellFormed ## A §4 algorithm and a lowercase hex digest of its length.
    cifUnknownAlgorithm
      ## Well-formed, in an algorithm §4 does not define. Not malformed: only
      ## the algorithm defines the digest length (Content-Id §1).
    cifMalformed ## Decidably invalid.

  ContentId* = object
    ## A classified content id. ``text`` is always the input, verbatim.
    form*: ContentIdForm
    text*: string
    algorithmName*: string ## Everything before the first ``:``.
    digest*: string ## Everything after it.
    algorithm*: ContentAlgorithm ## Meaningful only for ``cifWellFormed``.
    problem*: string ## Why it is malformed; "" otherwise.

const
  DigestLength*: array[ContentAlgorithm, int] = [40, 64, 64]
    ## Hex digits of each §4 algorithm's digest.
  EmptyTreeSha1* = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    ## The SHA-1 id of git's empty tree (Content-Id §4.1).

proc lookupAlgorithm*(name: string): (bool, ContentAlgorithm) =
  ## The §4 algorithm ``name`` identifies, by exact string equality.
  for a in ContentAlgorithm:
    if $a == name:
      return (true, a)
  (false, caGitTreeSha1)

proc isLowerHex(s: string): bool =
  if s.len == 0:
    return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true

proc isSafeStoreComponent*(name: string): bool =
  ## Content-Id §1's portable algorithm identifier grammar. The bound and
  ## device exclusions apply before lookup, including on non-Windows hosts.
  if name.len == 0 or name.len > 64:
    return false
  for c in name:
    if c notin {'a' .. 'z', '0' .. '9', '-'}:
      return false
  if name in ["con", "prn", "aux", "nul"]:
    return false
  if name.len == 4 and name[0 .. 2] in ["com", "lpt"] and name[3] in {'1' .. '9'}:
    return false
  true

proc parseContentId*(text: string): ContentId =
  ## Classify ``text`` per Content-Id §1. Never repairs: an uppercase or
  ## abbreviated digest is malformed, not "close enough".
  result.text = text
  let colon = text.find(':')
  if colon < 0:
    result.form = cifMalformed
    result.problem = "it has no `:` separating the algorithm from the digest"
    return
  result.algorithmName = text[0 ..< colon]
  result.digest = text[colon + 1 ..^ 1]
  if result.algorithmName.len == 0:
    result.form = cifMalformed
    result.problem = "nothing precedes the `:`"
    return
  if not isSafeStoreComponent(result.algorithmName):
    result.form = cifMalformed
    result.problem = "the algorithm identifier is not portable"
    return
  if not isLowerHex(result.digest):
    result.form = cifMalformed
    result.problem =
      if result.digest.len == 0:
        "the digest is empty"
      else:
        "the digest is not lowercase hexadecimal"
    return
  let (known, algorithm) = lookupAlgorithm(result.algorithmName)
  if not known:
    result.form = cifUnknownAlgorithm
    return
  if result.digest.len != DigestLength[algorithm]:
    result.form = cifMalformed
    result.problem =
      "a " & $algorithm & " digest has " & $DigestLength[algorithm] &
      " hex digits, this one has " & $result.digest.len
    return
  result.form = cifWellFormed
  result.algorithm = algorithm

proc formatContentId*(algorithm: ContentAlgorithm, digest: string): string =
  $algorithm & ":" & digest

# ---------------------------------------------------------------------------
# manifest-v1-sha256 (Content-Id §4.2)
# ---------------------------------------------------------------------------

type ManifestEntry* = object
  ## One tracked path, with the SHA-256 of its content already taken (so a
  ## caller can stream large files rather than hold them).
  path*: string ## Repo-relative, ``/``-separated, raw bytes.
  mode*: string ## ``100644``, ``100755``, ``120000`` or ``160000``.
  contentSha256*: string ## Lowercase hex SHA-256 of the entry's content.

const ManifestModes* = ["100644", "100755", "120000", "160000"]

proc byteOrder*(a, b: string): int =
  ## Plain unsigned comparison of raw bytes: the order Content-Id §4.2 and
  ## Canonical-Payload §3 require. Spelled out so the contract does not rest
  ## on a library ``cmp``.
  for i in 0 ..< min(a.len, b.len):
    let x = uint8(a[i])
    let y = uint8(b[i])
    if x != y:
      return (if x < y: -1 else: 1)
  cmp(a.len, b.len)

proc inScope*(path: string, scope: openArray[string]): bool =
  ## Whether ``path`` is within ``scope`` (empty: everything). A scope path
  ## names that file or the subtree beneath it, by whole components:
  ## ``src/d`` does not contain ``src/db/a.c``.
  if scope.len == 0:
    return true
  for prefix in scope:
    if path == prefix or
        (path.len > prefix.len and path.startsWith(prefix) and path[prefix.len] == '/'):
      return true
  false

proc manifestDigest*(
    entries: openArray[ManifestEntry]
): tuple[ok: bool, digest, problem: string] =
  ## The ``manifest-v1-sha256`` digest of ``entries`` (already scoped), or why
  ## they cannot have one: an unknown mode, a path that is empty, contains NUL
  ## or is not in normal form, or a duplicate path (Content-Id §3, §4.2).
  var sorted = @entries
  for e in sorted:
    if e.mode notin ManifestModes:
      return (
        false,
        "",
        "entry `" & e.path & "` has mode " & e.mode &
          ", which a manifest has no record for",
      )
    if e.path.len == 0 or '\0' in e.path:
      return (false, "", "a path that is empty or contains NUL cannot be represented")
    if e.path.startsWith("/") or e.path.startsWith("./"):
      return (false, "", "path `" & e.path & "` is not repo-relative")
    if not isLowerHex(e.contentSha256) or e.contentSha256.len != 64:
      return (false, "", "entry `" & e.path & "` carries no SHA-256 of its content")
  sorted.sort(
    proc(a, b: ManifestEntry): int =
      byteOrder(a.path, b.path)
  )
  var ctx = initSha256()
  for i, e in sorted:
    if i > 0 and sorted[i - 1].path == e.path:
      return (false, "", "path `" & e.path & "` appears twice")
    ctx.update(e.mode & " " & e.contentSha256 & " " & e.path & "\0")
  (true, ctx.hexDigest(), "")
