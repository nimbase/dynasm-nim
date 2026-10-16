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
    # SysV: args arrive in RDI, RSI, RDX (use RCX, RDX, R8 on Windows).
    alias xs, rdi
    alias ys, rsi
    alias n, rdx
    `xor` r8, r8 # acc
    `xor` ecx, ecx # i
    label loop
    cmp rcx, n
    jge fwd("done")
    mov rax, [xs + rcx*8]
    imul rax, [ys + rcx*8]
    add r8, rax
    add rcx, 1
    jmp bwd("loop")
    label done
    mov rax, r8
    ret()
  a.finalize()

when isMainModule:
  const N = 10_000
  var xs = newSeq[int64](N)
  var ys = newSeq[int64](N)
  for i in 0..<N:
    xs[i] = int64(i mod 100)
    ys[i] = int64((3 * i + 7) mod 100)
  var buf = buildDot()
  let dot = cast[DotFn](buf.ptrAt(AssemblyOffset(0)))
  var expected = 0'i64
  for i in 0..<N: expected += xs[i] * ys[i]
  assert dot(cast[pointer](addr xs[0]), cast[pointer](addr ys[0]),
    int64(N)) == expected
  let iters = benchIters(2_000)
  var acc = 0'i64
  for _ in 0..<iters:
    acc += dot(cast[pointer](addr xs[0]), cast[pointer](addr ys[0]),
      int64(N))
  assert acc == expected * iters
  echo "dot(10k) = ", expected, " x", iters, " iters"
  buf.destroy()
