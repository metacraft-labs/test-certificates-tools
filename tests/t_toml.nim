## The TOML reader: what it must accept (every rendering the conformance
## suite uses, plus the TOML 1.0 forms around them) and what it must refuse
## (redefinitions, malformed text). Pure parsing; no fixtures, no mocks.

import std/unittest
import test_certificates

proc accepts(text: string): bool =
  try:
    discard parseToml(text)
    true
  except TomlError:
    false

suite "toml reader accepts":
  test "strings of every kind, with escapes":
    let doc = parseToml(
      "a = \"x\\ty\\u00e9\\U0001F600\"\nb = 'C:\\path'\nc = \"\"\"\nline1\nline2\\\n   joined\"\"\"\nd = '''\nraw\\n'''\n"
    )
    check doc.get("a").str == "x\ty\u00e9\u{1F600}"
    check doc.get("b").str == "C:\\path"
    check doc.get("c").str == "line1\nline2joined"
    check doc.get("d").str == "raw\\n"

  test "multi-line strings may end with one or two quotes":
    check parseToml("a = \"\"\"x\"\"\"\"\"\n").get("a").str == "x\"\""
    check parseToml("a = '''x''''\n").get("a").str == "x'"

  test "CRLF line endings, read as LF inside multi-line strings":
    let doc = parseToml("a = \"\"\"\r\none\r\ntwo\"\"\"\r\nb = true\r\n")
    check doc.get("a").str == "one\ntwo"
    check doc.get("b").boolean

  test "a super-table defined after its sub-tables":
    let doc = parseToml("[x.y]\nk = 1\n[[x.z]]\nm = 2\n[x]\nn = 'v'\n")
    check doc.get("x").get("n").str == "v"
    check doc.get("x").get("y").get("k").raw == "1"
    check doc.get("x").get("z").items.len == 1

  test "inline tables, arrays of them, multi-line arrays with trailing commas and comments":
    let doc = parseToml(
      "t = { a = 1, b.c = 'd' }\narr = [\n  { argv = [ 'x', \"y\", ] }, # c\n  { argv = [] }\n]\n"
    )
    check doc.get("t").get("b").get("c").str == "d"
    check doc.get("arr").items.len == 2
    check doc.get("arr").items[0].get("argv").items.len == 2

  test "quoted and dotted keys, and sub-tables of dotted tables":
    let doc = parseToml(
      "\"quoted key\" = 1\n[fruit]\napple.color = 'red'\n[fruit.apple.texture]\nsmooth = true\n"
    )
    check doc.get("quoted key").raw == "1"
    check doc.get("fruit").get("apple").get("texture").get("smooth").boolean

  test "numbers and date-times are kept raw":
    for v in [
      "0", "-17", "1_000", "0xDEAD_beef", "0o755", "0b1101", "3.14", "-0.01", "5e+22",
      "6.626e-34", "inf", "-nan", "1979-05-27T07:32:00Z",
      "1979-05-27 07:32:00.999-07:00", "1979-05-27", "07:32:00",
    ]:
      check parseToml("v = " & v & "\n").get("v").raw == v

  test "a leading byte-order mark and no final newline":
    check parseToml("\xEF\xBB\xBFa = 'b'").get("a").str == "b"

suite "toml reader refuses":
  test "redefinitions":
    check not accepts("a = 1\na = 2\n")
    check not accepts("[a]\n[a]\n")
    check not accepts("[a]\nb.c = 1\n[a.b]\n") # a header over a dotted table
    check not accepts("[a.b.c]\n[a]\nb.c.d = 1\n") # dotted keys into a header table
    check not accepts("a = { b = 1 }\n[a]\n") # an inline table is complete
    check not accepts("a = { b = 1 }\n[a.c]\n")
    check not accepts("a = [1]\n[[a]]\n") # a static array is not an array of tables
    check not accepts("[[a]]\n[a]\n")

  test "malformed text":
    check not accepts("a = \"unterminated\n")
    check not accepts("a = \"bad \\q escape\"\n")
    check not accepts("a = \"\\uD800\"\n") # a surrogate
    check not accepts("a = \"raw\x01control\"\n")
    check not accepts("a = 'x'\rb = 1\n") # a lone CR
    check not accepts("a = \"\xC3\x28\"\n") # malformed UTF-8
    check not accepts("a = \"\xED\xA0\x80\"\n") # an encoded surrogate
    check not accepts("a = 1 b = 2\n")
    check not accepts("a = { b = 1, }\n") # trailing comma in an inline table
    check not accepts("a = {\n b = 1 }\n") # an inline table spans lines
    check not accepts("a = 01\n")
    check not accepts("a = tru\n")
    check not accepts("a =\n")
    check not accepts("[a\n")
