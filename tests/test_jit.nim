import unittest
import dynasm

# Machine-code execution tests are gated by host CPU: x64 bytes
# fault (SIGILL) on ARM and vice versa. Assembly-only checks stay
# unconditional; only the `f()` calls are fenced.

when defined(amd64):
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

when defined(arm64):
  test "aarch64 jit movz/ret returns immediate":
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      movz x0, 42
      ret()
    var buf = a.finalize()
    type Fn = proc(): int64 {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    check f() == 42
    buf.destroy()

  test "aarch64 jit countdown loop with cbnz":
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      mov x0, 0
      mov x1, 5
      label loop
      add x0, x0, 1
      sub x1, x1, 1
      cbnz x1, bwd("loop")
      ret()
    var buf = a.finalize()
    type Fn = proc(): int64 {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    check f() == 5
    buf.destroy()

  test "aarch64 jit str/ldr roundtrip through pointer arg":
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      mov x1, x0 # spill the pointer arg; x0 takes the value below
      movz x0, 0x1234
      str x0, [x1]
      ldr x0, [x1]
      ret()
    var buf = a.finalize()
    type Fn = proc(p: pointer): int64 {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    var cell = 0'i64
    check f(addr cell) == 0x1234
    check cell == 0x1234
    buf.destroy()

  test "aarch64 jit scalar fadd executes":
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      fmov d0, 1.0
      fmov d1, 2.0
      fadd d0, d0, d1
      ret()
    var buf = a.finalize()
    type Fn = proc(): float64 {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    check f() == 3.0
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
