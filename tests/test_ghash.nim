import unittest
import dynasm

# GHASH SSE set (PCLMULQDQ era): byte-exact goldens (host-independent,
# VecAssembler) plus execution micro-tests gated by host CPU (PCLMULQDQ
# via cpuid, not just arch: unlike SSE2, it is not guaranteed on amd64).

template rejects(body: untyped) =
  static:
    assert not compiles(body), "expected a compile-time error"

template accepts(body: untyped) =
  static:
    assert compiles(body), "expected this to compile"

test "pshufb encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    pshufb xmm0, xmm1
    pshufb xmm8, xmm9
    pshufb xmm0, [rax]
    pshufb xmm1, [rbx + rcx*8 + 16]
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x38'u8, 0x00'u8, 0xC1'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x38'u8, 0x00'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0x00'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0x38'u8, 0x00'u8, 0x4C'u8, 0xCB'u8, 0x10'u8]

test "pshufd encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    pshufd xmm0, xmm1, 0x0E
    pshufd xmm8, xmm9, 0x0E
    pshufd xmm0, [rax], 0x0E
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x70'u8, 0xC1'u8, 0x0E'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x70'u8, 0xC1'u8, 0x0E'u8,
    0x66'u8, 0x0F'u8, 0x70'u8, 0x00'u8, 0x0E'u8]

test "pclmulqdq encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    pclmulqdq xmm0, xmm1, 0x00
    pclmulqdq xmm0, xmm1, 0x11
    pclmulqdq xmm0, [rax], 0x00
    pclmulqdq xmm8, xmm9, 0x11
    pclmulqdq xmm1, [rbx + rcx*8 + 16], 0x00
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x3A'u8, 0x44'u8, 0xC1'u8,
    0x00'u8,
    0x66'u8, 0x0F'u8, 0x3A'u8, 0x44'u8, 0xC1'u8, 0x11'u8,
    0x66'u8, 0x0F'u8, 0x3A'u8, 0x44'u8, 0x00'u8, 0x00'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x3A'u8, 0x44'u8, 0xC1'u8, 0x11'u8,
    0x66'u8, 0x0F'u8, 0x3A'u8, 0x44'u8, 0x4C'u8, 0xCB'u8, 0x10'u8,
    0x00'u8]

test "punpcklqdq and por encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    punpcklqdq xmm0, xmm1
    punpcklqdq xmm0, [rax]
    por xmm0, xmm1
    por xmm0, [rax]
    por xmm8, xmm15
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x6C'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x6C'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0xEB'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0xEB'u8, 0x00'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0xEB'u8, 0xC7'u8]

test "qword shift encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    psllq xmm0, 1
    psrlq xmm0, 63
    psllq xmm8, 1
    psrlq xmm8, 63
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x73'u8, 0xF0'u8, 0x01'u8,
    0x66'u8, 0x0F'u8, 0x73'u8, 0xD0'u8, 0x3F'u8,
    0x66'u8, 0x41'u8, 0x0F'u8, 0x73'u8, 0xF0'u8, 0x01'u8,
    0x66'u8, 0x41'u8, 0x0F'u8, 0x73'u8, 0xD0'u8, 0x3F'u8]

test "ghash RIP-relative constant pool":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    global bswap
    u8 0x0F, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x09, 0x08,
      0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00
    pshufb xmm0, [glob("bswap")]
    pclmulqdq xmm0, [glob("bswap")], 0x00
    ret()
  let code = v.finalize()
  # 16 data + 9 (66 0F 38 00 05 rel32) + 10 (66 0F 3A 44 05 rel32 ib) + 1.
  check code.len == 36
  check code[16] == 0x66'u8
  check code[17] == 0x0F'u8
  check code[18] == 0x38'u8
  check code[19] == 0x00'u8
  check code[20] == 0x05'u8
  # rel32 from end of first insn (25) back to pool start (0): -25.
  check code[21] == 0xE7'u8
  check code[22] == 0xFF'u8
  check code[25] == 0x66'u8
  check code[26] == 0x0F'u8
  check code[27] == 0x3A'u8
  check code[28] == 0x44'u8
  check code[29] == 0x05'u8
  # rel32 is relative to the end of the rel32 field (34), before the
  # trailing imm8: 0 - 34 = -34.
  check code[30] == 0xDE'u8
  check code[34] == 0x00'u8 # imm8, not rel32 tail
  check code[35] == 0xC3'u8

