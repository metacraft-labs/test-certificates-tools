## A strict TOML 1.0 reader, sized for test certificates.
##
## A certificate must be read from ANY rendering of its fields
## (Canonical-Payload §5): the conformance suite's ``store/`` and ``payload/``
## groups deliberately deliver certificates written with literal strings,
## ``\uXXXX`` escapes, multi-line strings, inline tables, arrays of inline
## tables, multi-line arrays with trailing commas, quoted keys, comments,
## CRLF line endings, and a ``[certificate]`` table defined AFTER its
## sub-tables. A reader that rejects any of those fails a validly signed
## certificate against its own signature, which is why this is a real TOML
## parser rather than a line splitter.
##
## Why not an existing library: the Nim standard library has none; the
## widely used ``parsetoml`` does not compile against Nim 2.2 (a side-effecting
## ``==`` called from a ``func``); and ``toml_serialization``'s value decoder
## rejects exactly the valid "``[certificate]`` after ``[certificate.signature]``"
## documents the suite requires a reader to accept. Both findings were made by
## the other native implementations of this standard and are recorded there.
##
## What it is strict about — each a ``TomlError``, never a guess:
##
## * a key defined twice, a table defined twice, a header that redefines a
##   table made by dotted keys or an inline table, dotted keys that reach into
##   a table defined by a header (TOML 1.0, "Table" and "Inline Table");
## * malformed UTF-8, raw control characters in strings or comments, a lone CR;
## * escapes TOML does not define, and ``\u`` escapes naming surrogates or
##   values above U+10FFFF.
##
## Integers, floats and date-times are syntax-checked and kept as their raw
## text (``tkOther``): nothing a certificate's canonical payload contains has
## one of those types, so their numeric value is never needed, and a known
## field holding one is the record's error, not the parser's.
##
## Newlines inside multi-line strings are returned as LF, whichever of LF and
## CRLF the document used (TOML 1.0 lets a parser normalise them).
##
## Specification: https://toml.io/en/v1.0.0

import std/[strutils, tables, unicode]

type
  TomlError* = object of CatchableError ## The input is not TOML this reader accepts.

  TomlKind* = enum
    tkString
    tkBool
    tkArray
    tkTable
    tkOther ## An integer, float or date-time, kept as raw text.

  TableOrigin = enum
    toImplicit ## Created as a parent by a header (``[a.b]`` creates ``a``).
    toHeader ## Defined by its own ``[header]`` or ``[[header]]``.
    toDotted ## Created by a dotted key (``a.b = 1`` creates ``a``).
    toInline ## Written as ``{ … }``: complete as written.

  TomlNode* = ref object ## A parsed value.
    case kind*: TomlKind
    of tkString:
      str*: string
    of tkBool:
      boolean*: bool
    of tkArray:
      items*: seq[TomlNode]
      ofTables: bool ## Created by ``[[header]]``.
    of tkTable:
      keys*: seq[string] ## In document order.
      fields*: Table[string, TomlNode]
      origin: TableOrigin
      closed: bool ## Inside an inline table: nothing may add to it.
    of tkOther:
      raw*: string

  Parser = object
    s: string
    pos: int
    line: int

proc newTable(origin: TableOrigin): TomlNode =
  TomlNode(kind: tkTable, origin: origin, fields: initTable[string, TomlNode]())

proc fail(p: Parser, msg: string) {.noreturn.} =
  raise newException(TomlError, "line " & $p.line & ": " & msg)

proc atEnd(p: Parser): bool {.inline.} =
  p.pos >= p.s.len

proc peek(p: Parser, offset = 0): char {.inline.} =
  if p.pos + offset < p.s.len:
    p.s[p.pos + offset]
  else:
    '\0'

proc startsWithAt(p: Parser, text: string): bool =
  p.s.continuesWith(text, p.pos)

