## put: Transport §2.3, against the real filesystem and the built executable.
##
## * put_is_atomic_under_concurrent_publishers — many ``test-certificates
##   put`` PROCESSES publish overlapping sets (the same name signed and
##   unsigned, and distinct names) at once, while this process keeps reading
##   the store: no reader ever sees a partial or foreign file, every
##   publisher succeeds, no temporary file is left behind, and the signed
##   copy is what remains under the shared name.
## * system_put_refuses_to_follow_a_planted_symlink — a symbolic link
##   planted at each level below a system partition makes ``put --system``
##   fail without writing through it; a link planted at the final name is
##   replaced, never followed.
## * The replacement rules, ``put -``, owner-only permissions on a created
##   user root, and the records ``put`` refuses.
##
## No mocks.

import std/[osproc, sequtils, sets, streams, strtabs, tables, unittest]
import ./helpers
import test_certificates

when not defined(windows):
  import std/posix except Time

  proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

const ContentX = "git-tree-sha1:1111111111111111111111111111111111111111"

proc spawnPut(files: seq[string], env: seq[(string, string)]): Process =
  var e = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    e[k] = v
  for (k, v) in env:
    e[k] = v
  startProcess(cliBinary(), args = @["put"] & files, env = e, options = {})

proc modeOf(path: string): int =
  when defined(windows):
    0
  else:
    var st: Stat
    doAssert lstat(path.cstring, st) == 0
    int(st.st_mode) and 0o777

