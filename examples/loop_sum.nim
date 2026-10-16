# loop_sum — sum of 1..n compiled at runtime with dynasm.
#
# Run with:
#   nim r examples/loop_sum.nim
#
# JIT signature (SysV AMD64): sumTo(n: int64): int64.
# Checked against the closed form n*(n+1)/2.

import dynasm
import benchutil

type SumFn = proc(n: int64): int64 {.cdecl.}

proc buildSum(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: first arg arrives in RDI (use RCX on Windows x64).
    alias n, rdi
    mov rax, 0
    mov rcx, 1
    label loop
    cmp rcx, n
    jg fwd("done")
    add rax, rcx
    add rcx, 1
    jmp bwd("loop")
    label done
    ret()
  a.finalize()

when isMainModule:
  var buf = buildSum()
  let sumTo = cast[SumFn](buf.ptrAt(AssemblyOffset(0)))
  for n in [0'i64, 1, 2, 10, 100, 1000]:
    assert sumTo(n) == n * (n + 1) div 2, "mismatch at " & $n
  let iters = benchIters(100)
  var acc = 0'i64
  for _ in 0..<iters:
    acc += sumTo(1_000_000)
  assert acc == 500_000_500_000'i64 * iters
  echo "sumTo(1000000) = ", sumTo(1_000_000), " x", iters, " iters" # 500000500000
  buf.destroy()
