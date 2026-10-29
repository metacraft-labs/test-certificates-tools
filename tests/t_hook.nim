## hook: Tooling §4 — ``hook pre-push`` and ``hook install``, driven by real
## ``git push`` commands against real bare remotes in scratch directories,
## with real stores and the built executable as the hook.
##
## * pre_push_hook_publishes_and_pushes_notes_for_introduced_commits
## * pre_push_hook_never_fails_the_push — a remote that refuses the notes
##   ref, one that cannot be reached, one that never answers (the time
##   budget), an unreadable store, malformed input, a bad notes-ref setting,
##   no repository at all, wrong arguments.
## * receiving_side_finds_certificates_after_a_plain_git_push — the hook as
##   ``hook install`` writes it, found on ``PATH``; a fresh clone fetches,
##   imports and finds.
## * Deletions, tags (of a commit, of a tree), a new branch, a remote object
##   this clone never fetched, a push to a URL with no configured remote, a
##   user's ``notes push`` (the hook runs once and does not push again), the
##   opt-out variable, and ``hook install`` never replacing a hook.
##
## Most hooks here are a two-line script that counts its invocations and
## then execs the built binary by absolute path, so the count observes
## recursion directly. Every command runs with the isolated git configuration
## of ``helpers.isolatedEnv``. The one "remote that never answers"
## is git's own ``ext::`` transport running ``sleep``, which is exactly a
## remote helper that does not speak. One stand-in is justified: a
## ``test-certificates`` script that kills itself with SIGSEGV, because a real
## crash of the binary cannot be provoked on demand and what is under test is
## the installed hook script's answer to one.

import std/[monotimes, sequtils, unittest]
import ./helpers
import test_certificates

const Ref = DefaultNotesRef

proc installCountingHook(c: Clone, scratch: string): string =
  ## A pre-push hook that appends a line to the returned file, then runs the
  ## built binary as the hook body.
  result = scratch / (c.dir.extractFilename & "-hook-runs")
  let hook = c.dir / ".git" / "hooks" / "pre-push"
  writeFile(
    hook,
    "#!/bin/sh\necho run >> '" & result & "'\nexec '" & cliBinary() &
      "' hook pre-push \"$@\"\n",
  )
  setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})

proc runs(counter: string): int =
  if fileExists(counter):
    readFile(counter).count("run\n")
  else:
    0

proc push(c: Clone, args: varargs[string]): GitRun =
  gitWith(c.dir, @["push"] & @args, c.env)

proc commitFile(c: Clone, name, text: string): string =
  ## Commit ``text`` as ``name``; answer the new commit's tree.
  writeFile(c.dir / name, text)
  commitAll(c.dir, name)
  treeOf(c.dir, "HEAD")

proc certify(c: Clone, tree: string, target = "t-unit") =
  putIn(c, certificateText("git-tree-sha1:" & tree, targets = @[target]))

proc remoteKeys(remote: string): HashSet[string] =
  noteKeys(remote)

proc hookDirect(
    c: Clone,
    input: string,
    args: openArray[string] = ["origin", "origin"],
    extra: openArray[(string, string)] = [],
): CliRun =
  ## The hook body run by hand, as a dispatcher would run it.
  runCliProcess(@["hook", "pre-push"] & @args, c.env & @extra, c.dir, input)

proc zeros(): string =
  repeat('0', 40)