test "ghash operand rules are enforced":
  var ops = initVecAssembler(0)
  accepts:
    dynasm ops:
      arch x64
      pshufb xmm0, xmm1
  accepts:
    dynasm ops:
      arch x64
      pclmulqdq xmm0, xmm1, 0x00
  accepts:
    dynasm ops:
      arch x64
      pshufd xmm0, [rax], 0x0E
  accepts:
    dynasm ops:
      arch x64
      psllq xmm0, 1
  accepts:
    dynasm ops:
      arch x64
      por [rax], xmm1
  rejects:
    dynasm ops:
      arch x64
      pshufb rax, xmm0
  rejects:
    dynasm ops:
      arch x64
      pshufb [rax], xmm1
  rejects:
    dynasm ops:
      arch x64
      punpcklqdq [rax], xmm1
  rejects:
    dynasm ops:
      arch x64
      pshufb xmm0
  rejects:
    dynasm ops:
      arch x64
      por [rax], [rbx]
  rejects:
    dynasm ops:
      arch x64
      por xmm0, 5
  rejects:
    dynasm ops:
      arch x64
      pclmulqdq xmm0, xmm1
  rejects:
    dynasm ops:
      arch x64
      pclmulqdq xmm0, xmm1, 256
  rejects:
    dynasm ops:
      arch x64
      pclmulqdq xmm0, 5, 0x00
  rejects:
    dynasm ops:
      arch x64
      pshufd xmm0, xmm1
  rejects:
    dynasm ops:
      arch x64
      pshufd xmm0, xmm1, 256
  rejects:
    dynasm ops:
      arch x64
      psllq xmm0
  rejects:
    dynasm ops:
      arch x64
      psllq rax, 1
  rejects:
    dynasm ops:
      arch x64
      psllq [rax], 1
  rejects:
    dynasm ops:
      arch x64
      psrlq xmm0, 256
  rejects:
    dynasm ops:
      arch x64
      punpcklqdq xmm0, dword [rax]
  rejects:
    dynasm ops:
      arch x64
      pshufb xmm0, [rax + xmm1]
  rejects:
    dynasm ops:
      arch aarch64
      pshufb xmm0, xmm1
  rejects:
    dynasm ops:
      arch aarch64
      pclmulqdq xmm0, xmm1, 0x00
  rejects:
    dynasm ops:
      arch aarch64
      psllq xmm0, 1

