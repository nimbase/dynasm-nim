import unittest
import dynasm

test "dynasm macro basic mov/ret":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    mov rax, rbx
    ret()
  let code = ops.finalize()
  check code == @[0x48'u8, 0x8B'u8, 0xC3'u8, 0xC3'u8]

test "dynasm macro xor via backticks":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    `xor` edx, edx
    ret()
  let code = ops.finalize()
  # 31 D2, C3
  check code[0] == 0x31'u8
  check code[1] == 0xD2'u8

test "dynasm macro labels and jumps":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    label myloop
    nop()
    jmp fwd("myloop")
    label myloop
    ret()
  let code = ops.finalize()
  check code.len == 7
  check code[0] == 0x90'u8

test "dynasm macro global + lea rip":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    global hello
    bytes "Hi"
    lea rcx, [glob("hello")]
    ret()
  let code = ops.finalize()
  check code.len > 4

test "dynasm macro mem operands":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    mov rax, [rbx + 8]
    mov [rcx + rdx*4 + 16], rax
    sub rsp, 0x28
    add rsp, 0x28
    ret()
  let code = ops.finalize()
  check code.len > 5

test "dynasm macro data directives":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    u8 0x90, 0xCC
    u32 0x12345678
    align 8
    bytes "AB"
  let code = ops.finalize()
  check code[0] == 0x90'u8
  check code[1] == 0xCC'u8

test "dynasm macro dynamic labels":
  var ops = initVecAssembler(0)
  let myLbl = ops.newDynamicLabel()
  dynasm ops:
    arch x64
    jz dyn(myLbl)
    nop()
    dynamicLabel myLbl
    ret()
  let code = ops.finalize()
  check code.len == 8 # 0F 84 + rel32 (6) + 90 + C3

test "dynasm macro alias":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    alias myreg, rcx
    mov rax, myreg
    ret()
  let code = ops.finalize()
  # mov rax, rcx = 48 8B C1? dst rax(0), src rcx(1) => modrm C1
  check code[0] == 0x48'u8
  check code[2] == 0xC1'u8

test "dynasm macro mixed Nim code":
  var ops = initVecAssembler(0)
  let val = 42
  dynasm ops:
    arch x64
    mov rax, val
    ret()
  let code = ops.finalize()
  # mov rax,42 with sz64 + small imm => 5-byte mov eax,42
  # (B8 + imm32, zero-extended; no REX.W, no flags touched)
  check code == @[0xB8'u8, 0x2A'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0xC3'u8]

test "dynasm macro movabs keeps 10-byte form":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    movabs rax, 42
    ret()
  let code = ops.finalize()
  # Explicit movabs forces REX.W B8 + imm64 even for small values.
  check code.len == 11
  check code[0] == 0x48'u8
  check code[1] == 0xB8'u8
  check code[10] == 0xC3'u8

test "dynasm macro mov negative imm uses sign-extended form":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    mov rax, -1
    ret()
  let code = ops.finalize()
  # mov r/m64, imm32 sign-extended: REX.W C7 /0 id (7 bytes).
  check code == @[0x48'u8, 0xC7'u8, 0xC0'u8,
    0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xC3'u8]

test "dynasm macro backward jumps auto-shorten":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    label loop
    nop()
    jmp bwd("loop")
    ret()
  let code = ops.finalize()
  # loop at 0, nop, EB FD (target 0 - end 3 = -3), ret.
  check code == @[0x90'u8, 0xEB'u8, 0xFD'u8, 0xC3'u8]

test "dynasm macro backward jcc auto-shortens":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch x64
    label loop
    nop()
    jl bwd("loop")
    ret()
  let code = ops.finalize()
  # 7C FD, ret.
  check code == @[0x90'u8, 0x7C'u8, 0xFD'u8, 0xC3'u8]
