## store_path_and_content_id_conformance_vectors, notes_framing_vectors
##
## The specification's ``store/``, ``content/``, ``payload/`` and ``notes/``
## vector groups (Conformance §1, §3, §5), read from the specification repository's object
## store at the commit ``tests/spec-vectors.pin`` names, never from whatever
## revision its checkout happens to be on.
##
## * ``store/``: the path is derived from ``certificate.toml`` through the
##   library (canonical payload rebuilt from the parsed fields, never the
##   file hashed) and compared with ``expected-path.txt``; then ``put`` writes
##   the certificate into a scratch store and the file must be at exactly that
##   path, byte for byte the input.
## * ``content/``: every listed id is computed. ``git-tree-*`` ids go through
##   real git and the library's scoping recipe (Content-Id §4.1), in a
##   repository of the matching object format; ``manifest-v1-sha256`` ids are
##   computed both natively from the entries and through the git route.
## * ``payload/``: ``fields.json`` serialized, and any ``received.toml``
##   parsed and re-serialized, byte-compared with ``canonical.txt``.
## * ``verify/unknown-keys``: every malformed record is refused before naming,
##   including unknown claims in the excluded signature block (Standard §3.4).
## * ``notes/``: ``note.txt`` split per Transport §3.1 and every piece
##   compared with ``expected.json``; for a writer case ``add.txt`` added and
##   the blob byte-compared with ``expected-note.txt`` (notes_framing_vectors).
##
## Negative controls prove the walk is real: the number of cases walked must
## equal ``index.json``'s listing, and a corrupted copy of one expected value
## per group must be reported by the same checker. A pin the repository does
## not contain, and a malformed pin file, must be refused. No mocks.

import std/[base64, json, sequtils, tables, unittest, algorithm]
import ./helpers
import test_certificates

proc caseDirs(vectors, group: string): seq[string] =
  ## Every case of a group, identified by its ``pins.md`` (the directory
  ## contract: every case directory carries one).
  for kind, path in walkDir(vectors / group):
    if kind == pcDir and fileExists(path / "pins.md"):
      result.add path
  result.sort()

proc indexed(vectors, group: string): seq[string] =
  let index = parseJson(readFile(vectors / "index.json"))
  for entry in index["groups"][group]:
    result.add entry["name"].getStr
  result.sort()

# ---------------------------------------------------------------------------
# store/
# ---------------------------------------------------------------------------

proc checkStoreGroup(vectors: string): seq[string] =
  ## Every mismatch, as a sentence; empty when the group passes.
  let store = scratchDir("tcert-store-")
  defer:
    cleanup(store)
  for dir in caseDirs(vectors, "store"):
    let name = dir.extractFilename
    let text = readFile(dir / "certificate.toml")
    let expected = readFile(dir / "expected-path.txt")
    if not expected.endsWith("\n") or expected.count('\n') != 1:
      result.add name & ": expected-path.txt is not one LF-terminated line"
      continue
    let expectedPath = expected[0 ..^ 2]
    let parsed = parseCertificate(text)
    if not parsed.ok:
      result.add name & ": does not parse: " & parsed.problem
      continue
    let payload = canonicalPayload(parsed.certificate)
    if not payload.ok or payload.payload != readFile(dir / "canonical.txt"):
      result.add name & ": the rebuilt canonical payload differs from canonical.txt"
    let derived = storeNameOf(parsed.certificate)
    if not derived.ok or derived.relativePath != expectedPath:
      result.add name & ": derived `" & derived.relativePath & "`, expected `" &
        expectedPath & "`"
      continue
    # Through `put` too: the file lands at that path, byte for byte.
    let root = store / name
    let put = putCertificate(root, text)
    if not put.ok:
      result.add name & ": put failed: " & put.problem
    elif put.path != root / toNative(expectedPath) or readFile(put.path) != text:
      result.add name & ": put wrote `" & put.path & "`, or not the input bytes"

# ---------------------------------------------------------------------------
# content/
# ---------------------------------------------------------------------------

type VectorEntry = object
  path, mode, content: string

proc entriesOf(dir: string): seq[VectorEntry] =
  for e in parseJson(readFile(dir / "entries.json")):
    result.add VectorEntry(
      path: e["path"].getStr,
      mode: e["mode"].getStr,
      content: decode(e["content_b64"].getStr),
    )

