## The package version: one value, and the package's sources compile from
## their own source tree.
##
## ``test_certificates.nimble`` holds the version the release tooling and the
## flake read; ``src/test_certificates/version.nim`` carries it into the code.
## These tests refuse a mismatch between the two, and compile the library and
## the executable from a copy of ``src/`` with nothing of the checkout around
## it, in the two shapes a consumer receives: the ``src/`` directory on its own
## (a source archive or a vendored tree) and nimble's installed layout (the
## contents of ``src/`` beside the nimble file). The compiles use the real Nim
## compiler that built this test; no mocks.

import std/unittest
import ./helpers
import test_certificates/cli

const compiler = getCurrentCompilerExe()

proc nimbleVersion(): string =
  ## The version the nimble file declares, read the way the release tooling
  ## reads it: the ``version = "..."`` line.
  for line in readFile(repoRoot / "test_certificates.nimble").splitLines:
    let words = line.split('"')
    if words.len >= 3 and words[0].strip() == "version =":
      return words[1]
  fatal "no version line in test_certificates.nimble"

proc nim(args: openArray[string], cwd: string): GitRun =
  ## Run the compiler with no parent configuration from this checkout: the
  ## copy lives in a scratch directory, so the checkout's ``config.nims`` (its
  ## ``--path`` and nimcache) never applies.
  if not fileExists(compiler):
    fatal "the Nim compiler that built this test is gone: " & compiler
  result = runProcess(compiler, args, cwd)
  if not result.started:
    fatal "could not run " & compiler & ": " & result.failure

proc copySources(dest: string) =
  ## The contents of the checkout's ``src/``, and nothing else, into ``dest``.
  createDir(dest)
  for kind, path in walkDir(repoRoot / "src"):
    case kind
    of pcDir, pcLinkToDir:
      copyDir(path, dest / path.extractFilename)
    of pcFile, pcLinkToFile:
      copyFile(path, dest / path.extractFilename)

suite "version":
  test "the code's version is the nimble file's":
    check Version == nimbleVersion()
    let run = runCliProcess(["--version"])
    check run.exitCode == 0
    check run.output == "test-certificates " & nimbleVersion() & "\n"

  test "the library and the executable compile from the src directory alone":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    copySources(scratch / "src")
    for module in ["test_certificates.nim", "test_certificates_cli.nim"]:
      let run = nim(
        [
          "check",
          "--hints:off",
          "--nimcache:" & scratch / "nimcache",
          "--path:" & scratch / "src",
          scratch / "src" / module,
        ],
        scratch,
      )
      checkpoint module & ": " & run.stdout & run.stderr
      check run.exitCode == 0

  test "the executable builds and reports the version in nimble's installed layout":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let pkg = scratch / "pkgs2" / "test_certificates-" & nimbleVersion()
    copySources(pkg)
    copyFile(repoRoot / "test_certificates.nimble", pkg / "test_certificates.nimble")
    let exe = scratch / "test-certificates".addFileExt(ExeExt)
    let build = nim(
      [
        "c",
        "--hints:off",
        "--nimcache:" & scratch / "nimcache",
        "--path:" & pkg,
        "-o:" & exe,
        pkg / "test_certificates_cli.nim",
      ],
      scratch,
    )
    checkpoint build.stdout & build.stderr
    require build.exitCode == 0
    let run = runProcess(exe, ["--version"], scratch)
    check run.started
    check run.exitCode == 0
    check run.stdout == "test-certificates " & nimbleVersion() & "\n"