proc validateUtf8(s: string) =
  ## Reject malformed UTF-8 anywhere in the document (TOML 1.0: "A TOML file
  ## must be a valid UTF-8 encoded Unicode document"). ``std/unicode``'s
  ## ``validateUtf8`` accepts surrogates and overlong forms, so the check is
  ## written out against RFC 3629 §4.
  var i = 0
  var line = 1
  while i < s.len:
    let b = uint8(s[i])
    if b == uint8('\n'):
      inc line
    if b < 0x80:
      inc i
      continue
    var need = 0
    var lo = 0x80'u8
    var hi = 0xBF'u8
    if b >= 0xC2 and b <= 0xDF:
      need = 1
    elif b == 0xE0:
      need = 2
      lo = 0xA0
    elif b >= 0xE1 and b <= 0xEC:
      need = 2
    elif b == 0xED:
      need = 2
      hi = 0x9F # excludes the UTF-16 surrogates U+D800..U+DFFF
    elif b >= 0xEE and b <= 0xEF:
      need = 2
    elif b == 0xF0:
      need = 3
      lo = 0x90
    elif b >= 0xF1 and b <= 0xF3:
      need = 3
    elif b == 0xF4:
      need = 3
      hi = 0x8F # nothing above U+10FFFF
    else:
      raise newException(TomlError, "line " & $line & ": malformed UTF-8")
    if i + need >= s.len:
      raise newException(TomlError, "line " & $line & ": truncated UTF-8 sequence")
    let second = uint8(s[i + 1])
    if second < lo or second > hi:
      raise newException(TomlError, "line " & $line & ": malformed UTF-8")
    for k in 2 .. need:
      let c = uint8(s[i + k])
      if c < 0x80 or c > 0xBF:
        raise newException(TomlError, "line " & $line & ": malformed UTF-8")
    i += need + 1

proc isControl(c: char): bool {.inline.} =
  ## A character TOML forbids raw in strings and comments: U+0000..U+001F
  ## other than TAB, and U+007F. (Newlines are handled by the callers.)
  (c < ' ' and c != '\t') or c == '\x7F'

proc skipWs(p: var Parser) =
  while not p.atEnd and p.peek in {' ', '\t'}:
    inc p.pos

proc atNewline(p: Parser): bool =
  p.peek == '\n' or (p.peek == '\r' and p.peek(1) == '\n')

proc consumeNewline(p: var Parser) =
  if p.peek == '\n':
    inc p.pos
  elif p.peek == '\r' and p.peek(1) == '\n':
    p.pos += 2
  else:
    p.fail("expected a newline")
  inc p.line

proc skipComment(p: var Parser) =
  ## From ``#`` to the end of the line, not including the newline.
  assert p.peek == '#'
  inc p.pos
  while not p.atEnd and not p.atNewline:
    if p.peek == '\r':
      p.fail("a carriage return must be followed by a line feed")
    if isControl(p.peek):
      p.fail("control character in a comment")
    inc p.pos

proc skipWsCommentsNewlines(p: var Parser) =
  ## Whitespace, comments and newlines, as allowed inside an array.
  while not p.atEnd:
    let c = p.peek
    if c in {' ', '\t'}:
      inc p.pos
    elif c == '#':
      p.skipComment()
    elif p.atNewline:
      p.consumeNewline()
    elif c == '\r':
      p.fail("a carriage return must be followed by a line feed")
    else:
      break

proc endOfLine(p: var Parser) =
  ## After a key/value pair or a header: optional whitespace and comment, then
  ## a newline or the end of the document.
  p.skipWs()
  if p.peek == '#':
    p.skipComment()
  if p.atEnd:
    return
  if not p.atNewline:
    p.fail("unexpected `" & $p.peek & "` after a value or header")
  p.consumeNewline()

# ---------------------------------------------------------------------------
# Strings
# ---------------------------------------------------------------------------

proc parseHexEscape(p: var Parser, digits: int): string =
  if p.pos + digits > p.s.len:
    p.fail("truncated \\u escape")
  var value = 0
  for k in 0 ..< digits:
    let c = p.s[p.pos + k]
    let d =
      case c
      of '0' .. '9':
        ord(c) - ord('0')
      of 'a' .. 'f':
        ord(c) - ord('a') + 10
      of 'A' .. 'F':
        ord(c) - ord('A') + 10
      else:
        p.fail("invalid hex digit `" & $c & "` in a \\u escape")
    value = value * 16 + d
  p.pos += digits
  if value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF):
    p.fail(
      "\\u escape names U+" & toHex(value, 4) & ", which is not a Unicode scalar value"
    )
  $Rune(value)

