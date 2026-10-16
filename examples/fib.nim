# fib — iterative Fibonacci compiled at runtime with dynasm.
#
# Run with:
#   nim r examples/fib.nim
#
# The JIT function follows the SysV AMD64 convention (Linux/macOS):
#   fib(n: int64): int64   # n in RDI, result in RAX
# An `alias` maps the first-argument register so the same source also
# works on Windows x64 (first arg in RCX).

import dynasm
import benchutil

type FibFn = proc(n: int64): int64 {.cdecl.}

proc buildFib(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: first arg arrives in RDI (use RCX on Windows x64).
    alias n, rdi
    mov r8, n
    cmp r8, 1
    jle fwd("base")
    # fib(0) = 0, fib(1) = 1, else iterate a=0, b=1
    mov rcx, 0
    mov rdx, 1
    mov rsi, 2
    label loop
    mov rax, rcx
    add rax, rdx
    mov rcx, rdx
    mov rdx, rax
    add rsi, 1
    cmp rsi, r8
    jle bwd("loop")
    ret()
    label base
    mov rax, n
    ret()
  a.finalize()

proc fibRef(n: int64): int64 =
  if n <= 1: n
  else:
    var a = 0'i64
    var b = 1'i64
    for _ in 2..n:
      let c = a + b
      a = b
      b = c
    b

when isMainModule:
  var buf = buildFib()
  let fib = cast[FibFn](buf.ptrAt(AssemblyOffset(0)))
  for n in 0'i64..25'i64:
    assert fib(n) == fibRef(n), "mismatch at " & $n
  let iters = benchIters(500_000)
  var acc = 0'i64
  for _ in 0..<iters:
    acc += fib(30)
  assert acc == fibRef(30) * iters
  echo "fib(30) = ", fib(30), " x", iters, " iters" # 832040
  buf.destroy()
