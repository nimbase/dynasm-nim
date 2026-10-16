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
  # B8 + imm32? Actually mov rax, imm with sz64 => REX.W B8 + imm64
  check code[0] == 0x48'u8
