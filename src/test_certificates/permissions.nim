## Ownership and recipient access checks for opened POSIX store directories.
## Extended ACLs require a separate inheritance implementation; refuse them
## explicitly rather than assuming that mode bits describe effective access.
import std/[os, strutils, posix]

{.
  emit: """
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pwd.h>
#include <grp.h>
#include <stdlib.h>
#include <errno.h>
#if defined(__linux__)
#include <sys/xattr.h>
static int tcert_acl_free(int fd) {
  const char *names[] = {"system.posix_acl_access", "system.posix_acl_default", "system.nfs4_acl", "system.richacl"};
  for (unsigned int i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
    if (fgetxattr(fd, names[i], NULL, 0) >= 0) return 0;
    if (errno != ENODATA && errno != ENOTSUP) return -1;
  }
  return 1;
}
#elif defined(__APPLE__)
#include <sys/acl.h>
static int tcert_acl_free(int fd) {
  acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
  /* Darwin reports a file with no extended ACL as NULL with ENOENT, not as an
     empty ACL (acl_get_file(3), ERRORS). */
  if (!acl) return errno == ENOENT ? 1 : -1;
  acl_entry_t entry;
  /* Darwin returns 0 for an entry and -1/EINVAL for an empty valid ACL.
     https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/acl_get_entry.3.html */
  int n = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
  int saved_errno = errno;
  acl_free(acl);
  return n == 0 ? 0 : (saved_errno == EINVAL ? 1 : -1);
}
#else
static int tcert_acl_free(int fd) { return -1; }
#endif
static int tcert_recipient_bits(unsigned int uid, unsigned int gid, unsigned int mode) {
  /* Root can write regardless of discretionary permissions. */
  if (uid == 0) return 7;
  struct passwd *pw = getpwuid((uid_t)uid);
  if (!pw) return -1;
  /* Ask with a buffer and grow it on -1. Sizing it first with a NULL buffer
     relies on glibc reporting the count needed; the BSD/Darwin page does
     not promise it.
     https://man7.org/linux/man-pages/man3/getgrouplist.3.html */
  int count = 64;
  gid_t *groups = NULL;
  for (int tries = 0; tries < 8 && !groups; ++tries) {
    groups = malloc(sizeof(gid_t) * (size_t)count);
    if (!groups) return -1;
    int n = count;
    if (getgrouplist(pw->pw_name, pw->pw_gid, groups, &n) >= 0) {
      count = n;
    } else {
      free(groups);
      groups = NULL;
      count = n > count ? n : count * 2;
    }
  }
  if (!groups) return -1;
  int member = 0;
  for (int i = 0; i < count; ++i) if (groups[i] == (gid_t)gid) member = 1;
  free(groups);
  return member ? ((mode >> 3) & 7) : (mode & 7);
}
"""
.}

proc aclFree(fd: cint): cint {.importc: "tcert_acl_free", nodecl.}
proc recipientBits(
  uid, gid, mode: cuint
): cint {.importc: "tcert_recipient_bits", nodecl.}

type StorePolicy* = object
  system*: bool
  recipient*: Uid
  gid*: Gid
  dirMode*, fileMode*: int

proc checkOwner*(fd: cint, shown: string): string =
  ## Compare effective writer identity to the object actually opened.
  var st: Stat
  if fstat(fd, st) != 0:
    return "could not inspect ownership of '" & shown & "': " & $strerror(errno)
  if st.st_uid != geteuid():
    return
      "the store directory '" & shown & "' is owned by uid " & $st.st_uid &
      ", not by this account (uid " & $geteuid() & ")"

proc checkAccess*(
    fd: cint, shown: string, policy: StorePolicy, requireRead = true
): string =
  ## A system path must remain producer-owned and enforce recipient access.
  result = checkOwner(fd, shown)
  if result.len > 0 or not policy.system:
    return
  let acl = aclFree(fd)
  if acl != 1:
    return
      "unsupported ACL policy at '" & shown &
      "': effective access and inheritance cannot be established"
  var st: Stat
  if fstat(fd, st) != 0:
    return "could not inspect system permissions at '" & shown & "'"
  let bits =
    if policy.recipient == st.st_uid:
      7
    else:
      int(recipientBits(cuint(policy.recipient), cuint(st.st_gid), cuint(st.st_mode)))
  if bits < 0:
    return "could not establish the system recipient's group access at '" & shown & "'"
  if (bits and 2) != 0:
    return "the system recipient can write '" & shown & "'; refusing to enter it"
  let readBits = if S_ISDIR(st.st_mode): 5 else: 4
  if requireRead and (bits and readBits) != readBits:
    return "the system recipient cannot read and traverse '" & shown & "'"

proc systemPolicy*(
    fd: cint, root: string
): tuple[policy: StorePolicy, problem: string] =
  ## The numeric partition name identifies the actual account receiving records.
  result.policy.system = true
  try:
    let value = parseBiggestUInt(root.lastPathPart)
    if value > uint64(high(Uid)):
      raise newException(ValueError, "uid out of range")
    result.policy.recipient = Uid(value)
  except ValueError:
    result.problem = "the system partition must end in its recipient's numeric uid"
    return
  result.problem = checkAccess(fd, root, result.policy)
  if result.problem.len > 0:
    return
  var st: Stat
  if fstat(fd, st) != 0:
    result.problem = "could not inspect the system partition"
    return
  result.policy.gid = st.st_gid
  result.policy.dirMode = int(st.st_mode) and 0o777
  result.policy.fileMode = result.policy.dirMode and 0o666

proc applyPolicy*(fd: cint, policy: StorePolicy, directory: bool): string =
  ## Set group before mode: chown can clear setgid; umask cannot narrow access.
  var st: Stat
  if fstat(fd, st) != 0:
    return "could not inspect created store entry"
  if policy.system and fchown(fd, high(Uid), policy.gid) != 0:
    return "could not inherit the system partition's group: " & $strerror(errno)
  let mode = if directory: policy.dirMode else: policy.fileMode
  if fchmod(fd, Mode((int(st.st_mode) and 0o7000) or mode)) != 0:
    return "could not set created store entry permissions: " & $strerror(errno)
