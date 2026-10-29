## process: ``git.runProcess``, the one place this package starts a process,
## against real ``/bin/sh`` children. No mocks.
##
## * only_the_three_standard_streams_reach_the_child — no other descriptor
##   of this process is inherited, so neither is one of our pipes.
## * a_detached_grandchild_does_not_hold_the_run_open — a background process
##   that redirects its standard streams (an ``ssh`` control master, a
##   credential-cache daemon) must not keep our pipes open; a leaked copy
##   of a pipe end above 2 would make the run wait for it to exit.
## * exit statuses, a signal, the working directory, a missing executable,
##   a large input and output at once, and the time limit.
##
## POSIX only: the Windows path reads the pipes in turn with ``osproc``.

import std/[monotimes, os, strutils, times, unittest]
import test_certificates/git

when not defined(windows):
  proc elapsedMs(since: MonoTime): int64 =
    (getMonoTime() - since).inMilliseconds

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
