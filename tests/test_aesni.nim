import unittest
import dynasm

# AES-NI backend: byte-exact goldens (host-independent, VecAssembler)
# plus execution tests gated by host CPU (AES-NI via cpuid, not just
# arch: unlike SSE2, AES-NI is not guaranteed on amd64).

template rejects(body: untyped) =
  static:
    assert not compiles(body), "expected a compile-time error"

template accepts(body: untyped) =
  static:
    assert compiles(body), "expected this to compile"

test "aesni round instruction encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    aesenc xmm0, xmm1
    aesenclast xmm0, xmm1
    aesdec xmm0, xmm1
    aesdeclast xmm0, xmm1
    aesimc xmm0, xmm1
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x38'u8, 0xDC'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0xDD'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0xDE'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0xDF'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0xDB'u8, 0xC1'u8]

test "aesni high registers and memory forms":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    aesenc xmm8, xmm9
    aesdec xmm8, xmm15
    aesenc xmm0, [rax]
    aesenclast xmm2, [rdx]
    aesenc xmm1, [rbx + rcx*8 + 16]
    movdqa xmm0, dqword [rax]
    aesenc xmm0, oword [rbx + 8]
  check v.finalize() == @[0x66'u8, 0x45'u8, 0x0F'u8, 0x38'u8, 0xDC'u8,
    0xC1'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x38'u8, 0xDE'u8, 0xC7'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0xDC'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0xDD'u8, 0x12'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0xDC'u8, 0x4C'u8, 0xCB'u8, 0x10'u8,
    0x66'u8, 0x0F'u8, 0x6F'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0xDC'u8, 0x43'u8, 0x08'u8]

test "aeskeygenassist encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    aeskeygenassist xmm1, xmm2, 0x01
    aeskeygenassist xmm0, [rax], 0x10
    aeskeygenassist xmm8, xmm9, 0x2B
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x3A'u8, 0xDF'u8, 0xCA'u8,
    0x01'u8,
    0x66'u8, 0x0F'u8, 0x3A'u8, 0xDF'u8, 0x00'u8, 0x10'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x3A'u8, 0xDF'u8, 0xC1'u8, 0x2B'u8]

test "integer sse pxor movdqa movdqu encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    pxor xmm0, xmm1
    pxor xmm0, [rax]
    pxor xmm8, xmm15
    movdqa xmm0, xmm1
    movdqa xmm0, [rax]
    movdqa [rax], xmm1
    movdqu xmm0, xmm1
    movdqu xmm0, [rax]
    movdqu [rax], xmm1
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0xEF'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0xEF'u8, 0x00'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0xEF'u8, 0xC7'u8,
    0x66'u8, 0x0F'u8, 0x6F'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x6F'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0x7F'u8, 0x08'u8,
    0xF3'u8, 0x0F'u8, 0x6F'u8, 0xC1'u8,
    0xF3'u8, 0x0F'u8, 0x6F'u8, 0x00'u8,
    0xF3'u8, 0x0F'u8, 0x7F'u8, 0x08'u8]

test "aesni RIP-relative constant pool":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    global rkpool
    u8 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
      0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
    aesenc xmm0, [glob("rkpool")]
    movdqa xmm1, [glob("rkpool")]
    ret()
  let code = v.finalize()
  # 16 data + 9 (66 0F 38 DC 05 rel32) + 8 (66 0F 6F 05 rel32) + 1.
  # NB: the 0F38 forms are one byte longer than single-opcode SSE.
  check code.len == 34
  check code[16] == 0x66'u8
  check code[17] == 0x0F'u8
  check code[18] == 0x38'u8
  check code[19] == 0xDC'u8
  check code[20] == 0x05'u8
  # rel32 from end of first insn (25) back to pool start (0): -25.
  check code[21] == 0xE7'u8
  check code[22] == 0xFF'u8
  check code[25] == 0x66'u8
  check code[28] == 0x0D'u8
  # rel32 from end of second insn (33) back to pool start: -33.
  check code[29] == 0xDF'u8
  check code[33] == 0xC3'u8