proc parseEscape(p: var Parser, dest: var string) =
  ## After the backslash. TOML 1.0 defines exactly these escapes.
  let c = p.peek
  inc p.pos
  case c
  of 'b':
    dest.add '\b'
  of 't':
    dest.add '\t'
  of 'n':
    dest.add '\n'
  of 'f':
    dest.add '\f'
  of 'r':
    dest.add '\r'
  of '"':
    dest.add '"'
  of '\\':
    dest.add '\\'
  of 'u':
    dest.add p.parseHexEscape(4)
  of 'U':
    dest.add p.parseHexEscape(8)
  else:
    p.fail("unknown escape `\\" & $c & "`")

proc parseBasicString(p: var Parser): string =
  assert p.peek == '"'
  inc p.pos
  while true:
    if p.atEnd or p.atNewline or p.peek == '\r':
      p.fail("unterminated string")
    let c = p.peek
    if c == '"':
      inc p.pos
      return
    if c == '\\':
      inc p.pos
      p.parseEscape(result)
    elif isControl(c):
      p.fail("control character in a string; it must be escaped")
    else:
      result.add c
      inc p.pos

proc parseLiteralString(p: var Parser): string =
  assert p.peek == '\''
  inc p.pos
  while true:
    if p.atEnd or p.atNewline or p.peek == '\r':
      p.fail("unterminated literal string")
    let c = p.peek
    if c == '\'':
      inc p.pos
      return
    if isControl(c):
      p.fail("control character in a literal string")
    result.add c
    inc p.pos

proc parseMultiline(p: var Parser, quote: char): string =
  ## ``"""…"""`` (``quote`` = ``"``) or ``'''…'''`` (``'``).
  let delimiter = repeat(quote, 3)
  assert p.startsWithAt(delimiter)
  p.pos += 3
  # A newline immediately after the opening delimiter is trimmed.
  if p.atNewline:
    p.consumeNewline()
  while true:
    if p.atEnd:
      p.fail("unterminated multi-line string")
    if p.startsWithAt(delimiter):
      # Up to two further quotes belong to the content: `""""` ends with `"`.
      var extra = 0
      while extra < 2 and p.peek(3 + extra) == quote:
        inc extra
      for _ in 0 ..< extra:
        result.add quote
      p.pos += 3 + extra
      return
    let c = p.peek
    if p.atNewline:
      p.consumeNewline()
      result.add '\n'
    elif c == '\r':
      p.fail("a carriage return must be followed by a line feed")
    elif c == '\\' and quote == '"':
      # A line-ending backslash trims all whitespace and newlines after it.
      var look = p.pos + 1
      while look < p.s.len and p.s[look] in {' ', '\t'}:
        inc look
      if look < p.s.len and (
        p.s[look] == '\n' or
        (p.s[look] == '\r' and look + 1 < p.s.len and p.s[look + 1] == '\n')
      ):
        p.pos = look
        while not p.atEnd and (p.peek in {' ', '\t'} or p.atNewline):
          if p.atNewline:
            p.consumeNewline()
          else:
            inc p.pos
      else:
        inc p.pos
        p.parseEscape(result)
    elif isControl(c):
      p.fail("control character in a multi-line string")
    else:
      result.add c
      inc p.pos

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

const BareKeyChars = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-'}

proc parseSimpleKey(p: var Parser): string =
  case p.peek
  of '"':
    if p.startsWithAt("\"\"\""):
      p.fail("a key cannot be a multi-line string")
    p.parseBasicString()
  of '\'':
    if p.startsWithAt("'''"):
      p.fail("a key cannot be a multi-line string")
    p.parseLiteralString()
  of BareKeyChars:
    let start = p.pos
    while not p.atEnd and p.peek in BareKeyChars:
      inc p.pos
    p.s[start ..< p.pos]
  else:
    p.fail("expected a key, found `" & $p.peek & "`")

proc parseKey(p: var Parser): seq[string] =
  ## A possibly dotted key.
  result.add p.parseSimpleKey()
  while true:
    p.skipWs()
    if p.peek != '.':
      return
    inc p.pos
    p.skipWs()
    result.add p.parseSimpleKey()

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

proc parseValue(p: var Parser): TomlNode

