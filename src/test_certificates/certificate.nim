## The minimum of a certificate record the store needs: parse it, rebuild its
## canonical payload, hash that, and tell a signed record from an unsigned one.
##
## This package does not verify certificates (Tooling §1). It parses one only
## to NAME it: a record is stored under the SHA-256 of its canonical payload
## (Transport §2.2), and the canonical payload is rebuilt from the PARSED
## fields, never sliced out of the file (Canonical-Payload §5), so a
## cosmetically different rendering of the same record lands on the same name.
## Whether the record is signed decides the replacement rule of
## Transport §2.3.
##
## What makes a record unnameable, and so refused rather than stored:
##
## * it is not TOML, or its ``schema`` is not ``test-certificate.v1`` (the v1
##   layout names v1 payloads only);
## * a required field is missing or has the wrong type (Standard §3.1);
## * it has no target, no command, or a command with an empty ``argv``;
## * a value holds a control character Canonical-Payload §4 cannot represent;
## * ``key_id`` or ``base`` is present but empty (Canonical-Payload §2 rules 3
##   and 10: those are omitted, never emitted empty);
## * an unknown key or table appears anywhere, including the document root
##   and ``[certificate.signature]`` (Standard §3.4). Dropping it would name
##   only part of the received claim, even when the signature block is excluded
##   from the canonical payload (Canonical-Payload §5);
## * a signature block with only one of ``algorithm`` and ``value``.
##
## Specification: Canonical-Payload.md and Standard.md §3 of the
## test-certificates specification.

import std/[algorithm, strutils]
import ./[toml, sha256, content_id, layout]

const SchemaV1* = "test-certificate.v1"

type
  SignatureState* = enum
    ssAbsent ## No ``[certificate.signature]`` table.
    ssEmpty ## The table with empty ``algorithm`` and ``value``: unsigned.
    ssPresent ## Both non-empty: signed (not verified here).

  Certificate* = object ## The fields of a ``test-certificate.v1`` record, as parsed.
    framework*, project*, platform*: string
    targets*: seq[string] ## As written; canonicalisation sorts and dedups.
    result*, issuedAt*, issuer*: string
    hasKeyId*: bool
    keyId*: string
    repo*: string
    paths*: seq[string] ## Empty: a whole-repository claim.
    content*: string ## Verbatim.
    untracked*: bool
    hasBase*: bool
    base*: string
    commands*: seq[seq[string]] ## ``argv`` of each command, in order.
    signature*: SignatureState
    signatureAlgorithm*, signatureValue*: string

  CertificateParse* = object
    ok*: bool
    certificate*: Certificate
    problem*: string ## Why the record cannot be read or named.

  PayloadResult* = object
    ok*: bool
    payload*: string ## The canonical payload bytes.
    problem*: string

proc isSigned*(c: Certificate): bool =
  c.signature == ssPresent

# ---------------------------------------------------------------------------
# Canonical payload (Canonical-Payload §2–§4)
# ---------------------------------------------------------------------------

proc escapeValue(value: string, problem: var string): string =
  ## A TOML basic string per Canonical-Payload §4: exactly seven escapes,
  ## everything else literal, and no representation for other controls.
  result = "\""
  for ch in value:
    case ch
    of '\\':
      result.add "\\\\"
    of '"':
      result.add "\\\""
    of '\n':
      result.add "\\n"
    of '\r':
      result.add "\\r"
    of '\t':
      result.add "\\t"
    of '\b':
      result.add "\\b"
    of '\f':
      result.add "\\f"
    of '\0' .. '\x07', '\x0B', '\x0E' .. '\x1F', '\x7F':
      if problem.len == 0:
        problem =
          "control character U+" & toHex(ord(ch), 4) &
          " has no canonical representation (Canonical-Payload §4)"
      result.add ch
    else:
      result.add ch
  result.add '"'

proc sortedUnique*(values: openArray[string]): seq[string] =
  ## Deduplicated, then sorted by raw UTF-8 bytes (Canonical-Payload §3).
  result = @values
  result.sort(byteOrder)
  var w = 0
  for i in 0 ..< result.len:
    if i == 0 or result[i] != result[w - 1]:
      result[w] = result[i]
      inc w
  result.setLen(w)

