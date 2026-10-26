## The note blob: several certificate records in one git note
## (Transport §3.1), read, added to and merged without git.
##
## A blob is split on LINES EQUAL TO the delimiter ``# --- test-certificate
## ---`` (never on occurrences of its text: a canonical record escapes every
## newline inside a value, so no line of one can equal it). Lines end at LF;
## a CR belongs to its line, so a CRLF blob has no delimiter line at all.
##
## * The piece before the first delimiter is dropped when empty. When it is
##   not, it is a ``pkLeading`` piece: reported and kept, never parsed, even
##   when it would parse.
## * Every other piece is parsed as one certificate. One that does not parse
##   (or has no canonical payload) is a ``pkUnparsed`` piece: reported and
##   kept, and its neighbours are still read.
##
## Every piece keeps its exact bytes (``raw``, including the delimiter line
## before it), so ``renderNote(splitNote(b)) == b`` for every blob ``b``, and
## a writer that touches one piece leaves every other piece byte for byte.
##
## Two operations change a note:
##
## * ``addRecord`` is the writer rule of Transport §3.1: a record whose
##   payload is not present is appended; a SIGNED copy of a present payload
##   replaces the first record carrying it, in place; an unsigned copy never
##   replaces anything.
## * ``mergeNotes`` is the union two sides of a notes ref meet in (Tooling §3,
##   "never one side's"). It starts from the ``base`` blob — the side already
##   published — and adds every piece of ``other`` that ``base`` lacks, in
##   ``other``'s order, so the result is a function of the two inputs and of
##   which one is published. See its doc comment for the one place it departs
##   from ``addRecord``.
##
## Specification: Transport.md §3.1 of the test-certificates specification,
## https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#31-multiple-records-in-one-note

import std/strutils
import ./[certificate, sha256]

const NoteDelimiter* = "# --- test-certificate ---"
  ## The line that precedes every record in a note (Transport §3.1).

type
  PieceKind* = enum
    pkLeading ## Non-empty text before the first delimiter: never parsed.
    pkRecord ## A piece that parsed as a certificate with a canonical payload.
    pkUnparsed ## A piece after a delimiter that did not parse.

  NotePiece* = object
    kind*: PieceKind
    raw*: string
      ## The piece's exact bytes in the blob: for ``pkRecord`` and
      ## ``pkUnparsed`` the delimiter line before it, then ``body``; for
      ## ``pkLeading`` the text itself.
    body*: string ## ``raw`` without its delimiter line.
    payloadSha256*: string ## ``pkRecord``: the hash naming its payload.
    signed*: bool ## ``pkRecord``: whether it carries a non-empty signature block.
    certificate*: Certificate ## ``pkRecord``: the parsed record.
    problem*: string ## ``pkUnparsed``: why it does not parse.

  AddOutcome* = enum
    aoAppended ## The payload was not present; the record was appended.
    aoReplaced ## A signed copy replaced the present record in place.
    aoPresent ## The payload is present; nothing changed.

  MergedNote* = object
    blob*: string ## The merged note.
    changed*: bool ## ``blob`` differs from ``base``.
    added*: int ## Pieces of ``other`` appended.
    replaced*: int ## Unsigned records of ``base`` replaced by a signed copy.
    remarks*: seq[string]
      ## What the merge decided that a reader may want to know: a signed copy
      ## kept over another signed copy, leading text joined, a final LF
      ## added.

proc classify(
    body: string
): tuple[kind: PieceKind, c: Certificate, hash: string, problem: string] =
  let parsed = parseCertificate(body)
  if not parsed.ok:
    return (pkUnparsed, Certificate(), "", parsed.problem)
  let payload = canonicalPayload(parsed.certificate)
  if not payload.ok:
    return (pkUnparsed, Certificate(), "", payload.problem)
  (pkRecord, parsed.certificate, sha256Hex(payload.payload), "")

proc pieceAfterDelimiter(raw: string): NotePiece =
  ## A piece from its raw bytes, which begin with the delimiter line.
  result.raw = raw
  result.body =
    if raw.len > NoteDelimiter.len:
      raw[NoteDelimiter.len + 1 ..^ 1]
    else:
      ""
  let c = classify(result.body)
  result.kind = c.kind
  result.certificate = c.c
  result.payloadSha256 = c.hash
  result.signed = c.kind == pkRecord and c.c.isSigned
  result.problem = c.problem

proc isDelimiterLine(blob: string, start, lineEnd: int): bool =
  lineEnd - start == NoteDelimiter.len and blob.continuesWith(NoteDelimiter, start)

proc splitNote*(blob: string): seq[NotePiece] =
  ## Every piece of ``blob``, in blob order (Transport §3.1).
  var delimiters: seq[int]
  var i = 0
  while i < blob.len:
    let nl = blob.find('\n', i)
    let lineEnd = if nl < 0: blob.len else: nl
    if isDelimiterLine(blob, i, lineEnd):
      delimiters.add i
    i =
      if nl < 0:
        blob.len
      else:
        nl + 1
  let firstDelimiter =
    if delimiters.len > 0:
      delimiters[0]
    else:
      blob.len
  if firstDelimiter > 0:
    result.add NotePiece(
      kind: pkLeading,
      raw: blob[0 ..< firstDelimiter],
      body: blob[0 ..< firstDelimiter],
      problem:
        "text before the first `" & NoteDelimiter &
        "` line: a note framed some other way, or not framed; never parsed " &
        "(Transport §3.1)",
    )
  for k, start in delimiters:
    let stop =
      if k + 1 < delimiters.len:
        delimiters[k + 1]
      else:
        blob.len
    result.add pieceAfterDelimiter(blob[start ..< stop])