proc isDecInt(t: string): bool =
  ## ``[+-]?(0|[1-9](_?[0-9])*)``
  var s = t
  if s.len > 0 and s[0] in {'+', '-'}:
    s = s[1 ..^ 1]
  if s.len == 0 or s[0] notin Digits:
    return false
  if s[0] == '0':
    return s.len == 1
  var prevUnderscore = false
  for c in s:
    if c == '_':
      if prevUnderscore:
        return false
      prevUnderscore = true
    elif c in Digits:
      prevUnderscore = false
    else:
      return false
  not prevUnderscore

proc isDigitRun(t: string, allowed: set[char]): bool =
  ## Digits from ``allowed`` with single underscores between them.
  if t.len == 0 or t[0] == '_' or t[^1] == '_':
    return false
  var prevUnderscore = false
  for c in t:
    if c == '_':
      if prevUnderscore:
        return false
      prevUnderscore = true
    elif c in allowed:
      prevUnderscore = false
    else:
      return false
  true

proc isNumber(t: string): bool =
  if isDecInt(t):
    return true
  if t.len > 2 and t[0] == '0':
    case t[1]
    of 'x':
      return isDigitRun(t[2 ..^ 1], HexDigits)
    of 'o':
      return isDigitRun(t[2 ..^ 1], {'0' .. '7'})
    of 'b':
      return isDigitRun(t[2 ..^ 1], {'0', '1'})
    else:
      discard
  var s = t
  if s.len > 0 and s[0] in {'+', '-'}:
    s = s[1 ..^ 1]
  if s in ["inf", "nan"]:
    return true
  # float = dec-int ( frac [ exp ] / exp ), frac = "." digits, exp = e[+-]?digits
  let ePos = s.find({'e', 'E'})
  var mantissa =
    if ePos >= 0:
      s[0 ..< ePos]
    else:
      s
  if ePos >= 0:
    var exponent = s[ePos + 1 ..^ 1]
    if exponent.len > 0 and exponent[0] in {'+', '-'}:
      exponent = exponent[1 ..^ 1]
    if not isDigitRun(exponent, Digits):
      return false
  let dot = mantissa.find('.')
  if dot >= 0:
    if not isDigitRun(mantissa[dot + 1 ..^ 1], Digits):
      return false
    mantissa = mantissa[0 ..< dot]
  elif ePos < 0:
    return false
  isDecInt(mantissa)

proc isDateTime(t: string): bool =
  ## RFC 3339 date, time, local date-time or offset date-time, as TOML 1.0
  ## spells them. Checked for shape (digit positions and separators), which
  ## is what distinguishes a date-time from garbage; calendar validity is not
  ## needed by anything that reads these values.
  proc digitsAt(s: string, at, n: int): bool =
    if at + n > s.len:
      return false
    for k in at ..< at + n:
      if s[k] notin Digits:
        return false
    true

  proc isTime(s: string): bool =
    # HH:MM:SS(.frac)?(Z|[+-]HH:MM)?
    if not (
      digitsAt(s, 0, 2) and s.len >= 8 and s[2] == ':' and digitsAt(s, 3, 2) and
      s[5] == ':' and digitsAt(s, 6, 2)
    ):
      return false
    var i = 8
    if i < s.len and s[i] == '.':
      inc i
      let start = i
      while i < s.len and s[i] in Digits:
        inc i
      if i == start:
        return false
    if i == s.len:
      return true
    if s[i] in {'Z', 'z'}:
      return i + 1 == s.len
    if s[i] in {'+', '-'}:
      return
        s.len == i + 6 and digitsAt(s, i + 1, 2) and s[i + 3] == ':' and
        digitsAt(s, i + 4, 2)
    false

  if digitsAt(t, 0, 4) and t.len >= 10 and t[4] == '-' and digitsAt(t, 5, 2) and
      t[7] == '-' and digitsAt(t, 8, 2):
    if t.len == 10:
      return true
    if t[10] notin {'T', 't', ' '}:
      return false
    return isTime(t[11 ..^ 1])
  isTime(t)

