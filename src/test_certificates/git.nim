## Running git: one command, its exit status, and its stdout and stderr kept
## apart.
##
## The content-id recipes parse plumbing output (``write-tree``, ``ls-tree
## -z``, ``cat-file --batch``) that must not have warnings mixed into it, and
## some of them feed git a large standard input while it writes a large
## standard output (``cat-file --batch``). Writing all of the input before
## reading any output deadlocks as soon as both exceed a pipe buffer, so on
## POSIX the three pipes are serviced together with ``poll(2)``. No shell is
## involved anywhere: arguments reach git exactly as given.
##
## Windows has no ``poll`` over anonymous pipes; there the input is written
## first, then stdout and stderr are drained in turn. The recipes in this
## package keep each input small enough (one blob per ``cat-file`` request
## there) that this cannot block.

import std/[monotimes, os, strtabs, strutils, times]

when defined(windows):
  import std/[osproc, streams]
else:
  import std/posix

type
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
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  for (key, value) in overrides:
    result[key] = value

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
  # Here every pipe end is close-on-exec, and only the `dup2`ed copies on 0,
  # 1 and 2 (which `dup2` makes inheritable) reach the child.
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

  {.push stackTrace: off, profiler: off.}
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
    if plan.cwd[0] != '\0' and chdir(plan.cwd) < 0:
      fail()
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
      exe: string, args: openArray[string], cwd: string, env: StringTableRef
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

proc runProcess*(
    exe: string,
    args: openArray[string],
    cwd: string,
    env: openArray[(string, string)] = [],
    input = "",
    timeoutMs = 0,
): GitRun =
  ## Run ``exe`` with ``args`` in ``cwd``. ``env`` is added to (and overrides)
  ## this process's environment; nothing else is changed.
  ##
  ## On POSIX the child receives its three standard streams and no other
  ## descriptor of this process (see ``spawnPiped``), so a process it leaves
  ## running in the background holds our pipes open only if it keeps its
  ## own standard streams.
  ##
  ## With ``timeoutMs`` > 0 (POSIX only; ignored on Windows, whose drain is
  ## blocking), a process still running after that many milliseconds is sent
  ## SIGTERM, then SIGKILL a second later, and the run is answered as
  ## ``timedOut``. Its output pipes are not drained after that: a child it
  ## started (``ssh``, a credential helper) may still hold them open.
  when defined(windows):
    var p: Process
    try:
      p = startProcess(
        exe,
        workingDir = cwd,
        args = args,
        env = childEnvironment(env),
        options = {poUsePath},
      )
    except OSError as err:
      return GitRun(failure: "could not run " & exe & ": " & err.msg)
    result.started = true
    try:
      let ins = p.inputStream
      if input.len > 0:
        ins.write(input)
      ins.close()
      result.stdout = p.outputStream.readAll()
      result.stderr = p.errorStream.readAll()
      result.exitCode = p.waitForExit()
    except CatchableError as err:
      result.started = false
      result.failure = "talking to " & exe & " failed: " & err.msg
      try:
        p.terminate()
        discard p.waitForExit()
      except CatchableError:
        discard
    finally:
      p.close()
  else:
    var child: Spawned
    try:
      child = spawnPiped(exe, args, cwd, childEnvironment(env))
    except OSError as err:
      return GitRun(failure: "could not run " & exe & ": " & err.msg)
    result.started = true
    var inFd = child.stdinFd
    var outFd = child.stdoutFd
    var errFd = child.stderrFd
    var reaped = false
    var status: cint = 0
    try:
      var written = 0
      if input.len == 0:
        discard close(inFd)
        inFd = -1
      else:
        discard fcntl(inFd, F_SETFL, fcntl(inFd, F_GETFL) or O_NONBLOCK)
      var buffer = newString(65536)
      let deadline = deadlineIn(timeoutMs)
      while inFd >= 0 or outFd >= 0 or errFd >= 0:
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
        let wait = if deadline.limited: deadline.remainingMs else: -1
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
            let n =
              writeWithoutSigpipe(inFd, unsafeAddr input[written], input.len - written)
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
              result.stdout.add buffer[0 ..< n]
            else:
              result.stderr.add buffer[0 ..< n]
      if result.timedOut:
        let exited = reap(child.pid, WNOHANG)
        if exited.done:
          # It exited; a child it left behind holds the pipes open. Its own
          # answer stands.
          result.timedOut = false
          reaped = true
          status = exited.status
      if result.timedOut:
        discard kill(child.pid, SIGTERM)
        let graceEnds = deadlineIn(1000)
        while not reaped and not graceEnds.expired:
          let exited = reap(child.pid, WNOHANG)
          if exited.done:
            reaped = true
          else:
            sleep(10)
        if not reaped:
          discard kill(child.pid, SIGKILL)
          discard reap(child.pid, 0)
          reaped = true
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
        discard kill(child.pid, SIGKILL)
        discard reap(child.pid, 0)
    finally:
      for fd in [inFd, outFd, errFd]:
        if fd >= 0:
          discard close(fd)

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

proc gitRun*(
    cwd: string,
    args: openArray[string],
    indexFile = "",
    input = "",
    env: openArray[(string, string)] = [],
    timeoutMs = 0,
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
  var environment = @PathspecEnvironment
  var argv: seq[string]
  if indexFile.len > 0:
    environment.add ("GIT_INDEX_FILE", indexFile)
    argv.add ["-c", "core.splitIndex=false", "-c", "core.fsmonitor=false"]
  environment.add env
  argv.add args
  runProcess("git", argv, cwd, environment, input, timeoutMs)

proc git*(
    cwd: string,
    args: openArray[string],
    indexFile = "",
    input = "",
    env: openArray[(string, string)] = [],
    timeoutMs = 0,
): GitStep =
  ## Run ``git <args>`` in ``cwd`` (see ``gitRun``): success with its
  ## stdout, or a sentence naming the command, its status and its stderr.
  let run = gitRun(cwd, args, indexFile, input, env, timeoutMs)
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
