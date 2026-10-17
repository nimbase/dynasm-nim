# saxpy — integer y[i] = a*x[i] + y[i] streaming kernel.
#
# Run with:
#   nim r examples/saxpy.nim
#
# JIT signature (SysV AMD64): saxpy(a: int64, x, y: ptr int64, n: int64).
# Single-precision AXPY would need an SSE backend; this is the integer
# variant with the same memory-streaming shape: two loads, one
# multiply-add, one store per element.

import dynasm
import benchutil

type SaxpyFn = proc(a: int64, x, y: pointer, n: int64) {.cdecl.}

const N = 1_000_000

proc buildSaxpy*(): ExecutableBuffer =
  when defined(arm64) or defined(aarch64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slots (AAPCS64: X0-X3).
      alias aval, x0
      alias xs, x1
      alias ys, x2
      alias n, x3
      mov x9, xzr # i
      label loop
      cmp x9, n
      b.ge fwd("done")
      ldr x10, [xs, x9, lsl, 3]
      mul x10, x10, aval
      ldr x11, [ys, x9, lsl, 3]
      add x10, x10, x11
      str x10, [ys, x9, lsl, 3]
      add x9, x9, 1
      b bwd("loop")
      label done
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # Args: first slots (System V: RDI, RSI, RDX, RCX / Win64: RCX, RDX, R8, R9).
      alias aval, rdi, rcx
      alias xs, rsi, rdx
      alias ys, rdx, r8
      alias n, rcx, r9
      `xor` r10, r10 # i (r10: scratch on both ABIs; R9 holds an arg on Win64)
      label loop
      cmp r10, n
      jge fwd("done")
      mov rax, [xs + r10*8]
      imul rax, aval
      add rax, [ys + r10*8]
      mov [ys + r10*8], rax
      add r10, 1
      jmp bwd("loop")
      label done
      ret()
    a.finalize()

when isMainModule:
  var xs = newSeq[int64](N)
  var ys = newSeq[int64](N)
  var refY = newSeq[int64](N)
  for i in 0..<N:
    xs[i] = int64(i mod 1000)
    ys[i] = int64((i * 7) mod 1000)
  const A = 3'i64
  for i in 0..<N: refY[i] = A * xs[i] + ys[i]
  let bt0 = getMonoTime()
  var buf = buildSaxpy()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let saxpy = cast[SaxpyFn](buf.ptrAt(AssemblyOffset(0)))
  saxpy(A, cast[pointer](addr xs[0]), cast[pointer](addr ys[0]), int64(N))
  assert ys == refY, "mismatch"
  let iters = benchIters(20)
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    for i in 0..<N: ys[i] = int64((i * 7) mod 1000)
    saxpy(A, cast[pointer](addr xs[0]), cast[pointer](addr ys[0]),
      int64(N))
    assert ys == refY
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  echo "saxpy(1M) ok x", iters, " iters: ", rep
  buf.destroy()