proc parseOther(p: var Parser): TomlNode =
  ## An integer, float or date-time: the raw token, syntax-checked.
  const tokenChars = {'0' .. '9', 'A' .. 'Z', 'a' .. 'z', '_', '+', '-', '.', ':'}
  let start = p.pos
  while not p.atEnd and p.peek in tokenChars:
    inc p.pos
  # A date and a time may be separated by one space.
  if p.pos - start == 10 and p.peek == ' ' and p.peek(1) in Digits and
      p.s[start + 4] == '-':
    inc p.pos
    while not p.atEnd and p.peek in tokenChars:
      inc p.pos
  let token = p.s[start ..< p.pos]
  if token.len == 0:
    p.fail("expected a value, found `" & $p.peek & "`")
  if not (isNumber(token) or isDateTime(token)):
    p.fail("`" & token & "` is not a TOML value")
  TomlNode(kind: tkOther, raw: token)

proc closeTable(node: TomlNode) =
  ## Mark an inline table, and every table inside it, complete.
  case node.kind
  of tkTable:
    node.closed = true
    for key in node.keys:
      closeTable(node.fields[key])
  of tkArray:
    for item in node.items:
      closeTable(item)
  else:
    discard

proc assignDotted(p: Parser, table: TomlNode, key: seq[string], value: TomlNode) =
  ## ``a.b.c = value`` within ``table``.
  var t = table
  for i in 0 ..< key.len - 1:
    let k = key[i]
    if k notin t.fields:
      let child = newTable(toDotted)
      t.fields[k] = child
      t.keys.add k
      t = child
    else:
      let existing = t.fields[k]
      if existing.kind != tkTable:
        p.fail("`" & key[0 .. i].join(".") & "` is already defined as a value")
      if existing.closed or existing.origin != toDotted:
        p.fail(
          "dotted key `" & key.join(".") & "` would add to table `" &
            key[0 .. i].join(".") & "`, which is already defined"
        )
      t = existing
  let last = key[^1]
  if last in t.fields:
    p.fail("key `" & key.join(".") & "` is defined twice")
  t.fields[last] = value
  t.keys.add last

proc parseInlineTable(p: var Parser): TomlNode =
  assert p.peek == '{'
  inc p.pos
  result = newTable(toInline)
  p.skipWs()
  if p.peek == '}':
    inc p.pos
    return
  while true:
    p.skipWs()
    let key = p.parseKey()
    p.skipWs()
    if p.peek != '=':
      p.fail("expected `=` after a key in an inline table")
    inc p.pos
    p.skipWs()
    let value = p.parseValue()
    assignDotted(p, result, key, value)
    p.skipWs()
    if p.peek == ',':
      inc p.pos
      p.skipWs()
      if p.peek == '}':
        p.fail("an inline table cannot end with a trailing comma")
      continue
    if p.peek == '}':
      inc p.pos
      break
    p.fail("expected `,` or `}` in an inline table (inline tables are on one line)")
  closeTable(result)

proc parseArray(p: var Parser): TomlNode =
  assert p.peek == '['
  inc p.pos
  result = TomlNode(kind: tkArray)
  while true:
    p.skipWsCommentsNewlines()
    if p.peek == ']':
      inc p.pos
      return
    result.items.add p.parseValue()
    p.skipWsCommentsNewlines()
    if p.peek == ',':
      inc p.pos
      continue
    if p.peek == ']':
      inc p.pos
      return
    p.fail("expected `,` or `]` in an array")

proc parseValue(p: var Parser): TomlNode =
  if p.atEnd:
    p.fail("expected a value")
  case p.peek
  of '"':
    if p.startsWithAt("\"\"\""):
      TomlNode(kind: tkString, str: p.parseMultiline('"'))
    else:
      TomlNode(kind: tkString, str: p.parseBasicString())
  of '\'':
    if p.startsWithAt("'''"):
      TomlNode(kind: tkString, str: p.parseMultiline('\''))
    else:
      TomlNode(kind: tkString, str: p.parseLiteralString())
  of '[':
    p.parseArray()
  of '{':
    p.parseInlineTable()
  else:
    if p.startsWithAt("true") and
        (p.pos + 4 >= p.s.len or p.s[p.pos + 4] notin BareKeyChars):
      p.pos += 4
      TomlNode(kind: tkBool, boolean: true)
    elif p.startsWithAt("false") and
        (p.pos + 5 >= p.s.len or p.s[p.pos + 5] notin BareKeyChars):
      p.pos += 5
      TomlNode(kind: tkBool, boolean: false)
    else:
      p.parseOther()

