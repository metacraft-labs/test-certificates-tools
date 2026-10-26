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

import std/[os, osproc, strtabs, streams, strutils]

when not defined(windows):
  import std/posix

type
  GitRun* = object
    started*: bool ## False when git could not be run at all.
    exitCode*: int
    stdout*: string
    stderr*: string
    failure*: string ## Why it could not be started; "" when it was.

  GitStep* = object
    ok*: bool
    stdout*: string
    failure*: string ## A sentence naming the command and why it failed.

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

proc runProcess*(
    exe: string,
    args: openArray[string],
    cwd: string,
    env: openArray[(string, string)] = [],
    input = "",
): GitRun =
  ## Run ``exe`` with ``args`` in ``cwd``. ``env`` is added to (and overrides)
  ## this process's environment; nothing else is changed.
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
    when defined(windows):
      let ins = p.inputStream
      if input.len > 0:
        ins.write(input)
      ins.close()
      result.stdout = p.outputStream.readAll()
      result.stderr = p.errorStream.readAll()
    else:
      let inFd = p.inputHandle
      let outFd = p.outputHandle
      let errFd = p.errorHandle
      var written = 0
      var inOpen = true
      if input.len == 0:
        p.inputStream.close()
        inOpen = false
      else:
        discard fcntl(inFd, F_SETFL, fcntl(inFd, F_GETFL) or O_NONBLOCK)
      var outOpen = true
      var errOpen = true
      var buffer = newString(65536)
      while inOpen or outOpen or errOpen:
        var fds: seq[TPollfd]
        if inOpen:
          fds.add TPollfd(fd: inFd, events: POLLOUT)
        if outOpen:
          fds.add TPollfd(fd: outFd, events: POLLIN)
        if errOpen:
          fds.add TPollfd(fd: errFd, events: POLLIN)
        let ready = poll(addr fds[0], Tnfds(fds.len), -1)
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
              p.inputStream.close()
              inOpen = false
              continue
            let n =
              writeWithoutSigpipe(inFd, unsafeAddr input[written], input.len - written)
            if n < 0:
              if errno in [EAGAIN, EWOULDBLOCK, EINTR]:
                continue
              if errno == EPIPE:
                p.inputStream.close()
                inOpen = false
                continue
              raiseOSError(osLastError(), "write to git")
            written += n
            if written >= input.len:
              p.inputStream.close()
              inOpen = false
          else:
            let n = read(f.fd, addr buffer[0], buffer.len)
            if n < 0:
              if errno in [EAGAIN, EINTR]:
                continue
              raiseOSError(osLastError(), "read from git")
            if n == 0:
              if f.fd == outFd:
                outOpen = false
              else:
                errOpen = false
            elif f.fd == outFd:
              result.stdout.add buffer[0 ..< n]
            else:
              result.stderr.add buffer[0 ..< n]
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
]

proc git*(cwd: string, args: openArray[string], indexFile = "", input = ""): GitStep =
  ## Run ``git <args>`` in ``cwd``. With ``indexFile``, git reads and writes
  ## that index instead of the repository's, with the split index and the
  ## filesystem monitor off for the command (both would otherwise make git
  ## write outside, or trust state from outside, the temporary index).
  var env = @PathspecEnvironment
  var argv: seq[string]
  if indexFile.len > 0:
    env.add ("GIT_INDEX_FILE", indexFile)
    argv.add ["-c", "core.splitIndex=false", "-c", "core.fsmonitor=false"]
  argv.add args
  let run = runProcess("git", argv, cwd, env, input)
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
