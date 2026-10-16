import unittest
import dynasm

test "setcc encoder goldens":
  # sete al -> 0F 94 C0
  var v = initVecAssembler(0)
  encSetccReg(v, "sete", al)
  check v.finalize() == @[0x0F'u8, 0x94'u8, 0xC0'u8]
  # setl spl -> REX(40) 0F 9C C4 (spl needs forced REX)
  v = initVecAssembler(0)
  encSetccReg(v, "setl", spl)
  check v.finalize() == @[0x40'u8, 0x0F'u8, 0x9C'u8, 0xC4'u8]
  # setg r9b -> REX.B(41) 0F 9F C1
  v = initVecAssembler(0)
  encSetccReg(v, "setg", r9b)
  check v.finalize() == @[0x41'u8, 0x0F'u8, 0x9F'u8, 0xC1'u8]
  # setbe dl -> 0F 96 C2
  v = initVecAssembler(0)
  encSetccReg(v, "setbe", dl)
  check v.finalize() == @[0x0F'u8, 0x96'u8, 0xC2'u8]
  # setne ah -> 0F 95 C4 (high-byte reg, no REX)
  v = initVecAssembler(0)
  encSetccReg(v, "setne", ah)
  check v.finalize() == @[0x0F'u8, 0x95'u8, 0xC4'u8]
  # sete byte [rbx+8] -> 0F 94 43 08
  v = initVecAssembler(0)
  var mem = MemOp(hasBase: true, base: rbx,
    hasIndex: false, index: rax, scale: 1,
    disp: 8, hasDisp: true,
    hasRip: false, addrSizeOverride: false,
    ripLabel: fwd("unused"))
  encSetccMem(v, "sete", mem, true)
  check v.finalize() == @[0x0F'u8, 0x94'u8, 0x43'u8, 0x08'u8]

test "setcc dsl goldens":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    sete al
  check v.finalize() == @[0x0F'u8, 0x94'u8, 0xC0'u8]
  v = initVecAssembler(0)
  dynasm v:
    arch x64
    setg r9b
  check v.finalize() == @[0x41'u8, 0x0F'u8, 0x9F'u8, 0xC1'u8]
  v = initVecAssembler(0)
  dynasm v:
    arch x64
    sete byte [rbx+8]
  check v.finalize() == @[0x0F'u8, 0x94'u8, 0x43'u8, 0x08'u8]

when defined(amd64):
  test "setcc executes vancode comparison sequences":
    type CmpFn = proc(x, y: int64): int64 {.cdecl.}
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      cmp rdi, rsi
      sete al
      movzx eax, al
      ret()
    var buf = a.finalize()
    let eq = cast[CmpFn](buf.ptrAt(AssemblyOffset(0)))
    check eq(5, 5) == 1
    check eq(5, 6) == 0
    check eq(6, 5) == 0
    buf.destroy()
    var b = newAssembler(akX64)
    dynasm b:
      arch x64
      cmp rdi, rsi
      setl al
      movzx eax, al
      ret()
    buf = b.finalize()
    let lt = cast[CmpFn](buf.ptrAt(AssemblyOffset(0)))
    check lt(5, 6) == 1
    check lt(6, 5) == 0
    check lt(5, 5) == 0
    buf.destroy()
    var c = newAssembler(akX64)
    dynasm c:
      arch x64
      cmp rdi, rsi
      setg al
      movzx eax, al
      ret()
    buf = c.finalize()
    let gt = cast[CmpFn](buf.ptrAt(AssemblyOffset(0)))
    check gt(6, 5) == 1
    check gt(5, 6) == 0
    check gt(5, 5) == 0
    buf.destroy()