when defined(amd64):
  proc hostHasPclmul(): bool =
    ## cpuid.01H:ECX[1]; arch gating is not enough since PCLMULQDQ is
    ## not guaranteed on amd64 (same pattern as the AES-NI detector).
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      push rbx
      mov eax, 1
      db 0x0F, 0xA2 # cpuid (no mnemonic yet)
      mov edx, 2 # 1 shl 1
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

  proc jitShuffle2(dst: var array[16, uint8], a, b: array[16, uint8],
      mn: string, imm: int64) =
    ## Helper: dst = mn(a, b[, imm]) for the 2-operand GHASH forms.
    var aa = a
    var bb = b
    let ib = imm
    let op = mn
    var asmObj = newAssembler(akX64)
    # NOTE: mnemonic is fixed per call site below (no dynamic dispatch
    # inside dynasm blocks); this helper only shares the load/store.
    discard op
    discard ib
    if mn == "pshufb":
      dynasm asmObj:
        arch x64
        alias inptr, rdi, rcx
        alias maskptr, rsi, rdx
        alias outptr, rdx, r8
        movdqu xmm0, [inptr]
        movdqu xmm1, [maskptr]
        pshufb xmm0, xmm1
        movdqu [outptr], xmm0
        ret()
    elif mn == "por":
      dynasm asmObj:
        arch x64
        alias inptr, rdi, rcx
        alias maskptr, rsi, rdx
        alias outptr, rdx, r8
        movdqu xmm0, [inptr]
        movdqu xmm1, [maskptr]
        por xmm0, xmm1
        movdqu [outptr], xmm0
        ret()
    elif mn == "punpcklqdq":
      dynasm asmObj:
        arch x64
        alias inptr, rdi, rcx
        alias maskptr, rsi, rdx
        alias outptr, rdx, r8
        movdqu xmm0, [inptr]
        movdqu xmm1, [maskptr]
        punpcklqdq xmm0, xmm1
        movdqu [outptr], xmm0
        ret()
    var buf = asmObj.finalize()
    type Fn = proc(a, b, c: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr aa, addr bb, addr dst)
    buf.destroy()

  proc jitPclmul(a, b: array[16, uint8], imm: int64): array[16, uint8] =
    var asmObj = newAssembler(akX64)
    var x = a
    var y = b
    var o: array[16, uint8]
    let ib = imm
    dynasm asmObj:
      arch x64
      alias aptr, rdi, rcx
      alias bptr, rsi, rdx
      alias outptr, rdx, r8
      movdqu xmm0, [aptr]
      movdqu xmm1, [bptr]
      pclmulqdq xmm0, xmm1, ib
      movdqu [outptr], xmm0
      ret()
    var buf = asmObj.finalize()
    type Fn = proc(a, b, c: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr x, addr y, addr o)
    buf.destroy()
    o

  proc jitPshufd(x: array[16, uint8], imm: int64): array[16, uint8] =
    var asmObj = newAssembler(akX64)
    var s = x
    var o: array[16, uint8]
    let ib = imm
    dynasm asmObj:
      arch x64
      alias inptr, rdi, rcx
      alias outptr, rsi, rdx
      movdqu xmm0, [inptr]
      pshufd xmm0, xmm0, ib
      movdqu [outptr], xmm0
      ret()
    var buf = asmObj.finalize()
    type Fn = proc(a, b: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr s, addr o)
    buf.destroy()
    o

  proc jitShiftQ(x: array[16, uint8], mn: string,
      count: int64): array[16, uint8] =
    var asmObj = newAssembler(akX64)
    var s = x
    var o: array[16, uint8]
    let n = count
    if mn == "psllq":
      dynasm asmObj:
        arch x64
        alias inptr, rdi, rcx
        alias outptr, rsi, rdx
        movdqu xmm0, [inptr]
        psllq xmm0, n
        movdqu [outptr], xmm0
        ret()
    else:
      dynasm asmObj:
        arch x64
        alias inptr, rdi, rcx
        alias outptr, rsi, rdx
        movdqu xmm0, [inptr]
        psrlq xmm0, n
        movdqu [outptr], xmm0
        ret()
    var buf = asmObj.finalize()
    type Fn = proc(a, b: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr s, addr o)
    buf.destroy()
    o

  test "pshufb byte-reverses":
    if not hostHasPclmul():
      skip()
    var x: array[16, uint8]
    var idx: array[16, uint8]
    for i in 0 ..< 16:
      x[i] = cast[uint8](i)
      idx[i] = cast[uint8](15 - i)
    var o: array[16, uint8]
    jitShuffle2(o, x, idx, "pshufb", 0)
    for i in 0 ..< 16:
      check o[i] == cast[uint8](15 - i)

  test "pshufd 0x0E swaps 64-bit halves":
    if not hostHasPclmul():
      skip()
    var x: array[16, uint8]
    for i in 0 ..< 16:
      x[i] = cast[uint8](i + 1)
    # imm 0x0E = order [2,3,0,0]: dwords become [w2, w3, w0, w0].
    let o = jitPshufd(x, 0x0E)
    let want: array[16, uint8] = [9'u8, 10, 11, 12, 13, 14, 15, 16,
      1, 2, 3, 4, 1, 2, 3, 4]
    check o == want

  test "pclmulqdq carry-less multiply":
    if not hostHasPclmul():
      skip()
    # 0x01 * 0x1B = 0x1B (no carries involved).
    var a: array[16, uint8]
    var b: array[16, uint8]
    a[0] = 1'u8
    b[0] = 0x1B'u8
    let r0 = jitPclmul(a, b, 0x00)
    check r0[0] == 0x1B'u8
    for i in 1 ..< 16:
      check r0[i] == 0'u8
    # High halves: 0x02 * 0x03 = 0x06 (x*(x+1) = x^2+x). The 128-bit
    # product lands in the full destination: low qword 6, high qword 0.
    var c: array[16, uint8]
    var d: array[16, uint8]
    c[8] = 2'u8
    d[8] = 3'u8
    let r1 = jitPclmul(c, d, 0x11)
    check r1[0] == 6'u8
    for i in 1 ..< 16:
      check r1[i] == 0'u8

  test "punpcklqdq interleaves low halves":
    if not hostHasPclmul():
      skip()
    var a: array[16, uint8]
    var b: array[16, uint8]
    for i in 0 ..< 8:
      a[i] = 0xAA'u8
      b[i] = 0xCC'u8
    for i in 8 ..< 16:
      a[i] = 0xBB'u8
      b[i] = 0xDD'u8
    var o: array[16, uint8]
    jitShuffle2(o, a, b, "punpcklqdq", 0)
    for i in 0 ..< 8:
      check o[i] == 0xAA'u8
    for i in 8 ..< 16:
      check o[i] == 0xCC'u8

  test "por is bitwise or":
    if not hostHasPclmul():
      skip()
    var a: array[16, uint8]
    var b: array[16, uint8]
    for i in 0 ..< 16:
      a[i] = cast[uint8](i * 17)
      b[i] = cast[uint8](i * 11 + 5)
    var o: array[16, uint8]
    jitShuffle2(o, a, b, "por", 0)
    for i in 0 ..< 16:
      check o[i] == (a[i] or b[i])

  test "qword shifts":
    if not hostHasPclmul():
      skip()
    var one: array[16, uint8]
    one[0] = 1'u8
    let sl = jitShiftQ(one, "psllq", 1)
    check sl[0] == 2'u8
    for i in 1 ..< 16:
      check sl[i] == 0'u8
    var hi: array[16, uint8]
    hi[15] = 0x80'u8
    let sr = jitShiftQ(hi, "psrlq", 63)
    for i in 0 ..< 8:
      check sr[i] == 0'u8
    check sr[8] == 1'u8
    for i in 9 ..< 16:
      check sr[i] == 0'u8
