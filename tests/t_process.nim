## process: ``git.runProcess``, the one place this package starts a process,
## against real children: ``/bin/sh`` on POSIX, and on every platform
## ``tests/process_helper.nim``, a small program this file compiles first (see
## its header for what each mode does). No mocks.
##
## Everywhere:
##
## * only_the_standard_streams_reach_the_child — a handle (Windows) or
##   descriptor (POSIX) this process holds open and inheritable is not open
##   in the child; positive control: ``osproc.startProcess`` passes it on.
## * arguments_arrive_exactly_as_given — quoting (Windows: the Microsoft C
##   runtime's rules), spaces, quotes, backslashes, empty arguments, UTF-8.
## * exit statuses, the working directory, the environment, a missing
##   executable, a large input and output at once.
## * a_detached_grandchild_does_not_hold_the_run_open.
## * the_time_limit_stops_the_child_and_everything_it_started — a helper
##   (``tree``) that keeps the pipes is stopped with its grandchild, and the
##   run answers within the limit plus the stop's grace.
## * a_sink_receives_the_output_and_can_stop_the_child.
##
## POSIX only (each says why where it is declared):
##
## * the ``/bin/sh`` checks of descriptors 3..63, signals and SIGTERM-ignoring
##   children;
## * an_interrupt_stops_the_childs_process_group — SIGINT to a process
##   running a timed child stops the child's whole group before the signal
##   takes effect.

import std/[monotimes, os, osproc, streams, strutils, times, unittest]
import test_certificates/[git, work_refs]

when defined(windows):
  import std/winlean
else:
  import std/posix

proc elapsedMs(since: MonoTime): int64 =
  (getMonoTime() - since).inMilliseconds

let helper = block:
  let root = currentSourcePath().parentDir.parentDir
  let exe = root / "build" / "tests" / "process_helper".addFileExt(ExeExt)
  let compile = runProcess(
    getCurrentCompilerExe(),
    [
      "c",
      "--hints:off",
      "-d:release",
      "-o:" & exe,
      root / "tests" / "process_helper.nim",
    ],
    root,
  )
  if not compile.started or compile.exitCode != 0:
    stderr.writeLine "FATAL: could not build the process helper: " & compile.failure &
      compile.stdout & compile.stderr
    quit 1
  exe

proc readPid(path: string, waitMs = 10_000): int =
  ## The pid a helper wrote to ``path``, waiting for it to appear.
  let until = getMonoTime() + initDuration(milliseconds = waitMs)
  while getMonoTime() < until:
    if fileExists(path):
      return parseInt(readFile(path).strip())
    sleep(20)
  raise newException(IOError, "no pid file at " & path)

proc gone(pid: int, waitMs = 3000): bool =
  ## The process has ended (reaped, by whoever its parent now is), within
  ## ``waitMs``.
  let until = getMonoTime() + initDuration(milliseconds = waitMs)
  while getMonoTime() < until:
    if not processExists(pid):
      return true
    sleep(20)
  false

