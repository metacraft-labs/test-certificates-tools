## Real filesystem permission and FIFO fixtures; no mocks.
import std/unittest
when defined(windows):
  # POSIX-only: every case here is a system-store write or prune, which is
  # unsupported on Windows (docs/users/README.md), or a POSIX file type.
  echo "t_permission_paths: POSIX-only (system-store writes and pruning are unsupported on Windows); no case applies"
else:
  import ./helpers
  import test_certificates
  import std/posix except Time
const Content = "git-tree-sha1:1111111111111111111111111111111111111111"
suite "system store path permissions":
  when not defined(windows):
    test "unsafe existing directories are rejected before writer lock creation":
      for depth in 1 .. 3:
        for mode in [0o777, 0o700]:
          let dir = scratchDir()
          defer:
            cleanup(dir)
          let root = dir / recipientAccount()
          createDir(root)
          require chmod(root.cstring, Mode(0o755)) == 0
          var path = root
          for part in relativeOf(certificateText(Content)).split('/')[0 ..< depth]:
            path = path / part
            createDir(path)
            require chmod(path.cstring, Mode(0o755)) == 0
          require chmod(path.cstring, Mode(mode)) == 0
          let put = putCertificate(root, certificateText(Content), system = true)
          checkpoint put.problem
          check not put.ok
          check not fileExists(root / ".write-lock")
          check not pruneRoot(root, keep = 0, system = true).ok
          check dirExists(path)
    test "unsafe writer locks are refused without publishing":
      for fifo in [false, true]:
        let dir = scratchDir()
        defer:
          cleanup(dir)
        let root = dir / recipientAccount()
        createDir(root)
        require chmod(root.cstring, Mode(0o755)) == 0
        let lock = root / ".write-lock"
        if fifo:
          require mkfifo(lock.cstring, Mode(0o600)) == 0
        else:
          writeFile(lock, "sentinel")
          require chmod(lock.cstring, Mode(0o666)) == 0
        let put = putCertificate(root, certificateText(Content), system = true)
        checkpoint put.problem
        check not put.ok
        check not dirExists(root / "v1")
        if not fifo:
          check readFile(lock) == "sentinel"
    test "unsafe nested directories and interrupted-prune leftovers survive":
      for leftover in [false, true]:
        let dir = scratchDir()
        defer:
          cleanup(dir)
        let root = dir / recipientAccount()
        createDir(root)
        require chmod(root.cstring, Mode(0o755)) == 0
        let put = putCertificate(root, certificateText(Content), system = true)
        checkpoint put.problem
        require put.ok
        var content = put.path.parentDir
        if leftover:
          let aside = content.parentDir / ".interrupted.removing-fixture"
          moveDir(content, aside)
          content = aside
        createDir(content / "nested")
        require chmod((content / "nested").cstring, Mode(0o777)) == 0
        writeFile(content / "nested" / "sentinel", "unchanged")
        ageTree(content, 1000)
        let pruned = pruneRoot(root, keep = 0, system = true)
        checkpoint pruned.errors.join("\n")
        check not pruned.ok
        check readFile(content / "nested" / "sentinel") == "unchanged"

    test "an unsafe replacement after selection is refused before detach":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let root = dir / recipientAccount()
      createDir(root)
      require chmod(root.cstring, Mode(0o755)) == 0
      let put = putCertificate(root, certificateText(Content), system = true)
      checkpoint put.problem
      require put.ok
      let content = put.path.parentDir
      ageTree(content, 1000)
      var replaced = false
      let pruned = pruneRoot(
        root,
        keep = 0,
        system = true,
        onStep = proc(stage: PruneStage, relative: string) =
          if stage == psChosen:
            moveDir(content, dir / "original")
            createDir(content)
            require chmod(content.cstring, Mode(0o777)) == 0
            writeFile(content / "sentinel", "unchanged")
            replaced = true
        ,
      )
      require replaced
      checkpoint pruned.errors.join("\n")
      check not pruned.ok
      check pruned.removed.len == 0
      check readFile(content / "sentinel") == "unchanged"
      check fileExists(dir / "original" / put.path.lastPathPart)

    test "a detached path replaced by a symlink never reaches its target":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let root = dir / recipientAccount()
      createDir(root)
      require chmod(root.cstring, Mode(0o755)) == 0
      let put = putCertificate(root, certificateText(Content), system = true)
      checkpoint put.problem
      require put.ok
      ageTree(put.path.parentDir, 1000)
      let outside = dir / "outside"
      createDir(outside)
      writeFile(outside / "sentinel", "unchanged")
      var replaced = false
      let pruned = pruneRoot(
        root,
        keep = 0,
        system = true,
        onStep = proc(stage: PruneStage, relative: string) =
          if stage == psDetached:
            for kind, path in walkDir(put.path.parentDir.parentDir):
              if path.lastPathPart.startsWith("."):
                moveDir(path, dir / "detached-original")
                createSymlink(outside, path)
                replaced = true
        ,
      )
      require replaced
      check pruned.errors.len > 0
      check readFile(outside / "sentinel") == "unchanged"
      check fileExists(dir / "detached-original" / put.path.lastPathPart)
