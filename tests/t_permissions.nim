## Root admission checks use the real filesystem and real account database.
## ACL fixtures use setfacl against real files, never a mocked permission check.
##
## Several Linux cases need a second account: a root owned by another user, a
## partition whose group is the recipient's, a producer that is root and a
## recipient that reads as itself. Making those fixtures takes privilege, so
## on Linux this test binary runs as root — and gets there without sudo:
##
## 1. Already root: it runs as it is.
## 2. Otherwise it re-executes itself in a new user namespace
##    (``unshare --user --map-root-user --map-users=auto --map-groups=auto``,
##    util-linux, from the dev shell). There it is root over this account's
##    subordinate uid and gid ranges (``/etc/subuid``, ``/etc/subgid``, set up
##    by ``newuidmap``), which include ``nobody`` (65534): real ownership,
##    real permission checks by the real kernel, confined to the namespace
##    and to the temporary directories the tests create.
## 3. Where unprivileged user namespaces are unavailable (Ubuntu 24.04's
##    AppArmor restriction, as on GitHub's runners, or no subordinate ids)
##    and ``sudo -n`` works, it re-executes itself under ``sudo -n``.
## 4. Otherwise it FAILS, saying which of these it tried and why each could
##    not be used. Nothing is skipped.
##
## Commands as the recipient run under ``setpriv`` (util-linux) with the
## recipient's uid and gid and no supplementary groups.
import std/unittest
when defined(windows):
  # POSIX-only: system-store writes and pruning are unsupported on Windows
  # (docs/users/README.md), and the rest are POSIX ownership, mode and ACL
  # checks.
  echo "t_permissions: POSIX-only (system-store writes and pruning are unsupported on Windows); no case applies"
else:
  import ./helpers
  import test_certificates
  import std/posix except Time
when defined(linux):
  import std/tempfiles

const Content = "git-tree-sha1:1111111111111111111111111111111111111111"

when defined(linux):
  const
    PrivilegedMarker = "TEST_CERTIFICATES_PERMISSIONS_PRIVILEGED"
      ## Set in the re-executed test binary: a second attempt means the
      ## namespace or sudo did not make it root.
    NamespaceArgs =
      ["--user", "--map-root-user", "--map-users=auto", "--map-groups=auto", "--"]

  proc reexecAs(launcher: string, launcherArgs: seq[string]) {.noreturn.} =
    ## Replace this process with ``launcher launcherArgs...``.
    let argv = allocCStringArray(@[launcher] & launcherArgs)
    discard execvp(launcher.cstring, argv)
    fatal "could not run " & launcher & ": " & osErrorMsg(osLastError())

  proc becomeRoot() =
    ## See the header: root as it is, in a user namespace, or under sudo.
    if geteuid() == 0:
      return
    if getEnv(PrivilegedMarker) == "1":
      fatal "re-executed for privilege but still not root (euid " & $geteuid() & ")"
    let self = getAppFilename()
    let params = commandLineParams()
    var tried: seq[string]
    let probe = runProcess("unshare", @NamespaceArgs & @["true"], getCurrentDir())
    if probe.started and probe.exitCode == 0:
      putEnv(PrivilegedMarker, "1")
      reexecAs("unshare", @NamespaceArgs & @[self] & params)
    tried.add "a user namespace (`unshare " & NamespaceArgs.join(" ") & " true`): " &
      (if probe.started: probe.stderr.strip() else: probe.failure)
    let sudo = runProcess("sudo", ["-n", "true"], getCurrentDir())
    if sudo.started and sudo.exitCode == 0:
      # sudo resets the environment; carry what the tests read.
      var envArgs = @[PrivilegedMarker & "=1", "PATH=" & getEnv("PATH")]
      for name in ["TEST_CERTIFICATES_BIN", "TEST_CERTIFICATES_SPEC_DIR", "TMPDIR"]:
        if existsEnv(name):
          envArgs.add name & "=" & getEnv(name)
      reexecAs("sudo", @["-n", "env"] & envArgs & @[self] & params)
    tried.add "sudo -n: " & (if sudo.started: sudo.stderr.strip()
    else: sudo.failure)
    fatal "the Linux permission tests need root over a second account and could not get it.\n  Tried " &
      tried.join("\n  Tried ") &
      "\n  Provide one of: unprivileged user namespaces with subordinate ids for this" &
      " account (/etc/subuid, /etc/subgid, newuidmap; on Ubuntu 24.04 also" &
      " `sysctl kernel.apparmor_restrict_unprivileged_userns=0`), or noninteractive sudo."

  becomeRoot()

  proc asRecipient(recipient: string, args: openArray[string], cwd: string): GitRun =
    ## Run ``args`` as the recipient account: its uid and primary gid, no
    ## supplementary groups.
    let account = getpwuid(Uid(parseUInt(recipient)))
    doAssert account != nil
    runProcess(
      "setpriv",
      @["--reuid=" & recipient, "--regid=" & $account.pw_gid, "--clear-groups", "--"] &
        @args,
      cwd,
    )

  proc mustRun(args: openArray[string], cwd: string) =
    ## A fixture command, run as this (root) process; it must succeed.
    let run = runProcess(args[0], args[1 ..^ 1], cwd)
    doAssert run.started and run.exitCode == 0,
      args.join(" ") & ": " & run.failure & run.stderr

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
      mustRun(["chgrp", $account.pw_gid, root], dir)
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
      mustRun(["chown", recipient, root], dir)
      mustRun(["chmod", "0755", root], dir)
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
      mustRun(["chown", foreign, root], dir)
      mustRun(["chmod", "0777", root], dir)
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
          mustRun(["rm", "-rf", "--", root], dir)
        mustRun(["chown", "0:" & group, root], dir)
        mustRun(["chmod", partitionMode, root], dir)
        # The producer (this process, root) is not in the partition's group.
        require $int(getegid()) != group
        let cert = dir / "certificate.toml"
        writeFile(cert, certificateText(Content))
        let written = runProcess(
          "sh",
          [
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
        let read = asRecipient(recipient, ["cat", path], dir)
        checkpoint read.stderr
        check read.started and read.exitCode == 0
        check read.stdout == certificateText(Content)
        for child in [root / "v1", path.parentDir.parentDir, path.parentDir, path]:
          let metadata = runProcess("stat", ["-c", "%u %g %a", child], dir)
          require metadata.started and metadata.exitCode == 0
          let fields = metadata.stdout.splitWhitespace()
          require fields.len == 3
          check fields[0] == "0"
          check fields[1] == group
          check (parseOctInt(fields[2]) and 0o777) ==
            (if child == path: 0o640 else: 0o750)
        let denied = asRecipient(
          recipient,
          [
            "sh", "-c",
            "test ! -w \"$1\" && test ! -w \"$2\" && ! touch \"$1/forbidden\" && ! rm \"$2\"",
            "fixture", path.parentDir, path,
          ],
          dir,
        )
        checkpoint denied.stderr
        check denied.started and denied.exitCode == 0
        let remains = asRecipient(recipient, ["test", "-f", path], dir)
        check remains.started and remains.exitCode == 0
