# tail_recursive — genuine recursion via `call` to a local label.
#
# Run with:
#   nim r examples/tail_recursive.nim
#
# JIT signature (SysV AMD64): fact(n, acc: int64): int64.
# A tail-recursive factorial: each frame pushes N, folds it into the
# accumulator with `imul`, then `call`s the entry label with N-1.
# The stack stays balanced with push/pop around the call.

import dynasm
import benchutil

type FactFn = proc(n, acc: int64): int64 {.cdecl.}

proc buildFact(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI (use RCX, RDX on Windows x64).
    alias n, rdi
    alias acc, rsi
    label fact
    cmp n, 1
    jle fwd("base")
    push n
    imul acc, n
    sub n, 1
    call bwd("fact")
    pop n
    ret()
    label base
    mov rax, acc
    ret()
  a.finalize()

proc factRef(n, acc: int64): int64 =
  if n <= 1: acc
  else: factRef(n - 1, n * acc)

when isMainModule:
  let bt0 = getMonoTime()
  var buf = buildFact()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let fact = cast[FactFn](buf.ptrAt(AssemblyOffset(0)))
  for n in 0'i64..20'i64:
    assert fact(n, 1) == factRef(n, 1), "mismatch at " & $n
  let iters = benchIters(400_000)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += fact(15, 1)
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == factRef(15, 1) * iters
  echo "fact(20) = ", fact(20, 1), " x", iters, " iters of fact(15): ", rep # 2432902008176640000
  buf.destroy()