suite "runProcess, every platform":
  test "only_the_standard_streams_reach_the_child":
    when defined(windows):
      # An inheritable handle of this process: a file opened with
      # bInheritHandle = TRUE.
      let path = getTempDir() / ("t-process-handle-" & $getCurrentProcessId())
      writeFile(path, "x")
      var sa = SECURITY_ATTRIBUTES(
        nLength: int32(sizeof(SECURITY_ATTRIBUTES)), bInheritHandle: 1
      )
      let h = createFileW(
        newWideCString(path),
        GENERIC_READ,
        FILE_SHARE_READ,
        addr sa,
        OPEN_EXISTING,
        0,
        0,
      )
      require h != INVALID_HANDLE_VALUE
      defer:
        discard closeHandle(h)
        removeFile(path)
      let value = $int(h)
    else:
      # A descriptor without close-on-exec, numbered well above any the
      # child opens itself.
      let opened = posix.open("/dev/null", O_RDONLY)
      require opened >= 0
      let fd = fcntl(opened, F_DUPFD, cint(57))
      discard posix.close(opened)
      require fd >= 57
      defer:
        discard posix.close(fd)
      let value = $fd
    let run = runProcess(helper, ["handle", value], getCurrentDir())
    check run.started
    check run.exitCode == 0
    check run.stdout == "closed"
    # Positive control: Nim's own startProcess passes it on.
    let control = startProcess(helper, args = ["handle", value], options = {})
    let controlOut = control.outputStream.readAll()
    discard control.waitForExit()
    control.close()
    check controlOut == "open"

  test "arguments_arrive_exactly_as_given":
    let args = @[
      "plain", "", "two words", "tab\there", "quote\"inside", "\"quoted\"",
      "back\\slash", "trailing\\", "trailing two\\\\", "\\\"", "a\\\\\"b",
      "ends with space ", "unicode é 字", "%PATH%", "$HOME", "*", "-c",
    ]
    let run = runProcess(helper, @["args"] & args, getCurrentDir())
    check run.exitCode == 0
    var got = run.stdout.split('\0')
    check got[^1] == ""
    got.setLen(got.len - 1)
    check got == args

  test "exit statuses, the working directory and the environment":
    check runProcess(helper, ["exit", "7"], getCurrentDir()).exitCode == 7
    check runProcess(helper, ["exit", "0"], getCurrentDir()).exitCode == 0
    let here = getCurrentDir()
    let there = getTempDir()
    let pwd = runProcess(helper, ["pwd"], there)
    check pwd.exitCode == 0
    check sameFile(pwd.stdout, there)
    check getCurrentDir() == here
    let envRun = runProcess(helper, ["env", "TC_PROBE"], here, [("TC_PROBE", "a b")])
    check envRun.stdout == "a b"

  test "a missing executable or directory is reported, not raised":
    let run = runProcess("no-such-executable-for-t-process", [], getCurrentDir())
    check not run.started
    check "could not run" in run.failure
    let nowhere =
      runProcess(helper, ["exit", "0"], getTempDir() / "no-such-directory-t-process")
    check not nowhere.started
    check "could not run" in nowhere.failure

  test "large input and output at once do not deadlock":
    let data = repeat("0123456789abcdef", 1 shl 16) # 1 MiB
    let run = runProcess(helper, ["cat"], getCurrentDir(), input = data)
    check run.exitCode == 0
    check run.stdout == data
    check run.stderr == repeat('e', data.len)

  test "a_detached_grandchild_does_not_hold_the_run_open":
    let marker = getTempDir() / ("t-process-detach-" & $getCurrentProcessId())
    removeFile(marker)
    let started = getMonoTime()
    let run = runProcess(helper, ["detach", "8000", marker], getCurrentDir())
    let took = started.elapsedMs
    let grandchild = readPid(marker)
    defer:
      removeFile(marker)
      when not defined(windows):
        discard kill(Pid(grandchild), SIGKILL)
    check run.started
    check run.exitCode == 0
    checkpoint "took " & $took & " ms"
    check took < 4000
    check processExists(grandchild)

  test "the_time_limit_stops_the_child_and_everything_it_started":
    let marker = getTempDir() / ("t-process-tree-" & $getCurrentProcessId())
    removeFile(marker)
    let started = getMonoTime()
    let run =
      runProcess(helper, ["tree", "30000", marker], getCurrentDir(), timeoutMs = 1500)
    let took = started.elapsedMs
    defer:
      removeFile(marker)
    check run.timedOut
    check not run.started
    check "did not finish within 1500 ms" in run.failure
    checkpoint "took " & $took & " ms"
    check took < 6000
    let grandchild = readPid(marker, 1000)
    check gone(grandchild)
    # Unlimited: the same child runs to its end.
    let quick = runProcess(helper, ["sleep", "200"], getCurrentDir())
    check quick.exitCode == 0 and not quick.timedOut

  test "a_sink_receives_the_output_and_can_stop_the_child":
    let data = repeat("line of output\n", 20_000)
    var received = ""
    let all = runProcess(
      helper,
      ["cat"],
      getCurrentDir(),
      input = data,
      onStdout = proc(chunk: openArray[char]): bool =
        for c in chunk:
          received.add c
        true,
    )
    check all.exitCode == 0
    check all.stdout == ""
    check received == data
    var pieces = 0
    let stopped = runProcess(
      helper,
      ["cat"],
      getCurrentDir(),
      input = data,
      onStdout = proc(chunk: openArray[char]): bool =
        inc pieces
        false,
    )
    check stopped.stopped
    check not stopped.started
    check pieces == 1

