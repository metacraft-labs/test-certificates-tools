## Writing a certificate into a store root, atomically (Transport §2.3).
##
## 1. The directories are created as needed. A user root created here is
##    readable and writable by its owner only (``0700``), and so is every
##    directory created below it; record files are ``0600``.
## 2. The record is written under a temporary name in the SAME directory,
##    beginning with ``.`` and not ending in ``.toml``.
## 3. It is flushed (``fsync``), then renamed onto its final name.
##
## When the final name already exists, a SIGNED record replaces it and an
## UNSIGNED record keeps it: the name is the payload's hash and the signature
## block is not part of the payload, so the existing file is the same claim,
## or the same claim signed. The tool does not verify signatures (Tooling §1),
## so "signed" here means a non-empty ``[certificate.signature]`` block. The
## directory of a kept file is touched, so a just-re-tested content does not
## look old to the next prune.
##
## The file written is the record exactly as given, byte for byte: the store
## holds "the certificate as a TOML document" (Transport §2.2), and
## re-rendering it could only lose something a verifier wants.
##
## **Racing a prune (Transport §2.5).** A prune takes a content directory out
## of the store by renaming it aside, then deletes the renamed tree. A writer
## that lost its directory that way finds out in one of two ways: its
## temporary file vanished before the rename (the tree was deleted), or after
## the rename the path no longer leads to the directory it wrote into (it was
## renamed aside). Either way it recreates the directory and retries ONCE,
## which is what §2.5 promises is enough: the retry's directory was created
## after the rename aside, so that prune's deletion cannot reach it.
##
## **The system root (``put --system``).** For a privileged producer with no
## client to return the certificate to. Its partition must already exist
## (created by the producer's installer, with the platform's ownership and
## permissions, Transport §2.3) and be owned by the writing account: a
## partition the user can write is one a privileged write must not enter.
## Every component below the partition is opened with ``O_NOFOLLOW``, so a
## planted symbolic link fails the write rather than redirecting it, and
## directories and files created there take the partition's own permission
## bits (minus execute, for files), so the installer's choice of who may read
## carries down. Windows is not supported for ``--system`` in this release:
## the no-follow guarantee there needs reparse-point handling this package
## does not yet implement, and a write that cannot keep the promise is
## refused rather than attempted.

import std/os
import ./[certificate, layout]

when defined(windows):
  import std/times
else:
  import std/posix
  import ./posix_at

type
  PutStepHook* = proc(attempt: int) {.closure.}
    ## A test seam: called with the attempt number (0, then 1 on a retry)
    ## once the temporary file is written and flushed, just before the rename.
    ## ``nil`` in production.

  PutResult* = object
    ok*: bool
    path*: string ## The record's full path.
    relative*: string ## ``v1/<algorithm>/<digest>/<hash>.toml``.
    signed*: bool
    kept*: bool ## Unsigned, and an existing file was left in place.
    retried*: bool ## The first attempt lost its directory to a prune.
    problem*: string

const
  UserDirMode = 0o700
  UserFileMode = 0o600

proc systemPutSupported*(): bool =
  ## Whether ``put --system`` can keep its no-follow promise on this host.
  not defined(windows)

