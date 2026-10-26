## notes: Transport §3 and §3.1, Tooling §3 — ``notes publish``, ``import``,
## ``push`` and ``fetch`` against real git repositories, real bare remotes in
## scratch directories, real stores and the built executable.
##
## * notes_publish_keys_by_tree_and_is_idempotent
## * notes_import_round_trips_through_a_fresh_clone
## * concurrent_notes_pushes_keep_every_record — several clones' ``notes
##   push`` PROCESSES race to one bare remote; every record survives.
## * a_note_never_drops_an_unrecognised_framework — another framework's
##   record, a record of a schema this tool cannot read and foreign leading
##   text survive publish and a union merge byte for byte.
## * The deterministic merge path (one push rejected, merged, retried), a
##   framing fault reported without losing the other records, a git trace on
##   stderr that must not read as a framing fault, a SHA-256 repository, the
##   ``testCertificates.notesRef`` setting, a notes tree with fanout, and the
##   union merge of note blobs on its own.
##
## Every command runs with a global git configuration of its own that holds
## only ``user.useConfigOnly = true`` (``GIT_CONFIG_GLOBAL``,
## ``GIT_CONFIG_NOSYSTEM``, ``EMAIL`` cleared), so the developer's own
## settings cannot steer a result and git cannot guess an identity from the
## host name: the tool's fallback committer identity is exercised on every
## host. No mocks.

import std/[osproc, sequtils, sets, streams, strtabs, unittest]
import ./helpers
import test_certificates

const Ref = DefaultNotesRef

type Clone = object
  dir: string ## Working tree.
  store: string ## Its user root.
  env: seq[(string, string)]

proc isolatedEnv(scratch, store: string): seq[(string, string)] =
  let config = scratch / "isolated-gitconfig"
  if not fileExists(config):
    writeFile(config, "[user]\n\tuseConfigOnly = true\n")
  result = storeEnv(store, scratch / "system")
  result.add ("GIT_CONFIG_GLOBAL", config)
  result.add ("GIT_CONFIG_NOSYSTEM", "1")
  result.add ("EMAIL", "") # git takes an address from it before guessing.

proc tc(
    c: Clone, args: openArray[string], extra: openArray[(string, string)] = []
): CliRun =
  runCliProcess(args, c.env & @extra, cwd = c.dir)

proc newBareRemote(scratch: string, objectFormat = "sha1"): string =
  result = scratch / "remote.git"
  createDir(result)
  discard gitIn(result, ["init", "-q", "--bare", "--object-format=" & objectFormat])

proc newClone(scratch, remote, name: string): Clone =
  result.dir = scratch / name
  result.store = scratch / (name & "-store")
  discard gitIn(scratch, ["clone", "-q", remote, result.dir])
  result.env = isolatedEnv(scratch, result.store)

proc treeOf(repo, rev: string): string =
  gitIn(repo, ["rev-parse", rev & "^{tree}"]).strip()

proc noteBlob(repo, annotated: string, notesRef = Ref): string =
  ## The note's exact bytes, or "" when there is none.
  let listed = git(repo, ["notes", "--ref", notesRef, "list", annotated])
  if not listed.ok:
    return ""
  gitIn(repo, ["cat-file", "blob", listed.stdout.strip()])

proc noteKeys(repo: string, notesRef = Ref): HashSet[string] =
  let listed = git(repo, ["notes", "--ref", notesRef, "list"])
  if listed.ok:
    for line in listed.stdout.splitLines():
      let f = line.splitWhitespace()
      if f.len == 2:
        result.incl f[1]

proc writeNote(repo, annotated, bytes: string, notesRef = Ref) =
  ## Attach ``bytes`` verbatim with plain git, as another writer would.
  let blob = gitIn(repo, ["hash-object", "-w", "--stdin"], input = bytes).strip()
  discard gitIn(repo, ["notes", "--ref", notesRef, "add", "-f", "-C", blob, annotated])

