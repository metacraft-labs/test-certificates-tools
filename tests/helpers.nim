## Shared fixtures for the test suite: scratch directories, real git
## repositories, the built ``test-certificates`` binary, and the
## specification's conformance vectors at a pinned commit.
##
## No mocks: every test runs against the real filesystem, a real ``git`` and
## the real executable. Where a test needs to interleave two parties (a
## writer and a pruner), it uses the library's documented test seams
## (``PutStepHook``, ``PruneStepHook``) to choose the interleaving, and the
## parties themselves are the real code.
##
## Prerequisites FAIL the suite loudly, never skip it: the binary
## (``just build``), ``git`` on ``PATH``, and a checkout of the specification
## repository that contains the pinned commit.

import std/[os, strutils, tempfiles, times]
import test_certificates
import test_certificates/git

when not defined(windows):
  import std/posix except Time

export os, strutils, times, git

let repoRoot* = currentSourcePath().parentDir.parentDir

proc fatal*(msg: string) {.noreturn.} =
  ## Stop the whole test binary: a missing prerequisite is a failure, not a
  ## reason to report fewer tests.
  stderr.writeLine "FATAL: " & msg
  quit 1

proc cliBinary*(): string =
  ## The built executable. The Justfile's ``test`` recipe builds it first and
  ## exports ``TEST_CERTIFICATES_BIN``.
  result = getEnv(
    "TEST_CERTIFICATES_BIN",
    repoRoot / "build" / "bin" / "test-certificates".addFileExt(ExeExt),
  )
  if not fileExists(result):
    fatal "the test-certificates binary is not built at " & result &
      " (run `just build`)"

proc scratchDir*(prefix = "tcert-"): string =
  ## A fresh directory, removed by ``cleanup``.
  createTempDir(prefix, "")

proc cleanup*(dir: string) =
  ## Remove a scratch directory, restoring permissions a test removed first.
  if dir.len == 0 or not dirExists(dir):
    return
  for path in walkDirRec(dir, yieldFilter = {pcDir}, followFilter = {pcDir}):
    try:
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError:
      discard
  try:
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    removeDir(dir)
  except OSError:
    discard

type CliRun* = object
  exitCode*: int
  output*: string ## Standard output.
  errors*: string ## Standard error.

proc runCliProcess*(
    args: openArray[string], env: openArray[(string, string)] = [], cwd = "", input = ""
): CliRun =
  ## Run the built binary with ``env`` added to this process's environment.
  var e: seq[(string, string)] = @env
  let run = runProcess(
    cliBinary(),
    args,
    if cwd.len > 0:
      cwd
    else:
      getCurrentDir(),
    e,
    input,
  )
  if not run.started:
    fatal "could not run " & cliBinary() & ": " & run.failure
  CliRun(exitCode: run.exitCode, output: run.stdout, errors: run.stderr)

proc storeEnv*(user: string, systemBase = ""): seq[(string, string)] =
  ## The environment selecting a scratch store.
  result = @[("TEST_CERTIFICATES_DIR", user)]
  if systemBase.len > 0:
    result.add ("TEST_CERTIFICATES_SYSTEM_DIR", systemBase)

proc myAccount*(): string =
  let a = currentAccount()
  if not a.ok:
    fatal "cannot determine this process's account: " & a.problem
  a.account

proc gitIn*(dir: string, args: openArray[string], input = ""): string =
  ## Run git in ``dir`` (no temporary index); fail the suite if it fails.
  let run = runProcess(
    "git",
    @[
      "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c",
      "commit.gpgsign=false", "-c", "init.defaultBranch=main",
    ] & @args,
    dir,
    [],
    input,
  )
  if not run.started:
    fatal "git is not runnable: " & run.failure
  if run.exitCode != 0:
    fatal "`git " & args.join(" ") & "` failed in " & dir & ": " & run.stderr
  run.stdout

proc newRepo*(objectFormat = "sha1"): string =
  ## A fresh repository in a scratch directory.
  result = scratchDir("tcert-repo-")
  discard gitIn(result, ["init", "-q", "--object-format=" & objectFormat])

proc commitAll*(repo: string, message = "commit") =
  discard gitIn(repo, ["add", "-A"])
  discard gitIn(repo, ["commit", "-q", "--allow-empty", "-m", message])

# ---------------------------------------------------------------------------
# Certificates
# ---------------------------------------------------------------------------

