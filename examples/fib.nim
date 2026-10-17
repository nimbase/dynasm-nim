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
    # Args: first slot (System V: RDI / Win64: RCX).
    alias n, rdi, rcx
    mov r8, n
    cmp r8, 1
    jle fwd("base")
    # fib(0) = 0, fib(1) = 1, else iterate a=0, b=1
    mov r11, 0 # a (r11: scratch on both ABIs)
    mov rdx, 1 # b
    mov r10, 2 # i (r10: scratch on both ABIs; RSI is non-volatile on Win64)
    label loop
    mov rax, r11
    add rax, rdx
    mov r11, rdx
    mov rdx, rax
    add r10, 1
    cmp r10, r8
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
  let bt0 = getMonoTime()
  var buf = buildFib()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let fib = cast[FibFn](buf.ptrAt(AssemblyOffset(0)))
  for n in 0'i64..25'i64:
    assert fib(n) == fibRef(n), "mismatch at " & $n
  let iters = benchIters(500_000)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += fib(30)
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == fibRef(30) * iters
  echo "fib(30) = ", fib(30), " x", iters, " iters: ", rep # 832040
  buf.destroy()