proc inlineArray(values: openArray[string], problem: var string): string =
  result = "["
  for i, v in values:
    if i > 0:
      result.add ", "
    result.add escapeValue(v, problem)
  result.add "]"

proc canonicalPayload*(c: Certificate): PayloadResult =
  ## The exact bytes a signature over ``c`` covers, or why there are none.
  var problem = ""
  template need(cond: bool, msg: string) =
    if not cond:
      return PayloadResult(problem: msg)

  let targets = sortedUnique(c.targets)
  need(targets.len >= 1, "`targets` must name at least one target (Standard §3.1)")
  need(
    c.commands.len >= 1,
    "at least one [[certificate.command]] is required (Standard §3.1)",
  )
  need(
    not c.hasKeyId or c.keyId.len > 0,
    "`key_id` must be omitted when unsigned, not emitted empty (Canonical-Payload §2 rule 3)",
  )
  need(
    not c.hasBase or c.base.len > 0,
    "`base` must be omitted, not emitted empty (Canonical-Payload §2 rule 10)",
  )
  for p in c.paths:
    need(
      p.len > 0 and not p.startsWith("./") and not p.startsWith("/") and
        not p.endsWith("/") and '\\' notin p,
      "path `" & p & "` is not repo-relative and `/`-separated (Standard §3.2.1)",
    )
  for argv in c.commands:
    need(
      argv.len >= 1,
      "a command's `argv` must carry at least argv[0] (Canonical-Payload §2 rule 7)",
    )

  var lines: seq[string]
  lines.add "schema = " & escapeValue(SchemaV1, problem)
  lines.add ""
  lines.add "[certificate]"
  lines.add "framework = " & escapeValue(c.framework, problem)
  lines.add "project = " & escapeValue(c.project, problem)
  lines.add "platform = " & escapeValue(c.platform, problem)
  lines.add "targets = " & inlineArray(targets, problem)
  lines.add "result = " & escapeValue(c.result, problem)
  lines.add "issued_at = " & escapeValue(c.issuedAt, problem)
  lines.add "issuer = " & escapeValue(c.issuer, problem)
  if c.hasKeyId:
    lines.add "key_id = " & escapeValue(c.keyId, problem)
  lines.add ""
  lines.add "[certificate.vcs]"
  lines.add "repo = " & escapeValue(c.repo, problem)
  if c.paths.len > 0:
    lines.add "paths = " & inlineArray(sortedUnique(c.paths), problem)
  lines.add "content = " & escapeValue(c.content, problem)
  lines.add "untracked = " & (if c.untracked: "true" else: "false")
  if c.hasBase:
    lines.add "base = " & escapeValue(c.base, problem)
  for argv in c.commands:
    lines.add ""
    lines.add "[[certificate.command]]"
    lines.add "argv = " & inlineArray(argv, problem)
  if problem.len > 0:
    return PayloadResult(problem: problem)
  PayloadResult(ok: true, payload: lines.join("\n") & "\n")

proc canonicalRecord*(c: Certificate): PayloadResult =
  ## The record form a git note carries (Transport §3.1): the canonical
  ## payload, followed, when signed, by one blank line and the
  ## ``[certificate.signature]`` table with ``algorithm`` and ``value`` in
  ## that order, in the payload's formatting rules. An unsigned record,
  ## including one with the emptied block (Canonical-Payload §6), is its
  ## payload alone.
  result = canonicalPayload(c)
  if not result.ok or not c.isSigned:
    return
  var problem = ""
  result.payload.add "\n[certificate.signature]\n"
  result.payload.add "algorithm = " & escapeValue(c.signatureAlgorithm, problem) & "\n"
  result.payload.add "value = " & escapeValue(c.signatureValue, problem) & "\n"
  if problem.len > 0:
    return PayloadResult(problem: problem)

# ---------------------------------------------------------------------------
# Reading a record
# ---------------------------------------------------------------------------

const
  CertificateKeys = [
    "framework", "project", "platform", "targets", "result", "issued_at", "issuer",
    "key_id", "vcs", "command", "signature",
  ]
  VcsKeys = ["repo", "paths", "content", "untracked", "base"]