proc renderNote*(pieces: openArray[NotePiece]): string =
  ## The blob ``pieces`` make, byte for byte.
  for p in pieces:
    result.add p.raw

proc recordPiece*(record: string): NotePiece =
  ## The piece a writer adds for ``record`` (a record in §3.1 form, without
  ## a delimiter): the delimiter line, then the record.
  pieceAfterDelimiter(NoteDelimiter & "\n" & record)

proc terminateLast(pieces: var seq[NotePiece]): bool =
  ## Make sure the blob ends in LF before a piece is appended, so the
  ## appended delimiter starts a line. Only a blob some other writer left
  ## without its final LF needs this; answers whether a byte was added.
  if pieces.len > 0 and pieces[^1].raw.len > 0 and pieces[^1].raw[^1] != '\n':
    pieces[^1].raw.add '\n'
    if pieces[^1].kind == pkLeading or pieces[^1].raw.len > NoteDelimiter.len + 1:
      pieces[^1].body.add '\n'
    return true
  false

proc findRecord(pieces: openArray[NotePiece], payloadSha256: string): int =
  for i, p in pieces:
    if p.kind == pkRecord and p.payloadSha256 == payloadSha256:
      return i
  -1

proc addRecord*(pieces: var seq[NotePiece], record: NotePiece): AddOutcome =
  ## Transport §3.1's writer rule. ``record`` must be a ``pkRecord`` piece
  ## (see ``recordPiece``). A payload already present is never added again;
  ## a signed copy replaces the first record carrying it, in place, unless
  ## that record is byte-identical; an unsigned copy changes nothing. A new
  ## payload goes after the last piece, behind its own delimiter.
  doAssert record.kind == pkRecord
  let at = findRecord(pieces, record.payloadSha256)
  if at >= 0:
    if record.signed and pieces[at].body != record.body:
      pieces[at] = record
      return aoReplaced
    return aoPresent
  discard terminateLast(pieces)
  pieces.add record
  aoAppended

proc withoutFinalLf(s: string): string =
  if s.len > 0 and s[^1] == '\n':
    s[0 ..^ 2]
  else:
    s

proc containsLines(text, lines: string): bool =
  ## Whether ``lines`` occurs in ``text`` as whole lines: starting at the
  ## beginning of a line and ending at the end of one. A bare substring test
  ## would take leading text ``b\n`` as present in ``ab\n`` and drop it.
  var start = 0
  while true:
    let at = text.find(lines, start)
    if at < 0:
      return false
    let stop = at + lines.len
    if (at == 0 or text[at - 1] == '\n') and
        (stop == text.len or lines.endsWith('\n') or text[stop] == '\n'):
      return true
    start = at + 1

proc mergeNotes*(base, other: string): MergedNote =
  ## The union of two note blobs for the same object: ``base`` (the side
  ## already published) with every piece of ``other`` it lacks.
  ##
  ## * A record whose payload ``base`` lacks is appended, byte for byte.
  ## * A signed record of ``other`` replaces an UNSIGNED record of ``base``
  ##   with the same payload, in place (§3.1, as ``addRecord``).
  ## * Where both sides carry a signed copy of one payload and the copies
  ##   differ, ``base``'s is kept and the difference is remarked. This is
  ##   where a merge departs from ``addRecord``: §3.1 lets a new signed copy
  ##   replace a present one because its writer has just made the signature
  ##   (§2.3); a merge has made neither, cannot verify either (Tooling §1),
  ##   and keeping the published copy keeps two clones from trading the
  ##   record back and forth.
  ## * A piece that does not parse is appended unless ``base`` holds one
  ##   with the same body (ignoring a final LF a previous merge may have
  ##   added).
  ## * Leading text ``base`` lacks becomes ``base``'s leading text, or is
  ##   joined after it: it is never parsed, so joining keeps both sides'
  ##   bytes without turning either into a record.
  ##
  ## Merging ``other`` into the result again changes nothing.
  var pieces = splitNote(base)
  for p in splitNote(other):
    case p.kind
    of pkLeading:
      if pieces.len > 0 and pieces[0].kind == pkLeading:
        if not containsLines(pieces[0].raw, p.raw):
          if pieces[0].raw[^1] != '\n':
            pieces[0].raw.add '\n'
          pieces[0].raw.add p.raw
          pieces[0].body = pieces[0].raw
          result.changed = true
          result.remarks.add "both sides carry different text before the first delimiter; it was joined, and is still never parsed"
      else:
        pieces.insert(p, 0)
        result.changed = true
        inc result.added
    of pkRecord:
      let at = findRecord(pieces, p.payloadSha256)
      if at < 0:
        if terminateLast(pieces):
          result.remarks.add "the note did not end in LF; one was added before appending"
        var appended = p
        pieces.add appended
        result.changed = true
        inc result.added
      elif pieces[at].body != p.body:
        if p.signed and not pieces[at].signed:
          pieces[at].raw = p.raw
          pieces[at].body = p.body
          pieces[at].signed = true
          pieces[at].certificate = p.certificate
          result.changed = true
          inc result.replaced
        elif p.signed and pieces[at].signed:
          result.remarks.add "two differently signed copies of payload " &
            p.payloadSha256 & "; the published copy was kept"
    of pkUnparsed:
      var present = false
      for q in pieces:
        if q.kind == pkUnparsed and withoutFinalLf(q.body) == withoutFinalLf(p.body):
          present = true
          break
      if not present:
        if terminateLast(pieces):
          result.remarks.add "the note did not end in LF; one was added before appending"
        pieces.add p
        result.changed = true
        inc result.added
  result.blob = renderNote(pieces)
  if result.blob == base:
    result.changed = false
