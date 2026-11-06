import unittest
import dynasm

# P1 ChaCha SSE2 (4-lane kernel): paddd + dword shifts. Byte-exact
# goldens (host-independent) plus execution micro-tests gated by host
# CPU (SSE2 is baseline on amd64, so arch gating alone suffices here).

template rejects(body: untyped) =
  static:
    assert not compiles(body), "expected a compile-time error"

template accepts(body: untyped) =
  static:
    assert compiles(body), "expected this to compile"

test "paddd encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    paddd xmm0, xmm1
    paddd xmm0, [rax]
    paddd xmm8, xmm9
    paddd xmm1, [rbx + rcx*8 + 16]
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0xFE'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0xFE'u8, 0x00'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0xFE'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0xFE'u8, 0x4C'u8, 0xCB'u8, 0x10'u8]

test "dword shift encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    pslld xmm0, 4
    psrld xmm0, 4
    pslld xmm8, 4
    psrld xmm8, 12
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x72'u8, 0xF0'u8, 0x04'u8,
    0x66'u8, 0x0F'u8, 0x72'u8, 0xD0'u8, 0x04'u8,
    0x66'u8, 0x41'u8, 0x0F'u8, 0x72'u8, 0xF0'u8, 0x04'u8,
    0x66'u8, 0x41'u8, 0x0F'u8, 0x72'u8, 0xD0'u8, 0x0C'u8]

test "paddd RIP-relative constant pool":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    global cvec
    u32 0x11111111, 0x22222222, 0x33333333, 0x44444444
    paddd xmm0, [glob("cvec")]
    ret()
  let code = v.finalize()
  # 16 data + 8 (66 0F FE 05 rel32) + 1.
  check code.len == 25
  check code[16] == 0x66'u8
  check code[17] == 0x0F'u8
  check code[18] == 0xFE'u8
  check code[19] == 0x05'u8
  # rel32 from end of insn (24) back to pool start (0): -24.
  check code[20] == 0xE8'u8
  check code[24] == 0xC3'u8

test "chacha sse operand rules are enforced":
  var ops = initVecAssembler(0)
  accepts:
    dynasm ops:
      arch x64
      paddd xmm0, xmm1
  accepts:
    dynasm ops:
      arch x64
      pslld xmm0, 4
  accepts:
    dynasm ops:
      arch x64
      paddd xmm0, dqword [rax]
  rejects:
    dynasm ops:
      arch x64
      paddd rax, xmm0
  rejects:
    dynasm ops:
      arch x64
      paddd xmm0
  rejects:
    dynasm ops:
      arch x64
      paddd [rax], [rbx]
  rejects:
    dynasm ops:
      arch x64
      paddd xmm0, 5
  rejects:
    dynasm ops:
      arch x64
      paddd [rax], xmm1
  rejects:
    dynasm ops:
      arch x64
      pslld xmm0
  rejects:
    dynasm ops:
      arch x64
      pslld rax, 4
  rejects:
    dynasm ops:
      arch x64
      pslld [rax], 4
  rejects:
    dynasm ops:
      arch x64
      psrld xmm0, 256
  rejects:
    dynasm ops:
      arch x64
      paddd xmm0, qword [rax]
  rejects:
    dynasm ops:
      arch x64
      paddd xmm0, [rax + xmm1]
  rejects:
    dynasm ops:
      arch aarch64
      paddd xmm0, xmm1
  rejects:
    dynasm ops:
      arch aarch64
      pslld xmm0, 4

