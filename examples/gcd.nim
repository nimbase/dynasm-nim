# gcd — Euclid's algorithm with `div` in the hot loop.
#
# Run with:
#   nim r examples/gcd.nim
#
# JIT signature (SysV AMD64): gcd(a, b: int64): int64.
# Each iteration divides RDX:RAX by the divisor; the remainder in RDX
# becomes the next divisor. Shows multi-register division state
# threaded through a loop.

import dynasm
import benchutil

type GcdFn = proc(a, b: int64): int64 {.cdecl.}

proc buildGcd*(): ExecutableBuffer =
  when defined(arm64) or defined(aarch64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slots (AAPCS64: X0, X1). `udiv` + `msub` replace
      # the x64 `div` (remainder computed directly, no RDX state).
      alias u, x0
      alias v0, x1
      mov x9, v0 # v
      label loop
      cbz x9, fwd("done")
      udiv x10, u, x9 # q = u / v
      msub x10, x10, x9, u # r = u - q*v
      mov u, x9
      mov x9, x10
      b bwd("loop")
      label done
      ret() # result already in X0 (u)
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
      alias u, rdi, rcx
      alias v0, rsi, rdx
      # v lives in R10: div needs RDX as scratch, and RDX carries an
      # arg on Win64. R10 is scratch on both ABIs.
      mov r10, v0
      label loop
      cmp r10, 0
      je fwd("done")
      mov rax, u
      `xor` rdx, rdx
      `div` r10
      mov u, r10
      mov r10, rdx
      jmp bwd("loop")
      label done
      mov rax, u
      ret()
    a.finalize()

proc gcdRef(a, b: int64): int64 =
  var x = a
  var y = b
  while y != 0:
    let t = x mod y
    x = y
    y = t
  x

when isMainModule:
  let bt0 = getMonoTime()
  var buf = buildGcd()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let gcd = cast[GcdFn](buf.ptrAt(AssemblyOffset(0)))
  for (x, y) in [(48'i64, 18'i64), (1071, 462), (123456789, 987654321),
      (0, 7), (13, 13)]:
    assert gcd(x, y) == gcdRef(x, y), "mismatch at " & $x & "," & $y
  let iters = benchIters(800_000)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += gcd(123456789, 987654321)
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == gcdRef(123456789, 987654321) * iters
  echo "gcd(123456789,987654321) = ", gcd(123456789, 987654321),
    " x", iters, " iters: ", rep
  buf.destroy()