proc treeOf(
    entries: seq[VectorEntry], objectFormat: string
): tuple[repo, tree: string] =
  ## Write the entries as objects of a fresh repository, stage them into a
  ## scratch index and write the tree (the re-derivation vectors/README.md
  ## describes). A ``160000`` entry is not an object: its revision is used as
  ## is.
  let repo = newRepo(objectFormat)
  var info = ""
  for e in entries:
    let oid =
      if e.mode == "160000":
        e.content
      else:
        gitIn(repo, ["hash-object", "-w", "--stdin"], input = e.content).strip()
    info.add e.mode & " " & oid & "\t" & e.path & "\0"
  let index = repo / ".git" / "scratch-index"
  let staged =
    git(repo, ["update-index", "-z", "--index-info"], indexFile = index, input = info)
  doAssert staged.ok, staged.failure
  let written = git(repo, ["write-tree"], indexFile = index)
  doAssert written.ok, written.failure
  (repo, singleLine(written.stdout))

proc checkContentGroup(vectors: string): seq[string] =
  for dir in caseDirs(vectors, "content"):
    let name = dir.extractFilename
    let entries = entriesOf(dir)
    var repos = initTable[string, tuple[repo, tree: string]]()
    defer:
      for r in repos.values:
        cleanup(r.repo)
    for expected in parseJson(readFile(dir / "expected.json")):
      let algorithmName = expected["algorithm"].getStr
      var scope: seq[string]
      if expected["paths"].kind == JArray:
        for p in expected["paths"]:
          scope.add p.getStr
      let want = expected["id"].getStr
      let (known, algorithm) = lookupAlgorithm(algorithmName)
      if not known:
        result.add name & ": an algorithm this tool does not implement: " & algorithmName
        continue
      let format = if algorithm == caGitTreeSha256: "sha256" else: "sha1"
      if format notin repos:
        repos[format] = treeOf(entries, format)
      let (repo, tree) = repos[format]
      let computed = computeContentId(repo, commitState(tree), algorithm, scope)
      if computed.outcome != coComputed or computed.id != want:
        result.add name & ": " & algorithmName & " over " & $scope & " via git gave `" &
          computed.id & "` (" & computed.problem & "), expected `" & want & "`"
      if algorithm == caManifestV1Sha256:
        var manifest: seq[ManifestEntry]
        for e in entries:
          if inScope(e.path, scope):
            manifest.add ManifestEntry(
              path: e.path, mode: e.mode, contentSha256: sha256Hex(e.content)
            )
        let native = manifestDigest(manifest)
        if not native.ok or formatContentId(caManifestV1Sha256, native.digest) != want:
          result.add name & ": manifest over " & $scope & " natively gave `" &
            native.digest & "`"

# ---------------------------------------------------------------------------
# payload/
# ---------------------------------------------------------------------------

proc certificateOfFields(fields: JsonNode): Certificate =
  ## ``fields.json`` mirrors the TOML structure exactly (vectors/README.md).
  let c = fields["certificate"]
  proc strings(n: JsonNode): seq[string] =
    for v in n:
      result.add v.getStr

  result.framework = c["framework"].getStr
  result.project = c["project"].getStr
  result.platform = c["platform"].getStr
  result.targets = strings(c["targets"])
  result.result = c["result"].getStr
  result.issuedAt = c["issued_at"].getStr
  result.issuer = c["issuer"].getStr
  if c.hasKey("key_id"):
    result.hasKeyId = true
    result.keyId = c["key_id"].getStr
  let vcs = c["vcs"]
  result.repo = vcs["repo"].getStr
  if vcs.hasKey("paths"):
    result.paths = strings(vcs["paths"])
  result.content = vcs["content"].getStr
  result.untracked = vcs["untracked"].getBool
  if vcs.hasKey("base"):
    result.hasBase = true
    result.base = vcs["base"].getStr
  for command in c["command"]:
    result.commands.add strings(command["argv"])

