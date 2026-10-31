## Running git: one command, its exit status, and its stdout and stderr kept
## apart.
##
## The content-id recipes parse plumbing output (``write-tree``, ``ls-tree
## -z``, ``cat-file --batch``) that must not have warnings mixed into it, and
## some of them feed git a large standard input while it writes a large
## standard output (``cat-file --batch``). Writing all of the input before
## reading any output deadlocks as soon as both exceed a pipe buffer, so the
## three pipes are serviced together: with ``poll(2)`` on POSIX, with
## overlapped I/O and ``WaitForMultipleObjects`` on Windows
## (``windows_process``). No shell is involved anywhere: arguments reach git
## exactly as given.

import std/[monotimes, os, strtabs, strutils, times]

when defined(windows):
  import ./windows_process
else:
  import std/posix

const DefaultGitExe* = "git"
  ## The git a command runs unless its caller names another: the first
  ## ``git`` on ``PATH``.

type
  OutputSink* = proc(data: openArray[char]): bool {.closure.}
    ## Receives a process's standard output piece by piece as it arrives
    ## (``runProcess(onStdout = …)``); answers false to stop the process.

  GitRun* = object
    started*: bool ## False when git could not be run at all.
    exitCode*: int
    stdout*: string
    stderr*: string
    failure*: string ## Why it could not be started; "" when it was.
    timedOut*: bool
      ## It ran past its time limit and was stopped. ``started`` is then
      ## false and ``failure`` says so, so every caller that handles "could
      ## not run" handles this too.
    stopped*: bool
      ## The ``onStdout`` sink asked to stop, and the process was stopped.
      ## ``started`` is then false, as for ``timedOut``.

  Deadline* = object
    ## A point in time by which a sequence of commands must be done, or no
    ## limit at all (the default value).
    limited*: bool
    at*: MonoTime

  GitStep* = object
    ok*: bool
    stdout*: string
    failure*: string ## A sentence naming the command and why it failed.

proc deadlineIn*(ms: int): Deadline =
  ## ``ms`` milliseconds from now; no limit when ``ms`` is 0 or less.
  if ms <= 0:
    return Deadline()
  Deadline(limited: true, at: getMonoTime() + initDuration(milliseconds = ms))

proc expired*(d: Deadline): bool =
  d.limited and getMonoTime() >= d.at

proc remainingMs*(d: Deadline): int =
  ## The time left, for ``runProcess(timeoutMs = …)``: 0 (no limit) when
  ## unlimited, and at least 1 otherwise, so a limited deadline never turns
  ## into "no limit" by running out.
  if not d.limited:
    return 0
  max(1, int((d.at - getMonoTime()).inMilliseconds))