proc record(text: string): string =
  ## ``text``'s §3.1 record form.
  let parsed = parseCertificate(text)
  doAssert parsed.ok, parsed.problem
  let r = canonicalRecord(parsed.certificate)
  doAssert r.ok, r.problem
  r.payload

proc framed(records: varargs[string]): string =
  for r in records:
    result.add NoteDelimiter & "\n" & r

proc putIn(c: Clone, text: string) =
  let r = putCertificate(c.store, text)
  doAssert r.ok, r.problem

proc payloadHashes(blob: string): seq[string] =
  for p in splitNote(blob):
    if p.kind == pkRecord:
      result.add p.payloadSha256

proc spawnCli(c: Clone, args: seq[string]): Process =
  var e = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    e[k] = v
  for (k, v) in c.env:
    e[k] = v
  startProcess(
    cliBinary(), workingDir = c.dir, args = args, env = e, options = {poStdErrToStdOut}
  )

suite "notes":
  test "notes_publish_keys_by_tree_and_is_idempotent":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    writeFile(a.dir / "f", "one\n")
    commitAll(a.dir, "one")
    writeFile(a.dir / "f", "two\n")
    commitAll(a.dir, "two")
    writeFile(a.dir / "f", "one\n")
    commitAll(a.dir, "back to one") # Same tree as the first commit.
    let t1 = treeOf(a.dir, "HEAD~2")
    let t2 = treeOf(a.dir, "HEAD~1")
    check treeOf(a.dir, "HEAD") == t1
    let c1 = certificateText("git-tree-sha1:" & t1, targets = @["t-unit"])
    let c1b = certificateText("git-tree-sha1:" & t1, targets = @["t-integration"])
    let c2 = certificateText("git-tree-sha1:" & t2)
    # A non-canonical rendering in the store: the note carries the canonical one.
    let c2Crlf = certificateText("git-tree-sha1:" & t2, targets = @["t-crlf"]).replace(
        "\n", "\r\n"
      )
    for text in [c1, c1b, c2, c2Crlf]:
      putIn(a, text)

    # A range and a single commit; three commits, two trees.
    let first = tc(a, ["notes", "publish", "HEAD~2..HEAD", "HEAD~2"])
    check first.exitCode == 0
    checkpoint first.errors
    # Keyed by TREE, never by commit.
    check noteKeys(a.dir) == toHashSet([t1, t2])
    let note1 = noteBlob(a.dir, t1)
    check note1 == framed(record(c1b), record(c1)) or
      note1 == framed(record(c1), record(c1b))
    check noteBlob(a.dir, t2).payloadHashes.len == 2
    for p in splitNote(noteBlob(a.dir, t2)):
      check p.kind == pkRecord
      check '\r' notin p.raw
    let tip = gitIn(a.dir, ["rev-parse", Ref]).strip()
    # No identity in this isolated configuration: the fallback is used, and
    # said so.
    check "no committer identity" in first.errors
    check gitIn(a.dir, ["log", "-1", "--format=%cn <%ce>", Ref]).strip() ==
      "test-certificates <test-certificates@localhost>"

    # Publishing again adds nothing: the ref does not move.
    let again = tc(a, ["notes", "publish", "HEAD~2..HEAD"])
    check again.exitCode == 0
    check again.output == ""
    check "unchanged" in again.errors
    check gitIn(a.dir, ["rev-parse", Ref]).strip() == tip

    # A signed copy of a present payload replaces it in place; the other
    # record keeps its bytes and position.
    let signed1 =
      certificateText("git-tree-sha1:" & t1, targets = @["t-unit"], signed = true)
    let unsignedTwin = signed1.split("\n[certificate.signature]")[0] & "\n"
    putIn(a, unsignedTwin)
    # With an identity configured, it is the user's, and nothing is remarked.
    discard gitIn(a.dir, ["config", "user.name", "Some One"])
    discard gitIn(a.dir, ["config", "user.email", "some.one@example.org"])
    let withIdentity = tc(a, ["notes", "publish", "HEAD"])
    check withIdentity.exitCode == 0
    check "no committer identity" notin withIdentity.errors
    check gitIn(a.dir, ["log", "-1", "--format=%cn <%ce>", Ref]).strip() ==
      "Some One <some.one@example.org>"
    let before = splitNote(noteBlob(a.dir, t1))
    check before.len == 3
    putIn(a, signed1) # Replaces the unsigned file in the store.
    let replaced = tc(a, ["notes", "publish", "HEAD"])
    check replaced.exitCode == 0
    check "1 replaced" in replaced.errors
    let after = splitNote(noteBlob(a.dir, t1))
    check after.len == 3
    check after[0].raw == before[0].raw
    check after[1].raw == before[1].raw
    check after[2].body == record(signed1)
    check after[2].signed
    # An unsigned copy never replaces the signed one.
    let unchanged = noteBlob(a.dir, t1)
    let store2 = scratch / "store-2"
    var b = a
    b.store = store2
    b.env = isolatedEnv(scratch, store2)
    putIn(b, unsignedTwin)
    check tc(b, ["notes", "publish", "HEAD"]).exitCode == 0
    check noteBlob(a.dir, t1) == unchanged
    # Only the local ref: nothing reached the remote.
    check gitIn(remote, ["for-each-ref", "refs/notes/"]).strip() == ""

  test "notes_import_round_trips_through_a_fresh_clone":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    writeFile(a.dir / "f", "content\n")
    commitAll(a.dir)
    discard gitIn(a.dir, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    let tree = treeOf(a.dir, "HEAD")
    let unsigned = certificateText("git-tree-sha1:" & tree)
    let signed =
      certificateText("git-tree-sha1:" & tree, targets = @["t-signed"], signed = true)
    putIn(a, unsigned)
    putIn(a, signed)
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    let pushed = tc(a, ["notes", "push", "origin"])
    check pushed.exitCode == 0
    checkpoint pushed.errors

    # A fresh clone with an empty store: fetch, import, find.
    let b = newClone(scratch, remote, "b")
    check not dirExists(b.store)
    let fetched = tc(b, ["notes", "fetch", "origin"])
    check fetched.exitCode == 0
    check "created" in fetched.errors
    let imported = tc(b, ["notes", "import"])
    check imported.exitCode == 0
    checkpoint imported.errors
    let paths = imported.output.splitLines().filterIt(it.len > 0)
    check paths.len == 2
    for text in [unsigned, signed]:
      let path = b.store / toNative(relativeOf(text))
      check fileExists(path)
      check readFile(path) == record(text)
    let found = tc(b, ["find", "--commit", "HEAD"])
    check found.exitCode == 0
    check found.output.splitLines().filterIt(it.len > 0).len == 2
    # Importing again keeps the files (the unsigned one is "kept").
    check tc(b, ["notes", "import", "HEAD"]).exitCode == 0

  test "a push that loses the race merges the union and retries":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let seed = newClone(scratch, remote, "seed")
    writeFile(seed.dir / "f", "x\n")
    commitAll(seed.dir)
    discard gitIn(seed.dir, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    let a = newClone(scratch, remote, "a")
    let b = newClone(scratch, remote, "b")
    let tree = treeOf(a.dir, "HEAD")
    let shared = certificateText("git-tree-sha1:" & tree, targets = @["t-shared"])
    let ca = certificateText("git-tree-sha1:" & tree, targets = @["t-a"])
    let cb = certificateText("git-tree-sha1:" & tree, targets = @["t-b"])
    putIn(a, shared)
    putIn(a, ca)
    putIn(b, shared)
    putIn(b, cb)
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    check tc(b, ["notes", "publish", "HEAD"]).exitCode == 0
    check tc(a, ["notes", "push", "origin"]).exitCode == 0
    let racing = tc(b, ["notes", "push", "origin"])
    check racing.exitCode == 0
    checkpoint racing.errors
    check "after 2 attempt(s)" in racing.errors
    check "1 union merge(s)" in racing.errors
    let tip = gitIn(remote, ["rev-parse", Ref]).strip()
    # A real merge commit: both sides are parents.
    check gitIn(remote, ["rev-list", "--parents", "-n", "1", tip]).splitWhitespace().len ==
      3
    let note = noteBlob(remote, tree)
    # The published side is the base: a's records first, b's appended, the
    # shared one once.
    check note == framed(record(shared), record(ca), record(cb)) or
      note == framed(record(ca), record(shared), record(cb))
    check note.payloadHashes.toHashSet.len == 3
    check note.payloadHashes.len == 3
    # a fetches: a fast-forward to the merge.
    let back = tc(a, ["notes", "fetch", "origin"])
    check back.exitCode == 0
    check "fast-forwarded" in back.errors
    check gitIn(a.dir, ["rev-parse", Ref]).strip() == tip

  test "concurrent_notes_pushes_keep_every_record":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let seed = newClone(scratch, remote, "seed")
    writeFile(seed.dir / "f", "x\n")
    commitAll(seed.dir)
    discard gitIn(seed.dir, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    const Clones = 6
    var clones: seq[Clone]
    var expected: seq[string]
    var ownTrees: seq[string]
    let tree = treeOf(seed.dir, "HEAD")
    for i in 0 ..< Clones:
      let c = newClone(scratch, remote, "c" & $i)
      # Each clone: a record on the shared tree, one shared by everybody,
      # and a commit of its own whose tree only it has.
      let mine = certificateText("git-tree-sha1:" & tree, targets = @["t-clone-" & $i])
      putIn(c, mine)
      putIn(c, certificateText("git-tree-sha1:" & tree, targets = @["t-everybody"]))
      writeFile(c.dir / ("own-" & $i), $i)
      commitAll(c.dir)
      let own = treeOf(c.dir, "HEAD")
      ownTrees.add own
      putIn(c, certificateText("git-tree-sha1:" & own, targets = @["t-own"]))
      check tc(c, ["notes", "publish", "HEAD~1..HEAD", "HEAD~1"]).exitCode == 0
      expected.add sha256Hex(record(mine))
      clones.add c
    expected.add sha256Hex(
      record(certificateText("git-tree-sha1:" & tree, targets = @["t-everybody"]))
    )

    var processes: seq[Process]
    for c in clones:
      processes.add spawnCli(c, @["notes", "push", "origin"])
    var outputs: seq[string]
    for p in processes:
      let output = p.outputStream.readAll()
      let code = p.waitForExit()
      p.close()
      outputs.add output
      checkpoint output
      check code == 0

    let note = noteBlob(remote, tree)
    check note.payloadHashes.toHashSet == expected.toHashSet
    check note.payloadHashes.len == expected.len # Each once.
    for p in splitNote(note):
      check p.kind == pkRecord
    check noteKeys(remote) == toHashSet(ownTrees & @[tree])
    # Every clone converges on the remote's value.
    for c in clones:
      check tc(c, ["notes", "fetch", "origin"]).exitCode == 0
      check gitIn(c.dir, ["rev-parse", Ref]).strip() ==
        gitIn(remote, ["rev-parse", Ref]).strip()

  test "a_note_never_drops_an_unrecognised_framework":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let seed = newClone(scratch, remote, "seed")
    writeFile(seed.dir / "f", "x\n")
    commitAll(seed.dir)
    discard gitIn(seed.dir, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    let tree = treeOf(seed.dir, "HEAD")
    let content = "git-tree-sha1:" & tree
    # Another writer's note: foreign leading text, another framework's
    # record, and a record of a schema this tool cannot parse.
    let preamble = "# --- other-tool-certificate ---\nkind = \"theirs\"\n"
    let otherFramework =
      record(certificateText(content).replace("example-framework", "other-framework"))
    let futureSchema =
      "schema = \"test-certificate.v9\"\n\n[certificate]\nnovel = \"field\"\n"
    let foreign = preamble & framed(otherFramework, futureSchema)
    writeNote(seed.dir, tree, foreign)
    check tc(seed, ["notes", "push", "origin"]).exitCode == 0

    # A clone publishes its own record on top: every other piece is kept.
    let a = newClone(scratch, remote, "a")
    check tc(a, ["notes", "fetch", "origin"]).exitCode == 0
    let mine = certificateText(content, targets = @["t-mine"])
    putIn(a, mine)
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    check noteBlob(a.dir, tree) == foreign & framed(record(mine))

    # Meanwhile the seed adds a record of its own; the merge keeps everything.
    let seedRecord = certificateText(content, targets = @["t-seed"])
    putIn(seed, seedRecord)
    check tc(seed, ["notes", "publish", "HEAD"]).exitCode == 0
    check tc(seed, ["notes", "push", "origin"]).exitCode == 0
    let pushed = tc(a, ["notes", "push", "origin"])
    check pushed.exitCode == 0
    checkpoint pushed.errors
    let merged = noteBlob(remote, tree)
    check merged == foreign & framed(record(seedRecord), record(mine))
    let pieces = splitNote(merged)
    check pieces[0].kind == pkLeading
    check pieces[0].raw == preamble
    check pieces[1].raw == NoteDelimiter & "\n" & otherFramework
    check pieces[2].kind == pkUnparsed
    check pieces[2].raw == NoteDelimiter & "\n" & futureSchema

    # Import reports the two pieces it cannot take and stores the rest.
    let b = newClone(scratch, remote, "b")
    check tc(b, ["notes", "fetch", "origin"]).exitCode == 0
    let imported = tc(b, ["notes", "import"])
    check imported.exitCode == 0
    check imported.output.splitLines().filterIt(it.len > 0).len == 3
    check "leading text" in imported.errors
    check "does not parse" in imported.errors

  test "a framing fault is reported and the other records are still imported":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    writeFile(a.dir / "f", "x\n")
    commitAll(a.dir)
    let tree = treeOf(a.dir, "HEAD")
    let good = certificateText("git-tree-sha1:" & tree)
    let misattached = certificateText(
      "git-tree-sha1:1111111111111111111111111111111111111111", targets = @["t-other"]
    )
    # Text before the first delimiter that WOULD parse: never parsed.
    let wouldParse = certificateText("git-tree-sha1:" & tree, targets = @["t-leading"])
    writeNote(
      a.dir,
      tree,
      wouldParse & framed(record(good), "not = [toml\n", record(misattached)),
    )
    let imported = tc(a, ["notes", "import", "HEAD"])
    check imported.exitCode == 0
    checkpoint imported.errors
    check imported.output.strip() == a.store / toNative(relativeOf(good))
    check "leading text" in imported.errors
    check "record 2 does not parse" in imported.errors
    check "misattached" in imported.errors
    check not fileExists(a.store / toNative(relativeOf(wouldParse)))

  test "git's diagnostics on stderr never become note text":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    writeFile(a.dir / "f", "x\n")
    commitAll(a.dir)
    let tree = treeOf(a.dir, "HEAD")
    let good = certificateText("git-tree-sha1:" & tree)
    writeNote(a.dir, tree, framed(record(good)))
    # Positive control: git really does print here, on stderr.
    let traced = runProcess(
      "git",
      [
        "cat-file",
        "blob",
        git(a.dir, ["notes", "--ref", Ref, "list", tree]).stdout.strip(),
      ],
      a.dir,
      [("GIT_TRACE", "1"), ("GIT_TRACE_SETUP", "1")],
    )
    check traced.stderr.len > 0
    let imported =
      tc(a, ["notes", "import"], [("GIT_TRACE", "1"), ("GIT_TRACE_SETUP", "1")])
    check imported.exitCode == 0
    check "leading text" notin imported.errors
    check imported.output.strip() == a.store / toNative(relativeOf(good))
    # And publishing under a trace keeps the note exactly as it was.
    putIn(a, good)
    let published = tc(
      a, ["notes", "publish", "HEAD"], [("GIT_TRACE", "1"), ("GIT_TRACE_SETUP", "1")]
    )
    check published.exitCode == 0
    check noteBlob(a.dir, tree) == framed(record(good))

  test "a sha256 repository keys notes by its 64-digit tree ids":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch, "sha256")
    let a = newClone(scratch, remote, "a")
    check gitIn(a.dir, ["rev-parse", "--show-object-format"]).strip() == "sha256"
    writeFile(a.dir / "f", "x\n")
    commitAll(a.dir)
    discard gitIn(a.dir, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    let tree = treeOf(a.dir, "HEAD")
    check tree.len == 64
    let cert = certificateText("git-tree-sha256:" & tree)
    putIn(a, cert)
    # A certificate in the other algorithm is under another key: not found.
    putIn(a, certificateText("git-tree-sha1:" & tree[0 ..< 40]))
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    check noteKeys(a.dir) == toHashSet([tree])
    check noteBlob(a.dir, tree) == framed(record(cert))
    check tc(a, ["notes", "push", "origin"]).exitCode == 0
    let b = newClone(scratch, remote, "b")
    check tc(b, ["notes", "fetch", "origin"]).exitCode == 0
    let imported = tc(b, ["notes", "import"])
    check imported.exitCode == 0
    check imported.output.strip() == b.store / toNative(relativeOf(cert))

  test "testCertificates.notesRef is honoured and validated":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    writeFile(a.dir / "f", "x\n")
    commitAll(a.dir)
    let tree = treeOf(a.dir, "HEAD")
    putIn(a, certificateText("git-tree-sha1:" & tree))
    let vendor = "refs/notes/vendor/certificates"
    discard gitIn(a.dir, ["config", "testCertificates.notesRef", vendor])
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    check noteKeys(a.dir, vendor) == toHashSet([tree])
    check noteKeys(a.dir).len == 0
    check git(a.dir, ["rev-parse", "--verify", "--quiet", Ref]).ok == false
    check tc(a, ["notes", "push", "origin"]).exitCode == 0
    check gitIn(remote, ["for-each-ref", "--format=%(refname)", "refs/notes/"]).strip() ==
      vendor
    for bad in [
      "refs/heads/certificates", "refs/notes/bad..name", "refs/notes/",
      "refs/notes/test-certificates-work/x", "certificates",
    ]:
      discard gitIn(a.dir, ["config", "testCertificates.notesRef", bad])
      let refused = tc(a, ["notes", "publish", "HEAD"])
      check refused.exitCode == 1
      check "testCertificates.notesRef" in refused.errors
    # No work ref is ever left behind.
    check gitIn(
      a.dir,
      ["for-each-ref", "refs/notes/test-certificates-work/", "refs/test-certificates/"],
    )
      .strip() == ""

  test "a notes tree with fanout is read, written and merged":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    writeFile(a.dir / "f", "x\n")
    commitAll(a.dir)
    discard gitIn(a.dir, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    let b = newClone(scratch, remote, "b")
    let tree = treeOf(a.dir, "HEAD")
    # 300 notes on made-up objects: git switches the notes tree to fanout.
    let filler = framed(record(certificateText("git-tree-sha1:" & repeat('e', 40))))
    let blob = gitIn(a.dir, ["hash-object", "-w", "--stdin"], input = filler).strip()
    var fillerKeys: seq[string]
    for i in 0 ..< 300:
      let key = sha256Hex($i)[0 ..< 40]
      fillerKeys.add key
      discard gitIn(a.dir, ["notes", "--ref", Ref, "add", "-f", "-C", blob, key])
    let top = gitIn(a.dir, ["ls-tree", "--name-only", Ref]).splitLines()
    check top.anyIt(it.len == 2) # Fanout directories.
    let mine = certificateText("git-tree-sha1:" & tree, targets = @["t-a"])
    putIn(a, mine)
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    check noteKeys(a.dir).len == 301
    check noteBlob(a.dir, tree) == framed(record(mine))
    check tc(a, ["notes", "push", "origin"]).exitCode == 0
    # b diverged meanwhile, on the same tree: the merge walks the fanout.
    let theirs = certificateText("git-tree-sha1:" & tree, targets = @["t-b"])
    putIn(b, theirs)
    check tc(b, ["notes", "publish", "HEAD"]).exitCode == 0
    let merged = tc(b, ["notes", "fetch", "origin"])
    check merged.exitCode == 0
    check "merged" in merged.errors
    check noteKeys(b.dir).len == 301
    check noteBlob(b.dir, tree) == framed(record(mine), record(theirs))
    check noteBlob(b.dir, fillerKeys[17]) == filler

  test "push and fetch report what they could not do":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    writeFile(a.dir / "f", "x\n")
    commitAll(a.dir)
    # Nothing local to push; nothing remote to fetch: both fine.
    let nothing = tc(a, ["notes", "push", "origin"])
    check nothing.exitCode == 0
    check "no local notes" in nothing.errors
    let absent = tc(a, ["notes", "fetch", "origin"])
    check absent.exitCode == 0
    check "has no notes ref" in absent.errors
    # A remote that does not exist fails at once, without a prompt.
    putIn(a, certificateText("git-tree-sha1:" & treeOf(a.dir, "HEAD")))
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    let missing = tc(a, ["notes", "push", scratch / "no-such-remote.git"])
    check missing.exitCode == 1
    check "failed" in missing.errors
    check tc(a, ["notes", "fetch", scratch / "no-such-remote.git"]).exitCode == 1
    check tc(a, ["notes", "push"]).exitCode == 2
    check tc(a, ["notes", "publish"]).exitCode == 2
    check tc(a, ["notes", "publish", "--bogus"]).exitCode == 2
    check tc(a, ["notes", "publish", "no-such-revision"]).exitCode == 1

  test "a user's notes push runs the pre-push hook; a hook's own push does not":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    writeFile(a.dir / "f", "x\n")
    commitAll(a.dir)
    putIn(a, certificateText("git-tree-sha1:" & treeOf(a.dir, "HEAD")))
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    let hook = a.dir / ".git" / "hooks" / "pre-push"
    writeFile(hook, "#!/bin/sh\necho 'pre-push gate refused' >&2\nexit 1\n")
    setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})
    let gated = tc(a, ["notes", "push", "origin"])
    check gated.exitCode == 1
    check "pre-push gate refused" in gated.errors
    check git(remote, ["rev-parse", "--verify", "--quiet", Ref]).ok == false
    # The library call a pre-push hook makes skips the hook (Tooling §4).
    var saved: seq[(string, string, bool)]
    for (k, v) in a.env:
      saved.add (k, getEnv(k), existsEnv(k))
      putEnv(k, v)
    defer:
      for (k, v, existed) in saved:
        if existed:
          putEnv(k, v)
        else:
          delEnv(k)
    var options = defaultPushOptions()
    options.runHooks = false
    let pushed = pushNotes(a.dir, "origin", options = options)
    checkpoint pushed.problems.join("\n")
    check pushed.ok
    check pushed.outcome == soPushed
    check gitIn(remote, ["rev-parse", Ref]).strip() ==
      gitIn(a.dir, ["rev-parse", Ref]).strip()

suite "note blobs":
  let base = certificateText("git-tree-sha1:" & repeat('a', 40), targets = @["t-1"])
  let second = certificateText("git-tree-sha1:" & repeat('a', 40), targets = @["t-2"])
  let signedText = certificateText(
    "git-tree-sha1:" & repeat('a', 40), targets = @["t-s"], signed = true
  )
  let unsignedTwin = signedText.split("\n[certificate.signature]")[0] & "\n"

  test "split and render are exact inverses":
    for blob in [
      "",
      framed(record(base)),
      "lead\n" & framed(record(base), "garbage"),
      framed(record(base)) & NoteDelimiter,
      "no delimiter at all",
      framed(record(base)).replace("\n", "\r\n"),
    ]:
      check renderNote(splitNote(blob)) == blob
    # CRLF: no delimiter line, so all of it is leading text.
    let crlf = splitNote(framed(record(base)).replace("\n", "\r\n"))
    check crlf.len == 1 and crlf[0].kind == pkLeading

  test "the union merge is idempotent and keeps both sides":
    let ours = framed(record(base), "junk\n")
    let theirs = "preamble\n" & framed(record(second), record(base))
    let m = mergeNotes(theirs, ours)
    check m.changed
    check m.blob == theirs & framed("junk\n")
    check mergeNotes(m.blob, ours).changed == false
    check mergeNotes(m.blob, theirs).changed == false
    # The other way round holds the same pieces.
    let n = mergeNotes(ours, theirs)
    check n.blob.payloadHashes.toHashSet == m.blob.payloadHashes.toHashSet
    check splitNote(n.blob).len == splitNote(m.blob).len

  test "leading text is joined once and merges converge in any order":
    # The same leading text on both sides: nothing to do.
    let same = "preamble\n" & framed(record(base))
    check mergeNotes(same, "preamble\n" & framed(record(second))).blob ==
      same & framed(record(second))
    # Different leading text: joined once; merging either side, or the
    # joined result, again changes nothing — no growth over repeated cycles.
    let left = "left\n" & framed(record(base))
    let right = "right\n" & framed(record(second))
    let joined = mergeNotes(left, right)
    check joined.blob == "left\nright\n" & framed(record(base), record(second))
    check joined.remarks.len == 1
    for again in [left, right, joined.blob]:
      check mergeNotes(joined.blob, again).changed == false
    # Present means present as whole lines, not as a substring.
    let partial = mergeNotes("leftover\n" & framed(record(base)), "over\n")
    check partial.blob == "leftover\nover\n" & framed(record(base))
    # Three clones' notes merged pairwise in different orders hold the same
    # records, each once, and a further round changes nothing.
    let third = certificateText("git-tree-sha1:" & repeat('a', 40), targets = @["t-3"])
    let sides = [framed(record(base)), framed(record(second)), framed(record(third))]
    let abc = mergeNotes(mergeNotes(sides[0], sides[1]).blob, sides[2]).blob
    let cba = mergeNotes(mergeNotes(sides[2], sides[1]).blob, sides[0]).blob
    check abc.payloadHashes.len == 3
    check abc.payloadHashes.toHashSet == cba.payloadHashes.toHashSet
    check mergeNotes(abc, cba).changed == false
    check mergeNotes(cba, abc).changed == false

  test "a merge lets a signed copy replace an unsigned one, never the reverse":
    let unsignedSide = framed(record(base), record(unsignedTwin))
    let signedSide = framed(record(signedText))
    let up = mergeNotes(unsignedSide, signedSide)
    check up.replaced == 1
    check up.blob == framed(record(base), record(signedText))
    let down = mergeNotes(signedSide, unsignedSide)
    check down.blob == framed(record(signedText), record(base))
    # Two different signatures over one payload: the published one stays.
    let otherSig = record(signedText).replace("c2lnbmF0dXJl", "b3RoZXI=")
    let both = mergeNotes(signedSide, framed(otherSig))
    check both.blob == signedSide
    check both.remarks.len == 1

  test "a note left without its final LF gets one before an append":
    let unterminated = framed(record(base))[0 ..^ 2]
    let m = mergeNotes(unterminated, framed(record(second)))
    check m.blob == framed(record(base), record(second))
    check m.remarks.len == 1
    var pieces = splitNote(unterminated)
    check addRecord(pieces, recordPiece(record(second))) == aoAppended
    check renderNote(pieces) == framed(record(base), record(second))
