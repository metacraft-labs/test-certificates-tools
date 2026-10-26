## store_root_resolution_follows_transport_2_1
##
## Transport §2.1 for every platform, through the pure resolver with a table
## standing in for the environment (the environment IS the input; a table is
## the real value, not a mock of anything), and then through the built
## executable with a real environment, on this host.

import std/[tables, unittest]
import ./helpers
import test_certificates

proc envOf(values: openArray[(string, string)]): Environment =
  let table = values.toTable
  result = proc(name: string): string =
    table.getOrDefault(name, "")

suite "store roots":
  test "store_root_resolution_follows_transport_2_1":
    # Unix: TEST_CERTIFICATES_DIR wins when absolute.
    var r = resolveRoots(
      rpUnix,
      envOf(
        {
          "TEST_CERTIFICATES_DIR": "/srv/certs",
          "XDG_STATE_HOME": "/x",
          "HOME": "/home/u",
        }
      ),
      "1000",
    )
    check r.user == "/srv/certs"
    check r.system == "/var/lib/test-certificates/1000"
    check r.problems.len == 0
    # ... else XDG_STATE_HOME, else HOME.
    r = resolveRoots(
      rpUnix, envOf({"XDG_STATE_HOME": "/state", "HOME": "/home/u"}), "1000"
    )
    check r.user == "/state/test-certificates"
    r = resolveRoots(rpUnix, envOf({"HOME": "/home/u"}), "1000")
    check r.user == "/home/u/.local/state/test-certificates"
    # A relative TEST_CERTIFICATES_DIR / XDG_STATE_HOME is ignored, and said so.
    r = resolveRoots(
      rpUnix,
      envOf(
        {"TEST_CERTIFICATES_DIR": "certs", "XDG_STATE_HOME": "state", "HOME": "/home/u"}
      ),
      "1000",
    )
    check r.user == "/home/u/.local/state/test-certificates"
    check r.problems.len == 2
    check "relative path 'certs'" in r.problems[0]
    check "relative path 'state'" in r.problems[1]
    # An empty variable is unset, not relative.
    r = resolveRoots(
      rpUnix, envOf({"TEST_CERTIFICATES_DIR": "", "HOME": "/home/u"}), "1000"
    )
    check r.user == "/home/u/.local/state/test-certificates"
    check r.problems.len == 0
    # The system root: TEST_CERTIFICATES_SYSTEM_DIR/<uid> when absolute,
    # ignored when relative.
    r = resolveRoots(
      rpUnix, envOf({"HOME": "/h", "TEST_CERTIFICATES_SYSTEM_DIR": "/opt/tc"}), "0"
    )
    check r.system == "/opt/tc/0"
    r = resolveRoots(
      rpUnix, envOf({"HOME": "/h", "TEST_CERTIFICATES_SYSTEM_DIR": "opt/tc"}), "501"
    )
    check r.system == "/var/lib/test-certificates/501"
    check r.problems.len == 1
    # No account: the system root is left unresolved, never guessed.
    r = resolveRoots(rpUnix, envOf({"HOME": "/h"}), "")
    check r.system == ""
    check r.problems.len == 1
    # Nothing to resolve the user root from.
    r = resolveRoots(rpUnix, envOf({"HOME": "relative"}), "1")
    check r.user == ""
    check r.problems.len == 2

    # macOS: no XDG, Application Support under HOME and under /Library.
    r = resolveRoots(
      rpMacos, envOf({"XDG_STATE_HOME": "/state", "HOME": "/Users/u"}), "501"
    )
    check r.user == "/Users/u/Library/Application Support/test-certificates"
    check r.system == "/Library/Application Support/test-certificates/501"
    r = resolveRoots(
      rpMacos, envOf({"TEST_CERTIFICATES_DIR": "/c", "HOME": "/Users/u"}), "501"
    )
    check r.user == "/c"

    # Windows: LOCALAPPDATA, ProgramData and the SID.
    let sid = "S-1-5-21-1004336348-1177238915-682003330-512"
    r = resolveRoots(
      rpWindows,
      envOf(
        {
          "LOCALAPPDATA": "C:\\Users\\u\\AppData\\Local",
          "ProgramData": "C:\\ProgramData",
        }
      ),
      sid,
    )
    check r.user == "C:\\Users\\u\\AppData\\Local\\test-certificates"
    check r.system == "C:\\ProgramData\\test-certificates\\" & sid
    r = resolveRoots(
      rpWindows,
      envOf(
        {
          "TEST_CERTIFICATES_DIR": "D:\\certs",
          "LOCALAPPDATA": "C:\\L",
          "TEST_CERTIFICATES_SYSTEM_DIR": "\\\\server\\share",
          "ProgramData": "C:\\ProgramData",
        }
      ),
      sid,
    )
    check r.user == "D:\\certs"
    check r.system == "\\\\server\\share\\" & sid
    r = resolveRoots(
      rpWindows,
      envOf(
        {
          "TEST_CERTIFICATES_DIR": "certs",
          "LOCALAPPDATA": "C:\\L",
          "ProgramData": "C:\\ProgramData",
        }
      ),
      sid,
    )
    check r.user == "C:\\L\\test-certificates"
    check r.problems.len == 1
    check "%TEST_CERTIFICATES_DIR%" in r.problems[0]
    # A POSIX-absolute path is not absolute on Windows.
    r = resolveRoots(
      rpWindows,
      envOf(
        {
          "TEST_CERTIFICATES_DIR": "/c",
          "LOCALAPPDATA": "C:\\L",
          "ProgramData": "C:\\ProgramData",
        }
      ),
      sid,
    )
    check r.user == "C:\\L\\test-certificates"

    # Account identifiers that could escape the system root are refused.
    for bad in ["../0", "1000/..", "S-1-5", "", "12a"]:
      check systemPartition(rpUnix, envOf(newSeq[(string, string)]()), bad).path == ""
    check systemPartition(rpUnix, envOf(newSeq[(string, string)]()), "1000").path ==
      "/var/lib/test-certificates/1000"
    check systemPartition(rpWindows, envOf({"ProgramData": "C:\\PD"}), sid).path ==
      "C:\\PD\\test-certificates\\" & sid
    for bad in ["S-1-", "S-1-5-x", "1000", "S-1-5-21-..\\x"]:
      check systemPartition(rpWindows, envOf({"ProgramData": "C:\\PD"}), bad).path == ""

  test "the executable resolves this host's roots from the real environment":
    let account = myAccount()
    when defined(windows):
      check account.startsWith("S-1-")
    else:
      check account.allCharsInSet(Digits)
    let dir = scratchDir()
    defer:
      cleanup(dir)
    var run = runCliProcess(["store-root"], storeEnv(dir / "user", dir / "system"))
    check run.exitCode == 0
    check run.output ==
      "user: " & dir / "user" & "\nsystem: " & dir / "system" / account & "\n"
    # The relative variable is ignored and reported; the fallback is used.
    when not defined(windows) and not defined(macosx):
      run = runCliProcess(
        ["store-root"],
        [
          ("TEST_CERTIFICATES_DIR", "rel"),
          ("XDG_STATE_HOME", dir),
          ("TEST_CERTIFICATES_SYSTEM_DIR", ""),
        ],
      )
      check run.exitCode == 0
      check run.output.startsWith("user: " & dir / "test-certificates" & "\n")
      check "relative path 'rel'" in run.errors
      check ("system: /var/lib/test-certificates/" & account & "\n") in run.output