proc checkPayloadGroup(vectors: string): seq[string] =
  for dir in caseDirs(vectors, "payload"):
    let name = dir.extractFilename
    let want = readFile(dir / "canonical.txt")
    let fromFields =
      canonicalPayload(certificateOfFields(parseJson(readFile(dir / "fields.json"))))
    if not fromFields.ok or fromFields.payload != want:
      result.add name & ": fields.json serialized differently (" & fromFields.problem &
        ")"
    if fileExists(dir / "received.toml"):
      let parsed = parseCertificate(readFile(dir / "received.toml"))
      if not parsed.ok:
        result.add name & ": received.toml does not parse: " & parsed.problem
      elif canonicalPayload(parsed.certificate).payload != want:
        result.add name & ": received.toml re-serialized differently"

# ---------------------------------------------------------------------------
# notes/
# ---------------------------------------------------------------------------

proc checkNotesGroup(vectors: string): seq[string] =
  ## vectors/README.md, "Group 6": split ``note.txt``, compare every piece
  ## with ``expected.json``; for a writer case, add ``add.txt`` and compare
  ## with ``expected-note.txt`` byte for byte. Signatures are not verified:
  ## this package does not verify (Tooling §1), and ``signed`` is compared as
  ## the presence of a signature block.
  for dir in caseDirs(vectors, "notes"):
    let name = dir.extractFilename
    let note = readFile(dir / "note.txt")
    let pieces = splitNote(note)
    if renderNote(pieces) != note:
      result.add name & ": splitting and re-rendering note.txt changed its bytes"
    let expected = parseJson(readFile(dir / "expected.json"))["pieces"]
    if expected.len != pieces.len:
      result.add name & ": " & $pieces.len & " pieces, expected " & $expected.len
      continue
    for i, want in expected.getElems:
      let got = pieces[i]
      if want{"skipped"}.getBool(false):
        if got.kind == pkRecord:
          result.add name & ": piece " & $i & " was read as a record; expected skipped"
        continue
      if got.kind != pkRecord:
        result.add name & ": piece " & $i & " was skipped (" & got.problem &
          "); expected a record"
        continue
      let payload = canonicalPayload(got.certificate)
      if not payload.ok or payload.payload != want["payload"].getStr:
        result.add name & ": piece " & $i & "'s rebuilt payload differs"
      if got.signed != want["signed"].getBool:
        result.add name & ": piece " & $i & " signed=" & $got.signed & ", expected " &
          $want["signed"].getBool
    if fileExists(dir / "add.txt"):
      let add = readFile(dir / "add.txt")
      let record = recordPiece(add)
      if record.kind != pkRecord:
        result.add name & ": add.txt does not parse: " & record.problem
        continue
      # The writer's own rendering of the record is add.txt's form exactly.
      if canonicalRecord(record.certificate).payload != add:
        result.add name & ": canonicalRecord renders add.txt differently"
      var written = pieces
      discard addRecord(written, record)
      if renderNote(written) != readFile(dir / "expected-note.txt"):
        result.add name & ": adding add.txt did not produce expected-note.txt"

# ---------------------------------------------------------------------------

