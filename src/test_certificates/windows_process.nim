## Starting a process on Windows, for ``git.runProcess``.
##
## Nim's ``osproc.startProcess`` is not used, for three reasons that each
## break the pre-push hook's time budget (Tooling §4.3) or its hygiene:
##
## * It creates its pipes inheritable and starts the child with
##   ``bInheritHandles = TRUE`` and no handle list, so the child receives every
##   inheritable handle this process holds — including the pipes of another
##   ``runProcess`` running at the same time — and passes them on to whatever
##   it starts.
## * Its pipes are anonymous, so they can only be read blocking: a ``git``
##   that never writes and never exits holds the reader forever, and there is
##   no way to bound the wait.
## * Stopping the child (``TerminateProcess``) stops ``git`` only; the
##   ``ssh`` or credential helper it started keeps running and keeps the
##   pipes open.
##
## Here:
##
## * The child is started with ``CreateProcessW``, an extended startup info
##   and ``PROC_THREAD_ATTRIBUTE_HANDLE_LIST`` naming exactly its three
##   standard handles, so nothing else is inherited (``bInheritHandles`` must
##   still be TRUE for the list to apply).
##   https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute
## * It is created suspended and placed in a fresh Job Object before its first
##   instruction runs, so everything it starts is in the job too (a process
##   that asks to break away, ``CREATE_BREAKAWAY_FROM_JOB``, is allowed to:
##   that is a daemon designed to outlive its parent). The job carries
##   ``JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE``: stopping the run is
##   ``TerminateJobObject``, which ends ``git`` and its helpers together, and
##   if this process dies mid-run the job handle closes and they end as well.
##   A run that ends normally lifts kill-on-close before closing the handle,
##   so a daemon the child left running on purpose keeps running, as on
##   POSIX.
##   https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
## * Its standard streams are named pipes whose ends here are overlapped, so
##   one thread writes the input and reads both outputs with
##   ``WaitForMultipleObjects`` and a deadline: no pipe can fill while this
##   side waits on another, and the wait is bounded. The pipes are created
##   with ``FILE_FLAG_FIRST_PIPE_INSTANCE`` and ``PIPE_REJECT_REMOTE_CLIENTS``
##   under a unique name, so no other process can pose as either end.
## * The command line is quoted by the rules the Microsoft C runtime (and
##   ``CommandLineToArgvW``) use to split it, so each argument reaches the
##   child exactly as given.
##   https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments
##
## The executable is searched on ``PATH`` only (``.exe`` and ``.com``), never
## in the current directory, which ``CreateProcessW`` would search first: a
## ``git.exe`` committed to the repository being worked on must not run.
## Batch files are not run (``CreateProcessW`` would hand them to ``cmd.exe``,
## whose quoting rules differ).
##
## The child shares this process's console, so a Ctrl-C at the console
## reaches it as it reaches this process; if this process ends because of
## it, the job ends with it.

