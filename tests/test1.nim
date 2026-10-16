import unittest
import std/strutils
import dynasm

proc hx(b: seq[byte]): string =
  result = ""
  for i, x in b:
    if i > 0: result.add(" ")
    result.add(x.toHex(2))

test "relocation encode/decode":
  let r = fromEncoding(encodeKind(rkRelative, rsDWord))
  check r.kind == rkRelative
  check relSize(r.size) == 4
  let r2 = fromEncoding(encodeKind(rkAbsolute, rsByte))
  check r2.kind == rkAbsolute
  check relSize(r2.size) == 1

test "simple assembler push/align":
  var a = initSimpleAssembler()
  a.push(0x90'u8)
  a.pushU32(0x12345678'u32)
  a.align(8)
  check a.ops.len mod 8 == 0
  check a.ops[0] == 0x90'u8

test "vec assembler mov rax,rbx via encoder":
  var v = initVecAssembler(0)
  encMovRegReg(v, rax, rbx, sz64)
  let code = v.finalize()
  # 48 8B C3
  check code == @[0x48'u8, 0x8B'u8, 0xC3'u8]

test "vec assembler ret/nop":
  var v = initVecAssembler(0)
  encNop(v)
  encRet(v)
  check v.finalize() == @[0x90'u8, 0xC3'u8]

test "vec labels forward/backward jmp":
  var v = initVecAssembler(0)
  v.localLabel("loop")
  encNop(v)
  # jmp forward to next loop
  encJmpRel(v, fwd("loop"))
  v.localLabel("loop")
  encRet(v)
  let code = v.finalize()
  # nop, E9 <rel32>, C3 ; rel should point to second loop (offset 6?)
  # layout: 0:nop, 1:E9, 2..5 rel, 6:ret? Actually second loop at 6? Let's check:
  # first loop at 0, nop at 0..1, jmp at 1..6, second loop at 6, ret at 6.
  # jmp at location 6 (after E9+rel), ref 6, target 6 => rel 0.
  check code.len == 7
  check code[0] == 0x90'u8
  check code[1] == 0xE9'u8
  check code[6] == 0xC3'u8

test "vec global label + lea rip":
  var v = initVecAssembler(0)
  v.globalLabel("hello")
  v.push(0x41'u8)
  let helloOff = 0
  var v2 = initVecAssembler(0)
  # lea rcx, [rip+hello]
  var mem = MemOp(hasBase: false, base: rax,
    hasIndex: false, index: rax, scale: 1,
    disp: 0, hasDisp: false,
    hasRip: true, addrSizeOverride: false,
    ripLabel: glob("hello"))
  encLeaSized(v2, rcx, sz64, mem, true)
  v2.globalLabel("hello") # define after use? Actually need target; place at 0?
  # This test just checks it assembles without unknown label when defined
  # Redefine cleanly:
  var v3 = initVecAssembler(0)
  v3.globalLabel("hello")
  var mem2 = MemOp(hasBase: false, base: rax,
    hasIndex: false, index: rax, scale: 1,
    disp: 0, hasDisp: false,
    hasRip: true, addrSizeOverride: false,
    ripLabel: glob("hello"))
  encLeaSized(v3, rcx, sz64, mem2, true)
  let c3 = v3.finalize()
  # 48 8D 0D <rel32>. rel = target(0) - (loc(7)-4)= 0-3 = -3? loc=7, ref=4 => 7-4=3, 0-3=-3 = FFFFFFFD
  check c3[0] == 0x48'u8
  check c3[1] == 0x8D'u8

test "dynamic labels":
  var v = initVecAssembler(0)
  let d = v.newDynamicLabel()
  encJmpRel(v, dynLbl(d))
  v.dynamicLabel(d)
  encRet(v)
  let code = v.finalize()
  check code.len == 6
