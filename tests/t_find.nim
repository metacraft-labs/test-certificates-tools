## find: Transport §2.4 and §5, Content-Id §4.1 and §5, Tooling §2 — against
## real git repositories, a real store and the built executable.
##
## * find_unions_user_and_system_roots
## * find_staged_and_worktree_compute_the_content_id_without_touching_the_index
## * find_reports_none_found_apart_from_uncomputable
## * find_distinguishes_completed_empty_searches_and_unresolved_roots
## * find_distinguishes_unreadable_roots_from_empty_searches
##
## Permission cases remove read access on each root and its content directory,
## restore it before asserting, and require a non-root POSIX user. Both root
## orders run against the real built binary; neither root may hide the other.
##
## Expected content ids are derived independently of the code under test
## wherever that is possible: with ordinary porcelain in a COPY of the
## repository (``git add -u``, ``git rm --cached``, ``git write-tree``), or in
## a fresh repository holding only the in-scope files. No mocks.

import std/[algorithm, sequtils, unittest]
import ./helpers
import test_certificates

when not defined(windows):
  import std/posix except Time

proc putAt(root, text: string): string =
  let r = putCertificate(root, text)
  doAssert r.ok, r.problem
  r.path

proc treeOfFreshRepo(files: openArray[(string, string)]): string =
  ## The tree id of a fresh repository holding exactly ``files``.
  let repo = newRepo()
  defer:
    cleanup(repo)
  for (path, content) in files:
    createDir((repo / path).parentDir)
    writeFile(repo / path, content)
  discard gitIn(repo, ["add", "-A"])
  gitIn(repo, ["write-tree"]).strip()

proc copyRepo(repo: string): string =
  ## A full copy (working tree and .git) for independent derivations.
  result = scratchDir("tcert-copy-")
  removeDir(result)
  copyDirWithPermissions(repo, result)