test "aesni operand rules are enforced":
  var ops = initVecAssembler(0)
  accepts:
    dynasm ops:
      arch x64
      aesenc xmm0, xmm1
  accepts:
    dynasm ops:
      arch x64
      aeskeygenassist xmm0, xmm1, 0x01
  accepts:
    dynasm ops:
      arch x64
      pxor xmm0, [rax]
  accepts:
    dynasm ops:
      arch x64
      movdqa [rax], xmm1
  accepts:
    dynasm ops:
      arch x64
      movdqu xmm0, dqword [rax]
  rejects:
    dynasm ops:
      arch x64
      aesenc rax, xmm0
  rejects:
    dynasm ops:
      arch x64
      aesenc xmm0
  rejects:
    dynasm ops:
      arch x64
      aesenc xmm0, xmm1, xmm2
  rejects:
    dynasm ops:
      arch x64
      aesenc [rax], [rbx]
  rejects:
    dynasm ops:
      arch x64
      aesenc xmm0, dword [rax]
  rejects:
    dynasm ops:
      arch x64
      aesenc xmm0, [rax + xmm1]
  rejects:
    dynasm ops:
      arch x64
      aeskeygenassist xmm0, xmm1
  rejects:
    dynasm ops:
      arch x64
      aeskeygenassist xmm0, xmm1, 256
  rejects:
    dynasm ops:
      arch x64
      aeskeygenassist xmm0, xmm1, -1
  rejects:
    dynasm ops:
      arch x64
      aeskeygenassist xmm0, 5, 0x01
  rejects:
    dynasm ops:
      arch x64
      pxor xmm0, 5
  rejects:
    dynasm ops:
      arch x64
      movdqa rax, xmm0
  rejects:
    dynasm ops:
      arch x64
      movdqa xmm0, rax
  rejects:
    dynasm ops:
      arch x64
      movdqa xmm0, qword [rax]
  rejects:
    dynasm ops:
      arch x64
      movdqu [rax], [rbx]
  rejects:
    dynasm ops:
      arch x64
      movdqa xmm0, [rax + xmm1]
  rejects:
    dynasm ops:
      arch aarch64
      aesenc xmm0, xmm1
  rejects:
    dynasm ops:
      arch aarch64
      aeskeygenassist xmm0, xmm1, 0x01
  rejects:
    dynasm ops:
      arch aarch64
      pxor xmm0, xmm1

# --------------------------------------------------------------------------
# Scalar AES-128 reference (test oracle only): S-box computed via
# GF(2^8) inverse + affine transform, so no 256-byte table to typo.
# --------------------------------------------------------------------------

func rotl8(x: uint8, n: int): uint8 =
  (x shl n) or (x shr (8 - n))

