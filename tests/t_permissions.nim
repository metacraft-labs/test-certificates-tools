## Root admission checks use the real filesystem and real account database.
## ACL fixtures use setfacl against real files, never a mocked permission check.
## Linux account-isolation controls require passwordless sudo for temporary
## fixtures only. Missing prerequisites fail; no ownership check is mocked.
import std/unittest
when defined(linux):
  import std/tempfiles
import ./helpers
import test_certificates
when not defined(windows):
  import std/posix except Time

const Content = "git-tree-sha1:1111111111111111111111111111111111111111"

suite "store permission preconditions":
  when not defined(windows):
    test "a system recipient cannot also be its producer":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let root = dir / myAccount()
      createDir(root)
      let put = putCertificate(root, certificateText(Content), system = true)
      check not put.ok
      check "recipient" in put.problem
      let prune = pruneRoot(root, system = true)
      check not prune.ok
      check not fileExists(root / ".write-lock")

    test "system writes and prunes refuse writable or unreadable partitions":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let root = dir / recipientAccount()
      createDir(root)
      for mode in [0o777, 0o700]:
        require chmod(root.cstring, Mode(mode)) == 0
        let put = putCertificate(root, certificateText(Content), system = true)
        checkpoint put.problem
        check not put.ok
        let prune = pruneRoot(root, system = true)
        check not prune.ok
        check not fileExists(root / ".write-lock")
        check not dirExists(root / "v1")

  when defined(linux):
    test "unsupported access and default ACL policies fail before mutation":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      for acl in [
        "u:" & recipientAccount() & ":r-x", "d:u:" & recipientAccount() & ":r-x"
      ]:
        let root = dir / recipientAccount()
        createDir(root)
        require chmod(root.cstring, Mode(0o755)) == 0
        let set = runProcess("setfacl", ["-m", acl, root], dir)
        require set.started and set.exitCode == 0
        let put = putCertificate(root, certificateText(Content), system = true)
        checkpoint put.problem
        check not put.ok
        check "ACL" in put.problem
        check not pruneRoot(root, system = true).ok
        check not fileExists(root / ".write-lock")
        check not dirExists(root / "v1")
        removeDir(root)

  when defined(linux):
    test "system pruning unlinks nested symlinks without reaching their targets":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let root = dir / recipientAccount()
      createDir(root)
      require chmod(root.cstring, Mode(0o755)) == 0
      let written = putCertificate(root, certificateText(Content), system = true)
      checkpoint written.problem
      require written.ok
      let outside = dir / "outside"
      createDir(outside)
      writeFile(outside / "sentinel", "outside remains unchanged")
      createSymlink(outside, written.path.parentDir / "linked-directory")
      createSymlink(outside / "sentinel", written.path.parentDir / ".tmp-linked-file")
      ageTree(written.path.parentDir, 7200)
      let pruned = pruneRoot(
        root, keep = 0, system = true, now = getTime() + initDuration(hours = 2)
      )
      checkpoint pruned.errors.join("\n")
      check pruned.ok
      check pruned.errors.len == 0
      check pruned.removed.len == 1
      check not dirExists(written.path.parentDir)
      check readFile(outside / "sentinel") == "outside remains unchanged"
      var outsideCount = 0
      for kind, path in walkDir(outside):
        inc outsideCount
      check outsideCount == 1

    test "recipient group write access refuses a partition with no other access":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let recipient = recipientAccount()
      let account = getpwuid(Uid(parseUInt(recipient)))
      require account != nil
      let root = dir / recipient
      createDir(root)
      let group = runProcess("sudo", ["-n", "chgrp", $account.pw_gid, root], dir)
      require group.started and group.exitCode == 0
      require chmod(root.cstring, Mode(0o770)) == 0
      let put = putCertificate(root, certificateText(Content), system = true)
      checkpoint put.problem
      check not put.ok
      check "recipient can write" in put.problem
      let prune = pruneRoot(root, keep = 0, system = true)
      checkpoint prune.errors.join("\n")
      check not prune.ok
      check not fileExists(root / ".write-lock")
      check not dirExists(root / "v1")

    test "foreign ownership refuses a numeric system partition":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let recipient = recipientAccount()
      let root = dir / recipient
      createDir(root)
      let changed = runProcess("sudo", ["-n", "chown", recipient, root], dir)
      require changed.started and changed.exitCode == 0
      defer:
        let restored = runProcess("sudo", ["-n", "chown", myAccount(), root], dir)
        doAssert restored.started and restored.exitCode == 0, restored.stderr
      let mode = runProcess("sudo", ["-n", "chmod", "0755", root], dir)
      require mode.started and mode.exitCode == 0
      let put = putCertificate(root, certificateText(Content), system = true)
      checkpoint put.problem
      check not put.ok
      check "owned" in put.problem
      let prune = pruneRoot(root, keep = 0, system = true)
      checkpoint prune.errors.join("\n")
      check not prune.ok
      check not fileExists(root / ".write-lock")
      check not dirExists(root / "v1")

    test "a writable foreign user root is refused before any mutation":
      let dir = scratchDir()
      defer:
        cleanup(dir)
      let root = dir / "foreign"
      createDir(root)
      let foreign = recipientAccount()
      let changed = runProcess("sudo", ["-n", "chown", foreign, root], dir)
      require changed.started and changed.exitCode == 0
      defer:
        let restored = runProcess("sudo", ["-n", "chown", myAccount(), root], dir)
        doAssert restored.started and restored.exitCode == 0, restored.stderr
      let permissions = runProcess("sudo", ["-n", "chmod", "0777", root], dir)
      require permissions.started and permissions.exitCode == 0
      writeFile(root / "sentinel", "unchanged")
      let put = putCertificate(root, certificateText(Content))
      checkpoint put.problem
      check not put.ok
      check "own" in put.problem
      let prune = pruneRoot(root, keep = 0)
      checkpoint prune.errors.join("\n")
      check not prune.ok
      check not fileExists(root / ".write-lock")
      check not dirExists(root / "v1")
      check readFile(root / "sentinel") == "unchanged"

    for partitionMode in ["0750", "2750"]:
      test "a different group remains readable under umask 077, mode " & partitionMode &
        ":":
        # Nix's TMPDIR parent is private; the recipient needs a traversable
        # parent too, independently of the store permissions being tested.
        let dir = createTempDir("tcert-group-", "", "/tmp")
        defer:
          cleanup(dir)
        require chmod(dir.cstring, Mode(0o755)) == 0
        let recipient = recipientAccount()
        let account = getpwuid(Uid(parseUInt(recipient)))
        require account != nil
        let group = $account.pw_gid
        let root = dir / recipient
        createDir(root)
        defer:
          let removed = runProcess("sudo", ["-n", "rm", "-rf", "--", root], dir)
          doAssert removed.started and removed.exitCode == 0, removed.stderr
        let owner = runProcess("sudo", ["-n", "chown", "0:" & group, root], dir)
        require owner.started and owner.exitCode == 0
        let mode = runProcess("sudo", ["-n", "chmod", partitionMode, root], dir)
        require mode.started and mode.exitCode == 0
        let producerGroup = runProcess("sudo", ["-n", "id", "-g"], dir)
        require producerGroup.started and producerGroup.exitCode == 0
        require producerGroup.stdout.strip != group
        let cert = dir / "certificate.toml"
        writeFile(cert, certificateText(Content))
        let written = runProcess(
          "sudo",
          [
            "-n",
            "sh",
            "-c",
            "umask 077; export TEST_CERTIFICATES_SYSTEM_DIR=\"$4\"; exec \"$1\" put --system \"$2\" \"$3\"",
            "fixture",
            cliBinary(),
            recipient,
            cert,
            dir,
          ],
          dir,
        )
        checkpoint written.stderr
        require written.started and written.exitCode == 0
        let path = root / relativeOf(certificateText(Content))
        let read = runProcess("sudo", ["-n", "-u", "#" & recipient, "cat", path], dir)
        checkpoint read.stderr
        check read.started and read.exitCode == 0
        check read.stdout == certificateText(Content)
        for child in [root / "v1", path.parentDir.parentDir, path.parentDir, path]:
          let metadata =
            runProcess("sudo", ["-n", "stat", "-c", "%u %g %a", child], dir)
          require metadata.started and metadata.exitCode == 0
          let fields = metadata.stdout.splitWhitespace()
          require fields.len == 3
          check fields[0] == "0"
          check fields[1] == group
          check (parseOctInt(fields[2]) and 0o777) ==
            (if child == path: 0o640 else: 0o750)
        let denied = runProcess(
          "sudo",
          [
            "-n",
            "-u",
            "#" & recipient,
            "sh",
            "-c",
            "test ! -w \"$1\" && test ! -w \"$2\" && ! touch \"$1/forbidden\" && ! rm \"$2\"",
            "fixture",
            path.parentDir,
            path,
          ],
          dir,
        )
        checkpoint denied.stderr
        check denied.started and denied.exitCode == 0
        let remains =
          runProcess("sudo", ["-n", "-u", "#" & recipient, "test", "-f", path], dir)
        check remains.started and remains.exitCode == 0
