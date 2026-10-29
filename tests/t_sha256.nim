## SHA-256 against the FIPS 180-4 examples and against the system
## ``sha256sum`` (GNU coreutils) at every length around the 64-byte block and
## 56-byte padding boundaries, and on a large random input fed in uneven
## pieces. No mocks.

import std/[random, unittest]
import ./helpers
import test_certificates

proc systemSha256(data: string): string =
  let run = runProcess("sha256sum", ["-"], getCurrentDir(), [], data)
  if not run.started or run.exitCode != 0:
    fatal "sha256sum is not runnable: " & run.failure & run.stderr
  run.stdout.split(' ')[0]

suite "sha256":
  test "FIPS 180-4 examples":
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

  test "agrees with sha256sum around every padding boundary":
    var r = initRand(20261025)
    for length in 0 .. 200:
      var data = newString(length)
      for i in 0 ..< length:
        data[i] = char(r.rand(255))
      check sha256Hex(data) == systemSha256(data)

  test "streaming in uneven pieces equals one shot":
    var r = initRand(7)
    var data = newString(1_000_003)
    for i in 0 ..< data.len:
      data[i] = char(r.rand(255))
    var ctx = initSha256()
    var at = 0
    while at < data.len:
      let n = min(data.len - at, r.rand(1 .. 977))
      ctx.update(data.toOpenArray(at, at + n - 1))
      at += n
    let streamed = ctx.hexDigest()
    check streamed == sha256Hex(data)
    check streamed == systemSha256(data)
