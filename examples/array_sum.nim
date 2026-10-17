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

proc buildAsum*(): ExecutableBuffer =
  when defined(arm64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slots (AAPCS64: X0, X1). Register-offset load
      # with LSL #3 scales the index by 8, like [arr + i*8].
      alias arr, x0
      alias n, x1
      mov x9, xzr # total
      mov x10, xzr # i
      label loop
      cmp x10, n
      b.ge fwd("done")
      ldr x11, [arr, x10, lsl, 3]
      add x9, x9, x11
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
      # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
      alias arr, rdi, rcx
      alias n, rsi, rdx
      `xor` r8, r8 # total
      `xor` r10d, r10d # i (r10: scratch on both ABIs; RCX holds an arg on Win64)
      label loop
      cmp r10, n
      jge fwd("done")
      mov rax, [arr + r10*8]
      add r8, rax
      add r10, 1
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
