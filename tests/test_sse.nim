import unittest
import std/math
import dynasm

# SSE scalar-double + packed-double backend: byte-exact goldens
# (host-independent, VecAssembler only) plus execution tests gated
# by host CPU.

template rejects(body: untyped) =
  static:
    assert not compiles(body), "expected a compile-time error"

template accepts(body: untyped) =
  static:
    assert compiles(body), "expected this to compile"

test "sse movsd encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    movsd xmm0, xmm1
  check v.finalize() == @[0xF2'u8, 0x0F'u8, 0x10'u8, 0xC1'u8]
  var v2 = initVecAssembler(0)
  dynasm v2:
    arch x64
    movsd xmm8, xmm9
  # REX.R|REX.B for the high xmm regs.
  check v2.finalize() == @[0xF2'u8, 0x45'u8, 0x0F'u8, 0x10'u8, 0xC1'u8]
  var v3 = initVecAssembler(0)
  dynasm v3:
    arch x64
    movsd xmm0, [rax]
    movsd [rax], xmm1
  check v3.finalize() == @[0xF2'u8, 0x0F'u8, 0x10'u8, 0x00'u8,
    0xF2'u8, 0x0F'u8, 0x11'u8, 0x08'u8]
  var v4 = initVecAssembler(0)
  dynasm v4:
    arch x64
    movsd xmm0, [rax + 8]
    movsd xmm1, [rbx + rcx*8 + 16]
    # Win64 arg regs take the same encoder paths (REX.B for R8).
    movsd xmm0, [r8]
    cvtsi2sd xmm1, r8
  check v4.finalize() == @[0xF2'u8, 0x0F'u8, 0x10'u8, 0x40'u8, 0x08'u8,
    0xF2'u8, 0x0F'u8, 0x10'u8, 0x4C'u8, 0xCB'u8, 0x10'u8,
    0xF2'u8, 0x41'u8, 0x0F'u8, 0x10'u8, 0x00'u8,
    0xF2'u8, 0x49'u8, 0x0F'u8, 0x2A'u8, 0xC8'u8]

test "sse scalar alu encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    addsd xmm0, xmm1
    subsd xmm2, [rdx]
    mulsd xmm0, xmm0
    divsd xmm8, xmm9
    sqrtsd xmm0, xmm1
  check v.finalize() == @[0xF2'u8, 0x0F'u8, 0x58'u8, 0xC1'u8,
    0xF2'u8, 0x0F'u8, 0x5C'u8, 0x12'u8,
    0xF2'u8, 0x0F'u8, 0x59'u8, 0xC0'u8,
    0xF2'u8, 0x45'u8, 0x0F'u8, 0x5E'u8, 0xC1'u8,
    0xF2'u8, 0x0F'u8, 0x51'u8, 0xC1'u8]

test "sse ucomisd and xorpd encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    ucomisd xmm0, xmm1
    xorpd xmm0, xmm0
    xorpd xmm8, xmm15
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x2E'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x57'u8, 0xC0'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x57'u8, 0xC7'u8]

test "sse cvt encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm0, eax
    cvtsi2sd xmm1, dword [rbx + 4]
    cvtsi2sd xmm2, qword [rbx]
  check v.finalize() == @[0xF2'u8, 0x48'u8, 0x0F'u8, 0x2A'u8, 0xC0'u8,
    0xF2'u8, 0x0F'u8, 0x2A'u8, 0xC0'u8,
    0xF2'u8, 0x0F'u8, 0x2A'u8, 0x4B'u8, 0x04'u8,
    0xF2'u8, 0x48'u8, 0x0F'u8, 0x2A'u8, 0x13'u8]
  var v2 = initVecAssembler(0)
  dynasm v2:
    arch x64
    cvttsd2si rax, xmm0
    cvttsd2si ecx, [rdx]
  check v2.finalize() == @[0xF2'u8, 0x48'u8, 0x0F'u8, 0x2C'u8, 0xC0'u8,
    0xF2'u8, 0x0F'u8, 0x2C'u8, 0x0A'u8]

test "sse RIP-relative constant pool":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    global half
    f64 3.75
    movsd xmm0, [glob("half")]
    ret()
  let code = v.finalize()
  # 8 bytes of 3.75, then F2 0F 10 05 + rel32(-16), then C3.
  check code.len == 17
  check code[8] == 0xF2'u8
  check code[11] == 0x05'u8
  check code[12] == 0xF0'u8
  check code[16] == 0xC3'u8

test "sse operand rules are enforced":
  var ops = initVecAssembler(0)
  accepts:
    dynasm ops:
      arch x64
      movsd xmm0, xmm1
  rejects:
    dynasm ops:
      arch x64
      add rax, xmm0
  rejects:
    dynasm ops:
      arch x64
      movsd rax, xmm0
  rejects:
    dynasm ops:
      arch x64
      movsd xmm0, xmm1, xmm2
  rejects:
    dynasm ops:
      arch x64
      movsd [rax], [rbx]
  rejects:
    dynasm ops:
      arch x64
      cvtsi2sd xmm0, [rax]
  rejects:
    dynasm ops:
      arch x64
      movsd xmm0, dword [rax]
  accepts:
    dynasm ops:
      arch x64
      xorpd xmm0, [rax]
  rejects:
    dynasm ops:
      arch x64
      movsd xmm0, [rax + xmm1]
  rejects:
    dynasm ops:
      arch aarch64
      movsd xmm0, xmm1
  accepts:
    dynasm ops:
      arch x64
      movapd xmm0, xmm1
  accepts:
    dynasm ops:
      arch x64
      movapd xmm0, dqword [rax]
  accepts:
    dynasm ops:
      arch x64
      movupd xmm1, oword [rbx + 8]
  rejects:
    dynasm ops:
      arch x64
      movapd rax, xmm0
  rejects:
    dynasm ops:
      arch x64
      movapd xmm0, xmm1, xmm2
  rejects:
    dynasm ops:
      arch x64
      movapd [rax], [rbx]
  rejects:
    dynasm ops:
      arch x64
      movapd xmm0, qword [rax]
  rejects:
    dynasm ops:
      arch x64
      movapd xmm0, dword [rax]
  rejects:
    dynasm ops:
      arch x64
      addpd rax, xmm0
  rejects:
    dynasm ops:
      arch x64
      addpd xmm0, qword [rax]
  rejects:
    dynasm ops:
      arch x64
      addpd xmm0, [rax + xmm1]
  rejects:
    dynasm ops:
      arch aarch64
      movapd xmm0, xmm1

test "sse packed mov encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    movapd xmm0, xmm1
    movupd xmm0, xmm1
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x28'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x10'u8, 0xC1'u8]
  var v2 = initVecAssembler(0)
  dynasm v2:
    arch x64
    movapd xmm8, xmm9
    movupd xmm8, xmm9
  check v2.finalize() == @[0x66'u8, 0x45'u8, 0x0F'u8, 0x28'u8, 0xC1'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x10'u8, 0xC1'u8]
  var v3 = initVecAssembler(0)
  dynasm v3:
    arch x64
    movapd xmm0, [rax]
    movapd [rax], xmm1
    movupd xmm0, [rax + 8]
    movupd [rax], xmm1
  check v3.finalize() == @[0x66'u8, 0x0F'u8, 0x28'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0x29'u8, 0x08'u8,
    0x66'u8, 0x0F'u8, 0x10'u8, 0x40'u8, 0x08'u8,
    0x66'u8, 0x0F'u8, 0x11'u8, 0x08'u8]
  var v4 = initVecAssembler(0)
  dynasm v4:
    arch x64
    movupd xmm1, [rbx + rcx*8 + 16]
    movupd [r8], xmm0
    movapd xmm0, dqword [rax]
    movapd xmm1, oword [rbx + 8]
  check v4.finalize() == @[0x66'u8, 0x0F'u8, 0x10'u8, 0x4C'u8, 0xCB'u8,
    0x10'u8,
    0x66'u8, 0x41'u8, 0x0F'u8, 0x11'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0x28'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0x28'u8, 0x4B'u8, 0x08'u8]

test "sse packed alu encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    addpd xmm0, xmm1
    subpd xmm2, [rdx]
    mulpd xmm0, xmm0
    divpd xmm8, xmm9
    sqrtpd xmm0, xmm1
    maxpd xmm0, xmm1
    minpd xmm0, xmm1
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x58'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x5C'u8, 0x12'u8,
    0x66'u8, 0x0F'u8, 0x59'u8, 0xC0'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x5E'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x51'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x5F'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x5D'u8, 0xC1'u8]

test "sse packed logic encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    andpd xmm0, xmm1
    orpd xmm0, xmm1
    xorpd xmm0, xmm0
    xorpd xmm8, xmm15
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x54'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x56'u8, 0xC1'u8,
    0x66'u8, 0x0F'u8, 0x57'u8, 0xC0'u8,
    0x66'u8, 0x45'u8, 0x0F'u8, 0x57'u8, 0xC7'u8]
  var v2 = initVecAssembler(0)
  dynasm v2:
    arch x64
    andpd xmm0, [rax]
    orpd xmm1, [rbx + 8]
    xorpd xmm0, [rax]
  check v2.finalize() == @[0x66'u8, 0x0F'u8, 0x54'u8, 0x00'u8,
    0x66'u8, 0x0F'u8, 0x56'u8, 0x4B'u8, 0x08'u8,
    0x66'u8, 0x0F'u8, 0x57'u8, 0x00'u8]

test "sse packed RIP-relative constant pool":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    global two
    f64 3.75
    f64 1.25
    movapd xmm0, [glob("two")]
    ret()
  let code = v.finalize()
  # 16 bytes of data, then 66 0F 28 05 + rel32(-24), then C3.
  check code.len == 25
  check code[16] == 0x66'u8
  check code[19] == 0x05'u8
  check code[20] == 0xE8'u8
  check code[24] == 0xC3'u8

when defined(amd64):
  test "sse executes double add/mul/sqrt":
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # First-pointer args per ABI (System V: RDI/RSI/RDX,
      # Win64: RCX/RDX/R8).
      alias xp, rdi, rcx
      alias yp, rsi, rdx
      alias op, rdx, r8
      movsd xmm0, [xp]
      addsd xmm0, [yp]
      mulsd xmm0, xmm0
      sqrtsd xmm0, xmm0
      movsd [op], xmm0
      ret()
    var buf = a.finalize()
    type Fn = proc(x, y, outp: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    var x = 1.5
    var y = 2.25
    var o = 0.0
    f(addr x, addr y, addr o)
    check o == sqrt((1.5 + 2.25) * (1.5 + 2.25))
    buf.destroy()

  test "sse executes int-double conversions":
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias xv, rdi, rcx
      cvtsi2sd xmm0, xv
      addsd xmm0, xmm0
      cvttsd2si rax, xmm0
      ret()
    var buf = a.finalize()
    type Fn = proc(x: int64): int64 {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    check f(21) == 42
    check f(-3) == -6
    buf.destroy()

  test "sse executes ucomisd compare":
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias ap, rdi, rcx
      alias pb, rsi, rdx
      movsd xmm0, [ap]
      movsd xmm1, [pb]
      ucomisd xmm0, xmm1
      seta al
      movzx eax, al
      ret()
    var buf = a.finalize()
    type Fn = proc(x, y: pointer): int64 {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    var big = 2.0
    var small = 1.0
    check f(addr big, addr small) == 1
    check f(addr small, addr big) == 0
    check f(addr big, addr big) == 0
    buf.destroy()

  test "sse executes xorpd zeroing":
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias op, rdi, rcx
      xorpd xmm0, xmm0
      movsd [op], xmm0
      ret()
    var buf = a.finalize()
    type Fn = proc(outp: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    var o = 99.5
    f(addr o)
    check o == 0.0
    buf.destroy()

  test "sse executes packed add/mul":
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias xp, rdi, rcx
      alias yp, rsi, rdx
      alias op, rdx, r8
      movupd xmm0, [xp]
      movupd xmm1, [yp]
      addpd xmm0, xmm1
      mulpd xmm0, xmm1
      movupd [op], xmm0
      ret()
    var buf = a.finalize()
    type Fn = proc(x, y, outp: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    var x = [1.5, 2.0]
    var y = [2.0, 4.0]
    var o = [0.0, 0.0]
    f(addr x, addr y, addr o)
    check o[0] == (1.5 + 2.0) * 2.0
    check o[1] == (2.0 + 4.0) * 4.0
    buf.destroy()

  test "sse executes packed mov/logic":
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias xp, rdi, rcx
      alias yp, rsi, rdx
      alias op, rdx, r8
      movupd xmm0, [xp]
      movupd xmm1, [yp]
      andpd xmm0, xmm1
      movupd [op], xmm0
      movupd xmm0, [xp]
      orpd xmm0, [yp]
      movupd xmm1, [yp]
      xorpd xmm1, [yp]
      addpd xmm0, xmm1
      movupd [xp], xmm0
      ret()
    var buf = a.finalize()
    type Fn3 = proc(a, b, o: pointer) {.cdecl.}
    let f = cast[Fn3](buf.ptrAt(AssemblyOffset(0)))
    var av = [7.0, 9.0]
    var bv = [3.0, 5.0]
    var o = [0.0, 0.0]
    f(addr av, addr bv, addr o)
    # andpd of two doubles is a bitwise op; recompute via uint64 bits.
    proc bits(x: float64): uint64 = cast[uint64](x)
    proc fromBits(u: uint64): float64 = cast[float64](u)
    check o[0] == fromBits(bits(7.0) and bits(3.0))
    check o[1] == fromBits(bits(9.0) and bits(5.0))
    # orpd([ap]) + zero gives back the OR; stored to [ap].
    check av[0] == fromBits(bits(7.0) or bits(3.0))
    check av[1] == fromBits(bits(9.0) or bits(5.0))
    buf.destroy()
