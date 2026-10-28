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

  test "every store variable requires an absolute path on its platform":
    for platform in [rpUnix, rpMacos, rpWindows]:
      let account = if platform == rpWindows: "S-1-5-21-1000" else: "1000"
      let absolute = if platform == rpWindows: r"C:\state" else: "/state"
      var cases = @[
        ("TEST_CERTIFICATES_DIR", absolute, ""),
        (
          "TEST_CERTIFICATES_SYSTEM_DIR",
          (if platform == rpWindows: r"C:\state\S-1-5-21-1000" else: "/state/1000"),
          (
            case platform
            of rpUnix: "/var/lib/test-certificates/1000"
            of rpMacos: "/Library/Application Support/test-certificates/1000"
            of rpWindows: ""
          ),
        ),
      ]
      case platform
      of rpUnix:
        cases.add ("XDG_STATE_HOME", "/state/test-certificates", "")
        cases.add ("HOME", "/state/.local/state/test-certificates", "")
      of rpMacos:
        cases.add ("HOME", "/state/Library/Application Support/test-certificates", "")
      of rpWindows:
        cases.add ("LOCALAPPDATA", r"C:\state\test-certificates", "")
        cases.add ("ProgramData", r"C:\state\test-certificates\S-1-5-21-1000", "")
      for (variable, resolved, fallback) in cases:
        # Unset and empty are separate environment inputs. In each case only
        # this variable can supply the selected root, exposing its own rule.
        for value in [absolute, "relative", "C:drive-relative", "", "<unset>"]:
          var values: seq[(string, string)]
          if value != "<unset>":
            values.add (variable, value)
          let r = resolveRoots(platform, envOf(values), account)
          let system = variable in ["TEST_CERTIFICATES_SYSTEM_DIR", "ProgramData"]
          let actual = if system: r.system else: r.user
          checkpoint $platform & " " & variable & "=" & value
          check actual == (if value == absolute: resolved else: fallback)
          let problem = r.problems.join("\n")
          if value in ["relative", "C:drive-relative"]:
            check variable & (if platform == rpWindows: "%" else: "") &
              " is set to the relative path" in problem
          if actual.len == 0:
            check "the " & (if system: "system" else: "user") &
              " root cannot be resolved" in problem

  test "relative fallback variables never resolve against the current directory":
    # Platform and environment are the resolver's real inputs, so all platforms
    # can be exercised on every host without mocking an operating system.
    for platform in [rpUnix, rpMacos]:
      for home in ["relative-home", ""]:
        let r = resolveRoots(platform, envOf({"HOME": home}), "1000")
        check r.user == ""
        check r.system.len > 0
        check "the user root cannot be resolved" in r.problems[^1]
        if home.len > 0:
          check "$HOME is set to the relative path" in r.problems[0]
        else:
          check r.problems.len == 1
    let sid = "S-1-5-21-123-456-789-1000"
    for value in ["relative-data", "C:drive-relative", ""]:
      let r = resolveRoots(
        rpWindows, envOf({"LOCALAPPDATA": value, "ProgramData": value}), sid
      )
      check r.user == ""
      check r.system == ""
      check r.systemBase == ""
      check "the system root cannot be resolved" in r.problems[^1]
      if value.len > 0:
        check "%LOCALAPPDATA% is set to the relative path" in r.problems[0]
        check "%ProgramData% is set to the relative path" in r.problems[2]
      else:
        check r.problems.len == 2
    # Absolute overrides resolve both roots; unused relative fallbacks need no
    # diagnostic because they were never read.
    for platform in [rpUnix, rpMacos, rpWindows]:
      let user = if platform == rpWindows: r"C:\certs" else: "/certs"
      let base = if platform == rpWindows: r"C:\system" else: "/system"
      let account = if platform == rpWindows: sid else: "1000"
      let r = resolveRoots(
        platform,
        envOf(
          {
            "TEST_CERTIFICATES_DIR": user,
            "TEST_CERTIFICATES_SYSTEM_DIR": base,
            "XDG_STATE_HOME": "relative",
            "HOME": "relative",
            "LOCALAPPDATA": "relative",
            "ProgramData": "relative",
          }
        ),
        account,
      )
      check r.user == user
      check r.system == (
        if platform == rpWindows:
          r"C:\system\S-1-5-21-123-456-789-1000"
        else: "/system/1000"
      )
      check r.problems.len == 0
    # One invalid Windows fallback does not disable the other root, and an
    # invalid system override falls back to an absolute ProgramData.
    let r = resolveRoots(
      rpWindows,
      envOf(
        {
          "LOCALAPPDATA": "relative",
          "ProgramData": r"C:\PD",
          "TEST_CERTIFICATES_SYSTEM_DIR": "relative-system",
        }
      ),
      sid,
    )
    check r.user == ""
    check r.system == r"C:\PD\test-certificates\S-1-5-21-123-456-789-1000"

  test "an unresolved user root is reported and cannot receive a write":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let content = "git-tree-sha1:" & repeat('7', 40)
    let text = certificateText(content)
    let env = @[
      ("TEST_CERTIFICATES_DIR", "relative-store"),
      ("XDG_STATE_HOME", "relative-state"),
      ("HOME", "relative-home"),
      ("LOCALAPPDATA", "relative-local"),
      ("TEST_CERTIFICATES_SYSTEM_DIR", dir / "system"),
    ]
    let root = runCliProcess(["store-root"], env, cwd = dir)
    check root.exitCode == 1
    check root.output.startsWith("user: (unresolved)\n")
    check "the user root cannot be resolved" in root.errors
    let empty = runCliProcess(["find", "--content", content], env, cwd = dir)
    check empty.exitCode == 3
    check empty.output == ""
    check "searched user root (unresolved) [unresolved]" in empty.errors
    let put = runCliProcess(["put", "-"], env, cwd = dir, input = text)
    check put.exitCode != 0
    check put.output == ""
    check "the user root cannot be resolved" in put.errors
    for relative in [
      "relative-store", "relative-state", "relative-home", "relative-local"
    ]:
      check not dirExists(dir / relative)
    # An unresolved user root must not hide a candidate in the system root.
    let stored = putCertificate(dir / "system" / myAccount(), text)
    require stored.ok
    let found = runCliProcess(["find", "--content", content], env, cwd = dir)
    check found.exitCode == 0
    check found.output == stored.path & "\n"
    check "searched user root (unresolved) [unresolved]" in found.errors

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