when defined(amd64):
  proc jitVecAdd(a, b: array[16, uint8]): array[16, uint8] =
    var asmObj = newAssembler(akX64)
    var x = a
    var y = b
    var o: array[16, uint8]
    dynasm asmObj:
      arch x64
      alias aptr, rdi, rcx
      alias bptr, rsi, rdx
      alias outptr, rdx, r8
      movdqu xmm0, [aptr]
      movdqu xmm1, [bptr]
      paddd xmm0, xmm1
      movdqu [outptr], xmm0
      ret()
    var buf = asmObj.finalize()
    type Fn = proc(a, b, c: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr x, addr y, addr o)
    buf.destroy()
    o

  proc jitVecRotl(x: array[16, uint8], n: int64): array[16, uint8] =
    ## rotl32 each lane by n: or(slli(n), srli(32-n)) — the vrotl pattern.
    var asmObj = newAssembler(akX64)
    var s = x
    var o: array[16, uint8]
    let k = n
    let kc = 32 - n
    dynasm asmObj:
      arch x64
      alias inptr, rdi, rcx
      alias outptr, rsi, rdx
      movdqu xmm0, [inptr]
      movdqu xmm1, xmm0
      pslld xmm0, k
      psrld xmm1, kc
      por xmm0, xmm1
      movdqu [outptr], xmm0
      ret()
    var buf = asmObj.finalize()
    type Fn = proc(a, b: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr s, addr o)
    buf.destroy()
    o

  proc jitQuarterRound(a, b, c, d: array[16, uint8]): array[64, uint8] =
    ## One vector quarter-round (the vQuarterRound body, no lane
    ## shuffles): exercises paddd/pxor/pslld/psrld/por as the kernel
    ## uses them.
    var asmObj = newAssembler(akX64)
    var va = a
    var vb = b
    var vc = c
    var vd = d
    var o: array[64, uint8]
    dynasm asmObj:
      arch x64
      alias ap, rdi, rcx
      movdqu xmm0, [ap]
      movdqu xmm1, [ap + 16]
      movdqu xmm2, [ap + 32]
      movdqu xmm3, [ap + 48]
      paddd xmm0, xmm1
      pxor xmm3, xmm0
      movdqu xmm4, xmm3
      pslld xmm3, 16
      psrld xmm4, 16
      por xmm3, xmm4
      paddd xmm2, xmm3
      pxor xmm1, xmm2
      movdqu xmm4, xmm1
      pslld xmm1, 12
      psrld xmm4, 20
      por xmm1, xmm4
      paddd xmm0, xmm1
      pxor xmm3, xmm0
      movdqu xmm4, xmm3
      pslld xmm3, 8
      psrld xmm4, 24
      por xmm3, xmm4
      paddd xmm2, xmm3
      pxor xmm1, xmm2
      movdqu xmm4, xmm1
      pslld xmm1, 7
      psrld xmm4, 25
      por xmm1, xmm4
      movdqu [ap + 64], xmm0
      movdqu [ap + 80], xmm1
      movdqu [ap + 96], xmm2
      movdqu [ap + 112], xmm3
      ret()
    var buf = asmObj.finalize()
    type Fn = proc(a: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    var io: array[128, uint8]
    for i in 0 ..< 16:
      io[i] = va[i]
      io[16 + i] = vb[i]
      io[32 + i] = vc[i]
      io[48 + i] = vd[i]
    f(addr io)
    buf.destroy()
    for i in 0 ..< 64:
      o[i] = io[64 + i]
    o

  func rotl32(x: uint32, n: int): uint32 =
    (x shl n) or (x shr (32 - n))

  func scalarQuarterRound(a, b, c, d: array[4, uint32]): array[16, uint32] =
    var va = a
    var vb = b
    var vc = c
    var vd = d
    for i in 0 ..< 4:
      va[i] = va[i] + vb[i]
      vd[i] = rotl32(vd[i] xor va[i], 16)
      vc[i] = vc[i] + vd[i]
      vb[i] = rotl32(vb[i] xor vc[i], 12)
      va[i] = va[i] + vb[i]
      vd[i] = rotl32(vd[i] xor va[i], 8)
      vc[i] = vc[i] + vd[i]
      vb[i] = rotl32(vb[i] xor vc[i], 7)
    for i in 0 ..< 4:
      result[i] = va[i]
      result[4 + i] = vb[i]
      result[8 + i] = vc[i]
      result[12 + i] = vd[i]

  proc packU32(words: array[4, uint32]): array[16, uint8] =
    for i in 0 ..< 4:
      result[4 * i] = cast[uint8](words[i] and 0xFF'u32)
      result[4 * i + 1] = cast[uint8]((words[i] shr 8) and 0xFF'u32)
      result[4 * i + 2] = cast[uint8]((words[i] shr 16) and 0xFF'u32)
      result[4 * i + 3] = cast[uint8](words[i] shr 24)

  proc unpackU32(bytes: array[16, uint8]): array[4, uint32] =
    for i in 0 ..< 4:
      result[i] = uint32(bytes[4 * i]) or (uint32(bytes[4 * i + 1]) shl 8) or
        (uint32(bytes[4 * i + 2]) shl 16) or (uint32(bytes[4 * i + 3]) shl 24)

  test "paddd adds lanes":
    var a: array[16, uint8]
    var b: array[16, uint8]
    for i in 0 ..< 16:
      a[i] = cast[uint8](i * 17 + 3)
      b[i] = cast[uint8](i * 29 + 7)
    let o = jitVecAdd(a, b)
    let wa = unpackU32(a)
    let wb = unpackU32(b)
    var want: array[4, uint32]
    for i in 0 ..< 4:
      want[i] = wa[i] + wb[i]
    check o == packU32(want)

  test "dword rotates match scalar":
    var x: array[16, uint8]
    for i in 0 ..< 16:
      x[i] = cast[uint8](i * 13 + 1)
    for n in [16'i64, 12, 8, 7]:
      let o = jitVecRotl(x, n)
      let wx = unpackU32(x)
      var want: array[4, uint32]
      for i in 0 ..< 4:
        want[i] = rotl32(wx[i], int(n))
      check o == packU32(want)

  test "vector quarter round matches scalar":
    let a: array[4, uint32] = [0x11111111'u32, 0x22222222'u32,
      0x33333333'u32, 0x44444444'u32]
    let b: array[4, uint32] = [0x55555555'u32, 0x66666666'u32,
      0x77777777'u32, 0x88888888'u32]
    let c: array[4, uint32] = [0x01020304'u32, 0x05060708'u32,
      0x090A0B0C'u32, 0x0D0E0F10'u32]
    let d: array[4, uint32] = [0x10203040'u32, 0x50607080'u32,
      0x90A0B0C0'u32, 0xD0E0F000'u32]
    let o = jitQuarterRound(packU32(a), packU32(b), packU32(c),
      packU32(d))
    let want = scalarQuarterRound(a, b, c, d)
    var flat: array[64, uint8]
    # JIT writes vector-major: a[0..4] bytes, then b, c, d.
    let pa = packU32([want[0], want[1], want[2], want[3]])
    let pb = packU32([want[4], want[5], want[6], want[7]])
    let pc = packU32([want[8], want[9], want[10], want[11]])
    let pd = packU32([want[12], want[13], want[14], want[15]])
    for j in 0 ..< 16:
      flat[j] = pa[j]
      flat[16 + j] = pb[j]
      flat[32 + j] = pc[j]
      flat[48 + j] = pd[j]
    check o == flat