suite "find":
  test "find_unions_user_and_system_roots":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let account = myAccount()
    let user = dir / "user"
    let partition = dir / "system" / account
    createDir(partition)
    let content = "git-tree-sha1:2222222222222222222222222222222222222222"
    let signed = certificateText(content, signed = true)
    let noBlock = signed.split("\n[certificate.signature]")[0] & "\n"
    let both = certificateText(content, targets = @["t-both"])
    let systemOnly = certificateText(content, targets = @["t-system"])
    # The same name in both roots, differing copies: the user root holds the
    # record without its signature, the system root the signed one.
    let userNoBlock = putAt(user, noBlock)
    let systemSigned = putAt(partition, signed)
    check userNoBlock.extractFilename == systemSigned.extractFilename
    # The same name in both roots, byte-identical: one candidate.
    let userBoth = putAt(user, both)
    let systemBoth = putAt(partition, both)
    let systemOnlyPath = putAt(partition, systemOnly)
    let contentDir = userBoth.parentDir
    # A record whose own content is not its directory's: reported, ignored.
    let other =
      certificateText("git-tree-sha1:3333333333333333333333333333333333333333")
    writeFile(contentDir / (repeat('e', 64) & ".toml"), other)
    # A file that does not parse: still a candidate, with a note.
    let garbled = contentDir / (repeat('f', 64) & ".toml")
    writeFile(garbled, "not a certificate")
    # Never records: a temporary name and a non-.toml file.
    writeFile(contentDir / ".x.toml.tmp-1", both)
    writeFile(contentDir / "README", both)

    var run =
      runCliProcess(["find", "--content", content], storeEnv(user, dir / "system"))
    check run.exitCode == 0
    var listed = run.output.strip().splitLines()
    listed.sort()
    var expected = @[userNoBlock, systemSigned, userBoth, systemOnlyPath, garbled]
    expected.sort()
    check listed == expected
    check systemBoth notin listed
    check ("searched user root " & user & ": " & contentDir & " [listed]") in run.errors
    check ("searched system root " & partition & ": ") in run.errors
    check ("skipped " & systemBoth & ": byte-identical") in run.errors
    check "is not the id of the directory" in run.errors
    check "does not parse as a certificate" in run.errors

    # The library reports the same, with the signedness of each copy.
    let report = findById(
      resolveRoots(
        hostPlatform(),
        proc(n: string): string =
          (
            if n == "TEST_CERTIFICATES_DIR": user
            elif n == "TEST_CERTIFICATES_SYSTEM_DIR": dir / "system"
            else: ""
          ),
        account,
      ),
      content,
    )
    check report.candidates.len == 5
    check report.candidates.filterIt(it.path == systemSigned)[0].signed
    check not report.candidates.filterIt(it.path == userNoBlock)[0].signed

    # An unreadable system root is reported, and the user root still searched.
    when not defined(windows):
      if geteuid() == 0:
        fatal "this test must not run as root: root reads a mode-000 directory"
      setFilePermissions(partition, {})
      run =
        runCliProcess(["find", "--content", content], storeEnv(user, dir / "system"))
      setFilePermissions(partition, {fpUserRead, fpUserWrite, fpUserExec})
      check run.exitCode == 0
      check "[unreadable]" in run.errors
      listed = run.output.strip().splitLines()
      listed.sort()
      expected = @[userNoBlock, userBoth, garbled]
      expected.sort()
      check listed == expected
      # Unreadable below the root: the intermediate directory, not "absent".
      setFilePermissions(partition / "v1", {})
      run =
        runCliProcess(["find", "--content", content], storeEnv(user, dir / "system"))
      setFilePermissions(partition / "v1", {fpUserRead, fpUserWrite, fpUserExec})
      check run.exitCode == 0
      check "[unreadable]" in run.errors
      check "[absent]" notin run.errors

  test "find_staged_and_worktree_compute_the_content_id_without_touching_the_index":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let store = dir / "store"
    let repo = newRepo()
    defer:
      cleanup(repo)
    for (path, content) in [
      ("a.txt", "a\n"),
      ("src/b.txt", "b\n"),
      ("d.txt", "d\n"),
      ("lit*/x", "star\n"),
      ("litA/x", "plain\n"),
      ("other/y", "y\n"),
    ]:
      createDir((repo / path).parentDir)
      writeFile(repo / path, content)
    commitAll(repo, "base")
    # Staged: a modified file and a new file. Unstaged: a modification and a
    # deletion. Untracked: a file that must not count.
    writeFile(repo / "a.txt", "a staged\n")
    writeFile(repo / "c.txt", "new\n")
    discard gitIn(repo, ["add", "a.txt", "c.txt"])
    writeFile(repo / "src/b.txt", "b unstaged\n")
    removeFile(repo / "d.txt")
    writeFile(repo / "untracked.txt", "u\n")

    let indexPath = repo / ".git" / "index"
    let indexBytes = readFile(indexPath)
    let indexMtime = getLastModificationTime(indexPath)

    # Independent derivations, in copies of the repository.
    let stagedCopy = copyRepo(repo)
    defer:
      cleanup(stagedCopy)
    let stagedTree = gitIn(stagedCopy, ["write-tree"]).strip()
    let worktreeCopy = copyRepo(repo)
    defer:
      cleanup(worktreeCopy)
    discard gitIn(worktreeCopy, ["add", "-u"])
    let worktreeTree = gitIn(worktreeCopy, ["write-tree"]).strip()
    discard gitIn(worktreeCopy, ["rm", "-r", "-q", "--cached", "--", ".", ":!src"])
    let scopedTree = gitIn(worktreeCopy, ["write-tree"]).strip()
    let headTreeId = gitIn(repo, ["rev-parse", "HEAD^{tree}"]).strip()
    check stagedTree != worktreeTree
    check worktreeTree != headTreeId

    let stagedCert = putAt(
      store, certificateText("git-tree-sha1:" & stagedTree, targets = @["staged"])
    )
    let worktreeCert = putAt(
      store, certificateText("git-tree-sha1:" & worktreeTree, targets = @["worktree"])
    )
    let scopedCert = putAt(
      store, certificateText("git-tree-sha1:" & scopedTree, targets = @["scoped"])
    )
    let headCert =
      putAt(store, certificateText("git-tree-sha1:" & headTreeId, targets = @["head"]))
    let env = storeEnv(store, dir / "nosystem")

    var run = runCliProcess(["find", "--staged"], env, cwd = repo)
    check run.exitCode == 0
    check run.output == stagedCert & "\n"
    run = runCliProcess(["find", "--worktree"], env, cwd = repo / "src")
      # from a subdirectory
    check run.exitCode == 0
    check run.output == worktreeCert & "\n"
    check (
      "content id: git-tree-sha1:" & worktreeTree & " (computed from the working tree)"
    ) in run.errors
    run = runCliProcess(["find", "--worktree", "--paths", "src"], env, cwd = repo)
    check run.exitCode == 0
    check run.output == scopedCert & "\n"
    run = runCliProcess(["find", "--commit", "HEAD"], env, cwd = repo)
    check run.exitCode == 0
    check run.output == headCert & "\n"

    # Literal pathspecs: `lit*` names that directory, not a pattern matching
    # `litA` too; and the scoped id keeps full paths.
    let literal = computeContentId(repo, worktreeState(), caGitTreeSha1, ["lit*"])
    check literal.outcome == coComputed
    check literal.id == "git-tree-sha1:" & treeOfFreshRepo([("lit*/x", "star\n")])
    check literal.id != "git-tree-sha1:" & treeOfFreshRepo([("x", "star\n")])

    # The user's index was neither modified nor rewritten.
    check readFile(indexPath) == indexBytes
    check getLastModificationTime(indexPath) == indexMtime
    check not fileExists(indexPath & ".lock")
    # ... and staging still holds exactly what it held.
    check gitIn(repo, ["diff", "--cached", "--name-only"]).strip().splitLines() ==
      @["a.txt", "c.txt"]

  test "the working-tree id reads content, not stat data (racy git)":
    when defined(windows):
      skip()
    else:
      let repo = newRepo()
      defer:
        cleanup(repo)
      # Stat data git cannot distinguish: same size, same mtime, same inode;
      # ctime is not compared under these settings.
      discard gitIn(repo, ["config", "core.trustctime", "false"])
      discard gitIn(repo, ["config", "core.checkStat", "minimal"])
      let f = repo / "f.txt"
      writeFile(f, "aaaa\n")
      setLastModificationTime(f, fromUnix(1_700_000_000))
      discard gitIn(repo, ["add", "f.txt"])
      writeFile(f, "bbbb\n")
      setLastModificationTime(f, fromUnix(1_700_000_000))
      let truth = "git-tree-sha1:" & treeOfFreshRepo([("f.txt", "bbbb\n")])
      let stale = "git-tree-sha1:" & treeOfFreshRepo([("f.txt", "aaaa\n")])
      let computed = computeContentId(repo, worktreeState(), caGitTreeSha1)
      check computed.outcome == coComputed
      check computed.id == truth
      # Negative control: the same recipe WITHOUT dating the copy reads the
      # stat data and names the stale content, so the check above is a real one.
      let scratch = scratchDir()
      defer:
        cleanup(scratch)
      copyFile(repo / ".git" / "index", scratch / "index")
      check git(repo, ["add", "--update"], indexFile = scratch / "index").ok
      let naive = git(repo, ["write-tree"], indexFile = scratch / "index")
      check "git-tree-sha1:" & singleLine(naive.stdout) == stale

  test "find_reports_none_found_apart_from_uncomputable":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let store = dir / "store"
    let env = storeEnv(store, dir / "system")
    let content = "git-tree-sha1:4444444444444444444444444444444444444444"

    # None found: exit 1, and the report names both roots and directories.
    var run = runCliProcess(["find", "--content", content], env)
    check run.exitCode == 1
    check run.output == ""
    check (
      "searched user root " & store & ": " &
      store / "v1" / "git-tree-sha1" / "4444444444444444444444444444444444444444" &
      " [absent]"
    ) in run.errors
    check ("searched system root " & dir / "system" / myAccount()) in run.errors
    check "no certificates found" in run.errors
    # An algorithm outside Content-Id §4 is well-formed: a keyed lookup that
    # finds nothing, not an error.
    run = runCliProcess(["find", "--content", "blake3-tree:abcd"], env)
    check run.exitCode == 1
    # Found: exit 0.
    discard putAt(store, certificateText(content))
    run = runCliProcess(["find", "--content", content], env)
    check run.exitCode == 0

    # Uncomputable: exit 2, and nothing looked up.
    for args in [
      @["--content", "git-tree-sha1:ABC"],
      @["--content", "nocolon"],
      @["--content", "git-tree-sha1:" & repeat('a', 39)],
    ]:
      run = runCliProcess(@["find"] & args, env)
      checkpoint args.join(" ") & ": " & run.errors
      check run.exitCode == 2
      check "malformed" in run.errors
      check "searched" notin run.errors
    run = runCliProcess(["find", "--worktree"], env, cwd = dir) # not a repository
    check run.exitCode == 2
    check "not inside a git working tree" in run.errors

    let repo = newRepo()
    defer:
      cleanup(repo)
    run = runCliProcess(["find", "--commit", "HEAD"], env, cwd = repo) # unborn
    check run.exitCode == 2
    writeFile(repo / "f", "f\n")
    writeFile(repo / "g", "g\n")
    commitAll(repo)
    run = runCliProcess(["find", "--commit", "no-such-revision"], env, cwd = repo)
    check run.exitCode == 2
    run = runCliProcess(["find", "--commit", "--all"], env, cwd = repo)
    check run.exitCode == 64
    run = runCliProcess(
      ["find", "--worktree", "--algorithm", "git-tree-sha256"], env, cwd = repo
    )
    check run.exitCode == 2
    check "cannot be computed in this repository" in run.errors
    run = runCliProcess(["find", "--worktree", "--algorithm", "md5"], env, cwd = repo)
    check run.exitCode == 2
    run =
      runCliProcess(["find", "--worktree", "--paths", "../outside"], env, cwd = repo)
    check run.exitCode == 2
    # A manifest id is computable here, and simply not found.
    run = runCliProcess(
      ["find", "--worktree", "--algorithm", "manifest-v1-sha256"], env, cwd = repo
    )
    check run.exitCode == 1
    check "content id: manifest-v1-sha256:" in run.errors

    # States with no content id (Content-Id §3) are refused, naming the path.
    discard gitIn(repo, ["update-index", "--assume-unchanged", "f"])
    run = runCliProcess(["find", "--worktree"], env, cwd = repo)
    check run.exitCode == 2
    check "assume-unchanged: f" in run.errors
    discard gitIn(repo, ["update-index", "--no-assume-unchanged", "f"])
    discard gitIn(repo, ["update-index", "--skip-worktree", "g"])
    run = runCliProcess(["find", "--worktree"], env, cwd = repo)
    check run.exitCode == 2
    check "skip-worktree while their file is present: g" in run.errors
    # Scoped away from the flagged path, the state has an id.
    run = runCliProcess(["find", "--worktree", "--paths", "f"], env, cwd = repo)
    check run.exitCode == 1
    discard gitIn(repo, ["update-index", "--no-skip-worktree", "g"])
    # An unmerged index refuses both the staged and the working-tree state.
    discard gitIn(repo, ["checkout", "-q", "-b", "side"])
    writeFile(repo / "f", "side\n")
    commitAll(repo, "side")
    discard gitIn(repo, ["checkout", "-q", "main"])
    writeFile(repo / "f", "main\n")
    commitAll(repo, "main")
    discard runProcess(
      "git",
      ["-c", "user.name=T", "-c", "user.email=t@example.invalid", "merge", "-q", "side"],
      repo,
    )
    for state in ["--staged", "--worktree"]:
      run = runCliProcess(["find", state], env, cwd = repo)
      check run.exitCode == 2
      check "unmerged entries: f" in run.errors

    # Usage errors have their own status and precede content-id computation.
    for args in [
      newSeq[string](),
      @["--staged", "--worktree"],
      @["--content", content, "--paths", "x"],
      @["--bogus"],
      @["--content"],
      @["--commit"],
      @["--worktree", "--algorithm"],
      @["--worktree", "--paths"],
      @["--content", content, "--paths"],
      @["--content", content, "--algorithm", "md5"],
      @["--content", "nocolon", "--bogus"],
      @["--worktree", "--algorithm", "md5", "--bogus"],
    ]:
      run = runCliProcess(@["find"] & args, env, cwd = repo)
      check run.exitCode == 64
      check run.output == ""
      check "for usage" in run.errors
      check "searched" notin run.errors
      check "content id:" notin run.errors

  test "find_distinguishes_completed_empty_searches_and_unresolved_roots":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let user = dir / "user"
    let partition = dir / "system" / myAccount()
    let env = storeEnv(user, dir / "system")
    let content = "git-tree-sha1:" & repeat('5', 40)
    # Absent roots, empty roots, and empty content directories are all a
    # complete empty lookup. None is an unreadable store.
    for root in [user, partition]:
      let run = runCliProcess(["find", "--content", content], env)
      check run.exitCode == 1
      createDir(root)
    for root in [user, partition]:
      createDir(root / "v1" / "git-tree-sha1" / repeat('5', 40))
    var run = runCliProcess(["find", "--content", content], env)
    check run.exitCode == 1
    check run.errors.count("[listed]") == 2
    # An unresolved root makes discovery incomplete on every platform.
    check $findById(StoreRoots(user: user), content).outcome == "foIncomplete"

  when not defined(windows):
    test "find_distinguishes_unreadable_roots_from_empty_searches":
      if geteuid() == 0:
        fatal "this test must not run as root: root reads a mode-000 directory"
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let user = dir / "user"
      let partition = dir / "system" / myAccount()
      let env = storeEnv(user, dir / "system")
      let content = "git-tree-sha1:" & repeat('5', 40)
      let roots = StoreRoots(user: user, system: partition)
      for root in [user, partition]:
        createDir(root / "v1" / "git-tree-sha1" / repeat('5', 40))
      # Either root may be unreadable, at the root itself or below it. A
      # candidate from its peer wins; after removing it, emptiness is unknown.
      for (blocked, peer) in [(user, partition), (partition, user)]:
        for denied in [
          blocked, blocked / "v1", blocked / "v1" / "git-tree-sha1" / repeat('5', 40)
        ]:
          let candidate = putAt(peer, certificateText(content))
          setFilePermissions(denied, {})
          let found = runCliProcess(["find", "--content", content], env)
          removeFile(candidate)
          let empty = runCliProcess(["find", "--content", content], env)
          let report = findById(roots, content)
          setFilePermissions(denied, {fpUserRead, fpUserWrite, fpUserExec})
          checkpoint denied
          check found.exitCode == 0
          check found.output == candidate & "\n"
          check "[unreadable]" in found.errors
          check empty.exitCode == 3
          check empty.output == ""
          check empty.errors.count("searched ") == 2
          check "[unreadable]" in empty.errors
          check "search incomplete" in empty.errors
          # Check the library's classification without coupling to an enum
          # introduced by the fix, so this test runs against the old source.
          check $report.outcome == "foIncomplete"
