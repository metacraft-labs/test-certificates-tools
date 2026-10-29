## Where a user's certificate store is: the user root and the system root
## (Transport §2.1).
##
## Resolution is a pure function of the platform, the environment and the
## account identifier (``resolveRoots``), so every rule can be tested on any
## host; ``nativeRoots`` feeds it this process's real values. The environment
## is read on every call, never cached.
##
## The rules, as implemented:
##
## * user root: ``$TEST_CERTIFICATES_DIR`` when it is a non-empty ABSOLUTE
##   path; else ``$XDG_STATE_HOME/test-certificates`` (Unix, when absolute),
##   ``$HOME/.local/state/test-certificates`` (Unix),
##   ``$HOME/Library/Application Support/test-certificates`` (macOS) or
##   ``%LOCALAPPDATA%\test-certificates`` (Windows);
## * system root: ``$TEST_CERTIFICATES_SYSTEM_DIR/<user>`` when absolute; else
##   ``/var/lib/test-certificates/<uid>`` (Unix),
##   ``/Library/Application Support/test-certificates/<uid>`` (macOS) or
##   ``%ProgramData%\test-certificates\<SID>`` (Windows);
## * a RELATIVE value of any of these variables is ignored, and the reason is
##   kept, so a user who set one can see why it had no effect. A store whose
##   location depends on the current directory would be a different store for
##   each process.
##
## ``<user>`` is the numeric uid on POSIX and the account SID on Windows.

import std/[os, strutils]

when defined(windows):
  import std/widestrs
else:
  from std/posix import getuid

const StoreDirName* = "test-certificates"
  ## The leaf of every per-user and machine-wide root.

type
  RootPlatform* = enum
    rpUnix ## Linux and other Unix-likes.
    rpMacos
    rpWindows

  Environment* = proc(name: string): string {.closure.}
    ## Reads one environment variable; "" when unset.

  StoreRoots* = object
    user*: string ## The user root; "" when it cannot be resolved.
    system*: string ## This user's partition of the system root; "" when unresolved.
    systemBase*: string ## The machine-wide directory holding every user's partition.
    problems*: seq[string]
      ## Why a root is unresolved, or why a variable that was set was ignored.

proc hostPlatform*(): RootPlatform =
  when defined(windows):
    rpWindows
  elif defined(macosx):
    rpMacos
  else:
    rpUnix

proc isAbsoluteOn*(platform: RootPlatform, path: string): bool =
  ## Absolute in ``platform``'s terms, independent of the host.
  case platform
  of rpWindows:
    (path.len >= 3 and path[0] in Letters and path[1] == ':' and path[2] in {'\\', '/'}) or
      path.startsWith("\\\\")
  else:
    path.startsWith("/")

proc joinOn*(platform: RootPlatform, parts: varargs[string]): string =
  ## Join with ``platform``'s separator, independent of the host.
  let sep = if platform == rpWindows: '\\' else: '/'
  for part in parts:
    if result.len == 0:
      result = part
    elif result.endsWith(sep) or (platform == rpWindows and result.endsWith('/')):
      result.add part
    else:
      result.add sep
      result.add part

proc absoluteVariable(
    platform: RootPlatform, env: Environment, name: string, problems: var seq[string]
): string =
  let value = env(name)
  if value.len == 0:
    return ""
  if not isAbsoluteOn(platform, value):
    problems.add(
      (if platform == rpWindows: "%" & name & "%" else: "$" & name) &
        " is set to the relative path '" & value &
        "', which is ignored: a store whose location depends on the current directory " &
        "would be a different store for each process (Transport §2.1)"
    )
    return ""
  value

proc isValidAccount*(platform: RootPlatform, account: string): bool =
  ## Whether ``account`` can name a system partition: a decimal uid on POSIX,
  ## a string SID (``S-1-…``) on Windows. Anything else could name a path
  ## outside the system root.
  if account.len == 0 or account.len > 184:
    return false
  case platform
  of rpWindows:
    if not account.startsWith("S-1-"):
      return false
    for part in account[4 ..^ 1].split('-'):
      if part.len == 0:
        return false
      for c in part:
        if c notin Digits:
          return false
    true
  else:
    for c in account:
      if c notin Digits:
        return false
    true

proc systemBaseOf(
    platform: RootPlatform, env: Environment, problems: var seq[string]
): string =
  let explicit =
    absoluteVariable(platform, env, "TEST_CERTIFICATES_SYSTEM_DIR", problems)
  if explicit.len > 0:
    return explicit
  case platform
  of rpUnix:
    joinOn(platform, "/var/lib", StoreDirName)
  of rpMacos:
    joinOn(platform, "/Library/Application Support", StoreDirName)
  of rpWindows:
    let programData = absoluteVariable(platform, env, "ProgramData", problems)
    if programData.len == 0:
      problems.add "the system root cannot be resolved: %ProgramData% is not an absolute path"
      ""
    else:
      joinOn(platform, programData, StoreDirName)

proc systemPartition*(
    platform: RootPlatform, env: Environment, account: string
): tuple[path: string, problems: seq[string]] =
  ## The system partition of ``account`` (Transport §2.1), as ``put --system``
  ## and ``prune --system`` name it.
  if not isValidAccount(platform, account):
    result.problems.add "`" & account & "` is not a " &
      (if platform == rpWindows: "SID" else: "numeric uid") &
      ", so it names no system partition"
    return
  let base = systemBaseOf(platform, env, result.problems)
  if base.len > 0:
    result.path = joinOn(platform, base, account)