suite "conformance vectors":
  test "store_path_and_content_id_conformance_vectors":
    let vectors = pinnedVectors()
    defer:
      cleanup(vectors.parentDir)
    for group in ["store", "content", "payload"]:
      let walked = caseDirs(vectors, group)
      var names: seq[string]
      for d in walked:
        names.add d.extractFilename
      check names == indexed(vectors, group)
      check names.len > 0
    # Every case Conformance §5 and §3 require is present.
    for required in [
      "unsigned", "signed", "signed-non-canonical", "signed-non-canonical-no-block",
      "manifest-content", "scoped",
    ]:
      check dirExists(vectors / "store" / required)
    for required in [
      "order-independent", "byte-order", "modes", "scope-keeps-paths", "empty-scope",
      "non-ascii-path", "sha256-object-format",
    ]:
      check dirExists(vectors / "content" / required)

    let storeFailures = checkStoreGroup(vectors)
    for f in storeFailures:
      checkpoint f
    check storeFailures.len == 0
    let contentFailures = checkContentGroup(vectors)
    for f in contentFailures:
      checkpoint f
    check contentFailures.len == 0
    let payloadFailures = checkPayloadGroup(vectors)
    for f in payloadFailures:
      checkpoint f
    check payloadFailures.len == 0

  test "closed record schema vectors are all refused before naming":
    let vectors = pinnedVectors()
    defer:
      cleanup(vectors.parentDir)
    let dir = vectors / "verify" / "unknown-keys"
    let expected = parseJson(readFile(dir / "expected.json"))
    check expected["outcome"].getStr == "not-covered"
    var checked: seq[string]
    for rejected in expected["rejected"]:
      let name = rejected["certificate"].getStr
      checkpoint name
      let parsed = parseCertificate(readFile(dir / "certificates" / name))
      check not parsed.ok
      check "not a field" in parsed.problem
      checked.add name
    var present: seq[string]
    for kind, path in walkDir(dir / "certificates"):
      if kind == pcFile:
        present.add path.extractFilename
    checked.sort()
    present.sort()
    check checked == present
    check checked.len == 7

  test "notes_framing_vectors":
    let vectors = pinnedVectors()
    defer:
      cleanup(vectors.parentDir)
    var names: seq[string]
    for d in caseDirs(vectors, "notes"):
      names.add d.extractFilename
    check names == indexed(vectors, "notes")
    let notesFailures = checkNotesGroup(vectors)
    for f in notesFailures:
      checkpoint f
    check notesFailures.len == 0
    for required in [
      "appended", "corrupt-middle", "duplicate-not-added", "escaped-newline",
      "foreign-preamble", "signed-and-unsigned", "signed-replaces-unsigned",
      "single-unsigned", "unsigned-copy-not-added",
    ]:
      check dirExists(vectors / "notes" / required)

  test "negative controls: a corrupted vector is reported by the same checkers":
    let vectors = pinnedVectors()
    defer:
      cleanup(vectors.parentDir)
    # store/: one hex digit of an expected path.
    let pathFile = vectors / "store" / "signed" / "expected-path.txt"
    let original = readFile(pathFile)
    let flipped = original.replace("de22c2c4", "de22c2c5")
    check flipped != original
    writeFile(pathFile, flipped)
    let storeFailures = checkStoreGroup(vectors)
    check storeFailures.len == 1
    check storeFailures.len == 1 and storeFailures[0].startsWith("signed:")
    # content/: one expected id.
    let expectedFile = vectors / "content" / "modes" / "expected.json"
    let ids = readFile(expectedFile)
    writeFile(expectedFile, ids.replace("9f00743e", "9f00743f"))
    let contentFailures = checkContentGroup(vectors)
    check contentFailures.len == 1
    # payload/: one byte of a canonical payload.
    let canonicalFile = vectors / "payload" / "minimal" / "canonical.txt"
    writeFile(canonicalFile, readFile(canonicalFile).replace("passed", "failed"))
    check checkPayloadGroup(vectors).len == 1
    # notes/: a reader expectation (a skipped piece claimed to be a record),
    # and one byte of a writer's expected note.
    let piecesFile = vectors / "notes" / "foreign-preamble" / "expected.json"
    let pieces = parseJson(readFile(piecesFile))
    pieces["pieces"].elems[0] = %*{"payload": "x", "signed": false}
    writeFile(piecesFile, $pieces)
    let expectedNote = vectors / "notes" / "appended" / "expected-note.txt"
    writeFile(
      expectedNote, readFile(expectedNote).replace("t-unit\"]\n", "t-unit\"] \n")
    )
    let notesFailures = checkNotesGroup(vectors)
    for f in notesFailures:
      checkpoint f
    check notesFailures.len == 2
    check notesFailures.anyIt(it.startsWith("foreign-preamble:"))
    check notesFailures.anyIt(it.startsWith("appended:"))

  test "negative controls: the pin is honoured":
    let spec = specCheckout()
    let dest = scratchDir()
    defer:
      cleanup(dest)
    check extractVectorsAt(spec, repeat('0', 40), dest).len > 0
    let badPin = dest / "bad.pin"
    writeFile(badPin, "6e99d02\n")
    check readPin(badPin).problem.len > 0
    writeFile(badPin, repeat('a', 40))
    check readPin(badPin).problem.len > 0 # no trailing newline
    let (pin, problem) = readPin(repoRoot / "tests" / "spec-vectors.pin")
    check problem.len == 0
    check git(spec, ["cat-file", "-e", pin & "^{commit}"]).ok
