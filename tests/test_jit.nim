import unittest
import dynasm

test "jit assemble and execute simple ret42":
  # mov eax, 42; ret  => returns 42
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    mov eax, 42
    ret()
  var buf = a.finalize()
  check buf.len == 6 # B8 2A 00 00 00 C3? Actually mov eax,42 = B8 + imm32 (5) + C3
  type Fn = proc(): int32 {.cdecl.}
  let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
  let r = f()
  check r == 42
  buf.destroy()

test "jit with local label loop":
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    mov eax, 0
    label loop
    add eax, 1
    cmp eax, 5
    jl bwd("loop")
    ret()
  var buf = a.finalize()
  type Fn = proc(): int32 {.cdecl.}
  let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
  check f() == 5
  buf.destroy()

test "jit commit twice grows":
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    nop()
  a.commit()
  dynasm a:
    arch x64
    mov eax, 7
    ret()
  var buf = a.finalize()
  check buf.len == 1 + 5 + 1
  buf.destroy()
