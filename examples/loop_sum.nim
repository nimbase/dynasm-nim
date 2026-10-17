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

proc buildSum*(): ExecutableBuffer =
  when defined(arm64) or defined(aarch64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slot (AAPCS64: X0).
      alias n, x0
      mov x9, xzr # total
      mov x10, 1 # i
      label loop
      cmp x10, n
      b.gt fwd("done")
      add x9, x9, x10
      add x10, x10, 1
      b bwd("loop")
      label done
      mov x0, x9
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # Args: first slot (System V: RDI / Win64: RCX).
      alias n, rdi, rcx
      mov rax, 0
      mov r10, 1 # i (r10: scratch on both ABIs)
      label loop
      cmp r10, n
      jg fwd("done")
      add rax, r10
      add r10, 1
      jmp bwd("loop")
      label done
      ret()
    a.finalize()

when isMainModule:
  let bt0 = getMonoTime()
  var buf = buildSum()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let sumTo = cast[SumFn](buf.ptrAt(AssemblyOffset(0)))
  for n in [0'i64, 1, 2, 10, 100, 1000]:
    assert sumTo(n) == n * (n + 1) div 2, "mismatch at " & $n
  let iters = benchIters(100)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += sumTo(1_000_000)
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == 500_000_500_000'i64 * iters
  echo "sumTo(1000000) = ", sumTo(1_000_000), " x", iters, " iters: ", rep # 500000500000
  buf.destroy()