suite "hook pre-push":
  test "pre_push_hook_publishes_and_pushes_notes_for_introduced_commits":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    let counter = installCountingHook(a, scratch)
    # Already on the remote, then certified: not introduced by a later push.
    let t1 = commitFile(a, "f", "one\n")
    let first = push(a, "-q", "origin", "HEAD:refs/heads/main")
    check first.exitCode == 0
    check runs(counter) == 1
    checkpoint first.stderr
    # No certificates anywhere: nothing published, nothing pushed.
    check "no stored certificates for the 1 commit(s)" in first.stderr
    check git(remote, ["rev-parse", "--verify", "--quiet", Ref]).ok == false
    certify(a, t1)

    let t2 = commitFile(a, "f", "two\n")
    let t3 = commitFile(a, "f", "three\n")
    discard commitFile(a, "f", "four\n") # Introduced, not certified.
    certify(a, t2)
    certify(a, t3)
    certify(a, t3, "t-second")
    let second = push(a, "origin", "HEAD:refs/heads/main")
    checkpoint second.stderr
    check second.exitCode == 0
    check runs(counter) == 2 # The hook's own notes push ran no hook.
    check "2 certified tree(s) among 3 pushed commit(s): 3 certificate(s) added" in
      second.stderr
    check "pushed to origin" in second.stderr
    check remoteKeys(remote) == toHashSet([t2, t3])
    check noteBlob(remote, t3).splitNote().len == 2
    check gitIn(remote, ["rev-parse", Ref]).strip() ==
      gitIn(a.dir, ["rev-parse", Ref]).strip()

    # Nothing new: the hook makes no network operation and changes nothing.
    let tip = gitIn(remote, ["rev-parse", Ref]).strip()
    let third = push(a, "origin", "HEAD:refs/heads/main")
    check third.exitCode == 0
    check gitIn(remote, ["rev-parse", Ref]).strip() == tip

    # A remote object this clone never fetched: another clone moved main,
    # and this one force-pushes over it. The hook cannot compute
    # `<remote>..<local>` and falls back to the remote-tracking refs.
    let b = newClone(scratch, remote, "b")
    discard commitFile(b, "g", "from b\n")
    check push(b, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
    let t5 = commitFile(a, "f", "five\n")
    certify(a, t5)
    let stale = push(a, "--force", "origin", "HEAD:refs/heads/main")
    checkpoint stale.stderr
    check stale.exitCode == 0
    check "1 certified tree(s) among 1 pushed commit(s)" in stale.stderr
    check t5 in remoteKeys(remote)

  test "a new branch introduces only what the remote-tracking refs lack":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    let base = commitFile(a, "f", "base\n")
    check push(a, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
    discard gitIn(a.dir, ["fetch", "-q", "origin"])
    discard installCountingHook(a, scratch)
    certify(a, base) # On the remote already.
    discard gitIn(a.dir, ["checkout", "-q", "-b", "topic"])
    let topic = commitFile(a, "f", "topic\n")
    certify(a, topic)
    let pushed = push(a, "origin", "topic")
    checkpoint pushed.stderr
    check pushed.exitCode == 0
    check "1 certified tree(s) among 1 pushed commit(s)" in pushed.stderr
    check remoteKeys(remote) == toHashSet([topic])

  test "deletions, notes refs and tags of non-commits are left alone":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    let tree = commitFile(a, "f", "x\n")
    check push(a, "-q", "origin", "HEAD:refs/heads/main", "HEAD:refs/heads/topic").exitCode ==
      0
    discard gitIn(a.dir, ["fetch", "-q", "origin"])
    let counter = installCountingHook(a, scratch)
    certify(a, tree)
    # A deletion: nothing to publish, so nothing is pushed.
    let deleted = push(a, "origin", ":refs/heads/topic")
    checkpoint deleted.stderr
    check deleted.exitCode == 0
    check runs(counter) == 1
    check "test-certificates:" notin deleted.stderr
    check git(remote, ["rev-parse", "--verify", "--quiet", Ref]).ok == false
    # A tag of a tree is not a commit.
    discard gitIn(a.dir, ["tag", "tree-tag", tree])
    let tagged = push(a, "origin", "refs/tags/tree-tag")
    check tagged.exitCode == 0
    check git(remote, ["rev-parse", "--verify", "--quiet", Ref]).ok == false
    let direct = hookDirect(
      a,
      "refs/tags/tree-tag " & tree & " refs/tags/tree-tag " & zeros() & "\n" &
        "(delete) " & zeros() & " refs/heads/gone " &
        gitIn(a.dir, ["rev-parse", "HEAD"]).strip() & "\n" & Ref & " " &
        gitIn(a.dir, ["rev-parse", "HEAD"]).strip() & " " & Ref & " " & zeros() & "\n",
    )
    check direct.exitCode == 0
    check direct.errors == ""
    # An annotated tag of a commit counts, through the commit it peels to.
    let t2 = commitFile(a, "f", "y\n")
    certify(a, t2)
    discard gitIn(a.dir, ["tag", "-a", "-m", "release", "v1"])
    let release = push(a, "origin", "refs/tags/v1")
    checkpoint release.stderr
    check release.exitCode == 0
    check remoteKeys(remote) == toHashSet([t2])

  test "a push to a URL pushes the notes to that URL":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    var a = Clone(dir: scratch / "a", store: scratch / "a-store")
    a.env = isolatedEnv(scratch, a.store)
    createDir(a.dir)
    discard gitIn(a.dir, ["init", "-q"])
    discard installCountingHook(a, scratch)
    let tree = commitFile(a, "f", "by url\n")
    certify(a, tree)
    check gitIn(a.dir, ["remote"]).strip() == ""
    let pushed = push(a, remote, "HEAD:refs/heads/main")
    checkpoint pushed.stderr
    check pushed.exitCode == 0
    check ("pushed to " & remote) in pushed.stderr
    check remoteKeys(remote) == toHashSet([tree])

  test "a user's notes push runs the hook once, and the hook does not push again":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    let tree = commitFile(a, "f", "x\n")
    certify(a, tree)
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    let counter = installCountingHook(a, scratch)
    let notesPush = tc(a, ["notes", "push", "origin"])
    checkpoint notesPush.errors
    check notesPush.exitCode == 0
    check runs(counter) == 1
    check "certified tree" notin notesPush.errors
    check remoteKeys(remote) == toHashSet([tree])
    # The same with plain git.
    let t2 = commitFile(a, "f", "y\n")
    certify(a, t2)
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    let plain = push(a, "origin", Ref & ":" & Ref)
    checkpoint plain.stderr
    check plain.exitCode == 0
    check runs(counter) == 2
    check "test-certificates:" notin plain.stderr
    check remoteKeys(remote) == toHashSet([tree, t2])

  test "pre_push_hook_never_fails_the_push":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    let counter = installCountingHook(a, scratch)
    let tree = commitFile(a, "f", "x\n")
    certify(a, tree)
    let head = gitIn(a.dir, ["rev-parse", "HEAD"]).strip()
    let line = "refs/heads/main " & head & " refs/heads/main " & zeros() & "\n"

    # The remote refuses the notes ref: the branch still lands.
    let refuse = remote / "hooks" / "update"
    writeFile(
      refuse,
      "#!/bin/sh\ncase \"$1\" in refs/notes/*) echo 'no notes here' >&2; exit 1;; esac\nexit 0\n",
    )
    setFilePermissions(refuse, {fpUserRead, fpUserWrite, fpUserExec})
    let refused = push(a, "origin", "HEAD:refs/heads/main")
    checkpoint refused.stderr
    check refused.exitCode == 0
    check runs(counter) == 1
    check "warning: certificates were NOT fully propagated" in refused.stderr
    check "notes push origin" in refused.stderr
    check gitIn(remote, ["rev-parse", "refs/heads/main"]).strip() == head
    check git(remote, ["rev-parse", "--verify", "--quiet", Ref]).ok == false
    removeFile(refuse)

    # A remote that cannot be reached.
    let missing = scratch / "no-such-remote.git"
    let unreachable = hookDirect(a, line, [missing, missing])
    checkpoint unreachable.errors
    check unreachable.exitCode == 0
    check "warning:" in unreachable.errors

    # A remote that never answers: stopped within the time budget. The hook
    # runs with its standard streams on pipes, as a dispatcher that captures
    # its output runs it. The remote helper (`sleep`) outlives the git
    # process the hook stops; it must hold none of those pipes, or reading
    # them to the end would wait the full 20 s for it.
    when not defined(windows):
      let hang = "ext::sleep 20"
      let started = getMonoTime()
      let hung = hookDirect(
        a,
        line,
        [hang, hang],
        [
          ("TEST_CERTIFICATES_HOOK_TIMEOUT", "2"),
          ("GIT_CONFIG_COUNT", "1"),
          ("GIT_CONFIG_KEY_0", "protocol.ext.allow"),
          ("GIT_CONFIG_VALUE_0", "always"),
        ],
      )
      let took = (getMonoTime() - started).inMilliseconds
      checkpoint hung.errors
      check hung.exitCode == 0
      check took < 10_000
      check "did not finish within" in hung.errors or "time budget" in hung.errors

    # An unreadable store.
    when not defined(windows):
      let algorithmDir = a.store / "v1" / "git-tree-sha1"
      setFilePermissions(algorithmDir, {})
      let unreadable = hookDirect(a, line, [remote, remote])
      setFilePermissions(algorithmDir, {fpUserRead, fpUserWrite, fpUserExec})
      checkpoint unreadable.errors
      check unreadable.exitCode == 0
      check "could not be read" in unreadable.errors

    # Malformed input: reported, the good line still counts.
    let garbled = hookDirect(a, "garbage\nmain 123 main 456\n" & line, [remote, remote])
    checkpoint garbled.errors
    check garbled.exitCode == 0
    check "ignored pre-push input line 1" in garbled.errors
    check "ignored pre-push input line 2" in garbled.errors
    check remoteKeys(remote) == toHashSet([tree])

    # Wrong arguments, no repository, a notes-ref setting that is refused,
    # and an unknown remote name.
    check hookDirect(a, line, []).exitCode == 0
    check runCliProcess(["hook", "pre-push", "x", "x"], a.env, scratch, line).exitCode ==
      0
    discard gitIn(a.dir, ["config", NotesRefConfigKey, "refs/heads/not-notes"])
    let badRef = hookDirect(a, line)
    check badRef.exitCode == 0
    check "warning: notes ref" in badRef.errors
    discard gitIn(a.dir, ["config", "--unset", NotesRefConfigKey])
    check hookDirect(a, line, ["nowhere", "nowhere"]).exitCode == 0

    # Opted out: says so, touches nothing.
    let t2 = commitFile(a, "f", "y\n")
    certify(a, t2)
    check push(a, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
    let before = remoteKeys(remote)
    let t3 = commitFile(a, "f", "z\n")
    certify(a, t3)
    let optedOut = gitWith(
      a.dir,
      ["push", "origin", "HEAD:refs/heads/main"],
      a.env & @[("TEST_CERTIFICATES_HOOK", "off")],
    )
    check optedOut.exitCode == 0
    check "TEST_CERTIFICATES_HOOK=off" in optedOut.stderr
    check remoteKeys(remote) == before
    check t3 notin before

  test "receiving_side_finds_certificates_after_a_plain_git_push":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    let installed = tc(a, ["hook", "install"])
    checkpoint installed.errors
    check installed.exitCode == 0
    let hookPath = installed.output.strip()
    check readFile(hookPath) == PrePushHookScript
    let tree = commitFile(a, "f", "shipped\n")
    let cert = certificateText("git-tree-sha1:" & tree)
    putIn(a, cert)
    # The installed hook finds the tool on PATH.
    let path = cliBinary().parentDir & $PathSep & getEnv("PATH")
    let pushed = gitWith(
      a.dir, ["push", "origin", "HEAD:refs/heads/main"], a.env & @[("PATH", path)]
    )
    checkpoint pushed.stderr
    check pushed.exitCode == 0
    check "1 certificate(s) added" in pushed.stderr

    let b = newClone(scratch, remote, "b")
    check not dirExists(b.store)
    check tc(b, ["find", "--commit", "HEAD"]).exitCode == 1
    check tc(b, ["notes", "fetch", "origin"]).exitCode == 0
    let imported = tc(b, ["notes", "import"])
    check imported.exitCode == 0
    let found = tc(b, ["find", "--commit", "HEAD"])
    checkpoint found.errors
    check found.exitCode == 0
    let paths = found.output.splitLines().filterIt(it.len > 0)
    check paths == @[b.store / toNative(relativeOf(cert))]

    # Without the tool on PATH the installed hook says so and lets the push
    # go. PATH then holds only what the hook script and git need.
    let bare = scratch / "bin"
    createDir(bare)
    for tool in ["git", "cat"]:
      let exe = findExe(tool)
      check exe.len > 0
      createSymlink(exe, bare / tool)
    let t2 = commitFile(a, "f", "again\n")
    certify(a, t2)
    let noTool = gitWith(
      a.dir, ["push", "origin", "HEAD:refs/heads/main"], a.env & @[("PATH", bare)]
    )
    check noTool.exitCode == 0
    check "not on PATH" in noTool.stderr

    # A tool that crashes before reading its input (killed by a signal, the
    # one failure no exception handler sees) still lets the push go. The
    # stand-in is a script, not the real binary: a real crash cannot be
    # provoked on demand, and what is tested is the installed hook's answer.
    when not defined(windows):
      writeFile(bare / "test-certificates", "#!/bin/sh\nkill -SEGV $$\n")
      setFilePermissions(
        bare / "test-certificates", {fpUserRead, fpUserWrite, fpUserExec}
      )
      let t3 = commitFile(a, "f", "crash\n")
      certify(a, t3)
      let crashed = gitWith(
        a.dir, ["push", "origin", "HEAD:refs/heads/main"], a.env & @[("PATH", bare)]
      )
      checkpoint crashed.stderr
      check crashed.exitCode == 0
      check git(a.dir, ["rev-parse", "HEAD"]).stdout ==
        git(remote, ["rev-parse", "refs/heads/main"]).stdout

suite "hook install":
  test "never replaces an existing hook, and is idempotent":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    let printed = tc(a, ["hook", "install", "--print"])
    check printed.exitCode == 0
    check printed.output == PrePushHookScript
    check tc(a, ["hook", "install"]).exitCode == 0
    let again = tc(a, ["hook", "install"])
    check again.exitCode == 0
    check "already installed" in again.errors
    let hook = a.dir / ".git" / "hooks" / "pre-push"
    writeFile(hook, "#!/bin/sh\nexit 0\n")
    let refused = tc(a, ["hook", "install"])
    check refused.exitCode == 1
    check "already exists" in refused.errors
    check readFile(hook) == "#!/bin/sh\nexit 0\n"
    check tc(a, ["hook", "install", "--bogus"]).exitCode == 2
    check tc(a, ["hook"]).exitCode == 2
    check tc(a, ["hook", "post-commit"]).exitCode == 2

suite "pre-push input":
  test "parses git's lines and reports the rest":
    let oid = repeat('a', 40)
    let parsed = parsePrePushInput(
      "refs/heads/main " & oid & " refs/heads/main " & zeros() & "\r\n\n" &
        "too few fields\n" & "a " & repeat('g', 40) & " b " & oid & "\n" & "x " &
        repeat('b', 64) & " y " & repeat('0', 64)
    )
    check parsed.refs.len == 2
    check parsed.refs[0].remoteOid == zeros()
    check parsed.refs[1].localOid == repeat('b', 64)
    check parsed.faults.len == 2
