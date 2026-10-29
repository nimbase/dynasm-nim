import unittest
import dynasm

test "cmovcc encoder goldens":
  # cmove rax, rbx -> REX.W(48) 0F 44 C3
  var v = initVecAssembler(0)
  encCmovRegReg(v, "cmove", rax, rbx, sz64)
  check v.finalize() == @[0x48'u8, 0x0F'u8, 0x44'u8, 0xC3'u8]
  # cmovnz r9d, r10d -> REX.RB(45) 0F 45 CA
  v = initVecAssembler(0)
  encCmovRegReg(v, "cmovnz", r9d, r10d, sz32)
  check v.finalize() == @[0x45'u8, 0x0F'u8, 0x45'u8, 0xCA'u8]
  # cmovl ax, bx -> 66 0F 4C C3
  v = initVecAssembler(0)
  encCmovRegReg(v, "cmovl", ax, bx, sz16)
  check v.finalize() == @[0x66'u8, 0x0F'u8, 0x4C'u8, 0xC3'u8]
  # cmovge rcx, [rbx+8] -> REX.W(48) 0F 4D 4B 08
  v = initVecAssembler(0)
  var mem = MemOp(hasBase: true, base: rbx,
    hasIndex: false, index: rax, scale: 1,
    disp: 8, hasDisp: true,
    hasRip: false, addrSizeOverride: false,
    ripLabel: fwd("unused"))
  encCmovRegMem(v, "cmovge", rcx, mem, sz64, true)
  check v.finalize() ==
    @[0x48'u8, 0x0F'u8, 0x4D'u8, 0x4B'u8, 0x08'u8]
  # alias form: cmovc == cmovb (condition 2 -> 0F 42)
  v = initVecAssembler(0)
  encCmovRegReg(v, "cmovc", rax, rbx, sz64)
  check v.finalize() == @[0x48'u8, 0x0F'u8, 0x42'u8, 0xC3'u8]

test "cmovcc dsl goldens":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    cmove rax, rbx
  check v.finalize() == @[0x48'u8, 0x0F'u8, 0x44'u8, 0xC3'u8]
  v = initVecAssembler(0)
  dynasm v:
    arch x64
    cmovnz r9d, r10d
  check v.finalize() == @[0x45'u8, 0x0F'u8, 0x45'u8, 0xCA'u8]
  v = initVecAssembler(0)
  dynasm v:
    arch x64
    cmovge rcx, [rbx + 8]
  check v.finalize() ==
    @[0x48'u8, 0x0F'u8, 0x4D'u8, 0x4B'u8, 0x08'u8]

when defined(amd64):
  test "cmovcc executes conditional select":
    type SelFn = proc(c, a, b: int64): int64 {.cdecl.}
    var a = newAssembler(akX64)
    when defined(windows):
      # c=rcx, a=rdx, b=r8
      dynasm a:
        arch x64
        test rcx, rcx
        mov rax, r8
        cmovnz rax, rdx
        ret()
    else:
      # c=rdi, a=rsi, b=rdx
      dynasm a:
        arch x64
        test rdi, rdi
        mov rax, rdx
        cmovnz rax, rsi
        ret()
    var buf = a.finalize()
    let sel = cast[SelFn](buf.ptrAt(AssemblyOffset(0)))
    check sel(0, 10, 20) == 20
    check sel(1, 10, 20) == 10
    check sel(-5, 10, 20) == 10
    buf.destroy()

  test "cmovcc executes max via cmovl":
    type MaxFn = proc(x, y: int64): int64 {.cdecl.}
    var a = newAssembler(akX64)
    when defined(windows):
      dynasm a:
        arch x64
        cmp rcx, rdx
        mov rax, rcx
        cmovl rax, rdx
        ret()
    else:
      dynasm a:
        arch x64
        cmp rdi, rsi
        mov rax, rdi
        cmovl rax, rsi
        ret()
    var buf = a.finalize()
    let mx = cast[MaxFn](buf.ptrAt(AssemblyOffset(0)))
    check mx(3, 7) == 7
    check mx(7, 3) == 7
    check mx(5, 5) == 5
    buf.destroy()
