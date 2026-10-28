## prune: Transport §2.5, against a real store, a real git repository and
## the built executable.
##
## * prune_keeps_newest_and_head_tree
## * prune_renames_aside_so_a_retrying_writer_survives — a writer and a
##   pruner interleaved at the points that matter, using the library's test
##   seams (``PutStepHook``, ``PruneStepHook``) to CHOOSE the interleaving.
##   Both parties are the real code operating on the real filesystem; the
##   seams only decide when each runs, which a test of a race needs and
##   cannot get reliably from scheduling.
##
## No mocks.

import std/[algorithm, sequtils, unittest]
import ./helpers
import test_certificates

proc contentDirs(root: string): seq[string] =
  ## ``v1/<algorithm>/<digest>`` of every content directory, sorted.
  for algorithmKind, algorithmPath in walkDir(root / "v1"):
    for kind, path in walkDir(algorithmPath):
      if kind == pcDir and not path.extractFilename.startsWith("."):
        result.add "v1/" & algorithmPath.extractFilename & "/" & path.extractFilename
  result.sort()

proc dotNames(root: string): seq[string] =
  for algorithmKind, algorithmPath in walkDir(root / "v1"):
    for kind, path in walkDir(algorithmPath):
      if path.extractFilename.startsWith("."):
        result.add path

proc idOf(i: int): string =
  "git-tree-sha1:" & align($i, 40, '0')