proc parseCertificate*(text: string): CertificateParse =
  ## Read a record from any valid TOML rendering of it.
  var doc: TomlNode
  try:
    doc = parseToml(text)
  except TomlError as err:
    return CertificateParse(problem: "not valid TOML: " & err.msg)

  var problem = ""
  template bad(msg: string) =
    return CertificateParse(problem: msg)

  proc str(
      table: TomlNode, key, where: string, problem: var string, optional = false
  ): (bool, string) =
    let node = table.get(key)
    if node.isNil:
      if not optional and problem.len == 0:
        problem = "required field `" & where & key & "` is missing"
      return (false, "")
    if node.kind != tkString:
      if problem.len == 0:
        problem = "`" & where & key & "` must be a string"
      return (false, "")
    (true, node.str)

  proc strArray(
      table: TomlNode, key, where: string, problem: var string, optional = false
  ): (bool, seq[string]) =
    let node = table.get(key)
    if node.isNil:
      if not optional and problem.len == 0:
        problem = "required field `" & where & key & "` is missing"
      return (false, @[])
    if node.kind != tkArray:
      if problem.len == 0:
        problem = "`" & where & key & "` must be an array of strings"
      return (false, @[])
    var values: seq[string]
    for item in node.items:
      if item.kind != tkString:
        if problem.len == 0:
          problem = "`" & where & key & "` must be an array of strings"
        return (false, @[])
      values.add item.str
    (true, values)

  let schema = doc.get("schema")
  if schema.isNil:
    bad("required field `schema` is missing")
  if schema.kind != tkString:
    bad("`schema` must be a string")
  if schema.str != SchemaV1:
    bad(
      "schema `" & schema.str & "` is not " & SchemaV1 &
        ", the only schema this store layout names"
    )
  for key in doc.keys:
    if key notin ["schema", "certificate"]:
      bad("`" & key & "` is not a field of " & SchemaV1)
  let cert = doc.get("certificate")
  if cert.isNil or cert.kind != tkTable:
    bad("the [certificate] table is missing")
  for key in cert.keys:
    if key notin CertificateKeys:
      bad("`certificate." & key & "` is not a field of " & SchemaV1)

  var c: Certificate
  c.framework = str(cert, "framework", "certificate.", problem)[1]
  c.project = str(cert, "project", "certificate.", problem)[1]
  c.platform = str(cert, "platform", "certificate.", problem)[1]
  c.targets = strArray(cert, "targets", "certificate.", problem)[1]
  c.result = str(cert, "result", "certificate.", problem)[1]
  c.issuedAt = str(cert, "issued_at", "certificate.", problem)[1]
  c.issuer = str(cert, "issuer", "certificate.", problem)[1]
  (c.hasKeyId, c.keyId) = str(cert, "key_id", "certificate.", problem, optional = true)
  if problem.len > 0:
    bad(problem)

  let vcs = cert.get("vcs")
  if vcs.isNil or vcs.kind != tkTable:
    bad("the [certificate.vcs] table is missing")
  for key in vcs.keys:
    if key notin VcsKeys:
      bad(
        "`certificate.vcs." & key & "` is not a field of " & SchemaV1 &
          " (an earlier-draft record is re-issued, never translated: Canonical-Payload §7.1)"
      )
  c.repo = str(vcs, "repo", "certificate.vcs.", problem)[1]
  c.paths = strArray(vcs, "paths", "certificate.vcs.", problem, optional = true)[1]
  c.content = str(vcs, "content", "certificate.vcs.", problem)[1]
  (c.hasBase, c.base) = str(vcs, "base", "certificate.vcs.", problem, optional = true)
  let untracked = vcs.get("untracked")
  if untracked.isNil:
    if problem.len == 0:
      problem = "required field `certificate.vcs.untracked` is missing"
  elif untracked.kind != tkBool:
    if problem.len == 0:
      problem = "`certificate.vcs.untracked` must be a boolean"
  else:
    c.untracked = untracked.boolean
  if problem.len > 0:
    bad(problem)

  let commands = cert.get("command")
  if commands.isNil:
    bad("required field `certificate.command` is missing")
  if commands.kind != tkArray:
    bad("`certificate.command` must be an array of tables")
  for entry in commands.items:
    if entry.kind != tkTable:
      bad("`certificate.command` must be an array of tables")
    for key in entry.keys:
      if key != "argv":
        bad("`certificate.command." & key & "` is not a field of " & SchemaV1)
    let (_, argv) = strArray(entry, "argv", "certificate.command.", problem)
    if problem.len > 0:
      bad(problem)
    c.commands.add argv

  let signature = cert.get("signature")
  if signature.isNil:
    c.signature = ssAbsent
  else:
    if signature.kind != tkTable:
      bad("`certificate.signature` must be a table")
    for key in signature.keys:
      if key notin ["algorithm", "value"]:
        bad("`certificate.signature." & key & "` is not a field of " & SchemaV1)
    let (hasAlgorithm, algorithm) =
      str(signature, "algorithm", "certificate.signature.", problem, optional = true)
    let (hasValue, value) =
      str(signature, "value", "certificate.signature.", problem, optional = true)
    if problem.len > 0:
      bad(problem)
    c.signatureAlgorithm = algorithm
    c.signatureValue = value
    if algorithm.len == 0 and value.len == 0:
      # Absent or empty `algorithm` and `value` both mean unsigned
      # (Canonical-Payload §6); a table holding neither key is read the same.
      discard hasAlgorithm
      discard hasValue
      c.signature = ssEmpty
    elif algorithm.len > 0 and value.len > 0:
      c.signature = ssPresent
    else:
      bad(
        "the [certificate.signature] table has " & (
          if algorithm.len > 0: "an algorithm but no value"
          else: "a value but no algorithm"
        ) &
          ": it is neither a signature nor the empty unsigned form (Canonical-Payload §6)"
      )

  CertificateParse(ok: true, certificate: c)

