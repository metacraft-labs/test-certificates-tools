## The ``*at`` family of POSIX calls, which ``std/posix`` does not bind, and
## the constants they need.
##
## Writing through directory file descriptors is how ``put --system`` keeps
## its promise not to follow symbolic links below the system partition
## (Transport §2.3): each component is opened relative to the previous one
## with ``O_NOFOLLOW``, so a link planted anywhere along the way fails the
## open instead of redirecting a privileged write.
##
## ``openat`` is variadic in C. It is bound with ``{.varargs.}`` so the mode
## argument travels as a C variadic argument, which matters on Apple arm64,
## where variadic and fixed arguments are passed differently.
##
## Specifications:
## https://pubs.opengroup.org/onlinepubs/9799919799/functions/openat.html
## https://pubs.opengroup.org/onlinepubs/9799919799/functions/renameat.html

when defined(windows):
  {.error: "posix_at is POSIX-only".}

import std/posix

var
  O_NOFOLLOW* {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  O_DIRECTORY* {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  AT_SYMLINK_NOFOLLOW* {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint

proc openat*(
  dirfd: cint, path: cstring, flags: cint
): cint {.importc: "openat", header: "<fcntl.h>", varargs, sideEffect.}

proc mkdirat*(
  dirfd: cint, path: cstring, mode: Mode
): cint {.importc: "mkdirat", header: "<sys/stat.h>", sideEffect.}

proc renameat*(
  olddirfd: cint, oldpath: cstring, newdirfd: cint, newpath: cstring
): cint {.importc: "renameat", header: "<stdio.h>", sideEffect.}

proc fstatat*(
  dirfd: cint, path: cstring, buf: var Stat, flags: cint
): cint {.importc: "fstatat", header: "<sys/stat.h>", sideEffect.}

proc unlinkat*(
  dirfd: cint, path: cstring, flags: cint
): cint {.importc: "unlinkat", header: "<unistd.h>", sideEffect.}

proc futimens*(
  fd: cint, times: ptr array[2, Timespec]
): cint {.importc: "futimens", header: "<sys/stat.h>", sideEffect.}

proc c_rename*(
  oldpath, newpath: cstring
): cint {.importc: "rename", header: "<stdio.h>", sideEffect.}