suite "prune":
  test "prune_keeps_newest_and_head_tree":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let store = dir / "store"
    let repo = newRepo()
    defer:
      cleanup(repo)
    writeFile(repo / "f", "f\n")
    commitAll(repo)
    let head = "git-tree-sha1:" & gitIn(repo, ["rev-parse", "HEAD^{tree}"]).strip()

    # 25 content directories, newest first by index; the HEAD^{tree} one is
    # the OLDEST of all, and one beyond the newest 20 is being written into.
    var ids: seq[string]
    for i in 0 ..< 25:
      ids.add idOf(i)
    ids.add head
    var dirsByAge: seq[string]
    for i, id in ids:
      let path = putCertificate(store, certificateText(id)).path
      dirsByAge.add path.parentDir
    let busy = dirsByAge[22]
    writeFile(busy / ("." & repeat('9', 64) & ".toml.tmp-1-1-1"), "partial")
    for i, d in dirsByAge:
      ageTree(d, 1000 + i * 10)
    # A leftover of an interrupted prune: deleted, never counted.
    let leftover = store / "v1" / "git-tree-sha1" / (".abc" & RemovalMarker & "1-1")
    createDir(leftover / "nested")
    writeFile(leftover / "nested" / "x.toml", "x")

    let run = runCliProcess(
      ["prune", "--keep", "20"], storeEnv(store, dir / "system"), cwd = repo
    )
    checkpoint run.errors
    check run.exitCode == 0
    var removed = run.output.strip().splitLines()
    removed.sort()
    # Indexes 20..24 are beyond the newest 20; 22 is busy; HEAD's is kept.
    var expectedRemoved: seq[string]
    for i in [20, 21, 23, 24]:
      expectedRemoved.add "v1/git-tree-sha1/" & idOf(i).split(':')[1]
    expectedRemoved.sort()
    check removed == expectedRemoved
    var kept: seq[string]
    for i in 0 ..< 20:
      kept.add "v1/git-tree-sha1/" & idOf(i).split(':')[1]
    kept.add "v1/git-tree-sha1/" & idOf(22).split(':')[1]
    kept.add "v1/git-tree-sha1/" & head.split(':')[1]
    kept.sort()
    check contentDirs(store) == kept
    check dotNames(store).len == 0
    check "keeping the content of HEAD^{tree}: " & head in run.errors
    check "is being written into" in run.errors

    # Outside a repository nothing is protected; the default keeps 20.
    let outside = runCliProcess(["prune"], storeEnv(store, dir / "system"), cwd = dir)
    check outside.exitCode == 0
    let left = contentDirs(store)
    check left.len == 21 # 20 newest + the busy one
    check ("v1/git-tree-sha1/" & head.split(':')[1]) notin left

    # Usage errors.
    for args in [@["--keep", "-1"], @["--keep", "x"], @["--keep"], @["--what"]]:
      check runCliProcess(@["prune"] & args, storeEnv(store, dir / "system")).exitCode ==
        2

  test "prune protects the committed manifest even with zero retention":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let repo = newRepo()
    defer:
      cleanup(repo)
    writeFile(repo / "f", "committed\n")
    commitAll(repo)
    let manifest = computeContentId(repo, commitState("HEAD"), caManifestV1Sha256)
    require manifest.outcome == coComputed
    let stored = putCertificate(dir / "store", certificateText(manifest.id))
    require stored.ok
    ageTree(stored.path.parentDir, 1000)
    let run =
      runCliProcess(["prune", "--keep", "0"], storeEnv(dir / "store"), cwd = repo)
    checkpoint run.errors
    check run.exitCode == 0
    check fileExists(stored.path)
    check run.output.len == 0

  test "declared HEAD scopes protect both algorithms but not their subsets or dirty states":
    for format in ["sha1", "sha256"]:
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let repo = newRepo(format)
      defer:
        cleanup(repo)
      for name in ["src", "lib", "tests", "--literal", "other"]:
        writeFile(repo / name, name & " committed\n")
      commitAll(repo)
      let scopes = @[@["src", "lib"], @["tests"], @["--literal"]]
      var expected: seq[string]
      var paths: seq[string]
      for scope in @[newSeq[string]()] & scopes:
        let normalized = scope
        for manifest in [false, true]:
          let id =
            if manifest:
              computeContentId(
                repo, commitState("HEAD"), caManifestV1Sha256, normalized
              )
            else:
              computeContentId(repo, commitState("HEAD"), normalized)
          require id.outcome == coComputed
          let stored = putCertificate(dir / "store", certificateText(id.id))
          require stored.ok
          paths.add stored.path
          expected.add relativeOf(certificateText(id.id)).parentDir
      # Undeclared subsets do not become scopes, and modified state does not
      # substitute for the content actually committed at HEAD.
      var removed: seq[string]
      for scope in [@["src"], @["lib"], @["other"]]:
        let id = computeContentId(repo, commitState("HEAD"), scope)
        require id.outcome == coComputed
        let stored = putCertificate(dir / "store", certificateText(id.id))
        require stored.ok
        removed.add stored.path
      writeFile(repo / "src", "staged\n")
      discard gitIn(repo, ["add", "src"])
      writeFile(repo / "src", "working tree\n")
      let indexBefore = readFile(repo / ".git" / "index")
      for state in [stagedState(), worktreeState()]:
        let id = computeContentId(repo, state)
        require id.outcome == coComputed
        let stored = putCertificate(dir / "store", certificateText(id.id))
        require stored.ok
        removed.add stored.path
      for path in paths & removed:
        ageTree(path.parentDir, 1000)
      let run = runCliProcess(
        [
          "prune", "--keep", "0", "--paths", "src", "lib", "--paths", "tests",
          "--paths", "--", "--literal",
        ],
        storeEnv(dir / "store"),
        cwd = repo,
      )
      checkpoint run.errors
      check run.exitCode == 0
      for path in paths:
        check fileExists(path)
      for path in removed:
        check not fileExists(path)
      expected.sort()
      check contentDirs(dir / "store") == expected
      check readFile(repo / ".git" / "index") == indexBefore
      check readFile(repo / "src") == "working tree\n"

  test "bare repositories protect HEAD, and failed protection never prunes":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let repo = newRepo()
    defer:
      cleanup(repo)
    writeFile(repo / "f", "committed\n")
    commitAll(repo)
    let bare = dir / "bare.git"
    discard gitIn(dir, ["clone", "--bare", "-q", repo, bare])
    let native = computeContentId(repo, commitState("HEAD"))
    let manifest = computeContentId(repo, commitState("HEAD"), caManifestV1Sha256)
    var paths: seq[string]
    for id in [native.id, manifest.id]:
      let stored = putCertificate(dir / "store", certificateText(id))
      require stored.ok
      paths.add stored.path
      ageTree(stored.path.parentDir, 1000)
    let run =
      runCliProcess(["prune", "--keep", "0"], storeEnv(dir / "store"), cwd = bare)
    checkpoint run.errors
    check run.exitCode == 0
    for path in paths:
      check fileExists(path)
    let leftover =
      dir / "store" / "v1" / "git-tree-sha1" / (".old" & RemovalMarker & "1")
    createDir(leftover)
    writeFile(leftover / "partial", "keep on refusal")
    for args in [@["--paths"], @["--paths", "../bad"], @["--paths", "f", "--paths"]]:
      check runCliProcess(
        @["prune", "--keep", "0"] & args, storeEnv(dir / "store"), cwd = repo
      ).exitCode == 2
      for path in paths:
        check fileExists(path)
      check dirExists(leftover)
    let outside = runCliProcess(
      ["prune", "--keep", "0", "--paths", "f"], storeEnv(dir / "store"), cwd = dir
    )
    check outside.exitCode == 1
    check dirExists(leftover)
    let unborn = newRepo()
    defer:
      cleanup(unborn)
    let requested = runCliProcess(
      ["prune", "--keep", "0", "--paths", "f"], storeEnv(dir / "store"), cwd = unborn
    )
    check requested.exitCode == 1
    for path in paths:
      check fileExists(path)
    check dirExists(leftover)
    let noHead = headContentIds(unborn)
    check noHead.ok
    check noHead.ids.len == 0
    when not defined(windows):
      let account = myAccount()
      let partition = dir / "system" / account
      createDir(partition)
      var systemPaths: seq[string]
      for id in [native.id, manifest.id]:
        let stored = putCertificate(partition, certificateText(id), system = true)
        require stored.ok
        systemPaths.add stored.path
        ageTree(stored.path.parentDir, 1000)
      let systemRun = runCliProcess(
        ["prune", "--keep", "0", "--system", account],
        storeEnv(dir / "store", dir / "system"),
        cwd = repo,
      )
      checkpoint systemRun.errors
      check systemRun.exitCode == 0
      for path in systemPaths:
        check fileExists(path)
    # Break a real committed blob: native HEAD still resolves, but manifest
    # computation fails. No content or interrupted-prune leftover may go.
    let blob = gitIn(repo, ["rev-parse", "HEAD:f"]).strip()
    removeFile(repo / ".git" / "objects" / blob[0 .. 1] / blob[2 ..^ 1])
    let broken =
      runCliProcess(["prune", "--keep", "0"], storeEnv(dir / "store"), cwd = repo)
    checkpoint broken.errors
    check broken.exitCode == 1
    for path in paths:
      check fileExists(path)
    check dirExists(leftover)

  test "damaged repository discovery refuses before deleting contents or leftovers":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let repo = newRepo()
    defer:
      cleanup(repo)
    writeFile(repo / "f", "committed\n")
    commitAll(repo)
    let bare = dir / "bare.git"
    discard gitIn(dir, ["clone", "--bare", "-q", repo, bare])
    let stored = putCertificate(dir / "store", certificateText(idOf(73)))
    require stored.ok
    ageTree(stored.path.parentDir, 1000)
    let leftover =
      dir / "store" / "v1" / "git-tree-sha1" / (".old" & RemovalMarker & "1")
    createDir(leftover)
    writeFile(leftover / "partial", "retain on refusal")
    for repository in [repo, bare]:
      let head = (if repository == repo: repo / ".git" else: bare) / "HEAD"
      let original = readFile(head)
      for missing in [false, true]:
        if missing:
          removeFile(head)
        else:
          writeFile(head, "damaged\n")
        createDir(repository / "subdirectory")
        for cwd in [repository, repository / "subdirectory"]:
          let run =
            runCliProcess(["prune", "--keep", "0"], storeEnv(dir / "store"), cwd = cwd)
          checkpoint run.errors
          check run.exitCode == 1
          check fileExists(stored.path)
          check dirExists(leftover)
        writeFile(head, original)
    check not headContentIds(dir / "missing").ok
    let noGit = runCliProcess(
      ["prune", "--keep", "0"],
      storeEnv(dir / "store") & @[("PATH", dir / "no-executables")],
      cwd = repo,
    )
    checkpoint noGit.errors
    check noGit.exitCode == 1
    check fileExists(stored.path)
    check dirExists(leftover)

  test "prune --system prunes a partition its owner holds, and refuses a link":
    when defined(windows):
      skip()
    else:
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let account = myAccount()
      let partition = dir / "system" / account
      createDir(partition)
      for i in 0 ..< 3:
        let p = putCertificate(partition, certificateText(idOf(i)), system = true)
        check p.ok
        ageTree(p.path.parentDir, 1000 + i)
      var run = runCliProcess(
        ["prune", "--system", account, "--keep", "1"],
        storeEnv(dir / "u", dir / "system"),
        cwd = dir,
      )
      check run.exitCode == 0
      check contentDirs(partition).len == 1
      # A partition replaced by a link is refused.
      moveDir(partition, dir / "real")
      createSymlink(dir / "real", partition)
      run = runCliProcess(
        ["prune", "--system", account, "--keep", "0"],
        storeEnv(dir / "u", dir / "system"),
        cwd = dir,
      )
      check run.exitCode == 1
      check "symbolic link" in run.errors
      check contentDirs(dir / "real").len == 1

  test "prune_renames_aside_so_a_retrying_writer_survives":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let store = dir / "store"
    let id = idOf(7)
    let first = certificateText(id, targets = @["first"])
    let retrying = certificateText(id, targets = @["retrying"])
    let contentDir = store / toNative(relativeOf(first)).parentDir
    var observedDetached = false
    var retryResult: PutResult
    # The clock the prune's being-written guards compare with, far enough
    # ahead that the writer's fresh directory and temporary file do not
    # protect it: this test is about what happens when a prune DOES choose a
    # directory a writer is in, which the guards only make unlikely.
    let later = getTime() + initDuration(hours = 2)

    let hook: PutStepHook = proc(attempt: int) =
      if attempt != 0:
        return
      # The writer has created the directory and flushed its temporary
      # file; now a prune runs to completion.
      let pruned = pruneRoot(
        store,
        keep = 0,
        now = later,
        onStep = proc(stage: PruneStage, relative: string) =
          if stage == psDetached:
            # One atomic step has taken the directory out of the store: its
            # path is gone, the renamed tree holds the writer's temporary file.
            observedDetached = true
            check not dirExists(contentDir)
            let aside = dotNames(store)
            check aside.len == 1
            check toSeq(walkDir(aside[0])).len == 1
            # A writer whose attempt this defeated retries NOW, before the
            # renamed tree is deleted. It must land in a fresh directory
            # the deletion cannot reach.
            retryResult = putCertificate(store, retrying)
        ,
      )
      check pruned.removed == @[relativeOf(first).parentDir]
      check pruned.errors.len == 0

    let r = putCertificate(store, first, beforeRename = hook)
    check observedDetached
    # The retrying writer survived the deletion of the renamed tree.
    check retryResult.ok
    check fileExists(retryResult.path)
    check readFile(retryResult.path) == retrying
    # The interrupted writer noticed (its temporary file vanished with the
    # tree), recreated the directory and retried once.
    check r.ok
    check r.retried
    check readFile(r.path) == first
    check dotNames(store).len == 0
    check toSeq(walkDir(contentDir)).len == 2

  test "a writer whose directory is renamed aside under it retries into the store":
    # The other half of the race: the directory is renamed aside AFTER the
    # writer opened it and before its rename, and not yet deleted. The rename
    # then lands in the renamed-aside tree; the writer must notice that the
    # path no longer leads to the directory it wrote into, and retry.
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let store = dir / "store"
    let text = certificateText(idOf(8))
    let contentDir = store / toNative(relativeOf(text)).parentDir
    let aside = contentDir.parentDir / (".x" & RemovalMarker & "test")
    let hook: PutStepHook = proc(attempt: int) =
      if attempt == 0:
        moveDir(contentDir, aside)
    let r = putCertificate(store, text, beforeRename = hook)
    check r.ok
    check r.retried
    check readFile(r.path) == text
    check r.path.parentDir == contentDir
    # The leftover is any pruner's to delete, and is not counted.
    let pruned = pruneRoot(store, keep = 0, now = getTime())
    check pruned.leftovers == @[aside]
    check pruned.removed.len == 0 # the fresh directory is being written into
    check not dirExists(aside)
