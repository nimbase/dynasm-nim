# dot_product — dot product over two int64 arrays in JIT code.
#
# Run with:
#   nim r examples/dot_product.nim
#
# JIT signature (SysV AMD64): dot(a, b: ptr int64, n: int64): int64.
# Three arguments (RDI, RSI, RDX) plus `imul reg, mem` straight from
# the second array — multiply-accumulate with no extra loads.

import dynasm
import benchutil

type DotFn = proc(a, b: pointer, n: int64): int64 {.cdecl.}

proc buildDot(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # Args: first slots (System V: RDI, RSI, RDX / Win64: RCX, RDX, R8).
    alias xs, rdi, rcx
    alias ys, rsi, rdx
    alias n, rdx, r8
    `xor` r10, r10 # acc (r10: scratch on both ABIs)
    `xor` r11d, r11d # i (r11: scratch on both ABIs)
    label loop
    cmp r11, n
    jge fwd("done")
    mov rax, [xs + r11*8]
    imul rax, [ys + r11*8]
    add r10, rax
    add r11, 1
    jmp bwd("loop")
    label done
    mov rax, r10
    ret()
  a.finalize()

when isMainModule:
  const N = 10_000
  var xs = newSeq[int64](N)
  var ys = newSeq[int64](N)
  for i in 0..<N:
    xs[i] = int64(i mod 100)
    ys[i] = int64((3 * i + 7) mod 100)
  let bt0 = getMonoTime()
  var buf = buildDot()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let dot = cast[DotFn](buf.ptrAt(AssemblyOffset(0)))
  var expected = 0'i64
  for i in 0..<N: expected += xs[i] * ys[i]
  assert dot(cast[pointer](addr xs[0]), cast[pointer](addr ys[0]),
    int64(N)) == expected
  let iters = benchIters(2_000)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += dot(cast[pointer](addr xs[0]), cast[pointer](addr ys[0]),
      int64(N))
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == expected * iters
  echo "dot(10k) = ", expected, " x", iters, " iters: ", rep
  buf.destroy()
