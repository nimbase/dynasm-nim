# array_sum — streaming sum over an int64 array in JIT code.
#
# Run with:
#   nim r examples/array_sum.nim
#
# JIT signature (SysV AMD64): asum(arr: ptr int64, n: int64): int64.
# A tight pointer-chasing loop: one indexed load plus one add per
# element. The classic memory-bandwidth microbenchmark.

import dynasm
import benchutil

type AsumFn = proc(arr: pointer, n: int64): int64 {.cdecl.}

proc buildAsum(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI (use RCX, RDX on Windows x64).
    alias arr, rdi
    alias n, rsi
    `xor` r8, r8 # total
    `xor` ecx, ecx # i
    label loop
    cmp rcx, n
    jge fwd("done")
    mov rax, [arr + rcx*8]
    add r8, rax
    add rcx, 1
    jmp bwd("loop")
    label done
    mov rax, r8
    ret()
  a.finalize()

when isMainModule:
  const N = 100_000
  var data = newSeq[int64](N)
  for i in 0..<N: data[i] = int64(i + 1)
  let bt0 = getMonoTime()
  var buf = buildAsum()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let asum = cast[AsumFn](buf.ptrAt(AssemblyOffset(0)))
  let expected = N.int64 * (N.int64 + 1) div 2
  assert asum(cast[pointer](addr data[0]), int64(N)) == expected
  let iters = benchIters(500)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += asum(cast[pointer](addr data[0]), int64(N))
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == expected * iters
  echo "asum(1..", N, ") = ", expected, " x", iters, " iters: ", rep
  buf.destroy()