# POSIX only: these use /bin/sh, POSIX signals and process groups.
when not defined(windows):
  suite "runProcess":
    test "only_the_three_standard_streams_reach_the_child":
      # Every descriptor 3..63 the child has open; `[ -e /dev/fd/N ]` is
      # true exactly for an open one (on Linux through /proc/self/fd).
      let run = runProcess(
        "/bin/sh",
        [
          "-c",
          "fd=3; while [ $fd -lt 64 ]; do [ -e /dev/fd/$fd ] && echo $fd; fd=$((fd+1)); done; :",
        ],
        getCurrentDir(),
      )
      check run.started
      check run.exitCode == 0
      check run.stdout.strip() == ""
      # Positive control: an inherited descriptor is listed.
      let control = runProcess(
        "/bin/sh",
        [
          "-c",
          "exec 7</dev/null; fd=3; while [ $fd -lt 64 ]; do [ -e /dev/fd/$fd ] && echo $fd; fd=$((fd+1)); done; :",
        ],
        getCurrentDir(),
      )
      check control.stdout.strip() == "7"

    test "a_detached_grandchild_does_not_hold_the_run_open":
      let marker = getTempDir() / ("t-process-" & $getCurrentProcessId())
      let started = getMonoTime()
      let run = runProcess(
        "/bin/sh",
        [
          "-c", "sleep 8 </dev/null >/dev/null 2>&1 & echo $! >\"$0\"; echo started",
          marker,
        ],
        getCurrentDir(),
      )
      let took = started.elapsedMs
      try:
        discard execShellCmd("kill $(cat '" & marker & "') 2>/dev/null")
        removeFile(marker)
      except CatchableError:
        discard
      check run.started
      check run.exitCode == 0
      check run.stdout == "started\n"
      checkpoint "took " & $took & " ms"
      check took < 4000

    test "exit statuses, a signal and the working directory":
      check runProcess("/bin/sh", ["-c", "exit 7"], getCurrentDir()).exitCode == 7
      check runProcess("/bin/sh", ["-c", "kill -TERM $$"], getCurrentDir()).exitCode ==
        128 + 15
      let here = getCurrentDir()
      let there = getTempDir()
      let pwd = runProcess("pwd", ["-P"], there)
      check pwd.exitCode == 0
      check pwd.stdout.strip() == expandFilename(there)
      check getCurrentDir() == here
      let envRun = runProcess(
        "/bin/sh", ["-c", "printf %s \"$TC_PROBE\""], here, [("TC_PROBE", "a b")]
      )
      check envRun.stdout == "a b"

    test "a missing executable or directory is reported, not raised":
      let run = runProcess("no-such-executable-for-t-process", [], getCurrentDir())
      check not run.started
      check "could not run" in run.failure
      let nowhere =
        runProcess("/bin/sh", ["-c", "true"], "/no/such/directory/t-process")
      check not nowhere.started
      check "could not run" in nowhere.failure
      check runProcess("/bin/sh", ["-c", "true"], getCurrentDir()).exitCode == 0

    test "large input and output at once do not deadlock":
      let data = repeat("0123456789abcdef", 1 shl 16) # 1 MiB
      let run = runProcess(
        "/bin/sh", ["-c", "cat; cat >&2 </dev/null"], getCurrentDir(), input = data
      )
      check run.exitCode == 0
      check run.stdout == data

    test "the time limit stops a process that does not finish":
      let started = getMonoTime()
      let run =
        runProcess("/bin/sh", ["-c", "exec sleep 30"], getCurrentDir(), timeoutMs = 300)
      check run.timedOut
      check not run.started
      check "did not finish within 300 ms" in run.failure
      check started.elapsedMs < 5000
      # One that ignores SIGTERM is killed after the grace second.
      let stubborn = getMonoTime()
      let ignoring = runProcess(
        "/bin/sh",
        ["-c", "trap '' TERM; while :; do sleep 1; done"],
        getCurrentDir(),
        timeoutMs = 300,
      )
      check ignoring.timedOut
      check stubborn.elapsedMs < 5000

    test "an_interrupt_stops_the_childs_process_group":
      # POSIX only: Windows delivers a console Ctrl-C to every process on the
      # console, and the job object ends the child when this process does.
      let scratch = getTempDir() / ("t-process-int-" & $getCurrentProcessId())
      createDir(scratch)
      defer:
        removeDir(scratch)
      let runnerPidFile = scratch / "runner"
      let treePidFile = scratch / "tree"
      let started = getMonoTime()
      # `runProcess` blocks, so the signal is sent by a forked watcher once
      # the tree is up.
      let watcher = fork()
      if watcher == 0:
        let until = getMonoTime() + initDuration(seconds = 10)
        while getMonoTime() < until and not fileExists(treePidFile):
          sleep(20)
        if fileExists(runnerPidFile):
          discard kill(Pid(parseInt(readFile(runnerPidFile).strip())), SIGINT)
        exitnow(0)
      # The runner is started untimed (in this process group), so the signal
      # reaches it alone; it runs `tree` with a time limit, in a session of
      # its own.
      let outcome =
        runProcess(helper, ["runner", "30000", runnerPidFile, treePidFile], scratch)
      var status: cint
      discard waitpid(watcher, status, 0)
      let sent = fileExists(treePidFile)
      let runnerPid = readPid(runnerPidFile, 1000)
      let took = started.elapsedMs
      checkpoint "took " & $took & " ms; runner " & $runnerPid
      require sent
      # The runner died of the signal, after stopping its child's group.
      check outcome.exitCode == 128 + SIGINT
      check took < 8000
      let grandchild = readPid(treePidFile, 1000)
      check gone(grandchild)
