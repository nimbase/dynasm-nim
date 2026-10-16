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

proc buildSaxpy(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI, RDX, RCX.
    alias aval, rdi
    alias xs, rsi
    alias ys, rdx
    alias n, rcx
    `xor` r9, r9 # i
    label loop
    cmp r9, n
    jge fwd("done")
    mov rax, [xs + r9*8]
    imul rax, aval
    add rax, [ys + r9*8]
    mov [ys + r9*8], rax
    add r9, 1
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