proc certificateText*(
    content: string,
    targets = @["t-unit"],
    signed = false,
    issuedAt = "2026-06-23T10:14:33Z",
    platform = "linux/amd64",
    emptyBlock = false,
): string =
  ## A canonical-form certificate for ``content``. ``signed`` adds ``key_id``
  ## and a (syntactically present, never verified here) signature block.
  result = "schema = \"test-certificate.v1\"\n\n[certificate]\n"
  result.add "framework = \"example-framework\"\nproject = \"example\"\n"
  result.add "platform = \"" & platform & "\"\n"
  var quoted: seq[string]
  for t in targets:
    quoted.add "\"" & t & "\""
  result.add "targets = [" & quoted.join(", ") & "]\n"
  result.add "result = \"passed\"\nissued_at = \"" & issuedAt &
    "\"\nissuer = \"tests@host\"\n"
  if signed:
    result.add "key_id = \"example-key\"\n"
  result.add "\n[certificate.vcs]\nrepo = \"example\"\ncontent = \"" & content &
    "\"\nuntracked = false\n"
  result.add "\n[[certificate.command]]\nargv = [\"example-test\", \"run\"]\n"
  if signed:
    result.add "\n[certificate.signature]\nalgorithm = \"ed25519\"\nvalue = \"c2lnbmF0dXJl\"\n"
  elif emptyBlock:
    result.add "\n[certificate.signature]\nalgorithm = \"\"\nvalue = \"\"\n"

proc relativeOf*(text: string): string =
  ## The §2.2 relative path the library derives for ``text``.
  let parsed = parseCertificate(text)
  doAssert parsed.ok, parsed.problem
  let name = storeNameOf(parsed.certificate)
  doAssert name.ok, name.problem
  name.relativePath

# ---------------------------------------------------------------------------
# The specification's vectors, at a pinned commit
# ---------------------------------------------------------------------------

proc specCheckout*(): string =
  ## The specification repository, from ``TEST_CERTIFICATES_SPEC_DIR`` or the
  ## sibling checkout the workspace places next to this one.
  result =
    getEnv("TEST_CERTIFICATES_SPEC_DIR", repoRoot.parentDir / "test-certificates-spec")
  if not dirExists(result):
    fatal "the test-certificates-spec checkout is missing at " & result &
      " (clone https://github.com/metacraft-labs/test-certificates-spec there, or set TEST_CERTIFICATES_SPEC_DIR)"

proc readPin*(path: string): tuple[pin, problem: string] =
  ## A pin file: exactly one line holding a full 40-hex commit id.
  if not fileExists(path):
    return ("", "the pin file does not exist: " & path)
  let text = readFile(path)
  let pin = text.strip(leading = false, chars = {'\n'})
  if pin.len != 40 or not pin.allCharsInSet({'0' .. '9', 'a' .. 'f'}) or
      text != pin & "\n":
    return (
      "",
      "the pin file " & path & " must hold one full lowercase commit id and a newline",
    )
  (pin, "")

proc extractVectorsAt*(repository, pin, dest: string): string =
  ## Write ``vectors/`` as it is at commit ``pin`` of ``repository`` into
  ## ``dest``, from git's object store (never the checkout's working tree,
  ## which may be on any revision). Returns "" or the problem.
  let probe = git(repository, ["cat-file", "-e", pin & "^{commit}"])
  if not probe.ok:
    return
      "the pinned commit " & pin & " is not in " & repository & " (fetch it: `git -C " &
      repository & " fetch origin`)"
  let listing = git(repository, ["ls-tree", "-r", "-z", pin, "--", "vectors"])
  if not listing.ok:
    return listing.failure
  var count = 0
  for record in nulRecords(listing.stdout):
    let tab = record.find('\t')
    let fields = record[0 ..< tab].split(' ')
    let path = record[tab + 1 ..^ 1]
    if fields[1] != "blob":
      continue
    let blob = git(repository, ["cat-file", "blob", fields[2]])
    if not blob.ok:
      return blob.failure
    let target = dest / path
    createDir(target.parentDir)
    writeFile(target, blob.stdout)
    inc count
  if count == 0:
    return "commit " & pin & " has no vectors/ directory"
  ""

proc pinnedVectors*(): string =
  ## A scratch copy of the vectors at the commit ``tests/spec-vectors.pin``
  ## names. The caller removes it with ``cleanup``.
  let (pin, problem) = readPin(repoRoot / "tests" / "spec-vectors.pin")
  if problem.len > 0:
    fatal problem
  let dest = scratchDir("tcert-vectors-")
  let failure = extractVectorsAt(specCheckout(), pin, dest)
  if failure.len > 0:
    cleanup(dest)
    fatal failure
  dest / "vectors"

proc ageTree*(path: string, secondsAgo: int) =
  ## Date ``path`` ``secondsAgo`` seconds in the past.
  setLastModificationTime(path, getTime() - initDuration(seconds = secondsAgo))

proc recipientAccount*(): string =
  ## A real, distinct account for system-store tests. The writer cannot also
  ## be the recipient: its ownership grants write access.
  when defined(windows):
    myAccount()
  else:
    let entry = getpwnam("nobody")
    if entry == nil or entry.pw_uid == geteuid():
      fatal "system-store tests require a distinct nobody account"
    $entry.pw_uid