when defined(windows):
  import std/[algorithm, monotimes, os, strutils, times, widestrs]

  type
    WinHandle = int
    WinBool = int32

    SecurityAttributes {.pure.} = object
      nLength: uint32
      lpSecurityDescriptor: pointer
      bInheritHandle: WinBool

    StartupInfoW {.pure.} = object
      cb: uint32
      lpReserved, lpDesktop, lpTitle: pointer
      dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars: uint32
      dwFillAttribute, dwFlags: uint32
      wShowWindow, cbReserved2: uint16
      lpReserved2: pointer
      hStdInput, hStdOutput, hStdError: WinHandle

    StartupInfoExW {.pure.} = object
      startupInfo: StartupInfoW
      lpAttributeList: pointer

    ProcessInformation {.pure.} = object
      hProcess, hThread: WinHandle
      dwProcessId, dwThreadId: uint32

    Overlapped {.pure.} = object
      internal, internalHigh: uint
      offset, offsetHigh: uint32
      hEvent: WinHandle

    JobBasicLimits {.pure.} = object
      perProcessUserTimeLimit, perJobUserTimeLimit: int64
      limitFlags: uint32
      minimumWorkingSetSize, maximumWorkingSetSize: uint
      activeProcessLimit: uint32
      affinity: uint
      priorityClass, schedulingClass: uint32

    IoCounters {.pure.} = object
      readOperationCount, writeOperationCount, otherOperationCount: uint64
      readTransferCount, writeTransferCount, otherTransferCount: uint64

    JobExtendedLimits {.pure.} = object
      basic: JobBasicLimits
      io: IoCounters
      processMemoryLimit, jobMemoryLimit: uint
      peakProcessMemoryUsed, peakJobMemoryUsed: uint

  const
    InvalidHandle = WinHandle(-1)
    Infinite = 0xFFFF_FFFF'u32
    WaitObject0 = 0'u32
    WaitTimeout = 0x102'u32
    WaitFailed = 0xFFFF_FFFF'u32
    PipeAccessInbound = 0x1'u32
    PipeAccessOutbound = 0x2'u32
    FileFlagOverlapped = 0x4000_0000'u32
    FileFlagFirstPipeInstance = 0x0008_0000'u32
    PipeRejectRemoteClients = 0x8'u32
    GenericRead = 0x8000_0000'u32
    GenericWrite = 0x4000_0000'u32
    FileReadAttributes = 0x80'u32
    FileWriteAttributes = 0x100'u32
    OpenExisting = 3'u32
    StartfUseStdHandles = 0x100'u32
    CreateSuspended = 0x4'u32
    CreateUnicodeEnvironment = 0x400'u32
    ExtendedStartupInfoPresent = 0x0008_0000'u32
    ProcThreadAttributeHandleList = 0x0002_0002'u
    JobObjectExtendedLimitInformation = 9'i32
    JobObjectLimitBreakawayOk = 0x800'u32
    JobObjectLimitKillOnJobClose = 0x2000'u32
    ErrorFileNotFound = 2'u32
    ErrorBrokenPipe = 109'u32
    ErrorNoData = 232'u32
    ErrorIoPending = 997'u32
    BufferSize = 65536
    MaxCommandLine = 32767 ## CreateProcessW's limit, in UTF-16 units with the NUL.

  proc winCreateNamedPipe(
    name: WideCString,
    openMode, pipeMode, maxInstances, outBuffer, inBuffer, defaultTimeout: uint32,
    security: ptr SecurityAttributes,
  ): WinHandle {.stdcall, dynlib: "kernel32", importc: "CreateNamedPipeW".}

  proc winCreateFile(
    name: WideCString,
    access, share: uint32,
    security: ptr SecurityAttributes,
    creation, flags: uint32,
    templateFile: WinHandle,
  ): WinHandle {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}

  proc winCloseHandle(
    h: WinHandle
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}

  proc winReadFile(
    h: WinHandle, buffer: pointer, count: uint32, done: ptr uint32, ov: ptr Overlapped
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "ReadFile".}

  proc winWriteFile(
    h: WinHandle, buffer: pointer, count: uint32, done: ptr uint32, ov: ptr Overlapped
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "WriteFile".}

  proc winGetOverlappedResult(
    h: WinHandle, ov: ptr Overlapped, done: ptr uint32, wait: WinBool
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "GetOverlappedResult".}

  proc winCancelIoEx(
    h: WinHandle, ov: ptr Overlapped
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "CancelIoEx".}

  proc winCreateEvent(
    security: ptr SecurityAttributes,
    manualReset, initialState: WinBool,
    name: WideCString,
  ): WinHandle {.stdcall, dynlib: "kernel32", importc: "CreateEventW".}

  proc winWaitForMultipleObjects(
    count: uint32, handles: ptr WinHandle, waitAll: WinBool, ms: uint32
  ): uint32 {.stdcall, dynlib: "kernel32", importc: "WaitForMultipleObjects".}

  proc winWaitForSingleObject(
    h: WinHandle, ms: uint32
  ): uint32 {.stdcall, dynlib: "kernel32", importc: "WaitForSingleObject".}

  proc winInitializeProcThreadAttributeList(
    list: pointer, count, flags: uint32, size: ptr uint
  ): WinBool {.
    stdcall, dynlib: "kernel32", importc: "InitializeProcThreadAttributeList"
  .}

  proc winUpdateProcThreadAttribute(
    list: pointer,
    flags: uint32,
    attribute: uint,
    value: pointer,
    size: uint,
    previous: pointer,
    returnSize: ptr uint,
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "UpdateProcThreadAttribute".}

  proc winDeleteProcThreadAttributeList(
    list: pointer
  ) {.stdcall, dynlib: "kernel32", importc: "DeleteProcThreadAttributeList".}

  proc winCreateProcess(
    application, commandLine: WideCString,
    processAttributes, threadAttributes: ptr SecurityAttributes,
    inheritHandles: WinBool,
    flags: uint32,
    environment: pointer,
    currentDirectory: WideCString,
    startupInfo: ptr StartupInfoW,
    information: ptr ProcessInformation,
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "CreateProcessW".}

  proc winResumeThread(
    h: WinHandle
  ): uint32 {.stdcall, dynlib: "kernel32", importc: "ResumeThread".}

  proc winCreateJobObject(
    security: ptr SecurityAttributes, name: WideCString
  ): WinHandle {.stdcall, dynlib: "kernel32", importc: "CreateJobObjectW".}

  proc winSetInformationJobObject(
    job: WinHandle, infoClass: int32, info: pointer, length: uint32
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "SetInformationJobObject".}

  proc winAssignProcessToJobObject(
    job, process: WinHandle
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "AssignProcessToJobObject".}

  proc winTerminateJobObject(
    job: WinHandle, exitCode: uint32
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "TerminateJobObject".}

  proc winTerminateProcess(
    process: WinHandle, exitCode: uint32
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "TerminateProcess".}

  proc winGetExitCodeProcess(
    process: WinHandle, code: ptr uint32
  ): WinBool {.stdcall, dynlib: "kernel32", importc: "GetExitCodeProcess".}

  proc winGetLastError(): uint32 {.
    stdcall, dynlib: "kernel32", importc: "GetLastError"
  .}

  type
    WinOutputSink* = proc(data: openArray[char]): bool {.closure.}
      ## See ``git.OutputSink``.

    WinRun* = object ## What ``runWindowsProcess`` did; ``git.runProcess`` maps it.
      started*: bool
      exitCode*: int
      stdout*, stderr*: string
      failure*: string
      timedOut*: bool
      stopped*: bool

  proc quoteWindowsArgument*(arg: string): string =
    ## ``arg`` as one argument of a command line that the Microsoft C runtime
    ## and ``CommandLineToArgvW`` split back into exactly ``arg``: quoted when
    ## it is empty or holds whitespace or a quote; inside the quotes a ``"``
    ## is preceded by a backslash, and the backslashes before a ``"`` (or
    ## before the closing quote) are doubled. Backslashes anywhere else are
    ## literal. See "Parsing C command-line arguments":
    ## https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments
    if arg.len > 0 and not arg.contains({' ', '\t', '\n', '\v', '"'}):
      return arg
    result = "\""
    var i = 0
    while true:
      var backslashes = 0
      while i < arg.len and arg[i] == '\\':
        inc backslashes
        inc i
      if i == arg.len:
        result.add repeat('\\', backslashes * 2)
        break
      elif arg[i] == '"':
        result.add repeat('\\', backslashes * 2 + 1)
        result.add '"'
      else:
        result.add repeat('\\', backslashes)
        result.add arg[i]
      inc i
    result.add '"'

  proc windowsCommandLine*(program: string, args: openArray[string]): string =
    ## The command line for ``program`` (a path) and ``args``. The program
    ## name is parsed by different rules — no escapes, a quoted run ends at
    ## the next quote — so it is quoted whole, and a path cannot hold ``"``.
    result = "\"" & program & "\""
    for a in args:
      result.add ' '
      result.add quoteWindowsArgument(a)

  proc searchWindowsPath(exe: string): string =
    ## ``exe`` as a path when it names one (with ``.exe`` added when it has
    ## no extension and does not exist as given); otherwise the first
    ## ``<exe>.exe`` or ``<exe>.com`` (or ``exe`` itself when it ends in one
    ## of those) in a ``PATH`` directory. The current directory is never
    ## searched. "" when there is none.
    let ext = exe.splitFile.ext.toLowerAscii
    if exe.contains({'/', '\\', ':'}):
      if fileExists(exe):
        return exe
      if ext.len == 0 and fileExists(exe & ".exe"):
        return exe & ".exe"
      return ""
    let candidates =
      if ext in [".exe", ".com"]:
        @[exe]
      else:
        @[exe & ".exe", exe & ".com"]
    for raw in getEnv("PATH").split(';'):
      let dir = raw.strip(chars = {'"', ' '})
      if dir.len == 0 or not isAbsolute(dir):
        continue
      for c in candidates:
        let path = dir / c
        if fileExists(path):
          return path
    ""

  proc environmentBlock(env: openArray[(string, string)]): seq[Utf16Char] =
    ## ``NAME=value`` strings, each NUL-terminated, the block ending in an
    ## extra NUL, sorted case-insensitively by name as CreateProcess
    ## requires of an environment block.
    ## https://learn.microsoft.com/en-us/windows/win32/procthread/changing-environment-variables
    var entries = @env
    entries.sort(
      proc(a, b: (string, string)): int =
        cmp(a[0].toUpperAscii, b[0].toUpperAscii)
    )
    for (key, value) in entries:
      let w = newWideCString(key & "=" & value)
      for i in 0 ..< w.len:
        result.add w[i]
      result.add Utf16Char(0)
    if result.len == 0:
      result.add Utf16Char(0)
    result.add Utf16Char(0)

  var pipeCounter: int

  proc lastErrorText(what: string): string =
    let code = winGetLastError()
    what & " failed: " & osErrorMsg(OSErrorCode(code)) & " (error " & $code & ")"

  proc overlappedPipe(
      inbound: bool
  ): tuple[ok: bool, server, client: WinHandle, problem: string] =
    ## A named pipe whose server end (ours) is overlapped and not
    ## inheritable, and whose client end (the child's) is synchronous and
    ## inheritable. ``inbound``: the child writes, we read.
    inc pipeCounter
    let name =
      r"\\.\pipe\test-certificates-" & $getCurrentProcessId() & "-" & $pipeCounter & "-" &
      $getMonoTime().ticks
    let wname = newWideCString(name)
    let direction = if inbound: PipeAccessInbound else: PipeAccessOutbound
    let server = winCreateNamedPipe(
      wname,
      direction or FileFlagOverlapped or FileFlagFirstPipeInstance,
      PipeRejectRemoteClients, # Byte type, byte read mode, blocking (for the client).
      1,
      BufferSize,
      BufferSize,
      0,
      nil,
    )
    if server == InvalidHandle:
      return (false, InvalidHandle, InvalidHandle, lastErrorText("CreateNamedPipeW"))
    var inherit =
      SecurityAttributes(nLength: uint32(sizeof(SecurityAttributes)), bInheritHandle: 1)
    # The attribute rights let the child query and set the pipe's state,
    # which some runtimes do on their standard handles.
    let access =
      if inbound:
        GenericWrite or FileReadAttributes
      else:
        GenericRead or FileWriteAttributes
    let client = winCreateFile(wname, access, 0, addr inherit, OpenExisting, 0, 0)
    if client == InvalidHandle:
      let problem = lastErrorText("CreateFileW (pipe client)")
      discard winCloseHandle(server)
      return (false, InvalidHandle, InvalidHandle, problem)
    (true, server, client, "")

  type Stream = object
    server: WinHandle ## Our end; InvalidHandle once closed.
    event: WinHandle
    ov: Overlapped
    pending: bool ## An overlapped operation is in flight.
    buffer: string

  proc runWindowsProcess*(
      exe: string,
      args: openArray[string],
      cwd: string,
      env: openArray[(string, string)],
      input: string,
      timeoutMs: int,
      onStdout: WinOutputSink,
  ): WinRun =
    ## Run ``exe`` with exactly ``env`` as its environment; see the module
    ## comment and ``git.runProcess`` for the contract.
    let path = searchWindowsPath(exe)
    if path.len == 0:
      return WinRun(
        failure:
          "could not run " & exe & ": " & osErrorMsg(OSErrorCode(ErrorFileNotFound)) &
          " (not found on PATH)"
      )
    let commandText = windowsCommandLine(path, args)
    let commandLine = newWideCString(commandText)
    if commandLine.len >= MaxCommandLine:
      return WinRun(
        failure:
          "could not run " & exe & ": the command line is " & $commandLine.len &
          " UTF-16 units long, over Windows' limit of " & $(MaxCommandLine - 1)
      )
    var envBlock = environmentBlock(env)

    # Index 0: stdin (we write), 1: stdout, 2: stderr (we read).
    var streams: array[3, Stream]
    var clients: array[3, WinHandle]
    for i in 0 .. 2:
      streams[i].server = InvalidHandle
      streams[i].event = 0
      clients[i] = InvalidHandle
    var attributeList: pointer = nil
    var attributesReady = false
    var job: WinHandle = 0
    var info: ProcessInformation
    var processStarted = false
    var settled = false
      # The child exited, or was stopped together with everything it
      # started. Until then, leaving this proc early (an exception raised by
      # the output sink, say) stops it in `finally`.

    template closeIf(h: var WinHandle) =
      if h != InvalidHandle and h != 0:
        discard winCloseHandle(h)
      h = InvalidHandle

    try:
      for i in 0 .. 2:
        let made = overlappedPipe(inbound = i > 0)
        if not made.ok:
          return WinRun(failure: "could not run " & exe & ": " & made.problem)
        streams[i].server = made.server
        clients[i] = made.client
        streams[i].event = winCreateEvent(nil, 1, 0, nil)
        if streams[i].event == 0:
          return WinRun(
            failure: "could not run " & exe & ": " & lastErrorText("CreateEventW")
          )
        streams[i].ov.hEvent = streams[i].event
        if i > 0:
          streams[i].buffer = newString(BufferSize)

      # Exactly the three client ends are inherited.
      var size: uint = 0
      discard winInitializeProcThreadAttributeList(nil, 1, 0, addr size)
      attributeList = alloc0(int(size))
      if winInitializeProcThreadAttributeList(attributeList, 1, 0, addr size) == 0:
        return WinRun(
          failure:
            "could not run " & exe & ": " &
            lastErrorText("InitializeProcThreadAttributeList")
        )
      attributesReady = true
      if winUpdateProcThreadAttribute(
        attributeList,
        0,
        ProcThreadAttributeHandleList,
        addr clients[0],
        uint(sizeof(WinHandle) * 3),
        nil,
        nil,
      ) == 0:
        return WinRun(
          failure:
            "could not run " & exe & ": " & lastErrorText("UpdateProcThreadAttribute")
        )

      job = winCreateJobObject(nil, nil)
      if job != 0:
        var limits: JobExtendedLimits
        limits.basic.limitFlags =
          JobObjectLimitKillOnJobClose or JobObjectLimitBreakawayOk
        if winSetInformationJobObject(
          job, JobObjectExtendedLimitInformation, addr limits, uint32(sizeof(limits))
        ) == 0:
          discard winCloseHandle(job)
          job = 0

      var startup: StartupInfoExW
      startup.startupInfo.cb = uint32(sizeof(StartupInfoExW))
      startup.startupInfo.dwFlags = StartfUseStdHandles
      startup.startupInfo.hStdInput = clients[0]
      startup.startupInfo.hStdOutput = clients[1]
      startup.startupInfo.hStdError = clients[2]
      startup.lpAttributeList = attributeList
      let directoryText = newWideCString(cwd)
      let directory: WideCString =
        if cwd.len > 0:
          toWideCString(directoryText)
        else:
          nil
      let application = newWideCString(path)
      if winCreateProcess(
        application,
        commandLine,
        nil,
        nil,
        1,
        ExtendedStartupInfoPresent or CreateUnicodeEnvironment or CreateSuspended,
        addr envBlock[0],
        directory,
        addr startup.startupInfo,
        addr info,
      ) == 0:
        return WinRun(
          failure: "could not run " & exe & ": " & lastErrorText("CreateProcessW")
        )
      processStarted = true
      # The client ends now live only in the child.
      for i in 0 .. 2:
        closeIf(clients[i])
      # Into the job before it runs: everything it starts is then in the job
      # too. Without a job (nested jobs are refused before Windows 8, and
      # a job that forbids breakaway can refuse it), a stop ends `git` alone.
      if job != 0 and winAssignProcessToJobObject(job, info.hProcess) == 0:
        discard winCloseHandle(job)
        job = 0
      discard winResumeThread(info.hThread)
      closeIf(info.hThread)
      result.started = true

      let start = getMonoTime()
      template remaining(): uint32 =
        if timeoutMs <= 0:
          Infinite
        else:
          # Kept below `Infinite` (0xFFFFFFFF), which would wait forever.
          uint32(
            clamp(
              timeoutMs - int((getMonoTime() - start).inMilliseconds),
              0,
              int(Infinite) - 1,
            )
          )

      var written = 0
      if input.len == 0:
        closeIf(streams[0].server)

      template anyOpen(): bool =
        streams[0].server != InvalidHandle or streams[1].server != InvalidHandle or
          streams[2].server != InvalidHandle

      var failed = ""
      block pump:
        while anyOpen():
          # Start an operation on every open stream that has none in flight.
          for i in 0 .. 2:
            if streams[i].server == InvalidHandle or streams[i].pending:
              continue
            var ok: WinBool
            if i == 0:
              let chunk = min(BufferSize, input.len - written)
              ok = winWriteFile(
                streams[0].server,
                unsafeAddr input[written],
                uint32(chunk),
                nil,
                addr streams[0].ov,
              )
            else:
              ok = winReadFile(
                streams[i].server,
                addr streams[i].buffer[0],
                uint32(BufferSize),
                nil,
                addr streams[i].ov,
              )
            let err =
              if ok == 0:
                winGetLastError()
              else:
                0'u32
            if ok != 0 or err == ErrorIoPending:
              # Completed at once or queued: the event is set either way.
              streams[i].pending = true
            elif err in [ErrorBrokenPipe, ErrorNoData]:
              # The child closed its end (stdin: it stopped reading; its exit
              # status says why).
              closeIf(streams[i].server)
            else:
              failed = lastErrorText(if i == 0: "WriteFile" else: "ReadFile")
              break pump
          if not anyOpen():
            break
          var events: seq[WinHandle]
          for s in streams:
            if s.pending:
              events.add s.event
          let wait = winWaitForMultipleObjects(
            uint32(events.len), addr events[0], 0, remaining()
          )
          if wait == WaitTimeout:
            result.timedOut = true
            break pump
          if wait == WaitFailed:
            failed = lastErrorText("WaitForMultipleObjects")
            break pump
          # Service every operation that has completed, not only the first.
          for i in 0 .. 2:
            if not streams[i].pending or
                winWaitForSingleObject(streams[i].event, 0) != WaitObject0:
              continue
            streams[i].pending = false
            var done: uint32 = 0
            if winGetOverlappedResult(
              streams[i].server, addr streams[i].ov, addr done, 0
            ) == 0:
              let err = winGetLastError()
              if err in [ErrorBrokenPipe, ErrorNoData]:
                closeIf(streams[i].server)
                continue
              failed = lastErrorText("GetOverlappedResult")
              break pump
            if i == 0:
              written += int(done)
              if written >= input.len:
                closeIf(streams[0].server)
            elif done > 0:
              if i == 1 and onStdout != nil:
                if not onStdout(streams[i].buffer.toOpenArray(0, int(done) - 1)):
                  result.stopped = true
                  break pump
              elif i == 1:
                result.stdout.add streams[i].buffer[0 ..< int(done)]
              else:
                result.stderr.add streams[i].buffer[0 ..< int(done)]

      # Wait for the exit itself, within what is left of the budget.
      var exited = false
      if failed.len == 0 and not result.timedOut and not result.stopped:
        let wait = winWaitForSingleObject(info.hProcess, remaining())
        if wait == WaitObject0:
          exited = true
        elif wait == WaitTimeout:
          result.timedOut = true
        else:
          failed = lastErrorText("WaitForSingleObject")
      elif result.timedOut:
        # It had already exited when the time ran out (a helper it left
        # behind holds the pipes past the budget, and is ended): its own
        # answer stands.
        if winWaitForSingleObject(info.hProcess, 0) == WaitObject0:
          exited = true
          result.timedOut = false
          if job != 0:
            discard winTerminateJobObject(job, 1)

      if exited:
        settled = true
      else:
        # Stop it and everything it started.
        if job != 0:
          discard winTerminateJobObject(job, 1)
        else:
          discard winTerminateProcess(info.hProcess, 1)
        discard winWaitForSingleObject(info.hProcess, 5000)
        settled = true
        result.started = false
        result.exitCode = -1
        if result.timedOut:
          result.failure =
            exe & " did not finish within " & $timeoutMs & " ms and was stopped"
        elif result.stopped:
          result.failure = exe & " was stopped: its output was no longer wanted"
        else:
          result.failure = "talking to " & exe & " failed: " & failed
        return
      if failed.len > 0:
        result.started = false
        result.failure = "talking to " & exe & " failed: " & failed
        return
      var code: uint32 = 0
      if winGetExitCodeProcess(info.hProcess, addr code) == 0:
        result.started = false
        result.failure =
          "talking to " & exe & " failed: " & lastErrorText("GetExitCodeProcess")
        return
      result.exitCode = int(code)
    finally:
      # An operation still in flight writes into `streams`: cancel it and
      # wait for it to finish before anything is released.
      for i in 0 .. 2:
        if streams[i].pending and streams[i].server != InvalidHandle:
          discard winCancelIoEx(streams[i].server, addr streams[i].ov)
          var done: uint32
          discard
            winGetOverlappedResult(streams[i].server, addr streams[i].ov, addr done, 1)
          streams[i].pending = false
        closeIf(streams[i].server)
        if streams[i].event != 0:
          discard winCloseHandle(streams[i].event)
        closeIf(clients[i])
      if processStarted and not settled:
        # Left early: stop the child (possibly still suspended) and what it
        # started, rather than leave them running unseen.
        if job != 0:
          discard winTerminateJobObject(job, 1)
        else:
          discard winTerminateProcess(info.hProcess, 1)
      if processStarted:
        closeIf(info.hThread)
        closeIf(info.hProcess)
      # A run that settled is over: what the child left running on purpose
      # (a daemon that detached, as on POSIX) keeps running, so kill-on-close
      # is lifted before the handle goes. It only ever served for this
      # process dying mid-run; every stop is an explicit TerminateJobObject.
      if job != 0:
        if settled:
          var keep: JobExtendedLimits
          keep.basic.limitFlags = JobObjectLimitBreakawayOk
          discard winSetInformationJobObject(
            job, JobObjectExtendedLimitInformation, addr keep, uint32(sizeof(keep))
          )
        discard winCloseHandle(job)
      if attributeList != nil:
        if attributesReady:
          winDeleteProcThreadAttributeList(attributeList)
        dealloc(attributeList)
