## Content-Id §1 algorithm names and Tooling §2 opaque relay behavior.
## Uses the real filesystem and built executable; no mocks.
import std/unittest
import ./helpers
import test_certificates

suite "portable algorithm names":
  test "invalid prefixes are malformed before lookup or store access":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let root = dir / "store"
    let outside = dir / "outside"
    writeFile(outside, "sentinel")
    for name in [
      "../x",
      "a/b",
      "a\\b",
      ".x",
      "x.",
      "CON",
      "con",
      "prn",
      "aux",
      "nul",
      "com1",
      "com9",
      "lpt1",
      "lpt9",
      "nul.x",
      "a_b",
      "Upper",
      "é",
      repeat('x', 65),
    ]:
      let content = name & ":aa"
      checkpoint content
      check parseContentId(content).form == cifMalformed
      let file = dir / "input.toml"
      writeFile(file, certificateText(content))
      check runCliProcess(["put", file], storeEnv(root)).exitCode != 0
      check runCliProcess(["find", "--content", content], storeEnv(root)).exitCode == 2
      check not dirExists(root)
      check readFile(outside) == "sentinel"

  test "unknown portable identifiers roundtrip without computation or rewriting":
    let dir = scratchDir()
    defer:
      cleanup(dir)
    let root = dir / "store"
    for name in ["future-v2", "-", "0", "com0", "lpt0", "con-v2", repeat('x', 64)]:
      let content = name & ":a"
      check parseContentId(content).form == cifUnknownAlgorithm
      let file = dir / "input.toml"
      let text = certificateText(content)
      writeFile(file, text)
      let written = runCliProcess(["put", file], storeEnv(root))
      require written.exitCode == 0
      let path = written.output.strip()
      check path.parentDir == root / "v1" / name / "a"
      check readFile(path) == text
      let found = runCliProcess(["find", "--content", content], storeEnv(root))
      check found.exitCode == 0
      check found.output.strip() == path