proc resolveRoots*(
    platform: RootPlatform, env: Environment, account: string
): StoreRoots =
  ## Both roots per Transport §2.1. ``account`` is this user's uid (POSIX) or
  ## SID (Windows); "" leaves the system root unresolved rather than guessed,
  ## since a guess could name another user's partition.
  let explicitUser =
    absoluteVariable(platform, env, "TEST_CERTIFICATES_DIR", result.problems)
  if explicitUser.len > 0:
    result.user = explicitUser
  else:
    case platform
    of rpUnix:
      let state = absoluteVariable(platform, env, "XDG_STATE_HOME", result.problems)
      if state.len > 0:
        result.user = joinOn(platform, state, StoreDirName)
      else:
        let home = absoluteVariable(platform, env, "HOME", result.problems)
        if home.len > 0:
          result.user = joinOn(platform, home, ".local", "state", StoreDirName)
        else:
          result.problems.add "the user root cannot be resolved: neither $TEST_CERTIFICATES_DIR, " &
            "$XDG_STATE_HOME nor $HOME is an absolute path"
    of rpMacos:
      let home = absoluteVariable(platform, env, "HOME", result.problems)
      if home.len > 0:
        result.user =
          joinOn(platform, home, "Library", "Application Support", StoreDirName)
      else:
        result.problems.add "the user root cannot be resolved: neither $TEST_CERTIFICATES_DIR nor " &
          "$HOME is an absolute path"
    of rpWindows:
      let local = absoluteVariable(platform, env, "LOCALAPPDATA", result.problems)
      if local.len > 0:
        result.user = joinOn(platform, local, StoreDirName)
      else:
        result.problems.add "the user root cannot be resolved: neither %TEST_CERTIFICATES_DIR% " &
          "nor %LOCALAPPDATA% is an absolute path"

  result.systemBase = systemBaseOf(platform, env, result.problems)
  if account.len == 0:
    result.problems.add "the system root cannot be resolved: this process does not know its account's " &
      (if platform == rpWindows: "SID" else: "uid")
    return
  if not isValidAccount(platform, account):
    result.problems.add "the system root cannot be resolved: `" & account &
      "` is not a valid account id"
    return
  if result.systemBase.len > 0:
    result.system = joinOn(platform, result.systemBase, account)

# ---------------------------------------------------------------------------
# This process's account
# ---------------------------------------------------------------------------

when defined(windows):
  type
    Handle = int
    SidAndAttributes {.pure.} = object
      sid: pointer
      attributes: uint32

  const
    TokenQuery = 0x0008'u32
    TokenUserClass = 1'i32

  proc getCurrentProcess(): Handle {.
    stdcall, dynlib: "kernel32", importc: "GetCurrentProcess"
  .}

  proc closeHandle(
    h: Handle
  ): int32 {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}

  proc localFree(
    p: pointer
  ): pointer {.stdcall, dynlib: "kernel32", importc: "LocalFree".}

  proc openProcessToken(
    process: Handle, access: uint32, token: var Handle
  ): int32 {.stdcall, dynlib: "advapi32", importc: "OpenProcessToken".}

  proc getTokenInformation(
    token: Handle, class: int32, info: pointer, length: uint32, returned: var uint32
  ): int32 {.stdcall, dynlib: "advapi32", importc: "GetTokenInformation".}

  proc convertSidToStringSidW(
    sid: pointer, text: var WideCString
  ): int32 {.stdcall, dynlib: "advapi32", importc: "ConvertSidToStringSidW".}

proc currentAccount*(): tuple[ok: bool, account, problem: string] =
  ## This process's uid (POSIX) or the SID of its token's user (Windows).
  ## https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation
  ## https://learn.microsoft.com/en-us/windows/win32/api/sddl/nf-sddl-convertsidtostringsidw
  when defined(windows):
    var token: Handle
    if openProcessToken(getCurrentProcess(), TokenQuery, token) == 0:
      return (false, "", "OpenProcessToken failed: " & osErrorMsg(osLastError()))
    defer:
      discard closeHandle(token)
    var needed: uint32
    discard getTokenInformation(token, TokenUserClass, nil, 0, needed)
    if needed == 0:
      return (false, "", "GetTokenInformation failed: " & osErrorMsg(osLastError()))
    var buffer = newSeq[byte](needed)
    if getTokenInformation(token, TokenUserClass, addr buffer[0], needed, needed) == 0:
      return (false, "", "GetTokenInformation failed: " & osErrorMsg(osLastError()))
    let user = cast[ptr SidAndAttributes](addr buffer[0])
    var text: WideCString
    if convertSidToStringSidW(user.sid, text) == 0:
      return (false, "", "ConvertSidToStringSidW failed: " & osErrorMsg(osLastError()))
    let sid = $text
    discard localFree(cast[pointer](text))
    (true, sid, "")
  else:
    (true, $getuid(), "")

proc nativeEnvironment*(): Environment =
  ## This process's environment, read at call time.
  result = proc(name: string): string =
    getEnv(name)

proc nativeRoots*(): StoreRoots =
  ## Both roots as this process resolves them now.
  let account = currentAccount()
  result = resolveRoots(hostPlatform(), nativeEnvironment(), account.account)
  if not account.ok:
    result.problems.add account.problem
