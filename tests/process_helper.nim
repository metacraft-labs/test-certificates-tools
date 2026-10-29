## A small program ``t_process`` starts through ``git.runProcess``, so the
## same process tests run on POSIX and on Windows, where ``/bin/sh`` does not
## exist. It is a real child process, not a mock: each mode does one thing a
## real ``git`` (or a helper ``git`` starts) does.
##
## Modes (the first argument):
##
## * ``args`` — write every further argument followed by a NUL.
## * ``cat`` — copy standard input to standard output, then write as many
##   ``e`` bytes to standard error.
## * ``exit <n>`` — exit with status ``n``.
## * ``pwd`` — write the working directory.
## * ``env <name>`` — write the variable's value.
## * ``sleep <ms>`` — sleep.
## * ``handle <n>`` — write ``open`` or ``closed``: whether the descriptor
##   (POSIX) or handle value (Windows) ``n`` is open in this process.
## * ``tree <ms> <pidfile>`` — start ``sleep <ms>`` as a grandchild that
##   keeps this process's standard streams, write its pid to ``pidfile``,
##   then sleep ``<ms>``: git with an ``ssh`` that will not exit.
## * ``detach <ms> <pidfile>`` — start ``sleep <ms>`` as a grandchild with
##   none of this process's streams or handles, write its pid, and exit:
##   a daemon (``credential-cache``, an ``ssh`` control master).
## * ``runner <ms> <pidfile> <treepidfile>`` — write this process's pid to
##   ``pidfile``, then run ``tree <ms> <treepidfile>`` through
##   ``runProcess`` with a time limit of a minute, and report the result.

import std/[os, osproc, strutils]
import test_certificates/git

when defined(windows):
  import std/[widestrs, winlean]

  proc helperGetHandleInformation(
    h: Handle, flags: ptr DWORD
  ): WINBOOL {.stdcall, dynlib: "kernel32", importc: "GetHandleInformation".}

else:
  import std/posix

proc writeAtomically(path, text: string) =
  writeFile(path & ".tmp", text)
  moveFile(path & ".tmp", path)

proc detachSleep(ms: string): int =
  ## Start ``<self> sleep <ms>`` with no inherited stream or handle; its pid.
  when defined(windows):
    var si: STARTUPINFO
    si.cb = int32(sizeof(si))
    var pi: PROCESS_INFORMATION
    let cmd = newWideCString("\"" & getAppFilename() & "\" sleep " & ms)
    const DetachedProcess = 0x8'i32
    if createProcessW(nil, cmd, nil, nil, 0, DetachedProcess, nil, nil, si, pi) == 0:
      raiseOSError(osLastError(), "CreateProcessW")
    discard closeHandle(pi.hThread)
    discard closeHandle(pi.hProcess)
    int(pi.dwProcessId)
  else:
    let pid = fork()
    if pid < 0:
      raiseOSError(osLastError(), "fork")
    if pid == 0:
      let null = open("/dev/null", O_RDWR)
      discard dup2(null, 0)
      discard dup2(null, 1)
      discard dup2(null, 2)
      discard setsid()
      let argv = allocCStringArray([getAppFilename(), "sleep", ms])
      discard execv(getAppFilename().cstring, argv)
      exitnow(127)
    int(pid)

proc main(): int =
  let args = commandLineParams()
  if args.len == 0:
    stderr.writeLine "process_helper: no mode"
    return 2
  case args[0]
  of "args":
    for a in args[1 ..^ 1]:
      stdout.write a
      stdout.write '\0'
  of "cat":
    let data = stdin.readAll()
    stdout.write data
    stdout.flushFile()
    stderr.write repeat('e', data.len)
  of "exit":
    return parseInt(args[1])
  of "pwd":
    stdout.write getCurrentDir()
  of "env":
    stdout.write getEnv(args[1])
  of "sleep":
    sleep(parseInt(args[1]))
  of "handle":
    let n = parseInt(args[1])
    when defined(windows):
      var flags: DWORD
      stdout.write(
        if helperGetHandleInformation(Handle(n), addr flags) != 0: "open" else: "closed"
      )
    else:
      stdout.write(if fcntl(cint(n), F_GETFD) != -1: "open" else: "closed")
  of "tree":
    let child = startProcess(
      getAppFilename(), args = ["sleep", args[1]], options = {poParentStreams}
    )
    writeAtomically(args[2], $child.processID)
    sleep(parseInt(args[1]))
  of "detach":
    writeAtomically(args[2], $detachSleep(args[1]))
  of "runner":
    writeAtomically(args[2], $getCurrentProcessId())
    let run = runProcess(
      getAppFilename(), ["tree", args[1], args[3]], getCurrentDir(), timeoutMs = 60_000
    )
    stdout.write "started=" & $run.started & " failure=" & run.failure
  else:
    stderr.writeLine "process_helper: unknown mode " & args[0]
    return 2
  0

quit main()