func gmul(a, b: uint8): uint8 =
  var aa = a
  var bb = b
  var r = 0'u8
  while bb != 0'u8:
    if (bb and 1'u8) != 0'u8:
      r = r xor aa
    let hi = (aa and 0x80'u8) != 0'u8
    aa = aa shl 1
    if hi:
      aa = aa xor 0x1b'u8
    bb = bb shr 1
  r

func sboxOf(x: uint8): uint8 =
  var inv = 0'u8
  if x != 0'u8:
    var r = 1'u8
    var b = x
    var e = 254
    while e > 0:
      if (e and 1) != 0:
        r = gmul(r, b)
      b = gmul(b, b)
      e = e shr 1
    inv = r
  inv xor rotl8(inv, 1) xor rotl8(inv, 2) xor rotl8(inv, 3) xor
    rotl8(inv, 4) xor 0x63'u8

func invSboxOf(y: uint8): uint8 =
  for i in 0 ..< 256:
    if sboxOf(cast[uint8](i)) == y:
      return cast[uint8](i)
  0'u8 # unreachable

const RconArr = [0x01'u8, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
  0x1b, 0x36]

func expandKey128(key: array[16, uint8]): array[11, array[16, uint8]] =
  var w: array[44, array[4, uint8]]
  for i in 0 ..< 4:
    for j in 0 ..< 4:
      w[i][j] = key[4 * i + j]
  for i in 4 ..< 44:
    var t = w[i - 1]
    if i mod 4 == 0:
      # NB: explicit temp; t = [t[1], t[2], t[3], t[0]] miscompiles
      # (in-place element stores clobber t[0] before the last read).
      let r0 = t[0]
      t = [t[1], t[2], t[3], r0]
      for j in 0 ..< 4:
        t[j] = sboxOf(t[j])
      t[0] = t[0] xor RconArr[i div 4 - 1]
    for j in 0 ..< 4:
      w[i][j] = w[i - 4][j] xor t[j]
  for k in 0 ..< 11:
    for i in 0 ..< 4:
      for j in 0 ..< 4:
        result[k][4 * i + j] = w[4 * k + i][j]

func shiftRowsFwd(s: var array[16, uint8]) =
  let t = s
  for r in 0 ..< 4:
    for c in 0 ..< 4:
      s[r + 4 * c] = t[r + 4 * ((c + r) mod 4)]

func shiftRowsInv(s: var array[16, uint8]) =
  let t = s
  for r in 0 ..< 4:
    for c in 0 ..< 4:
      s[r + 4 * c] = t[r + 4 * ((c - r + 4) mod 4)]

func mixColumn(s: var array[16, uint8]) =
  for c in 0 ..< 4:
    let a0 = s[4 * c]
    let a1 = s[1 + 4 * c]
    let a2 = s[2 + 4 * c]
    let a3 = s[3 + 4 * c]
    s[4 * c] = gmul(a0, 2'u8) xor gmul(a1, 3'u8) xor a2 xor a3
    s[1 + 4 * c] = a0 xor gmul(a1, 2'u8) xor gmul(a2, 3'u8) xor a3
    s[2 + 4 * c] = a0 xor a1 xor gmul(a2, 2'u8) xor gmul(a3, 3'u8)
    s[3 + 4 * c] = gmul(a0, 3'u8) xor a1 xor a2 xor gmul(a3, 2'u8)

func invMixColumn(s: var array[16, uint8]) =
  for c in 0 ..< 4:
    let a0 = s[4 * c]
    let a1 = s[1 + 4 * c]
    let a2 = s[2 + 4 * c]
    let a3 = s[3 + 4 * c]
    s[4 * c] = gmul(a0, 0x0e'u8) xor gmul(a1, 0x0b'u8) xor
      gmul(a2, 0x0d'u8) xor gmul(a3, 0x09'u8)
    s[1 + 4 * c] = gmul(a0, 0x09'u8) xor gmul(a1, 0x0e'u8) xor
      gmul(a2, 0x0b'u8) xor gmul(a3, 0x0d'u8)
    s[2 + 4 * c] = gmul(a0, 0x0d'u8) xor gmul(a1, 0x09'u8) xor
      gmul(a2, 0x0e'u8) xor gmul(a3, 0x0b'u8)
    s[3 + 4 * c] = gmul(a0, 0x0b'u8) xor gmul(a1, 0x0d'u8) xor
      gmul(a2, 0x09'u8) xor gmul(a3, 0x0e'u8)

func aesEncBlock(rk: array[11, array[16, uint8]],
    pt: array[16, uint8]): array[16, uint8] =
  var s = pt
  for j in 0 ..< 16:
    s[j] = s[j] xor rk[0][j]
  for rnd in 1 ..< 10:
    for j in 0 ..< 16:
      s[j] = sboxOf(s[j])
    shiftRowsFwd(s)
    mixColumn(s)
    for j in 0 ..< 16:
      s[j] = s[j] xor rk[rnd][j]
  for j in 0 ..< 16:
    s[j] = sboxOf(s[j])
  shiftRowsFwd(s)
  for j in 0 ..< 16:
    s[j] = s[j] xor rk[10][j]
  s

func aesDecBlock(rk: array[11, array[16, uint8]],
    ct: array[16, uint8]): array[16, uint8] =
  var s = ct
  for j in 0 ..< 16:
    s[j] = s[j] xor rk[10][j]
  for rnd in countdown(9, 1):
    shiftRowsInv(s)
    for j in 0 ..< 16:
      s[j] = invSboxOf(s[j])
    for j in 0 ..< 16:
      s[j] = s[j] xor rk[rnd][j]
    invMixColumn(s)
  shiftRowsInv(s)
  for j in 0 ..< 16:
    s[j] = invSboxOf(s[j])
  for j in 0 ..< 16:
    s[j] = s[j] xor rk[0][j]
  s

func decSchedule(rk: array[11, array[16, uint8]]): array[11,
    array[16, uint8]] =
  ## Equivalent-inverse-cipher schedule for aesdec/aesdeclast.
  result[0] = rk[10]
  result[10] = rk[0]
  for i in 1 ..< 10:
    var t = rk[10 - i]
    invMixColumn(t)
    result[i] = t

func assistEmu(src: array[16, uint8], imm: uint8): array[16, uint8] =
  ## Scalar model of aeskeygenassist, validated against silicon.
  ## DEST[31:0] = SubWord(w1); DEST[63:32] = SubWord(RotWord(w1))^Rcon;
  ## DEST[95:64] = SubWord(w3); DEST[127:96] = SubWord(RotWord(w3))^Rcon.
  for j in 0 ..< 4:
    result[j] = sboxOf(src[4 + j])
  let r1 = [src[5], src[6], src[7], src[4]]
  for j in 0 ..< 4:
    result[4 + j] = sboxOf(r1[j])
  result[4] = result[4] xor imm
  for j in 0 ..< 4:
    result[8 + j] = sboxOf(src[12 + j])
  let r3 = [src[13], src[14], src[15], src[12]]
  for j in 0 ..< 4:
    result[12 + j] = sboxOf(r3[j])
  result[12] = result[12] xor imm

when defined(amd64):
  proc hostHasAesNi(): bool =
    ## Runtime cpuid.01H:ECX[25]; arch gating alone is not enough
    ## since AES-NI is not guaranteed on amd64.
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      push rbx
      mov eax, 1
      db 0x0F, 0xA2 # cpuid (no mnemonic yet)
      mov edx, 33554432 # 1 shl 25
      test ecx, edx
      setnz al
      movzx eax, al
      pop rbx
      ret()
    var buf = a.finalize()
    type Fn = proc(): int32 {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    let r = f()
    buf.destroy()
    r != 0

  proc jitAes128Enc(rk: array[11, array[16, uint8]],
      pt: var array[16, uint8], ct: var array[16, uint8]) =
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias inptr, rdi, rcx
      alias rkptr, rsi, rdx
      alias outptr, rdx, r8
      movdqu xmm0, [inptr]
      movdqu xmm1, [rkptr]
      pxor xmm0, xmm1
      aesenc xmm0, [rkptr + 16]
      aesenc xmm0, [rkptr + 32]
      aesenc xmm0, [rkptr + 48]
      aesenc xmm0, [rkptr + 64]
      aesenc xmm0, [rkptr + 80]
      aesenc xmm0, [rkptr + 96]
      aesenc xmm0, [rkptr + 112]
      aesenc xmm0, [rkptr + 128]
      aesenc xmm0, [rkptr + 144]
      aesenclast xmm0, [rkptr + 160]
      movdqu [outptr], xmm0
      ret()
    var buf = a.finalize()
    type Fn = proc(a, b, c: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr pt, addr rk, addr ct)
    buf.destroy()

  proc jitAes128Dec(dk: array[11, array[16, uint8]],
      ct: var array[16, uint8], pt: var array[16, uint8]) =
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias inptr, rdi, rcx
      alias rkptr, rsi, rdx
      alias outptr, rdx, r8
      movdqu xmm0, [inptr]
      movdqu xmm1, [rkptr]
      pxor xmm0, xmm1
      aesdec xmm0, [rkptr + 16]
      aesdec xmm0, [rkptr + 32]
      aesdec xmm0, [rkptr + 48]
      aesdec xmm0, [rkptr + 64]
      aesdec xmm0, [rkptr + 80]
      aesdec xmm0, [rkptr + 96]
      aesdec xmm0, [rkptr + 112]
      aesdec xmm0, [rkptr + 128]
      aesdec xmm0, [rkptr + 144]
      aesdeclast xmm0, [rkptr + 160]
      movdqu [outptr], xmm0
      ret()
    var buf = a.finalize()
    type Fn = proc(a, b, c: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr ct, addr dk, addr pt)
    buf.destroy()

  proc jitAesimc(x: array[16, uint8]): array[16, uint8] =
    var a = newAssembler(akX64)
    var s = x
    var o: array[16, uint8]
    dynasm a:
      arch x64
      alias inptr, rdi, rcx
      alias outptr, rsi, rdx
      movdqu xmm0, [inptr]
      aesimc xmm0, xmm0
      movdqu [outptr], xmm0
      ret()
    var buf = a.finalize()
    type Fn = proc(a, b: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr s, addr o)
    buf.destroy()
    o

  proc jitAssist(src: array[16, uint8], imm: int64): array[16, uint8] =
    var a = newAssembler(akX64)
    var s = src
    var o: array[16, uint8]
    let ib = imm
    dynasm a:
      arch x64
      alias inptr, rdi, rcx
      alias outptr, rsi, rdx
      movdqu xmm0, [inptr]
      aeskeygenassist xmm1, xmm0, ib
      movdqu [outptr], xmm1
      ret()
    var buf = a.finalize()
    type Fn = proc(a, b: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr s, addr o)
    buf.destroy()
    o

  test "aes128 ecb encrypt matches NIST KAT":
    if not hostHasAesNi():
      skip()
    var key: array[16, uint8]
    var pt: array[16, uint8]
    for i in 0 ..< 16:
      key[i] = cast[uint8](i)
      pt[i] = cast[uint8](i * 17)
    let rk = expandKey128(key)
    let want: array[16, uint8] = [0x69'u8, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b,
      0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a]
    check aesEncBlock(rk, pt) == want # scalar oracle sanity
    var p = pt
    var c: array[16, uint8]
    jitAes128Enc(rk, p, c)
    check c == want

  test "aes128 ecb decrypt round-trips":
    if not hostHasAesNi():
      skip()
    var key: array[16, uint8]
    var pt: array[16, uint8]
    for i in 0 ..< 16:
      key[i] = cast[uint8](i * 3 + 1)
      pt[i] = cast[uint8](i * 17 + 5)
    let rk = expandKey128(key)
    let ct = aesEncBlock(rk, pt)
    check aesDecBlock(rk, ct) == pt # scalar oracle sanity
    let dk = decSchedule(rk)
    var c = ct
    var p: array[16, uint8]
    jitAes128Dec(dk, c, p)
    check p == pt

  test "aesimc matches scalar invmixcolumn":
    if not hostHasAesNi():
      skip()
    var x: array[16, uint8]
    for i in 0 ..< 16:
      x[i] = cast[uint8](i * 11 + 7)
    var want = x
    invMixColumn(want)
    check jitAesimc(x) == want

  test "aeskeygenassist matches scalar model":
    if not hostHasAesNi():
      skip()
    var src: array[16, uint8]
    for i in 0 ..< 16:
      src[i] = cast[uint8](i)
    for imm in [0x01'u8, 0x10, 0x36, 0x00]:
      check jitAssist(src, cast[int64](imm)) == assistEmu(src, imm)
    var z: array[16, uint8]
    check jitAssist(z, 0x01) == assistEmu(z, 0x01)