# ---------------------------------------------------------------------------
# Naming (Transport §2.2)
# ---------------------------------------------------------------------------

type StoreName* = object
  ## Where a record lives in a root, as ``/``-separated components.
  ok*: bool
  algorithm*: string ## ``<algorithm>``, the content id before its first `:`.
  digest*: string ## ``<digest>``, after it.
  payloadSha256*: string ## The file name, without ``.toml``.
  problem*: string

proc relativePath*(n: StoreName): string =
  ## ``v1/<algorithm>/<digest>/<payload-hash>.toml``, ``/``-separated whatever
  ## the platform (the form ``expected-path.txt`` uses).
  LayoutVersion & "/" & n.algorithm & "/" & n.digest & "/" & n.payloadSha256 & ".toml"

proc contentDirOf*(
    contentId: string
): tuple[ok: bool, algorithm, digest, problem: string] =
  ## The two directory components a content id names: split at its FIRST
  ## `:`. Requires a well-formed id, or a well-formed one in an algorithm
  ## Content-Id §4 does not define whose name is a safe directory name.
  let parsed = parseContentId(contentId)
  case parsed.form
  of cifMalformed:
    (
      false,
      "",
      "",
      "content id `" & contentId & "` is malformed: " & parsed.problem &
        " (Content-Id §1)",
    )
  of cifUnknownAlgorithm:
    if not isSafeStoreComponent(parsed.algorithmName):
      (
        false,
        "",
        "",
        "content id `" & contentId &
          "` names an algorithm that cannot be a directory name",
      )
    else:
      (true, parsed.algorithmName, parsed.digest, "")
  of cifWellFormed:
    (true, parsed.algorithmName, parsed.digest, "")

proc storeNameOf*(c: Certificate): StoreName =
  ## The record's §2.2 name. Requires a well-formed ``content`` (Tooling §2,
  ## ``put``) and a canonical payload.
  let dir = contentDirOf(c.content)
  if not dir.ok:
    return StoreName(problem: dir.problem)
  let payload = canonicalPayload(c)
  if not payload.ok:
    return StoreName(problem: payload.problem)
  StoreName(
    ok: true,
    algorithm: dir.algorithm,
    digest: dir.digest,
    payloadSha256: sha256Hex(payload.payload),
  )