when not defined(windows):
  proc errorText(context: string): string =
    context & ": " & $strerror(errno)

  proc closeFd(fd: cint) =
    if fd >= 0:
      discard posix.close(fd)

  type DirOpen = object
    fd: cint
    problem: string
    vanished: bool ## A component was missing and ``create`` was false.

  proc openChain(
      rootFd: cint,
      rootPath: string,
      components: openArray[string],
      create, noFollow: bool,
      dirMode: int,
  ): DirOpen =
    ## Open ``components`` below ``rootFd`` one at a time, creating missing
    ## ones when ``create``. With ``noFollow``, a symbolic link at any
    ## component is refused.
    var fd = posix.dup(rootFd)
    if fd < 0:
      return DirOpen(fd: -1, problem: errorText("dup"))
    var shown = rootPath
    for comp in components:
      shown = shown / comp
      var flags = O_RDONLY or O_DIRECTORY or O_CLOEXEC
      if noFollow:
        flags = flags or O_NOFOLLOW
      var next = openat(fd, comp.cstring, flags)
      if next < 0 and errno == ENOENT:
        if not create:
          closeFd(fd)
          return
            DirOpen(fd: -1, vanished: true, problem: "'" & shown & "' does not exist")
        var created = true
        if mkdirat(fd, comp.cstring, Mode(dirMode)) != 0:
          if errno != EEXIST:
            let problem = errorText("could not create '" & shown & "'")
            closeFd(fd)
            return DirOpen(fd: -1, problem: problem)
          created = false # another writer made it first
        next = openat(fd, comp.cstring, flags)
        if next >= 0 and created:
          # `mkdirat` applies the process umask, so a restrictive umask
          # would leave a system-root directory its user cannot read. The
          # permission bits are set again through the descriptor, and only
          # when the umask changed them: `fchmod` by an owner outside the
          # directory's group clears a set-group-id bit inherited from the
          # parent, which is how group ownership carries down.
          var st: Stat
          if fstat(next, st) != 0:
            let problem = errorText("could not stat '" & shown & "'")
            closeFd(next)
            closeFd(fd)
            return DirOpen(fd: -1, problem: problem)
          let perms = int(st.st_mode) and 0o777
          if perms != (dirMode and 0o777) and
              fchmod(next, Mode((int(st.st_mode) and 0o7000) or (dirMode and 0o777))) !=
              0:
            let problem = errorText("could not set the mode of '" & shown & "'")
            closeFd(next)
            closeFd(fd)
            return DirOpen(fd: -1, problem: problem)
      if next < 0:
        let savedErrno = errno
        var st: Stat
        if noFollow and fstatat(fd, comp.cstring, st, AT_SYMLINK_NOFOLLOW) == 0 and
            S_ISLNK(st.st_mode):
          closeFd(fd)
          return DirOpen(
            fd: -1,
            problem:
              "refusing to follow the symbolic link at '" & shown &
              "': a write into the system root never follows links (Transport §2.3)",
          )
        errno = savedErrno
        let problem = errorText("could not open '" & shown & "'")
        closeFd(fd)
        return DirOpen(fd: -1, problem: problem)
      closeFd(fd)
      fd = next
    DirOpen(fd: fd)

  proc sameDirectory(a, b: cint): bool =
    var x, y: Stat
    fstat(a, x) == 0 and fstat(b, y) == 0 and x.st_dev == y.st_dev and
      x.st_ino == y.st_ino

  proc writeAll(fd: cint, bytes: string): bool =
    var written = 0
    while written < bytes.len:
      let n = posix.write(fd, unsafeAddr bytes[written], bytes.len - written)
      if n < 0:
        if errno == EINTR:
          continue
        return false
      written += n
    true

  proc openRoot(
      root: string, system: bool
  ): tuple[fd: cint, dirMode, fileMode: int, problem: string] =
    ## The root's directory descriptor, and the modes for what is created
    ## below it.
    if system:
      let fd =
        posix.open(root.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW)
      if fd < 0:
        if errno == ENOENT:
          return (
            cint(-1),
            0,
            0,
            "the system partition '" & root & "' does not exist; it is created " &
              "by the privileged producer's installer, with ownership and permissions that let its user " &
              "read it and not write it (Transport §2.3)",
          )
        var st: Stat
        if lstat(root.cstring, st) == 0 and S_ISLNK(st.st_mode):
          return (
            cint(-1),
            0,
            0,
            "refusing to follow the symbolic link at the system partition '" & root & "'",
          )
        return (
          cint(-1),
          0,
          0,
          errorText("could not open the system partition '" & root & "'"),
        )
      var st: Stat
      if fstat(fd, st) != 0:
        let problem = errorText("could not stat '" & root & "'")
        closeFd(fd)
        return (cint(-1), 0, 0, problem)
      if st.st_uid != geteuid():
        closeFd(fd)
        return (
          cint(-1),
          0,
          0,
          "the system partition '" & root & "' is owned by uid " & $st.st_uid &
            ", not by this producer's account (uid " & $geteuid() &
            "); a partition its user can " &
            "write is not one a privileged producer may write into (Transport §2.3)",
        )
      let dirMode = int(st.st_mode) and 0o777
      return (fd, dirMode, dirMode and 0o666, "")
    if not dirExists(root):
      try:
        let parent = root.parentDir
        if parent.len > 0 and not dirExists(parent):
          createDir(parent)
        if mkdir(root.cstring, Mode(UserDirMode)) != 0 and errno != EEXIST:
          return
            (cint(-1), 0, 0, errorText("could not create the user root '" & root & "'"))
      except OSError as err:
        return
          (cint(-1), 0, 0, "could not create the user root '" & root & "': " & err.msg)
    let fd = posix.open(root.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if fd < 0:
      return (cint(-1), 0, 0, errorText("could not open the user root '" & root & "'"))
    (fd, UserDirMode, UserFileMode, "")

  proc writeRecord(
      root: string,
      name: StoreName,
      bytes: string,
      signed, system: bool,
      hook: PutStepHook,
  ): PutResult =
    result.relative = name.relativePath
    result.path = root / toNative(result.relative)
    result.signed = signed
    let components = [LayoutVersion, name.algorithm, name.digest]
    let fileName = name.payloadSha256 & RecordSuffix
    for attempt in 0 .. 1:
      result.retried = attempt > 0
      let opened = openRoot(root, system)
      if opened.fd < 0:
        result.problem = opened.problem
        return
      let rootFd = opened.fd
      defer:
        closeFd(rootFd)
      let chain = openChain(
        rootFd, root, components, create = true, noFollow = system, opened.dirMode
      )
      if chain.fd < 0:
        result.problem = chain.problem
        return
      let dirFd = chain.fd
      defer:
        closeFd(dirFd)

      # Whether the directory we hold is still the one the path leads to.
      proc stillInStore(): bool =
        let again = openChain(
          rootFd, root, components, create = false, noFollow = system, opened.dirMode
        )
        if again.fd < 0:
          return false
        result = sameDirectory(again.fd, dirFd)
        closeFd(again.fd)

      if not signed:
        var st: Stat
        if fstatat(dirFd, fileName.cstring, st, AT_SYMLINK_NOFOLLOW) == 0 and
            S_ISREG(st.st_mode):
          discard futimens(dirFd, nil) # mark the content written now (see module doc)
          if stillInStore():
            result.ok = true
            result.kept = true
            return
          if attempt == 0:
            continue
          result.problem =
            "the content directory disappeared twice while it was written"
          return

      let temporary = temporaryName(fileName)
      let tfd = openat(
        dirFd,
        temporary.cstring,
        O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW or O_CLOEXEC,
        cint(opened.fileMode),
      )
      if tfd < 0:
        if errno == ENOENT and attempt == 0:
          continue # the directory was removed under us
        result.problem = errorText(
          "could not create a temporary file in '" & result.path.parentDir & "'"
        )
        return
      var ok =
        fchmod(tfd, Mode(opened.fileMode)) == 0 and writeAll(tfd, bytes) and
        fsync(tfd) == 0
      let writeProblem =
        if ok:
          ""
        else:
          errorText("could not write '" & temporary & "'")
      if posix.close(tfd) != 0 and ok:
        ok = false
      if not ok:
        discard unlinkat(dirFd, temporary.cstring, 0)
        result.problem =
          if writeProblem.len > 0:
            writeProblem
          else:
            errorText("could not close '" & temporary & "'")
        return
      if hook != nil:
        hook(attempt)
      if renameat(dirFd, temporary.cstring, dirFd, fileName.cstring) != 0:
        let savedErrno = errno
        discard unlinkat(dirFd, temporary.cstring, 0)
        if savedErrno == ENOENT and attempt == 0:
          continue # the temporary file vanished: a prune deleted the tree
        errno = savedErrno
        result.problem =
          errorText("could not rename the record into place at '" & result.path & "'")
        return
      discard fsync(dirFd) # durability of the rename; best effort
      if stillInStore():
        result.ok = true
        return
      if attempt == 0:
        continue
      result.problem = "the content directory disappeared twice while it was written"
      return

else:
  proc writeRecord(
      root: string,
      name: StoreName,
      bytes: string,
      signed, system: bool,
      hook: PutStepHook,
  ): PutResult =
    ## Path-based: Windows has no ``openat``. Only the user root is written
    ## here (see ``systemPutSupported``).
    result.relative = name.relativePath
    result.path = root / toNative(result.relative)
    result.signed = signed
    let dir = result.path.parentDir
    for attempt in 0 .. 1:
      result.retried = attempt > 0
      try:
        createDir(dir)
      except OSError as err:
        result.problem = "could not create '" & dir & "': " & err.msg
        return
      if not signed and fileExists(result.path):
        try:
          setLastModificationTime(dir, getTime())
        except OSError:
          discard
        result.ok = true
        result.kept = true
        return
      let temporary = dir / temporaryName(result.path.extractFilename)
      try:
        var f: File
        if not open(f, temporary, fmWrite):
          raise newException(IOError, "cannot open '" & temporary & "'")
        try:
          f.write(bytes)
          f.flushFile()
        finally:
          f.close()
        if hook != nil:
          hook(attempt)
        # MoveFileExW with MOVEFILE_REPLACE_EXISTING: an atomic replace
        # within one volume.
        moveFile(temporary, result.path)
        result.ok = true
        return
      except CatchableError as err:
        try:
          removeFile(temporary)
        except CatchableError:
          discard
        if attempt == 0 and not dirExists(dir):
          continue
        result.problem = "could not write '" & result.path & "': " & err.msg
        return

proc putCertificate*(
    root: string, bytes: string, system = false, beforeRename: PutStepHook = nil
): PutResult =
  ## Parse ``bytes`` as a certificate and write it under its Transport §2.2
  ## name in ``root`` (a user root, or with ``system`` a system partition).
  if root.len == 0:
    return PutResult(problem: "no store root to write to")
  if system and not systemPutSupported():
    return PutResult(
      problem:
        "`put --system` is not supported on this platform: writing a system " &
        "partition without following links is not implemented here (Transport §2.3)"
    )
  let parsed = parseCertificate(bytes)
  if not parsed.ok:
    return
      PutResult(problem: "not a certificate this store can name: " & parsed.problem)
  let name = storeNameOf(parsed.certificate)
  if not name.ok:
    return PutResult(problem: name.problem)
  writeRecord(root, name, bytes, parsed.certificate.isSigned, system, beforeRename)

proc putFile*(root, path: string, system = false): PutResult =
  ## ``putCertificate`` over a file's contents.
  var bytes: string
  try:
    bytes = readFile(path)
  except IOError as err:
    return PutResult(problem: "could not read '" & path & "': " & err.msg)
  except OSError as err:
    return PutResult(problem: "could not read '" & path & "': " & err.msg)
  result = putCertificate(root, bytes, system)
  if not result.ok:
    result.problem = path & ": " & result.problem
