## Existing user stores belong to the effective writer/pruner account.
## Inspect a directory handle's owner SID and compare it to the effective
## thread token (or process token when not impersonating). An unreadable
## security descriptor is a refusal, never permission to adopt a foreign root.
when defined(windows):
  import std/[os, widestrs, winlean]

  type
    SidAndAttributes = object
      sid: pointer
      attributes: DWORD

    TokenUserInfo = object
      user: SidAndAttributes

  proc ownerCreateFile(
    name: WideCString,
    access, sharing: DWORD,
    security: pointer,
    creation, flags: DWORD,
    templateFile: Handle,
  ): Handle {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}

  proc ownerGetSecurityInfo(
    handle: Handle,
    objectType, information: DWORD,
    owner, group, dacl, sacl, descriptor: ptr pointer,
  ): DWORD {.stdcall, dynlib: "advapi32", importc: "GetSecurityInfo".}

  proc ownerOpenThreadToken(
    thread: Handle, access: DWORD, asSelf: WINBOOL, token: ptr Handle
  ): WINBOOL {.stdcall, dynlib: "advapi32", importc: "OpenThreadToken".}

  proc ownerOpenProcessToken(
    process: Handle, access: DWORD, token: ptr Handle
  ): WINBOOL {.stdcall, dynlib: "advapi32", importc: "OpenProcessToken".}

  proc ownerGetTokenInformation(
    token: Handle, kind: DWORD, buffer: pointer, size: DWORD, needed: ptr DWORD
  ): WINBOOL {.stdcall, dynlib: "advapi32", importc: "GetTokenInformation".}

  proc ownerEqualSid(
    a, b: pointer
  ): WINBOOL {.stdcall, dynlib: "advapi32", importc: "EqualSid".}

  proc ownerCurrentThread(): Handle {.
    stdcall, dynlib: "kernel32", importc: "GetCurrentThread"
  .}

  proc ownerCurrentProcess(): Handle {.
    stdcall, dynlib: "kernel32", importc: "GetCurrentProcess"
  .}

  proc ownerLocalFree(
    memory: pointer
  ): pointer {.stdcall, dynlib: "kernel32", importc: "LocalFree".}

  proc checkUserRootOwner*(root: string): string =
    ## Empty on success; a diagnostic on any failed or unsupported check.
    let directory = ownerCreateFile(
      newWideCString(root),
      DWORD(0x00020000),
      DWORD(7),
      nil,
      DWORD(3),
      DWORD(0x02000000),
      Handle(0),
    )
    if directory == INVALID_HANDLE_VALUE:
      return
        "could not check ownership of user root '" & root & "': " &
        osErrorMsg(osLastError())
    defer:
      discard closeHandle(directory)
    var sid, descriptor: pointer
    let error =
      ownerGetSecurityInfo(directory, 1, 1, addr sid, nil, nil, nil, addr descriptor)
    if error != 0:
      return
        "could not check ownership of user root '" & root & "': " &
        osErrorMsg(OSErrorCode(error))
    defer:
      discard ownerLocalFree(descriptor)
    if sid == nil:
      return "user root '" & root & "' has no account owner"
    var token: Handle
    if ownerOpenThreadToken(ownerCurrentThread(), 8, WINBOOL(1), addr token) == 0:
      # ERROR_NO_TOKEN means this thread is not impersonating. Other errors
      # must not silently change which account the check represents.
      if osLastError() != OSErrorCode(1008):
        return "could not inspect effective account: " & osErrorMsg(osLastError())
      if ownerOpenProcessToken(ownerCurrentProcess(), 8, addr token) == 0:
        return "could not inspect process account: " & osErrorMsg(osLastError())
    defer:
      discard closeHandle(token)
    var needed: DWORD
    discard ownerGetTokenInformation(token, 1, nil, 0, addr needed)
    if needed == 0:
      return "could not determine effective account SID: " & osErrorMsg(osLastError())
    let buffer = alloc(needed.int)
    defer:
      dealloc(buffer)
    if ownerGetTokenInformation(token, 1, buffer, needed, addr needed) == 0:
      return "could not read effective account SID: " & osErrorMsg(osLastError())
    let user = cast[ptr TokenUserInfo](buffer)
    if ownerEqualSid(sid, user.user.sid) == 0:
      return "user root '" & root & "' is owned by another account"
    ""