# ---------------------------------------------------------------------------
# Headers and the document
# ---------------------------------------------------------------------------

proc descend(p: Parser, root: TomlNode, key: seq[string]): TomlNode =
  ## The table a header's parent path names, creating implicit tables. The
  ## last element of an array of tables is entered.
  var t = root
  for i, k in key:
    if k notin t.fields:
      let child = newTable(toImplicit)
      t.fields[k] = child
      t.keys.add k
      t = child
      continue
    let existing = t.fields[k]
    case existing.kind
    of tkTable:
      if existing.closed:
        p.fail(
          "table `" & key[0 .. i].join(".") &
            "` is an inline table and cannot be extended"
        )
      t = existing
    of tkArray:
      if not existing.ofTables:
        p.fail("`" & key[0 .. i].join(".") & "` is an array, not a table")
      t = existing.items[^1]
    else:
      p.fail("`" & key[0 .. i].join(".") & "` is already defined as a value")
  t

proc parseHeader(p: var Parser, root: TomlNode): TomlNode =
  ## ``[a.b]`` or ``[[a.b]]``; returns the table that key/values now go into.
  let isArray = p.startsWithAt("[[")
  p.pos += (if isArray: 2 else: 1)
  p.skipWs()
  let key = p.parseKey()
  p.skipWs()
  if isArray:
    if not p.startsWithAt("]]"):
      p.fail("expected `]]` to close an array-of-tables header")
    p.pos += 2
  else:
    if p.peek != ']':
      p.fail("expected `]` to close a table header")
    inc p.pos
  let parent = descend(p, root, key[0 ..^ 2])
  let last = key[^1]
  let shown = key.join(".")
  if isArray:
    if last notin parent.fields:
      let arr = TomlNode(kind: tkArray, ofTables: true)
      parent.fields[last] = arr
      parent.keys.add last
    let arr = parent.fields[last]
    if arr.kind != tkArray or not arr.ofTables:
      p.fail("`" & shown & "` is already defined, and not as an array of tables")
    result = newTable(toHeader)
    arr.items.add result
  else:
    if last notin parent.fields:
      result = newTable(toHeader)
      parent.fields[last] = result
      parent.keys.add last
    else:
      result = parent.fields[last]
      if result.kind != tkTable or result.origin != toImplicit or result.closed:
        p.fail("table `" & shown & "` is defined twice")
      result.origin = toHeader
  p.endOfLine()

proc parseToml*(text: string): TomlNode =
  ## Parse a whole TOML document into its root table.
  try:
    var p = Parser(s: text, line: 1)
    # A UTF-8 byte-order mark is tolerated at the very start.
    if p.startsWithAt("\xEF\xBB\xBF"):
      p.pos = 3
    validateUtf8(text)
    let root = newTable(toHeader)
    var current = root
    while true:
      p.skipWs()
      if p.atEnd:
        break
      let c = p.peek
      if c == '#':
        p.skipComment()
        if not p.atEnd:
          p.consumeNewline()
      elif p.atNewline:
        p.consumeNewline()
      elif c == '\r':
        p.fail("a carriage return must be followed by a line feed")
      elif c == '[':
        current = p.parseHeader(root)
      else:
        let key = p.parseKey()
        p.skipWs()
        if p.peek != '=':
          p.fail("expected `=` after key `" & key.join(".") & "`")
        inc p.pos
        p.skipWs()
        let value = p.parseValue()
        assignDotted(p, current, key, value)
        p.endOfLine()
    root
  except TomlError as err:
    raise err
  except CatchableError as err:
    # Nothing above raises anything else by design; if a bug makes it do so,
    # it is still reported as unreadable input rather than escaping as an
    # exception type the caller does not expect.
    raise newException(TomlError, "internal TOML reader error: " & err.msg)

proc get*(table: TomlNode, key: string): TomlNode =
  ## The value under ``key`` in ``table``, or nil when absent (or when
  ## ``table`` is not a table).
  if table.isNil or table.kind != tkTable:
    return nil
  table.fields.getOrDefault(key, nil)
