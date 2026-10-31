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
##   user's ``notes push`` (the hook runs once and does not push again), two
##   refs whose remote objects bound each other's introduced commits, a
##   budget that would be unlimited, the opt-out variable, and ``hook
##   install`` never replacing a hook. Declared scopes: ``t_scopes``.
## * a_push_to_a_url_streams_a_long_history_in_bounded_memory — 50 000
##   commits made by ``git fast-import``; in-process, so the allocator's
##   high-water mark can be read. Batched scoped trees choose what one batch
##   chooses.
## * Partial clones: real `--filter` clones over a real transport. A remote
##   object the clone lacks gives §4.2's commit set and no network operation;
##   declared scopes read no blob; a tree or a note the clone lacks, with a
##   promisor that never answers, stays inside the budget; a note it lacks is
##   still fetched when the promisor answers.
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

import std/[monotimes, sequtils, tables, unittest]
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
    check git(a.dir, ["rev-parse", "--verify", "--quiet", Ref]).ok == false
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

  test "the other refs' remote objects bound what each ref introduces":
    # Pushed to a URL, so there are no remote-tracking refs: only the remote
    # object of `main`, pushed alongside, keeps the new branch from
    # introducing its whole history (Tooling §4.2, exclusion 1).
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    var a = Clone(dir: scratch / "a", store: scratch / "a-store")
    a.env = isolatedEnv(scratch, a.store)
    createDir(a.dir)
    discard gitIn(a.dir, ["init", "-q", "-b", "main"])
    let base = commitFile(a, "f", "base\n")
    check push(a, "-q", remote, "main").exitCode == 0
    discard installCountingHook(a, scratch)
    certify(a, base) # On the remote, under main.
    let onMain = commitFile(a, "f", "main\n")
    certify(a, onMain)
    discard gitIn(a.dir, ["checkout", "-q", "-b", "topic", "HEAD~1"])
    let onTopic = commitFile(a, "f", "topic\n")
    certify(a, onTopic)
    let both = push(a, remote, "main", "topic")
    checkpoint both.stderr
    check both.exitCode == 0
    check "2 certified tree(s) among 2 pushed commit(s)" in both.stderr
    check remoteKeys(remote) == toHashSet([onMain, onTopic])
    check base notin noteKeys(a.dir)

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
    # its output runs it. The remote helper (`sleep`) is stopped together
    # with the git that started it (its process group; on Windows its job),
    # and must hold none of the hook's pipes meanwhile, or reading them to
    # the end would wait the full 20 s for it. On Windows `sleep` is
    # Git for Windows' own (usr\bin, which scripts/windows/test.ps1 puts on
    # PATH), and the stop is the job object's.
    if findExe("sleep").len == 0:
      fatal "`sleep` is not on PATH (on Windows: Git for Windows' usr\\bin)"
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

    # A budget that is not a whole number of seconds of at least 1 — "no
    # limit" included — is reported and the default used (Tooling §4.3).
    for value in ["0", "-1", "soon"]:
      let ignored = hookDirect(
        a, line, [remote, remote], [("TEST_CERTIFICATES_HOOK_TIMEOUT", value)]
      )
      check ignored.exitCode == 0
      check ("ignored TEST_CERTIFICATES_HOOK_TIMEOUT=" & value) in ignored.errors

    # Opted out: says so, touches nothing.
    let t2 = commitFile(a, "f", "y\n")
    certify(a, t2)
    check push(a, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
    let before = remoteKeys(remote)
    let localBefore = gitIn(a.dir, ["rev-parse", Ref]).strip()
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
    check gitIn(a.dir, ["rev-parse", Ref]).strip() == localBefore

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

proc importHistory(dir: string, count: int, scoped: bool) =
  ## ``count`` commits on ``main``, made by ``git fast-import`` in chunks of
  ## 5 000 so no large input is ever held here. Commit ``i`` (from 1) has
  ## ``other`` = ``i``, a distinct tree per commit, and with ``scoped`` a file
  ## ``src/a`` = ``i div 10``, so ten neighbouring commits share their tree in
  ## the scope ``src``.
  var i = 1
  while i <= count:
    var stream = ""
    let last = min(count, i + 4999)
    for n in i .. last:
      stream.add "commit refs/heads/main\n"
      stream.add "committer T <t@example.invalid> " & $(1_700_000_000 + n) & " +0000\n"
      stream.add "data 1\nx\n"
      if n == i and i > 1:
        stream.add "from refs/heads/main^0\n"
      let other = $n & "\n"
      stream.add "M 100644 inline other\ndata " & $other.len & "\n" & other & "\n"
      if scoped:
        let a = $(n div 10) & "\n"
        stream.add "M 100644 inline src/a\ndata " & $a.len & "\n" & a & "\n"
    discard gitIn(dir, ["fast-import", "--quiet"], input = stream)
    i = last + 1

proc hookInProcess(c: Clone, remote, tip: string, batchTrees = 0): HookReport =
  ## The hook as a library call, for a push of ``main`` to the URL
  ## ``remote`` that does not have it.
  var options = defaultHookOptions()
  options.batchTrees = batchTrees
  prePushHook(
    c.dir,
    "",
    remote,
    "refs/heads/main " & tip & " refs/heads/main " & zeros() & "\n",
    StoreRoots(user: c.store),
    options,
  )

suite "hook pre-push, long histories":
  # A push to a URL with nothing known on the remote considers the pushed
  # ref's whole history. In-process library calls, so the allocator's
  # high-water mark (`getMaxMem`) can be read: it must not grow with the
  # history, as it did when the whole `rev-list` output was held.
  setup:
    let gitConfig = getTempDir() / ("t-hook-gitconfig-" & $getCurrentProcessId())
    writeFile(gitConfig, "")
    putEnv("GIT_CONFIG_GLOBAL", gitConfig)
    putEnv("GIT_CONFIG_NOSYSTEM", "1")
  teardown:
    delEnv("GIT_CONFIG_GLOBAL")
    delEnv("GIT_CONFIG_NOSYSTEM")
    removeFile(gitConfig)

  test "a_push_to_a_url_streams_a_long_history_in_bounded_memory":
    const Commits = 50_000
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    var a = Clone(dir: scratch / "a", store: scratch / "a-store")
    createDir(a.dir)
    discard gitIn(a.dir, ["init", "-q", "-b", "main"])
    importHistory(a.dir, Commits, scoped = false)
    let tip = gitIn(a.dir, ["rev-parse", "main"]).strip()
    let deep = gitIn(a.dir, ["rev-parse", "main~" & $(Commits - 10)]).strip()
    certify(a, treeOf(a.dir, tip))
    certify(a, treeOf(a.dir, deep))
    let before = getMaxMem()
    let started = getMonoTime()
    let report = hookInProcess(a, remote, tip)
    let grew = getMaxMem() - before
    checkpoint "took " & $(getMonoTime() - started).inMilliseconds & " ms; " &
      "the allocator's high-water mark grew by " & $grew & " bytes"
    checkpoint report.problems.join("\n")
    check report.introducedCount == Commits
    check report.certified == @[tip, deep]
    check report.propagated
    check remoteKeys(remote) == toHashSet([treeOf(a.dir, tip), treeOf(a.dir, deep)])
    # The listing alone is about 4.5 MB of text (two lines of 41 and 47
    # bytes a commit); holding it, or a sequence of its commits, would show.
    check grew < 2 * 1024 * 1024

  test "batched scoped trees choose what one batch chooses":
    const Commits = 3_000
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    var a = Clone(dir: scratch / "a", store: scratch / "a-store")
    createDir(a.dir)
    discard gitIn(a.dir, ["init", "-q", "-b", "main"])
    discard gitIn(a.dir, ["config", "--add", ScopeSection & ".src.path", "src"])
    importHistory(a.dir, Commits, scoped = true)
    let tip = gitIn(a.dir, ["rev-parse", "main"]).strip()
    proc commit(n: int): string =
      gitIn(a.dir, ["rev-parse", "main~" & $(Commits - n)]).strip()

    # Commits 500..509 share their scoped tree; the newest of them is the
    # first rev-list meets. Commit 3's own tree is certified too.
    let scopedId = computeContentId(a.dir, commitState(commit(505)), ["src"])
    require scopedId.outcome == coComputed
    putIn(a, certificateText(scopedId.id))
    certify(a, treeOf(a.dir, commit(3)))
    let small = hookInProcess(a, remote, tip, batchTrees = 7)
    checkpoint small.problems.join("\n")
    check small.introducedCount == Commits
    check small.certified == @[commit(509), commit(3)]
    let whole = hookInProcess(a, remote, tip, batchTrees = Commits + 1)
    check whole.certified == small.certified
    check whole.introducedCount == Commits

# ---------------------------------------------------------------------------
# Partial clones (Tooling §4.2, §4.3)
# ---------------------------------------------------------------------------

const
  StallSeconds = 20
  HookBudget = ("TEST_CERTIFICATES_HOOK_TIMEOUT", "2")
    ## Far below the stall, so a hook that waits for the stall cannot pass.
  WithinBudgetMs = 15_000
    ## A generous bound for a 2 s budget on a slow machine, still below the
    ## 20 s stall a single unbudgeted command would wait for.

proc fileUrl(path: string): string =
  ## A filter is only honoured over a real transport; a plain path is copied
  ## by the local clone optimisation, whole.
  when defined(windows):
    "file:///" & path.replace('\\', '/')
  else:
    "file://" & path

proc newPartialClone(scratch, remote, name, filter: string): Clone =
  ## A real partial clone of ``remote``, with no worktree, so that it holds no
  ## blob the checkout would have fetched.
  discard gitIn(remote, ["config", "uploadpack.allowFilter", "true"])
  result.dir = scratch / name
  result.store = scratch / (name & "-store")
  discard gitIn(
    scratch,
    ["clone", "-q", "--no-checkout", "--filter=" & filter, fileUrl(remote), result.dir],
  )
  result.env = isolatedEnv(scratch, result.store)

proc isAbsent(c: Clone, oid: string): bool =
  ## Whether this clone lacks the object, asked so that asking cannot fetch it.
  gitWith(c.dir, ["cat-file", "-e", oid], [NoLazyFetch]).exitCode != 0

proc stallPromisor(c: Clone): seq[(string, string)] =
  ## Point the clone's promisor remote at a helper that never answers
  ## (`ext::sleep`, the same real stall as "one that never answers" above),
  ## and answer the environment that allows that transport.
  discard gitIn(c.dir, ["remote", "set-url", "origin", "ext::sleep " & $StallSeconds])
  @[
    HookBudget,
    ("GIT_CONFIG_COUNT", "1"),
    ("GIT_CONFIG_KEY_0", "protocol.ext.allow"),
    ("GIT_CONFIG_VALUE_0", "always"),
  ]

proc newTree(c: Clone, name, text: string): string =
  ## A tree of one file, written without a worktree or an index.
  let blob = gitIn(c.dir, ["hash-object", "-w", "--stdin"], input = text).strip()
  gitIn(c.dir, ["mktree"], input = "100644 blob " & blob & "\t" & name & "\n").strip()

proc commitOn(c: Clone, tree, parent: string): string =
  gitIn(c.dir, ["commit-tree", "-m", "x", "-p", parent, tree]).strip()

proc seedRemote(scratch: string): tuple[remote: string, seed: Clone] =
  ## A remote whose ``main`` has two commits, with a directory and a file.
  result.remote = newBareRemote(scratch)
  result.seed = newClone(scratch, result.remote, "seed")
  createDir(result.seed.dir / "src")
  writeFile(result.seed.dir / "src" / "f", "one\n")
  writeFile(result.seed.dir / "other", "x\n")
  commitAll(result.seed.dir, "first")
  writeFile(result.seed.dir / "src" / "f", "two\n")
  commitAll(result.seed.dir, "second")
  doAssert push(result.seed, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0

proc pushLine(local, remoteOid: string): string =
  "refs/heads/x " & local & " refs/heads/main " & remoteOid & "\n"

proc millisSince(start: MonoTime): int64 =
  (getMonoTime() - start).inMilliseconds

proc gitWrapper(path, real, before: string): string =
  ## An executable at ``path`` that runs the shell text ``before`` and then is
  ## the real git. Justified, as the header of this file requires of a stand-in:
  ## the real git does everything; the wrapper only makes observable or
  ## provokable what cannot otherwise be (which git ran, a git that ignores a
  ## variable, a stall at one chosen command).
  writeFile(path, "#!/bin/sh\n" & before & "\nexec " & quoteShell(real) & " \"$@\"\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  path

suite "hook pre-push, partial clones":
  test "a_remote_object_the_clone_lacks_makes_no_network_operation_with_a_stalled_promisor":
    # §4.3: nothing to carry, no network operation. The remote object is the
    # one §4.2 names, and looking it up used to make a lazy fetch.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (remote, seed) = seedRemote(scratch)
    let p = newPartialClone(scratch, remote, "partial", "blob:none")
    let main = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
    discard commitFile(seed, "g", "moved on\n")
    check push(seed, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
    let moved = gitIn(seed.dir, ["rev-parse", "HEAD"]).strip()
    check isAbsent(p, moved)
    let mine = commitOn(p, newTree(p, "m", "mine\n"), main)
    let stall = stallPromisor(p)
    let trace = scratch / "trace"
    let started = getMonoTime()
    let run = hookDirect(p, pushLine(mine, moved), extra = stall & ("GIT_TRACE", trace))
    let took = millisSince(started)
    checkpoint run.errors
    check run.exitCode == 0
    check "no stored certificates for the 1 commit(s)" in run.errors
    check "warning" notin run.errors
    # Not "within the budget": no time spent, and no fetch even attempted.
    check took < WithinBudgetMs
    check " fetch " notin readFile(trace)
    check isAbsent(p, moved)

  test "a_remote_object_the_clone_lacks_gives_the_commit_set_of_section_4_2":
    # §4.2's table, third and fourth rows, with the old value really absent:
    # everything new is introduced, what the tracking refs reach is not, and
    # the unknown object is never treated as an exclusion it cannot be.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (remote, seed) = seedRemote(scratch)
    let p = newPartialClone(scratch, remote, "partial", "blob:none")
    let main = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
    discard commitFile(seed, "g", "moved on\n")
    check push(seed, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
    let moved = gitIn(seed.dir, ["rev-parse", "HEAD"]).strip()
    check isAbsent(p, moved)
    let middleTree = newTree(p, "m", "middle\n")
    let tipTree = newTree(p, "m", "tip\n")
    let middle = commitOn(p, middleTree, main)
    let tip = commitOn(p, tipTree, middle)
    let publishedTree = treeOf(p.dir, main)
    certify(p, middleTree)
    certify(p, tipTree)
    certify(p, publishedTree) # On the remote already: not introduced.

    let tracked = hookDirect(p, pushLine(tip, moved))
    checkpoint tracked.errors
    check tracked.exitCode == 0
    check "2 certified tree(s) among 2 pushed commit(s)" in tracked.errors
    check remoteKeys(remote) == toHashSet([middleTree, tipTree])
    check isAbsent(p, moved)

    # No remote-tracking refs stand in for a URL: the whole history counts.
    let byUrl = hookDirect(p, pushLine(tip, moved), [remote, remote])
    checkpoint byUrl.errors
    check byUrl.exitCode == 0
    check "among 4 pushed commit(s)" in byUrl.errors
    check remoteKeys(remote) == toHashSet([middleTree, tipTree, publishedTree])
    check isAbsent(p, moved)

    # Another entry's absent remote object excludes nothing either, and does
    # not stop the entry whose remote object is known.
    let mixed = hookDirect(
      p,
      pushLine(tip, main) & "refs/heads/y " & tip & " refs/heads/y " & moved & "\n",
      [remote, remote],
    )
    checkpoint mixed.errors
    check mixed.exitCode == 0
    check "warning" notin mixed.errors
    check "among 2 pushed commit(s)" in mixed.errors

  test "declared_scopes_read_no_blob_of_a_blob_none_clone":
    # `write-tree` checks every entry's object, which in a partial clone
    # fetches them all, so a scope made every push reach the promisor.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (remote, seed) = seedRemote(scratch)
    let p = newPartialClone(scratch, remote, "partial", "blob:none")
    let main = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
    discard gitIn(p.dir, ["config", "testCertificatesScope.s.path", "src"])
    let blob = gitIn(p.dir, ["rev-parse", "origin/main:src/f"]).strip()
    check isAbsent(p, blob)
    let tree = treeOf(p.dir, main)
    # The same scoped tree as a clone that has every blob computes.
    let scope = DeclaredScope(names: @["s"], paths: @["src"])
    let full = scopedTrees(seed.dir, 40, [tree], [scope])
    check full.ok
    let scoped = full.trees[tree][0]
    # A commit of the same tree, new to the remote: pushed to a URL, so its
    # history is what is introduced.
    let again = commitOn(p, tree, main)

    # Nothing certified, promisor stalled: nothing touches it.
    let answering = gitIn(p.dir, ["remote", "get-url", "origin"]).strip()
    let stall = stallPromisor(p)
    let started = getMonoTime()
    let quiet = hookDirect(p, pushLine(again, zeros()), [remote, remote], stall)
    let took = millisSince(started)
    checkpoint quiet.errors
    check quiet.exitCode == 0
    check "warning" notin quiet.errors
    check took < WithinBudgetMs
    check isAbsent(p, blob)

    # Certified in the scope: published under that same tree, still no blob.
    discard gitIn(p.dir, ["remote", "set-url", "origin", answering])
    certify(p, scoped)
    let carried = hookDirect(p, pushLine(again, zeros()), [remote, remote])
    checkpoint carried.errors
    check carried.exitCode == 0
    check "warning" notin carried.errors
    check remoteKeys(remote) == toHashSet([scoped])
    check isAbsent(p, blob)

  test "a_tree_the_clone_lacks_is_reported_within_the_budget":
    # A tree:0 clone cannot tell what a scope selects without fetching, and
    # with nothing known to carry the hook may not fetch: reported, not waited
    # for, and the push goes on.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (remote, seed) = seedRemote(scratch)
    let p = newPartialClone(scratch, remote, "partial", "tree:0")
    discard commitFile(seed, "g", "moved on\n")
    check push(seed, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
    discard gitIn(p.dir, ["fetch", "-q", "origin"])
    let fetched = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
    let tree = gitIn(p.dir, ["log", "-1", "--format=%T", fetched]).strip()
    check isAbsent(p, tree)
    discard gitIn(p.dir, ["config", "testCertificatesScope.s.path", "src"])
    let stall = stallPromisor(p)

    # With an empty store no scoped tree can be certified: nothing is read,
    # and there is nothing to warn about.
    let empty = hookDirect(p, pushLine(fetched, zeros()), [remote, remote], stall)
    checkpoint empty.errors
    check empty.exitCode == 0
    check "warning" notin empty.errors
    check isAbsent(p, tree)

    # With something stored, what a scope selects cannot be told without a
    # fetch, and the report says what to do about it.
    certify(p, repeat('a', 40))
    let started = getMonoTime()
    let run = hookDirect(p, pushLine(fetched, zeros()), [remote, remote], stall)
    let took = millisSince(started)
    checkpoint run.errors
    check run.exitCode == 0
    check "could not read trees for the declared scopes" in run.errors
    check "notes publish" in run.errors
    check took < WithinBudgetMs
    check isAbsent(p, tree)

  proc treeZeroClone(
      scratch: string
  ): tuple[remote: string, seed, p: Clone, commit, tree: string] =
    ## A ``tree:0`` clone with a declared scope, lacking the tree of the commit
    ## it is about to push.
    let (remote, seed) = seedRemote(scratch)
    let p = newPartialClone(scratch, remote, "partial", "tree:0")
    discard commitFile(seed, "g", "moved on\n")
    check push(seed, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
    discard gitIn(p.dir, ["fetch", "-q", "origin"])
    let commit = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
    let tree = gitIn(p.dir, ["log", "-1", "--format=%T", commit]).strip()
    doAssert isAbsent(p, tree)
    discard gitIn(p.dir, ["config", "testCertificatesScope.s.path", "src"])
    (remote, seed, p, commit, tree)

  test "a_tree_zero_clone_still_carries_the_certificate_of_a_commits_own_tree":
    # The unscoped note is what a gateway reads. Not telling a scope must not
    # cost it: and with that to carry a fetch is allowed, so the scoped tree of
    # the same commit is found and published as well.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (_, seed, p, commit, tree) = treeZeroClone(scratch)
    let scope = DeclaredScope(names: @["s"], paths: @["src"])
    let scoped = scopedTrees(seed.dir, 40, [tree], [scope]).trees[tree][0]
    certify(p, tree)
    certify(p, scoped, "t-scoped")
    let target = scratch / "target.git"
    discard gitIn(scratch, ["init", "-q", "--bare", target])
    let run = hookDirect(p, pushLine(commit, zeros()), [target, target])
    checkpoint run.errors
    check run.exitCode == 0
    check "could not read trees for the declared scopes" in run.errors
    check noteKeys(target) == toHashSet([tree, scoped])

  test "a_tree_zero_clone_stops_at_the_budget_reading_trees_for_what_it_carries":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (_, _, p, commit, tree) = treeZeroClone(scratch)
    certify(p, tree)
    let target = scratch / "target.git"
    discard gitIn(scratch, ["init", "-q", "--bare", target])
    let stall = stallPromisor(p)
    let started = getMonoTime()
    let run = hookDirect(p, pushLine(commit, zeros()), [target, target], stall)
    let took = millisSince(started)
    checkpoint run.errors
    check run.exitCode == 0
    check "certificates were NOT fully propagated" in run.errors
    check took < WithinBudgetMs
    check noteKeys(target).len == 0

  test "the_remedy_the_warning_names_carries_a_certificate_for_a_scope":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (_, seed, p, commit, tree) = treeZeroClone(scratch)
    let scope = DeclaredScope(names: @["s"], paths: @["src"])
    let scoped = scopedTrees(seed.dir, 40, [tree], [scope]).trees[tree][0]
    certify(p, scoped, "t-scoped")
    let target = scratch / "target.git"
    discard gitIn(scratch, ["init", "-q", "--bare", target])
    let run = hookDirect(p, pushLine(commit, zeros()), [target, target])
    checkpoint run.errors
    check run.exitCode == 0
    check "notes publish" in run.errors
    check noteKeys(target).len == 0
    let published = tc(p, ["notes", "publish", commit])
    checkpoint published.errors
    check published.exitCode == 0
    let pushed = tc(p, ["notes", "push", target])
    checkpoint pushed.errors
    check pushed.exitCode == 0
    check noteKeys(target) == toHashSet([scoped])

  proc withAbsentNote(
      scratch: string, certifyTree = true
  ): tuple[remote: string, seed, p: Clone, mine, tree: string] =
    ## A partial clone holding the remote's notes ref but not the blob of the
    ## note on ``tree``, with (``certifyTree``) its own certificate for that
    ## tree, and a new commit of it to push.
    let (remote, seed) = seedRemote(scratch)
    let p = newPartialClone(scratch, remote, "partial", "blob:none")
    let main = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
    let tree = treeOf(p.dir, main)
    certify(seed, tree, "t-seed")
    check tc(seed, ["notes", "publish", "HEAD"]).exitCode == 0
    check tc(seed, ["notes", "push", "origin"]).exitCode == 0
    discard gitIn(p.dir, ["fetch", "-q", "origin", "+" & Ref & ":" & Ref])
    let note = gitIn(p.dir, ["rev-parse", Ref & ":" & tree]).strip()
    doAssert isAbsent(p, note)
    if certifyTree:
      certify(p, tree, "t-partial")
    (remote, seed, p, commitOn(p, tree, main), tree)

  test "a_note_the_clone_lacks_is_fetched_when_the_promisor_answers":
    # The lazy fetch the hook must keep: a note is added to, never overwritten.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (remote, _, p, mine, tree) = withAbsentNote(scratch)
    let run = hookDirect(p, pushLine(mine, zeros()), [remote, remote])
    checkpoint run.errors
    check run.exitCode == 0
    check "warning" notin run.errors
    check noteBlob(remote, tree).splitNote().len == 2

  test "a_note_the_clone_lacks_stays_within_the_budget_when_the_promisor_stalls":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (remote, _, p, mine, tree) = withAbsentNote(scratch)
    let before = gitIn(remote, ["rev-parse", Ref]).strip()
    let localBefore = gitIn(p.dir, ["rev-parse", Ref]).strip()
    let stall = stallPromisor(p)
    let started = getMonoTime()
    let run = hookDirect(p, pushLine(mine, zeros()), [remote, remote], stall)
    let took = millisSince(started)
    checkpoint run.errors
    check run.exitCode == 0
    check "cannot read note blob" in run.errors
    check "certificates were NOT fully propagated" in run.errors
    check took < WithinBudgetMs
    # Nothing was overwritten, here or there, and no work ref was left behind.
    check gitIn(remote, ["rev-parse", Ref]).strip() == before
    check gitIn(p.dir, ["rev-parse", Ref]).strip() == localBefore
    check gitIn(p.dir, ["for-each-ref", "refs/test-certificates/"]).len == 0
    check noteBlob(remote, tree).splitNote().len == 1

  test "the_merge_after_a_lost_race_stays_within_the_budget_when_the_promisor_stalls":
    # The notes go to a second remote that answers, whose notes moved. Merging
    # needs the note this clone lacks, which only the stalled promisor can
    # give: that read is inside the push's budget too.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let (remote, seed, p, mine, tree) = withAbsentNote(scratch, certifyTree = false)
    let second = scratch / "second.git"
    discard gitIn(scratch, ["clone", "-q", "--bare", remote, second])
    discard gitIn(second, ["fetch", "-q", remote, "+" & Ref & ":" & Ref])
    certify(seed, tree, "t-moved-on")
    check tc(seed, ["notes", "publish", "HEAD"]).exitCode == 0
    check push(seed, "-q", second, Ref & ":" & Ref).exitCode == 0
    discard gitIn(p.dir, ["remote", "add", "second", second])
    # Something this clone can publish without reading the absent note.
    let newTreeOid = newTree(p, "m", "new\n")
    let newCommit = commitOn(p, newTreeOid, mine)
    certify(p, newTreeOid)
    let stall = stallPromisor(p)
    let started = getMonoTime()
    let run = hookDirect(
      p,
      "refs/heads/z " & newCommit & " refs/heads/z " & zeros() & "\n",
      ["second", second],
      stall,
    )
    let took = millisSince(started)
    checkpoint run.errors
    check run.exitCode == 0
    # The merge was reached, so the remote was seen to have moved without
    # fetching what it moved to, and it stopped at the note.
    check "cannot read note blob" in run.errors
    check "certificates were NOT fully propagated" in run.errors
    check took < WithinBudgetMs

  test "an_absent_local_object_is_reported_and_a_tag_of_an_absent_blob_is_not":
    # §4.1 skips what is not a commit. An object that cannot be examined is not
    # known to be one: skipping it could drop what the push introduces.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    discard commitFile(a, "f", "one\n")
    let absent = repeat('1', 40)
    proc tagOf(kind: string): string =
      gitIn(
        a.dir,
        ["hash-object", "-t", "tag", "-w", "--stdin"],
        input =
          "object " & absent & "\ntype " & kind &
          "\ntag t\ntagger T <t@example.invalid> 0 +0000\n\nm\n",
      )
        .strip()

    let lost = hookDirect(a, pushLine(absent, zeros()))
    checkpoint lost.errors
    check lost.exitCode == 0
    check "cannot be told" in lost.errors
    check "certificates were NOT fully propagated" in lost.errors

    let ofCommit = hookDirect(a, pushLine(tagOf("commit"), zeros()))
    checkpoint ofCommit.errors
    check ofCommit.exitCode == 0
    check "cannot be told" in ofCommit.errors

    let outer = gitIn(
        a.dir,
        ["hash-object", "-t", "tag", "-w", "--stdin"],
        input =
          "object " & tagOf("commit") &
          "\ntype tag\ntag o\ntagger T <t@example.invalid> 0 +0000\n\nm\n",
      )
      .strip()
    check "cannot be told" in hookDirect(a, pushLine(outer, zeros())).errors

    let ofBlob = hookDirect(a, pushLine(tagOf("blob"), zeros()))
    checkpoint ofBlob.errors
    check ofBlob.exitCode == 0
    check "warning" notin ofBlob.errors

suite "hook pre-push, the git it runs":
  # A real git behind every wrapper, and real clones: the only thing a wrapper
  # adds is what a real git cannot be made to do on demand (being another git,
  # ignoring a variable, stalling at one chosen command). See `gitWrapper`.
  setup:
    let gitConfig = getTempDir() / ("t-hook-wrapper-config-" & $getCurrentProcessId())
    writeFile(gitConfig, "[user]\n\tname = T\n\temail = t@example.invalid\n")
    putEnv("GIT_CONFIG_GLOBAL", gitConfig)
    putEnv("GIT_CONFIG_NOSYSTEM", "1")

  teardown:
    delEnv("GIT_CONFIG_GLOBAL")
    delEnv("GIT_CONFIG_NOSYSTEM")
    removeFile(gitConfig)

  when not defined(windows):
    test "the_git_a_caller_names_runs_every_command_of_the_hook":
      # What a program embedding the library relies on (`PushOptions.gitExe`):
      # the `git` first on PATH must never run, in the deciding stage or after
      # it. Every stage is reached: a tag of a tree, a scope, a publish, a push.
      let scratch = scratchDir()
      defer:
        cleanup(scratch)
      let remote = newBareRemote(scratch)
      let a = newClone(scratch, remote, "a")
      createDir(a.dir / "src")
      let tree = commitFile(a, "src/f", "one\n")
      let tip = gitIn(a.dir, ["rev-parse", "HEAD"]).strip()
      discard gitIn(a.dir, ["config", "testCertificatesScope.s.path", "src"])
      certify(a, tree)
      let tagged = gitIn(
          a.dir,
          ["hash-object", "-t", "tag", "-w", "--stdin"],
          input =
            "object " & tree &
            "\ntype tree\ntag t\ntagger T <t@example.invalid> 0 +0000\n\nm\n",
        )
        .strip()

      let named = scratch / "named.log"
      let wrongLog = scratch / "wrong.log"
      let wrongDir = scratch / "wrong-bin"
      createDir(wrongDir)
      let real = findExe("git")
      discard gitWrapper(wrongDir / "git", real, "printf '%s\\n' \"$*\" >> " & wrongLog)
      var options = defaultHookOptions()
      options.push.gitExe =
        gitWrapper(scratch / "named-git", real, "printf '%s\\n' \"$*\" >> " & named)

      let path = getEnv("PATH")
      putEnv("PATH", wrongDir & $PathSep & path)
      let report = prePushHook(
        a.dir,
        "",
        remote,
        "refs/heads/main " & tip & " refs/heads/main " & zeros() & "\n" & "refs/tags/t " &
          tagged & " refs/tags/t " & zeros() & "\n",
        StoreRoots(user: a.store),
        options,
      )
      putEnv("PATH", path)
      checkpoint report.problems.join("\n")
      check report.propagated
      check report.pushRan
      check noteKeys(remote) == toHashSet([tree])
      # The wrong git never ran, and the named one ran each stage's commands.
      check not fileExists(wrongLog)
      let calls = readFile(named).splitLines()
      for command in [
        "rev-parse --verify --quiet", "cat-file -t", "remote", "config -z",
        "rev-list --format=%T", "cat-file --batch", "ls-tree -r", "notes --ref", "push ",
      ]:
        checkpoint command
        check calls.anyIt(command in it)

    test "a_commit_whose_lookup_failed_is_reported_and_not_skipped_as_no_commit":
      # §4.1 skips what is not a commit. A commit whose lookup failed for any
      # other reason (a lookup stopped by the deadline, while the next command
      # got through) must not read as one, or its history would be dropped.
      let scratch = scratchDir()
      defer:
        cleanup(scratch)
      let remote = newBareRemote(scratch)
      let a = newClone(scratch, remote, "a")
      let tree = commitFile(a, "f", "one\n")
      let tip = gitIn(a.dir, ["rev-parse", "HEAD"]).strip()
      certify(a, tree)
      var options = defaultHookOptions()
      options.push.gitExe = gitWrapper(
        scratch / "failing-git",
        findExe("git"),
        "case \"$*\" in *\"^{commit}\"*) exit 1;; esac",
      )
      let report = prePushHook(
        a.dir, "", remote, pushLine(tip, zeros()), StoreRoots(user: a.store), options
      )
      check report.skipped.len == 0
      check not report.propagated
      check report.problems.anyIt("cannot be told" in it)

    test "the_work_ref_is_deleted_when_the_budget_runs_out_while_it_is_in_use":
      # `NotesRepo.dropWorkRef` is outside the deadline on purpose: the command
      # the deadline just stopped is why it runs. The stall is at `notes add`,
      # the one command that holds the work ref, and the recording made there
      # shows the ref really existed, so its absence afterwards is a deletion.
      let scratch = scratchDir()
      defer:
        cleanup(scratch)
      let remote = newBareRemote(scratch)
      let a = newClone(scratch, remote, "a")
      let first = commitFile(a, "f", "one\n")
      certify(a, first)
      check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
      let tree = commitFile(a, "f", "two\n")
      let tip = gitIn(a.dir, ["rev-parse", "HEAD"]).strip()
      certify(a, tree, "t-second")
      let before = gitIn(a.dir, ["rev-parse", Ref]).strip()
      let seen = scratch / "seen"
      let real = findExe("git")
      var options = defaultHookOptions()
      options.push.timeoutMs = 2000
      options.push.gitExe = gitWrapper(
        scratch / "stalling-git",
        real,
        "case \"$1\" in notes) " & quoteShell(real) & " for-each-ref " & WorkRefPrefix &
          " > " & quoteShell(seen) & "; exec sleep " & $StallSeconds & ";; esac",
      )
      let started = getMonoTime()
      let report = prePushHook(
        a.dir, "", remote, pushLine(tip, zeros()), StoreRoots(user: a.store), options
      )
      let took = millisSince(started)
      checkpoint report.problems.join("\n")
      check took < WithinBudgetMs
      check not report.propagated
      check not report.pushRan
      check WorkRefPrefix in readFile(seen)
      check gitIn(a.dir, ["for-each-ref", WorkRefPrefix]).len == 0
      check gitIn(a.dir, ["rev-parse", Ref]).strip() == before

    proc ignoringLazyFetchVariable(scratch: string): HookOptions =
      ## A git that behaves as one too old to know ``GIT_NO_LAZY_FETCH``
      ## (measured: 2.38.5), whatever the git on this host is.
      result = defaultHookOptions()
      result.push.timeoutMs = 2000
      result.push.gitExe =
        gitWrapper(scratch / "old-git", findExe("git"), "unset GIT_NO_LAZY_FETCH")

    proc stalled(c: Clone) =
      discard gitIn(c.dir, ["config", "protocol.ext.allow", "always"])
      discard
        gitIn(c.dir, ["remote", "set-url", "origin", "ext::sleep " & $StallSeconds])

    test "a_git_that_ignores_the_variable_is_stopped_at_a_remote_object_it_lacks":
      # The lookup makes the lazy fetch, and only the deadline ends it. That
      # spends the budget, so the hook says so, and the push goes on.
      let scratch = scratchDir()
      defer:
        cleanup(scratch)
      let (remote, seed) = seedRemote(scratch)
      let p = newPartialClone(scratch, remote, "partial", "blob:none")
      let main = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
      discard commitFile(seed, "g", "moved on\n")
      check push(seed, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
      let moved = gitIn(seed.dir, ["rev-parse", "HEAD"]).strip()
      let mine = commitOn(p, newTree(p, "m", "mine\n"), main)
      stalled(p)
      let started = getMonoTime()
      let report = prePushHook(
        p.dir,
        "origin",
        "origin",
        pushLine(mine, moved),
        StoreRoots(user: p.store),
        ignoringLazyFetchVariable(scratch),
      )
      let took = millisSince(started)
      checkpoint report.problems.join("\n")
      check took < WithinBudgetMs
      check not report.pushRan
      check report.problems.anyIt("time budget" in it)

    test "the_budget_is_one_when_the_deciding_stage_consumes_it":
      # The lookup above used to have a budget of its own: the certificates then
      # went on and were published and pushed under a second one, twice what
      # the user was told. The push goes to an answering URL, so only the
      # budget can stop it.
      let scratch = scratchDir()
      defer:
        cleanup(scratch)
      let (remote, seed) = seedRemote(scratch)
      let p = newPartialClone(scratch, remote, "partial", "blob:none")
      let main = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
      discard commitFile(seed, "g", "moved on\n")
      check push(seed, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
      let moved = gitIn(seed.dir, ["rev-parse", "HEAD"]).strip()
      let tree = newTree(p, "m", "mine\n")
      let mine = commitOn(p, tree, main)
      certify(p, tree)
      stalled(p)
      let started = getMonoTime()
      let report = prePushHook(
        p.dir,
        "",
        remote,
        pushLine(mine, moved),
        StoreRoots(user: p.store),
        ignoringLazyFetchVariable(scratch),
      )
      let took = millisSince(started)
      checkpoint report.problems.join("\n")
      check took < WithinBudgetMs
      check not report.propagated
      check not report.publishRan
      check not report.pushRan
      check report.problems.anyIt("time budget" in it)
      check noteKeys(remote).len == 0

    test "what_the_deciding_stage_spent_is_not_given_back_to_the_publish":
      # Deciding finishes in time, and spends most of the budget: a slow command
      # that still answers. The publish then has what is left and no more, so a
      # command that would have fitted a second budget is stopped.
      let scratch = scratchDir()
      defer:
        cleanup(scratch)
      let remote = newBareRemote(scratch)
      let a = newClone(scratch, remote, "a")
      let tree = commitFile(a, "f", "one\n")
      let tip = gitIn(a.dir, ["rev-parse", "HEAD"]).strip()
      certify(a, tree)
      var options = defaultHookOptions()
      options.push.timeoutMs = 2000
      options.push.gitExe = gitWrapper(
        scratch / "slow-git",
        findExe("git"),
        "case \"$1 $2\" in \"rev-list --format=%T\") sleep 1.5;; notes*) sleep 1;; esac",
      )
      let report = prePushHook(
        a.dir, "", remote, pushLine(tip, zeros()), StoreRoots(user: a.store), options
      )
      checkpoint report.problems.join("\n")
      check not report.propagated
      check not (report.publishRan and report.published.ok)
      check not report.pushRan
      check noteKeys(remote).len == 0

    test "a_git_that_ignores_the_variable_is_stopped_at_a_tree_it_lacks":
      # The tree read of a declared scope in a tree:0 clone: only the deadline
      # ends it, because this git makes the fetch the variable forbids.
      let scratch = scratchDir()
      defer:
        cleanup(scratch)
      let (remote, seed) = seedRemote(scratch)
      let p = newPartialClone(scratch, remote, "partial", "tree:0")
      discard commitFile(seed, "g", "moved on\n")
      check push(seed, "-q", "origin", "HEAD:refs/heads/main").exitCode == 0
      discard gitIn(p.dir, ["fetch", "-q", "origin"])
      let fetched = gitIn(p.dir, ["rev-parse", "origin/main"]).strip()
      let tree = gitIn(p.dir, ["log", "-1", "--format=%T", fetched]).strip()
      check isAbsent(p, tree)
      discard gitIn(p.dir, ["config", "testCertificatesScope.s.path", "src"])
      certify(p, repeat('a', 40)) # The store holds something, not for this tree.
      stalled(p)
      let started = getMonoTime()
      let report = prePushHook(
        p.dir,
        "",
        remote,
        pushLine(fetched, zeros()),
        StoreRoots(user: p.store),
        ignoringLazyFetchVariable(scratch),
      )
      let took = millisSince(started)
      checkpoint report.problems.join("\n")
      check took < WithinBudgetMs
      check not report.propagated
      check not report.pushRan