suite "put":
  test "put_is_atomic_under_concurrent_publishers":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let root = dir / "store"
    # The inputs: one name published both unsigned and signed, and distinct
    # names; padded so a partial write would be easy to observe.
    var inputs: seq[string]
    var allowed = initTable[string, HashSet[string]]() # file name -> acceptable contents
    # The signed record and the same record without its signature block
    # (key_id kept) share a name (Transport §2.3).
    let signedBase = certificateText(ContentX, signed = true)
    let unsignedX =
      signedBase.split("\n[certificate.signature]")[0] & "\n# " & repeat('u', 20000) &
      "\n"
    let signedX = signedBase & "# " & repeat('s', 20000) & "\n"
    for text in [unsignedX, signedX]:
      inputs.add text
    for i in 0 ..< 8:
      inputs.add certificateText(ContentX, targets = @["t-" & $i]) & "# " &
        repeat(char(ord('a') + i), 30000) & "\n"
    var files: seq[string]
    for i, text in inputs:
      let f = dir / ("input-" & $i & ".toml")
      writeFile(f, text)
      files.add f
      let name = relativeOf(text).extractFilename
      allowed.mgetOrPut(name, initHashSet[string]()).incl text
    check allowed.len == 9 # the signed and unsigned copies share a name

    var processes: seq[Process]
    for p in 0 ..< 16:
      # Each publisher puts every input, in its own rotation, three times over.
      var mine: seq[string]
      for round in 0 ..< 3:
        for k in 0 ..< files.len:
          mine.add files[(k + p + round) mod files.len]
      processes.add spawnPut(mine, storeEnv(root))

    # Read the store while they run.
    let contentDir =
      root / "v1" / "git-tree-sha1" / "1111111111111111111111111111111111111111"
    var reads = 0
    var foreign: seq[string]
    while processes.anyIt(it.running):
      if dirExists(contentDir):
        for kind, path in walkDir(contentDir):
          let name = path.extractFilename
          if not isRecordName(name):
            continue
          var bytes: string
          try:
            bytes = readFile(path)
          except IOError:
            continue # replaced between listing and opening: fine
          inc reads
          if name notin allowed or bytes notin allowed[name]:
            foreign.add name & " (" & $bytes.len & " bytes)"
    for p in processes:
      let code = p.waitForExit()
      if code != 0:
        checkpoint p.errorStream.readAll()
      check code == 0
      p.close()
    check foreign.len == 0
    checkpoint "reads during publication: " & $reads
    check reads > 0

    # Final state: every name holds a complete input; the shared name holds
    # the signed copy; no temporary file survives.
    var names: seq[string]
    for kind, path in walkDir(contentDir):
      let name = path.extractFilename
      check not name.startsWith(".")
      names.add name
      check readFile(path) in allowed[name]
    check names.len == 9
    check readFile(contentDir / relativeOf(signedX).extractFilename) == signedX

  test "a relay waits for a concurrent signer before inspecting an unsigned copy":
    when not defined(windows):
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let vectors = pinnedVectors()
      defer:
        cleanup(vectors.parentDir)
      let good = readFile(vectors / "store" / "signed" / "certificate.toml")
      let unsigned = good.split("\n[certificate.signature]")[0] & "\n"
      let bad = good.replace("value = \"", "value = \"AAAA")
      let first = putCertificate(dir, unsigned)
      check first.ok
      # Act as another conforming signer, holding the same persistent lock
      # and replacing its unsigned copy while the relay is waiting.
      let fd = posix.open((dir / ".write-lock").cstring, O_RDWR or O_CREAT, Mode(0o600))
      require fd >= 0
      require flock(fd, 2) == 0
      defer:
        discard posix.close(fd)
      let input = dir / "incoming"
      writeFile(input, bad)
      let child = spawnPut(@[input], storeEnv(dir))
      defer:
        child.close()
      sleep(100)
      check child.running # The unfixed relay completes without honoring the lock.
      let temporary = dir / "signer-temporary"
      writeFile(temporary, good)
      moveFile(temporary, first.path)
      check flock(fd, 8) == 0 # LOCK_UN
      check child.waitForExit() == 0
      check readFile(first.path) == good

  test "negative control: the same reader catches a writer that is not atomic":
    # Without this, the test above could pass because its reader never
    # managed to look at a file mid-write. A writer that truncates and
    # rewrites in place (what `cat > final` does) must be caught by the same
    # read-and-compare loop.
    when defined(windows):
      skip()
    else:
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let source = dir / "source"
      let target = dir / "target"
      let content = repeat("0123456789abcdef", 1 shl 18) # 4 MiB: several write(2)s
      writeFile(source, content)
      writeFile(target, content)
      let writer = startProcess(
        "/bin/sh",
        args = [
          "-c", "i=0; while [ $i -lt 400 ]; do cat \"$1\" > \"$2\"; i=$((i+1)); done",
          "sh", source, target,
        ],
        options = {},
      )
      var torn = 0
      while writer.running:
        try:
          if readFile(target) != content:
            inc torn
        except IOError:
          discard
      discard writer.waitForExit()
      writer.close()
      checkpoint "torn reads observed: " & $torn
      check torn > 0

  test "a signed copy replaces an unsigned one; an unsigned copy keeps what is there":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let root = dir / "store"
    let unsigned = certificateText(ContentX, signed = false)
    let emptyBlock = certificateText(ContentX, emptyBlock = true)
    let signed = certificateText(ContentX, signed = true)
    # `unsigned` and `emptyBlock` share a name (Canonical-Payload §6);
    # `signed` carries key_id, so its payload and name differ.
    check relativeOf(unsigned) == relativeOf(emptyBlock)
    check relativeOf(unsigned) != relativeOf(signed)
    var r = putCertificate(root, unsigned)
    check r.ok and not r.kept
    r = putCertificate(root, emptyBlock)
    check r.ok and r.kept
    check readFile(r.path) == unsigned
    # The same claim, signed: here the signed record without its block, and
    # the signed record itself, which must replace it.
    let noBlock = signed.split("\n[certificate.signature]")[0] & "\n"
    check relativeOf(noBlock) == relativeOf(signed)
    r = putCertificate(root, noBlock)
    check r.ok and not r.kept
    r = putCertificate(root, signed)
    check r.ok and not r.kept and r.signed
    check readFile(r.path) == signed
    r = putCertificate(root, noBlock)
    check r.ok and r.kept
    check readFile(r.path) == signed

  test "a relay preserves an existing signed copy when a different signature arrives":
    let dir = scratchDir()
    let vectors = pinnedVectors()
    defer:
      cleanup(dir)
      cleanup(vectors.parentDir)
    let good = readFile(vectors / "store" / "signed" / "certificate.toml")
    # Keep every signed payload byte, changing only the excluded signature.
    let bad = good.replace("value = \"", "value = \"AAAA")
    check bad != good
    check relativeOf(good) == relativeOf(bad)
    let first = runCliProcess(["put", "-"], storeEnv(dir), input = good)
    check first.exitCode == 0
    let second = runCliProcess(["put", "-"], storeEnv(dir), input = bad)
    check second.exitCode == 0
    check readFile(first.output.strip()) == good
    let kept = putCertificate(dir, bad)
    check kept.ok and kept.kept
    check readFile(kept.path) == good

  test "a relay reports malformed and misnamed stored records without replacing them":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let text = certificateText(ContentX, signed = true)
    let path = dir / toNative(relativeOf(text))
    createDir(path.parentDir)
    for old in ["malformed", certificateText(ContentX, targets = @["other"])]:
      writeFile(path, old)
      let put = putCertificate(dir, text)
      check not put.ok
      check put.problem.len > 0
      check readFile(path) == old

  test "put - reads a certificate from standard input; owner-only on a created user root":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let root = dir / "deep" / "store"
    let text = certificateText(ContentX)
    let run = runCliProcess(["put", "-"], storeEnv(root), input = text)
    check run.exitCode == 0
    check run.output == root / toNative(relativeOf(text)) & "\n"
    check readFile(run.output.strip()) == text
    when not defined(windows):
      check modeOf(root) == 0o700
      check modeOf(root / "v1") == 0o700
      check modeOf(run.output.strip()) == 0o600

  test "records that cannot be named are refused, and nothing is written":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let root = dir / "store"
    let good = certificateText(ContentX)
    for (label, text) in [
      ("malformed content", good.replace(ContentX, "git-tree-sha1:ABC")),
      ("no content", good.replace("content = \"" & ContentX & "\"\n", "")),
      (
        "earlier draft",
        good.replace(
          "content = \"" & ContentX & "\"\n", "commit = \"abc\"\nclean = true\n"
        ),
      ),
      ("unknown schema", good.replace("test-certificate.v1", "test-certificate.v2")),
      ("no targets", good.replace("targets = [\"t-unit\"]", "targets = []")),
      ("not TOML", "schema = \n"),
      (
        "half a signature",
        good & "\n[certificate.signature]\nalgorithm = \"ed25519\"\nvalue = \"\"\n",
      ),
      ("a path-like algorithm", good.replace(ContentX, "../x:" & repeat('a', 40))),
      # Names Windows would not store as spelled: a device, a trailing dot.
      ("a device-name algorithm", good.replace(ContentX, "Nul.x:" & repeat('a', 40))),
      ("a trailing-dot algorithm", good.replace(ContentX, "algo.:" & repeat('a', 40))),
    ]:
      let r = putCertificate(root, text)
      checkpoint label & ": " & r.problem
      check not r.ok
      check r.problem.len > 0
    check not dirExists(root / "v1")
    # Through the executable: one bad file among good ones fails the run,
    # and the good ones are still written.
    writeFile(dir / "good.toml", good)
    writeFile(dir / "bad.toml", "nonsense")
    let run =
      runCliProcess(["put", dir / "good.toml", dir / "bad.toml"], storeEnv(root))
    check run.exitCode == 1
    check run.output.strip() == root / toNative(relativeOf(good))
    check "bad.toml" in run.errors

  test "system_put_refuses_to_follow_a_planted_symlink":
    when defined(windows):
      # Windows: --system is refused outright, never attempted.
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let run = runCliProcess(
        ["put", "--system", myAccount(), "-"],
        storeEnv(dir / "u", dir / "s"),
        input = certificateText(ContentX),
      )
      check run.exitCode == 1
      check "not supported" in run.errors
    else:
      let account = myAccount()
      let text = certificateText(ContentX)
      let relative = relativeOf(text)
      let parts = relative.split('/') # v1, algorithm, digest, file
      proc freshPartition(dir: string): string =
        result = dir / "system" / account
        createDir(result)
        setFilePermissions(
          result, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec}
        )

      # Success first: the partition's permission bits carry down.
      block:
        let dir = scratchDir()
        defer:
          cleanup(dir)
        let partition = freshPartition(dir)
        let run = runCliProcess(
          ["put", "--system", account, "-"],
          storeEnv(dir / "user", dir / "system"),
          input = text,
        )
        check run.exitCode == 0
        check run.output.strip() == partition / relative
        check modeOf(partition / "v1") == 0o750
        check modeOf(partition / relative) == 0o640
        check not dirExists(dir / "user") # the user root is not touched

      # The same under a restrictive umask: what is created still takes the
      # partition's bits, or the user could not read their own partition.
      block:
        let dir = scratchDir()
        defer:
          cleanup(dir)
        let partition = freshPartition(dir)
        let run = runProcess(
          "sh",
          ["-c", "umask 077; exec \"$0\" put --system \"$1\" -", cliBinary(), account],
          getCurrentDir(),
          storeEnv(dir / "user", dir / "system"),
          text,
        )
        checkpoint run.stderr
        check run.exitCode == 0
        check modeOf(partition / "v1") == 0o750
        check modeOf(partition / parts[0] / parts[1] / parts[2]) == 0o750
        check modeOf(partition / relative) == 0o640

      # A link planted in place of each directory below the partition.
      for depth in 1 .. 3:
        let dir = scratchDir()
        defer:
          cleanup(dir)
        let partition = freshPartition(dir)
        let elsewhere = dir / "elsewhere"
        createDir(elsewhere)
        var parent = partition
        for k in 0 ..< depth - 1:
          parent = parent / parts[k]
          createDir(parent)
        createSymlink(elsewhere, parent / parts[depth - 1])
        let run = runCliProcess(
          ["put", "--system", account, "-"],
          storeEnv(dir / "user", dir / "system"),
          input = text,
        )
        checkpoint "depth " & $depth & ": " & run.errors
        check run.exitCode == 1
        check "symbolic link" in run.errors
        check toSeq(walkDirRec(elsewhere)).len == 0

      # A link at the final name cannot be inspected safely and is preserved.
      for signed in [false, true]:
        let dir = scratchDir()
        defer:
          cleanup(dir)
        let partition = freshPartition(dir)
        let victim = dir / "victim.txt"
        writeFile(victim, "victim")
        let doc = certificateText(ContentX, signed = signed)
        let path = partition / relativeOf(doc)
        createDir(path.parentDir)
        createSymlink(victim, path)
        let run = runCliProcess(
          ["put", "--system", account, "-"],
          storeEnv(dir / "user", dir / "system"),
          input = doc,
        )
        check run.exitCode == 1
        check "not a regular file" in run.errors
        check readFile(victim) == "victim"
        check symlinkExists(path)

      # The partition itself as a link, and a missing partition.
      block:
        let dir = scratchDir()
        defer:
          cleanup(dir)
        createDir(dir / "system")
        createDir(dir / "elsewhere")
        createSymlink(dir / "elsewhere", dir / "system" / account)
        var run = runCliProcess(
          ["put", "--system", account, "-"],
          storeEnv(dir / "user", dir / "system"),
          input = text,
        )
        check run.exitCode == 1
        check "symbolic link" in run.errors
        check toSeq(walkDirRec(dir / "elsewhere")).len == 0
        run = runCliProcess(
          ["put", "--system", "4242424", "-"],
          storeEnv(dir / "user", dir / "system"),
          input = text,
        )
        check run.exitCode == 1
        check "does not exist" in run.errors
        run = runCliProcess(
          ["put", "--system", "../x", "-"],
          storeEnv(dir / "user", dir / "system"),
          input = text,
        )
        check run.exitCode == 1
        check "numeric uid" in run.errors