proc childEnvironment(overrides: openArray[(string, string)]): StringTableRef =
  ## This process's environment with ``overrides`` applied. Names are
  ## case-insensitive on Windows (``Path`` and ``PATH`` are one variable), so
  ## an override there replaces the variable whatever its spelling.
  result =
    newStringTable(when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  for (key, value) in overrides:
    result[key] = value

when defined(windows):
  proc environmentPairs(table: StringTableRef): seq[(string, string)] =
    for key, value in table:
      result.add (key, value)

when not defined(windows):
  proc writeWithoutSigpipe(fd: cint, data: pointer, len: int): int =
    ## ``write(2)`` to a pipe whose reader may have gone, without letting
    ## SIGPIPE kill the calling process and without changing the process-wide
    ## signal disposition (which belongs to the program linking this library).
    ## SIGPIPE is blocked in this thread for the write; one it raised is
    ## consumed before the mask is restored, unless it was already pending.
    ## See write(2) ("EPIPE ... A SIGPIPE signal shall also be sent to the
    ## thread") and sigwait(2) in POSIX.1-2024:
    ## https://pubs.opengroup.org/onlinepubs/9799919799/functions/write.html
    var blockSet, oldSet, pendingBefore: Sigset
    discard sigemptyset(blockSet)
    discard sigaddset(blockSet, SIGPIPE)
    discard sigpending(pendingBefore)
    let wasPending = sigismember(pendingBefore, SIGPIPE) == 1
    discard pthread_sigmask(SIG_BLOCK, blockSet, oldSet)
    result = write(fd, data, len)
    let savedErrno = errno
    if result < 0 and savedErrno == EPIPE and not wasPending:
      # `sigwait` returns at once for a pending signal. It is used rather
      # than `sigtimedwait`, which macOS does not provide; the `sigpending`
      # check makes sure it can never block.
      var pendingNow: Sigset
      discard sigpending(pendingNow)
      if sigismember(pendingNow, SIGPIPE) == 1:
        var consumed: cint
        discard sigwait(blockSet, consumed)
    discard pthread_sigmask(SIG_SETMASK, oldSet, blockSet)
    errno = savedErrno

when not defined(windows):
  # Process spawning on POSIX is done here rather than with `osproc`, whose
  # `startProcess` creates its pipes without close-on-exec and, after
  # `dup2`-ing them onto the child's 0, 1 and 2, never closes the originals
  # (Nim 2.2 `osproc.startProcessAuxSpawn` / `startProcessAfterFork`). The
  # child therefore holds a second copy of every pipe end on a descriptor
  # above 2, and passes it on to everything it starts: an `ssh` control
  # master, a `credential-cache` daemon, a remote helper. Such a process,
  # which detaches and redirects its standard streams, still holds our
  # stdout and stderr pipes open, so reading them to the end waits for it to
  # exit — a push that hangs on a background process the user never sees.
  # Here every pipe end is close-on-exec, only the `dup2`ed copies on 0, 1
  # and 2 (which `dup2` makes inheritable) reach the child, and the child
  # closes every other descriptor before `execve` (`closeOtherDescriptors`),
  # so not even one the program linking this library opened without
  # close-on-exec is passed on.
  #
  # `fork` + `execve` rather than `posix_spawn`: the child must start in
  # `cwd`, and `posix_spawn_file_actions_addchdir_np` is missing from the
  # glibc 2.28 the release binaries are linked against (it came in 2.29),
  # while changing this process's own directory around the spawn would race
  # every other thread of the program linking this library. Between `fork`
  # and `execve` the child calls only async-signal-safe functions.
  # pipe2(2): https://man7.org/linux/man-pages/man2/pipe.2.html
  # fork(2): https://pubs.opengroup.org/onlinepubs/9799919799/functions/fork.html

  when defined(linux) or defined(freebsd) or defined(netbsd) or defined(openbsd):
    proc pipe2(
      fds: var array[2, cint], flags: cint
    ): cint {.importc, header: "<unistd.h>".}

  proc closeOnExecPipe(): array[2, cint] =
    ## A pipe whose two ends are close-on-exec and above 2: a pipe end on 0,
    ## 1 or 2 (possible when this process was started with one of them
    ## closed) would be `dup2`ed onto itself in the child, which keeps the
    ## close-on-exec flag and loses the stream.
    var fds: array[2, cint]
    when declared(pipe2):
      if pipe2(fds, O_CLOEXEC) != 0:
        raiseOSError(osLastError(), "pipe2")
    else:
      # No `pipe2` (macOS): the flag is set right after. A process forked by
      # another thread in between could inherit these two ends; this library
      # never starts processes from more than one thread at once.
      if pipe(fds) != 0:
        raiseOSError(osLastError(), "pipe")
      for fd in fds:
        discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    for i in 0 .. 1:
      if fds[i] <= 2:
        let moved = fcntl(fds[i], F_DUPFD_CLOEXEC, cint(3))
        let err = osLastError()
        discard close(fds[i])
        if moved < 0:
          discard close(fds[1 - i])
          raiseOSError(err, "fcntl(F_DUPFD_CLOEXEC)")
        fds[i] = moved
    fds

  proc searchPath(exe: string): string =
    ## ``exe`` as ``execvp`` would find it: as given when it names a path,
    ## else the first executable file of that name in a ``PATH`` directory
    ## (an empty entry is the current directory, as POSIX specifies). Unlike
    ## ``os.findExe``, the current directory is never searched first. ""
    ## when there is none.
    if '/' in exe:
      return exe
    for dir in getEnv("PATH", "/usr/bin:/bin").split(':'):
      let candidate = (if dir.len == 0: "." else: dir) & "/" & exe
      if fileExists(candidate) and access(candidate.cstring, X_OK) == 0:
        return candidate

  type
    Spawned = object
      pid: Pid
      stdinFd, stdoutFd, stderrFd: cint ## Our ends of the three pipes.

    ChildPlan = object ## Everything the forked child needs, prepared before ``fork``.
      path, cwd: cstring
      argv, envp: cstringArray
      stdinFd, stdoutFd, stderrFd, reportFd: cint
      ownSession: bool ## Start a new session (and process group) first.
      parent: Pid ## This process, to notice having been orphaned already.
      maxFd: cint ## Descriptors below this are closed in the child (3 and up).

  when defined(linux):
    const PrSetPdeathsig = cint(1) ## prctl(2) option.
    proc prctl(
      option: cint, arg: culong
    ): cint {.importc, header: "<sys/prctl.h>", varargs.}

  when defined(linux):
    const SysCloseRange = clong(436)
      ## close_range(2); the same on every Linux architecture.
    proc syscall(number: clong): clong {.importc, header: "<unistd.h>", varargs.}

  const DescriptorLimitCap = 65536
    ## The most descriptors closed one by one where close_range(2) is missing.

  proc descriptorLimit(): cint =
    ## One above the highest descriptor this process can have open (its
    ## RLIMIT_NOFILE soft limit), capped at ``DescriptorLimitCap``.
    var limit: RLimit
    if getrlimit(RLIMIT_NOFILE, limit) != 0:
      return DescriptorLimitCap
    # `std/posix` declares the field `int`, but C's `rlim_t` is unsigned. Any
    # comparison or range check made on the field itself is compiled as an
    # unsigned C comparison against the bounds, so `cint(65536)` failed its
    # check and `<= 0` missed RLIM_INFINITY. Copy it into a real signed local
    # first; RLIM_INFINITY (all ones) then reads as negative, i.e. unlimited.
    let current = cast[int64](limit.rlim_cur)
    if current <= 0 or current > DescriptorLimitCap:
      return DescriptorLimitCap
    cint(current)

  {.push stackTrace: off, profiler: off.}
  proc closeOtherDescriptors(keep, limit: cint) =
    ## In the forked child: close every descriptor from 3 up, except ``keep``
    ## (the close-on-exec report pipe), so the program receives its three
    ## standard streams and nothing else this process had open without
    ## close-on-exec — the guarantee the Windows handle list gives there.
    ## close_range(2) (Linux 5.9) in two calls around ``keep``; otherwise, or
    ## where it is refused, one ``close`` per possible descriptor.
    ## https://man7.org/linux/man-pages/man2/close_range.2.html
    when defined(linux):
      if (keep <= 3 or syscall(SysCloseRange, cuint(3), cuint(keep - 1), cuint(0)) == 0) and
          syscall(SysCloseRange, cuint(keep + 1), high(cuint), cuint(0)) == 0:
        return
    var fd: cint = 3
    while fd < limit:
      if fd != keep:
        discard close(fd)
      inc fd

  proc runChild(plan: ptr ChildPlan) {.noreturn.} =
    ## The forked child, up to ``execve``: async-signal-safe calls only, no
    ## allocation. A failure is written to ``reportFd`` as an errno.
    template fail() =
      var code = errno
      discard write(plan.reportFd, addr code, sizeof(code))
      exitnow(127)

    if dup2(plan.stdinFd, 0) < 0 or dup2(plan.stdoutFd, 1) < 0 or
        dup2(plan.stderrFd, 2) < 0:
      fail()
    closeOtherDescriptors(plan.reportFd, plan.maxFd)
    if plan.cwd[0] != '\0' and chdir(plan.cwd) < 0:
      fail()
    if plan.ownSession:
      # Its own session and process group, so that stopping it reaches every
      # process it started (see `runProcess`).
      if setsid() < 0:
        fail()
      when defined(linux):
        # SIGKILL when the thread that started it dies; if that already
        # happened, it would never be delivered.
        if prctl(PrSetPdeathsig, culong(SIGKILL)) < 0:
          fail()
        if getppid() != plan.parent:
          exitnow(127)
    # No signal blocked (this thread may be blocking SIGPIPE, see
    # `writeWithoutSigpipe`), and SIGPIPE at its default, which an ignored
    # disposition here would otherwise pass on through `execve`.
    var none: Sigset
    discard sigemptyset(none)
    discard sigprocmask(SIG_SETMASK, none, none)
    signal(SIGPIPE, SIG_DFL)
    discard execve(plan.path, plan.argv, plan.envp)
    fail()

  {.pop.}

  proc spawnPiped(
      exe: string,
      args: openArray[string],
      cwd: string,
      env: StringTableRef,
      ownSession = false,
  ): Spawned =
    ## Start ``exe`` (searched on ``PATH`` when it has no slash) with its
    ## standard streams on fresh pipes, in ``cwd``, with exactly ``env``.
    ## Raises ``OSError`` when it cannot be started.
    let path = searchPath(exe)
    if path.len == 0:
      raiseOSError(OSErrorCode(ENOENT), exe & " (not found on PATH)")
    var created: seq[cint]
    template closeAll() =
      for fd in created:
        if fd >= 0:
          discard close(fd)

    var inPipe, outPipe, errPipe, report: array[2, cint]
    try:
      inPipe = closeOnExecPipe()
      created.add inPipe
      outPipe = closeOnExecPipe()
      created.add outPipe
      errPipe = closeOnExecPipe()
      created.add errPipe
      report = closeOnExecPipe()
      created.add report
    except OSError:
      closeAll()
      raise

    var argv = @[exe]
    argv.add args
    var envList: seq[string]
    for key, value in env:
      envList.add key & "=" & value
    var plan = ChildPlan(
      path: path.cstring,
      cwd: cwd.cstring,
      argv: allocCStringArray(argv),
      envp: allocCStringArray(envList),
      stdinFd: inPipe[0],
      stdoutFd: outPipe[1],
      stderrFd: errPipe[1],
      reportFd: report[1],
      ownSession: ownSession,
      parent: getpid(),
      maxFd: descriptorLimit(),
    )
    let pid = fork()
    if pid == 0:
      runChild(addr plan)
    let forkError = osLastError()
    deallocCStringArray(plan.argv)
    deallocCStringArray(plan.envp)
    if pid < 0:
      closeAll()
      raiseOSError(forkError, "fork")
    # The child's ends now live only in the child.
    discard close(inPipe[0])
    discard close(outPipe[1])
    discard close(errPipe[1])
    discard close(report[1])
    # The report pipe closes on `execve`: end of file is success, an errno
    # is a failure before it.
    var code: cint = 0
    var got = 0
    while true:
      got = read(report[0], addr code, sizeof(code))
      if got < 0 and errno == EINTR:
        continue
      break
    discard close(report[0])
    if got == sizeof(code):
      discard close(inPipe[1])
      discard close(outPipe[0])
      discard close(errPipe[0])
      var status: cint
      while waitpid(pid, status, 0) < 0 and errno == EINTR:
        discard
      raiseOSError(OSErrorCode(code), exe)
    result.pid = pid
    result.stdinFd = inPipe[1]
    result.stdoutFd = outPipe[0]
    result.stderrFd = errPipe[0]

  proc reap(pid: Pid, options: cint): tuple[done: bool, status: cint] =
    ## ``waitpid`` that retries on EINTR. ``done`` false: still running
    ## (with WNOHANG), or not ours to wait for.
    while true:
      var status: cint = 0
      let r = waitpid(pid, status, options)
      if r == pid:
        return (true, status)
      if r < 0 and errno == EINTR:
        continue
      return (false, 0)

when not defined(windows):
  template forwardedSignals(): untyped =
    ## Signals that end this process by default and that a terminal or a
    ## supervisor sends to stop it. While a child of its own session runs,
    ## they are held and passed on to that child's group first. A template,
    ## not a constant: on macOS `std/posix` imports the signal numbers as
    ## variables, which a constant cannot be built from.
    [SIGINT, SIGTERM, SIGHUP]

  const
    InterruptPollMs = 100
      ## How often a pending forwarded signal is looked for while the child
      ## runs (``poll`` is not woken by a blocked signal).
    StopGraceMs = 1000 ## Between the first signal to a stopped child and SIGKILL.

  when defined(linux):
    var
      cWEXITED {.importc: "WEXITED", header: "<sys/wait.h>".}: cint
      cWNOWAIT {.importc: "WNOWAIT", header: "<sys/wait.h>".}: cint
      cP_PID {.importc: "P_PID", header: "<sys/wait.h>".}: cint
    proc waitid(
      idtype: cint, id: Id, info: var SigInfo, options: cint
    ): cint {.importc, header: "<sys/wait.h>".}

  proc exitedUnreaped(pid: Pid): tuple[known, exited: bool] =
    ## Whether the child has exited, WITHOUT reaping it: its pid (and so its
    ## process-group id) stays allocated to the zombie until ``reap``.
    ## ``known`` false where that cannot be asked (not Linux).
    ## https://man7.org/linux/man-pages/man2/waitid.2.html
    when defined(linux):
      while true:
        var info: SigInfo
        zeroMem(addr info, sizeof(info))
        if waitid(cP_PID, Id(pid), info, cWEXITED or WNOHANG or cWNOWAIT) == 0:
          return (true, info.si_pid == pid)
        if errno != EINTR:
          return (false, false)
    else:
      (false, false)

  proc stopChild(
      pid: Pid, group: bool, first: cint, reaped: var bool, status: var cint
  ) =
    ## Send ``first`` to the child (to its whole process group with
    ## ``group``), wait up to ``StopGraceMs`` for it to exit, then SIGKILL,
    ## and reap it. With ``group``, what is left of the group gets SIGKILL
    ## too: helpers that outlive their ``git`` still hold its pipes past the
    ## budget. The group id is the child's pid (it is a session leader). That
    ## last SIGKILL is sent while the child is not yet reaped where that can
    ## be told (Linux, ``exitedUnreaped``), so the id cannot have been reused
    ## by a stranger; elsewhere it follows the reap, and POSIX does not reuse
    ## a pid while a process group of that id still has members.
    let target =
      if group:
        Pid(-pid)
      else:
        pid
    if reaped:
      return
    discard kill(target, first)
    let graceEnds = deadlineIn(StopGraceMs)
    while not reaped and not graceEnds.expired:
      let peek = exitedUnreaped(pid)
      if peek.known:
        if peek.exited:
          break
        sleep(10)
        continue
      let exited = reap(pid, WNOHANG)
      if exited.done:
        reaped = true
        status = exited.status
      else:
        sleep(10)
    if not reaped:
      # The child, alive or a zombie, still holds its pid and group id.
      discard kill(target, SIGKILL)
      status = reap(pid, 0).status
      reaped = true
    elif group:
      # Reaped already (not Linux): only the group's remaining members can
      # hold the id now.
      discard kill(target, SIGKILL)

proc runProcess*(
    exe: string,
    args: openArray[string],
    cwd: string,
    env: openArray[(string, string)] = [],
    input = "",
    timeoutMs = 0,
    onStdout: OutputSink = nil,
): GitRun =
  ## Run ``exe`` with ``args`` in ``cwd``. ``env`` is added to (and overrides)
  ## this process's environment; nothing else is changed.
  ##
  ## The child receives its three standard streams and no other handle or
  ## descriptor of this process (POSIX: ``spawnPiped``; Windows:
  ## ``windows_process``), so a process it leaves running in the background
  ## holds our pipes open only if it keeps its own standard streams.
  ##
  ## ``onStdout``, when given, receives standard output as it arrives instead
  ## of ``stdout`` collecting it, so output of any size is processed in
  ## bounded memory. When it answers false the child is stopped and the run
  ## answered as ``stopped``.
  ##
  ## With ``timeoutMs`` > 0, a process still running after that many
  ## milliseconds is stopped together with everything it started, and the
  ## run is answered as ``timedOut``. Its output pipes are not drained after
  ## that: a helper it started (``ssh``, a credential helper) may still hold
  ## them open. A process that had already exited when the time ran out
  ## keeps its own answer.
  ##
  ## * POSIX: the child is started in a session of its own (``setsid``), and
  ##   is stopped with SIGTERM to its process group, then SIGKILL a second
  ##   later. While it runs, SIGINT, SIGTERM and SIGHUP (those the calling
  ##   thread does not already block) are held in this thread; one that
  ##   arrives is sent to the child's group, the group is stopped as above,
  ##   and the signal is then released to take its usual effect here — so a
  ##   Ctrl-C that interrupts a push does not leave the hook's ``git`` and
  ##   ``ssh`` running, unseen, after it. If the handler of the program
  ##   linking this library returns, the run is answered as interrupted. On
  ##   Linux the child also gets SIGKILL if this thread dies
  ##   (``PR_SET_PDEATHSIG``), for the deaths no handler sees. The new
  ##   session has no controlling terminal: a helper that would prompt on
  ##   ``/dev/tty`` (``ssh`` asking for a passphrase) fails at once and is
  ##   reported, instead of stopping on SIGTTIN in a background process group
  ##   until the budget is spent; ``GIT_TERMINAL_PROMPT=0`` already forbids
  ##   git's own prompts on every run.
  ## * Windows: the child runs in a Job Object, stopped with
  ##   ``TerminateJobObject``; see ``windows_process``.
  ##
  ## Without a time limit the child stays in this process's session and
  ## process group, so a terminal's Ctrl-C reaches it directly and it may
  ## prompt on the terminal as before.
  when defined(windows):
    let ran = runWindowsProcess(
      exe,
      args,
      cwd,
      environmentPairs(childEnvironment(env)),
      input,
      timeoutMs,
      onStdout,
    )
    GitRun(
      started: ran.started,
      exitCode: ran.exitCode,
      stdout: ran.stdout,
      stderr: ran.stderr,
      failure: ran.failure,
      timedOut: ran.timedOut,
      stopped: ran.stopped,
    )
  else:
    let timed = timeoutMs > 0
    # The forwarded signals this thread does not block already: held from
    # BEFORE the fork, so one that arrives while the child is being started
    # is not lost with the child left running (it is forwarded as soon as
    # the child's pid is known), and released (and so delivered) in
    # `finally`. The child unblocks every signal before `execve`, and a
    # forked child starts with no signal pending.
    var watched: Sigset
    var savedMask: Sigset
    var watching = false
    discard sigemptyset(watched)
    if timed:
      var none: Sigset
      discard sigemptyset(none)
      discard pthread_sigmask(SIG_BLOCK, none, savedMask)
      for s in forwardedSignals():
        if sigismember(savedMask, s) != 1:
          discard sigaddset(watched, s)
          watching = true
      if watching:
        discard pthread_sigmask(SIG_BLOCK, watched, none)
    var child: Spawned
    try:
      child = spawnPiped(exe, args, cwd, childEnvironment(env), ownSession = timed)
    except OSError as err:
      if watching:
        var unused: Sigset
        discard pthread_sigmask(SIG_SETMASK, savedMask, unused)
      return GitRun(failure: "could not run " & exe & ": " & err.msg)
    result.started = true
    var inFd = child.stdinFd
    var outFd = child.stdoutFd
    var errFd = child.stderrFd
    var reaped = false
    var status: cint = 0
    var interruptedBy: cint = 0
    try:
      var written = 0
      if input.len == 0:
        discard close(inFd)
        inFd = -1
      else:
        discard fcntl(inFd, F_SETFL, fcntl(inFd, F_GETFL) or O_NONBLOCK)
      var buffer = newString(65536)
      let deadline = deadlineIn(timeoutMs)
      block pump:
        while inFd >= 0 or outFd >= 0 or errFd >= 0:
          if watching:
            var pending: Sigset
            discard sigpending(pending)
            for s in forwardedSignals():
              if sigismember(watched, s) == 1 and sigismember(pending, s) == 1:
                interruptedBy = s
                break pump
          if deadline.expired:
            result.timedOut = true
            break
          var fds: seq[TPollfd]
          if inFd >= 0:
            fds.add TPollfd(fd: inFd, events: POLLOUT)
          if outFd >= 0:
            fds.add TPollfd(fd: outFd, events: POLLIN)
          if errFd >= 0:
            fds.add TPollfd(fd: errFd, events: POLLIN)
          var wait = if deadline.limited: deadline.remainingMs else: -1
          if watching:
            wait = min(wait, InterruptPollMs)
          let ready = poll(addr fds[0], Tnfds(fds.len), cint(wait))
          if ready < 0:
            if errno == EINTR:
              continue
            raiseOSError(osLastError(), "poll")
          for f in fds:
            if f.revents == 0:
              continue
            if f.fd == inFd:
              if (f.revents and (POLLERR or POLLHUP)) != 0:
                # The child stopped reading: its exit status says why.
                discard close(inFd)
                inFd = -1
                continue
              let n = writeWithoutSigpipe(
                inFd, unsafeAddr input[written], input.len - written
              )
              if n < 0:
                if errno in [EAGAIN, EWOULDBLOCK, EINTR]:
                  continue
                if errno == EPIPE:
                  discard close(inFd)
                  inFd = -1
                  continue
                raiseOSError(osLastError(), "write to " & exe)
              written += n
              if written >= input.len:
                discard close(inFd)
                inFd = -1
            else:
              let n = read(f.fd, addr buffer[0], buffer.len)
              if n < 0:
                if errno in [EAGAIN, EINTR]:
                  continue
                raiseOSError(osLastError(), "read from " & exe)
              if n == 0:
                discard close(f.fd)
                if f.fd == outFd:
                  outFd = -1
                else:
                  errFd = -1
              elif f.fd == outFd:
                if onStdout != nil:
                  if not onStdout(buffer.toOpenArray(0, n - 1)):
                    result.stopped = true
                    break pump
                else:
                  result.stdout.add buffer[0 ..< n]
              else:
                result.stderr.add buffer[0 ..< n]
      if interruptedBy != 0:
        stopChild(child.pid, timed, interruptedBy, reaped, status)
        result.started = false
        result.exitCode = -1
        result.failure =
          exe & " was stopped: this process received signal " & $interruptedBy
        return
      if result.stopped:
        stopChild(child.pid, timed, SIGTERM, reaped, status)
        result.started = false
        result.exitCode = -1
        result.failure = exe & " was stopped: its output was no longer wanted"
        return
      if result.timedOut:
        # It exited; a helper it left behind holds the pipes open past the
        # budget, and is ended — before the reap where that can be told
        # (see `stopChild`). Its own answer stands.
        let peek = exitedUnreaped(child.pid)
        if peek.known and peek.exited:
          discard kill(Pid(-child.pid), SIGKILL)
        let exited = reap(child.pid, WNOHANG)
        if exited.done:
          result.timedOut = false
          reaped = true
          status = exited.status
          if not peek.known:
            discard kill(Pid(-child.pid), SIGKILL)
      if result.timedOut:
        stopChild(child.pid, timed, SIGTERM, reaped, status)
        result.started = false
        result.exitCode = -1
        result.failure =
          exe & " did not finish within " & $timeoutMs & " ms and was stopped"
        return
      if not reaped:
        status = reap(child.pid, 0).status
        reaped = true
      result.exitCode = int(exitStatusLikeShell(status))
    except CatchableError as err:
      result.started = false
      result.failure = "talking to " & exe & " failed: " & err.msg
      if not reaped:
        stopChild(child.pid, timed, SIGKILL, reaped, status)
    finally:
      for fd in [inFd, outFd, errFd]:
        if fd >= 0:
          discard close(fd)
      if watching:
        # A held signal is delivered here, with the child already stopped.
        var unused: Sigset
        discard pthread_sigmask(SIG_SETMASK, savedMask, unused)

const PathspecEnvironment* = [
  # Scope paths are passed with `--literal-pathspecs` (Content-Id §4.1:
  # "Pathspecs MUST be literal"); an inherited setting must not fight that
  # flag or make matching case-insensitive.
  ("GIT_GLOB_PATHSPECS", "0"),
  ("GIT_NOGLOB_PATHSPECS", "0"),
  ("GIT_ICASE_PATHSPECS", "0"),
  # Read-only commands such as `git status` opportunistically rewrite the
  # index they read (refreshing stat data). Nothing here may write the
  # user's index, so no optional write is wanted anywhere.
  ("GIT_OPTIONAL_LOCKS", "0"),
  # A library call must never stop to ask for credentials on a terminal:
  # `notes push` and `notes fetch` talk to remotes, and a hook or a CI job
  # has nobody to answer. A remote that needs credentials it cannot get
  # fails, and the failure is reported.
  ("GIT_TERMINAL_PROMPT", "0"),
]

const NoLazyFetch* = ("GIT_NO_LAZY_FETCH", "1")
  ## For a command's ``env``: it answers from this repository's objects alone.
  ## In a partial clone git otherwise fetches an absent object from the
  ## promisor remote, inside commands that look purely local (``rev-parse``,
  ## ``write-tree``), with no time limit of their own; a child process inherits
  ## the variable.
  ## See GIT_NO_LAZY_FETCH in https://git-scm.com/docs/git
  ##
  ## The variable rather than the ``--no-lazy-fetch`` option, because a git
  ## that predates the feature ignores a variable but stops with "unknown
  ## option" at an option, which would break every command here. Measured:
  ## git 2.42.2, 2.44.2 and 2.53.0 honour the variable, 2.38.5 ignores it. Such
  ## a git still lazy-fetches, so a caller with a time budget does not rely on
  ## this alone (``hook.peeledCommit``).

proc gitRun*(
    cwd: string,
    args: openArray[string],
    indexFile = "",
    input = "",
    env: openArray[(string, string)] = [],
    timeoutMs = 0,
    onStdout: OutputSink = nil,
    gitExe = DefaultGitExe,
): GitRun =
  ## Run ``git <args>`` in ``cwd`` and answer everything it did: its exit
  ## status, stdout and stderr, apart. For the callers that must tell one
  ## failure from another (``push --porcelain`` reports a rejected ref on
  ## stdout with a non-zero status); every other caller uses ``git``.
  ## ``env`` is added to the fixed environment above, and may override it.
  ##
  ## With ``indexFile``, git reads and writes that index instead of the
  ## repository's, with the split index and the filesystem monitor off for
  ## the command (both would otherwise make git write outside, or trust state
  ## from outside, the temporary index).
  ##
  ## ``gitExe`` is the git to run: a path, or a name looked up on ``PATH``.
  ## A program embedding this library that has resolved its own git (a build
  ## tool that pins one) passes it, so the library never runs a different
  ## git than its caller does. "" means ``DefaultGitExe``.
  var environment = @PathspecEnvironment
  var argv: seq[string]
  if indexFile.len > 0:
    environment.add ("GIT_INDEX_FILE", indexFile)
    argv.add ["-c", "core.splitIndex=false", "-c", "core.fsmonitor=false"]
  environment.add env
  argv.add args
  runProcess(
    if gitExe.len == 0: DefaultGitExe else: gitExe,
    argv,
    cwd,
    environment,
    input,
    timeoutMs,
    onStdout,
  )

proc git*(
    cwd: string,
    args: openArray[string],
    indexFile = "",
    input = "",
    env: openArray[(string, string)] = [],
    timeoutMs = 0,
    gitExe = DefaultGitExe,
): GitStep =
  ## Run ``git <args>`` in ``cwd`` (see ``gitRun``): success with its
  ## stdout, or a sentence naming the command, its status and its stderr.
  let run = gitRun(cwd, args, indexFile, input, env, timeoutMs, gitExe = gitExe)
  let shown = "`git " & args.join(" ") & "`"
  if not run.started:
    return GitStep(failure: "could not run " & shown & ": " & run.failure)
  if run.exitCode != 0:
    return GitStep(
      failure: shown & " failed (exit " & $run.exitCode & "): " & run.stderr.strip()
    )
  GitStep(ok: true, stdout: run.stdout)

proc singleLine*(output: string): string =
  ## The one line a plumbing command printed, without its terminator only:
  ## a path may legitimately end in spaces.
  result = output
  result.stripLineEnd()

proc nulRecords*(output: string): seq[string] =
  ## Split ``-z`` output. The final record is NUL-terminated, so the empty
  ## string after it is not a record.
  if output.len == 0:
    return @[]
  result = output.split('\0')
  if result[^1].len == 0:
    result.setLen(result.len - 1)
