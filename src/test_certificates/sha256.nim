## SHA-256 (FIPS 180-4), streaming.
##
## The store names every certificate by the SHA-256 of its canonical payload
## (Transport §2.2), and ``manifest-v1-sha256`` content ids hash every file
## (Content-Id §4.2). The Nim standard library has no SHA-256, and this
## package deliberately depends on nothing beyond it, so that the store
## operations can be linked into any Nim producer without dragging a
## dependency tree along. The digest identifies public content and involves
## no key, so a constant-time implementation is not required; correctness
## is, and ``tests/t_sha256.nim`` checks it against the FIPS 180-4 examples
## and against the system ``sha256sum`` across the padding boundaries.
##
## Specification: https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf

const
  RoundConstants: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32,
    0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32,
    0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32,
    0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32, 0x983e5152'u32,
    0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
    0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32,
    0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32,
    0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32, 0x19a4c116'u32, 0x1e376c08'u32,
    0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32,
    0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32,
  ]

  InitialState: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32, 0x510e527f'u32,
    0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32,
  ]

type Sha256* = object
  ## An incremental SHA-256 computation. Feed it with ``update`` and read the
  ## result once with ``hexDigest``.
  state: array[8, uint32]
  buffer: array[64, uint8]
  buffered: int ## Bytes held in ``buffer``, always < 64 between calls.
  total: uint64 ## Bytes fed so far.

proc rotr(x: uint32, n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

proc compress(s: var array[8, uint32], chunk: openArray[uint8]) =
  ## One 64-byte block of FIPS 180-4 §6.2.2.
  var w: array[64, uint32]
  for t in 0 ..< 16:
    w[t] =
      (uint32(chunk[t * 4]) shl 24) or (uint32(chunk[t * 4 + 1]) shl 16) or
      (uint32(chunk[t * 4 + 2]) shl 8) or uint32(chunk[t * 4 + 3])
  for t in 16 ..< 64:
    let s0 = rotr(w[t - 15], 7) xor rotr(w[t - 15], 18) xor (w[t - 15] shr 3)
    let s1 = rotr(w[t - 2], 17) xor rotr(w[t - 2], 19) xor (w[t - 2] shr 10)
    w[t] = w[t - 16] + s0 + w[t - 7] + s1
  var
    a = s[0]
    b = s[1]
    c = s[2]
    d = s[3]
    e = s[4]
    f = s[5]
    g = s[6]
    h = s[7]
  for t in 0 ..< 64:
    let bigS1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
    let ch = (e and f) xor ((not e) and g)
    let t1 = h + bigS1 + ch + RoundConstants[t] + w[t]
    let bigS0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
    let maj = (a and b) xor (a and c) xor (b and c)
    let t2 = bigS0 + maj
    h = g
    g = f
    f = e
    e = d + t1
    d = c
    c = b
    b = a
    a = t1 + t2
  s[0] += a
  s[1] += b
  s[2] += c
  s[3] += d
  s[4] += e
  s[5] += f
  s[6] += g
  s[7] += h

proc initSha256*(): Sha256 =
  ## A fresh computation.
  result.state = InitialState

proc update*(ctx: var Sha256, data: openArray[char]) =
  ## Feed ``data``'s bytes.
  ctx.total += uint64(data.len)
  var i = 0
  if ctx.buffered > 0:
    while i < data.len and ctx.buffered < 64:
      ctx.buffer[ctx.buffered] = uint8(data[i])
      inc ctx.buffered
      inc i
    if ctx.buffered == 64:
      compress(ctx.state, ctx.buffer)
      ctx.buffered = 0
  var chunk: array[64, uint8]
  while data.len - i >= 64:
    for k in 0 ..< 64:
      chunk[k] = uint8(data[i + k])
    compress(ctx.state, chunk)
    i += 64
  while i < data.len:
    ctx.buffer[ctx.buffered] = uint8(data[i])
    inc ctx.buffered
    inc i

proc hexDigest*(ctx: var Sha256): string =
  ## Finish the computation and return the lowercase hex digest. The context
  ## must not be fed again afterwards.
  let bitLength = ctx.total * 8
  # Padding (FIPS 180-4 §5.1.1): a 1 bit, zeros up to 56 mod 64 bytes, then
  # the message length in bits as a big-endian 64-bit integer.
  var padding = @[char(0x80)]
  while (ctx.total + uint64(padding.len)) mod 64 != 56:
    padding.add char(0)
  for shift in countdown(56, 0, 8):
    padding.add char((bitLength shr uint64(shift)) and 0xff)
  let total = ctx.total
  ctx.update(padding)
  ctx.total = total
  const hexChars = "0123456789abcdef"
  result = newStringOfCap(64)
  for word in ctx.state:
    for shift in countdown(28, 0, 4):
      result.add hexChars[int((word shr uint32(shift)) and 0xf)]

proc sha256Hex*(data: openArray[char]): string =
  ## Lowercase hex SHA-256 of ``data``'s bytes.
  var ctx = initSha256()
  ctx.update(data)
  ctx.hexDigest()
