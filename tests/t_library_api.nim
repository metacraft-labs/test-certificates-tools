## The library as a consumer links it: the README's example, and the command
## line driven in-process through ``runCli`` (the same procedure the
## executable calls), against a real scratch store. No mocks.

import std/unittest
import ./helpers
import test_certificates
import test_certificates/cli

suite "library api":
  test "the README example compiles and works":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let repo = newRepo()
    defer:
      cleanup(repo)
    writeFile(repo / "f", "f\n")
    discard gitIn(repo, ["add", "f"])
    let tree = gitIn(repo, ["write-tree"]).strip()
    # The README runs in a repository holding cert.toml (untracked).
    writeFile(repo / "cert.toml", certificateText("git-tree-sha1:" & tree))
    let previous = getCurrentDir()
    setCurrentDir(repo)
    defer:
      setCurrentDir(previous)
    putEnv("TEST_CERTIFICATES_DIR", dir / "store")
    putEnv("TEST_CERTIFICATES_SYSTEM_DIR", dir / "system")

    # --- the README's example, verbatim ---
    let roots = nativeRoots()
    let written = putCertificate(roots.user, readFile("cert.toml"))
    if not written.ok:
      echo written.problem

    let report =
      find(roots, FindQuery(byContent: false, repository: ".", state: stagedState()))
    for candidate in report.candidates:
      echo candidate.path
    # --- end ---

    check written.ok
    check report.outcome == foFound
    check report.candidates.len == 1
    check report.candidates[0].path == written.path

  test "runCli answers the exit status and never terminates the process":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    putEnv("TEST_CERTIFICATES_DIR", dir / "store")
    let outPath = dir / "out"
    let errPath = dir / "err"
    var output = open(outPath, fmWrite)
    var errors = open(errPath, fmWrite)
    let io = CliIo(input: stdin, output: output, errors: errors)
    check runCli(["--version"], io) == 0
    check runCli(["no-such-command"], io) == 2
    check runCli([], io) == 2
    check runCli(["find", "--content", "git-tree-sha1:" & repeat('5', 40)], io) == 1
    check runCli(["put", dir / "missing.toml"], io) == 1
    output.close()
    errors.close()
    check readFile(outPath).startsWith("test-certificates " & Version & "\n")
    check "unknown command no-such-command" in readFile(errPath)
    check "could not read" in readFile(errPath)

  test "unknown keys and tables are malformed at every record level":
    let valid = certificateText("git-tree-sha1:" & repeat('5', 40))
    check parseCertificate(valid).ok
    check parseCertificate(
      valid & "\n[certificate.signature]\nalgorithm = ''\nvalue = ''\n"
    ).ok
    for malformed in [
      "unexpected = 'claim'\n" & valid,
      valid.replace("[certificate]", "[certificate]\nunexpected = 'claim'"),
      valid.replace("[certificate.vcs]", "[certificate.vcs]\nunexpected = 'claim'"),
      valid.replace(
        "[[certificate.command]]", "[[certificate.command]]\nunexpected = 'claim'"
      ),
      valid &
        "\n[certificate.signature]\nalgorithm = ''\nvalue = ''\nunexpected = 'claim'\n",
      valid & "\n[extension]\nunexpected = 'claim'\n",
      valid & "\n[extension]\n",
      valid & "\n[certificate.extension]\n",
      valid & "\n[certificate.vcs.extension]\n",
      valid & "\n[certificate.command.extension]\n",
      valid & "\n[certificate.signature.extension]\n",
      valid &
        "\n[certificate.signature]\nalgorithm = ''\nvalue = ''\n[certificate.signature.extension]\nunexpected = 'claim'\n",
    ]:
      let parsed = parseCertificate(malformed)
      check not parsed.ok
      check "not a field" in parsed.problem
