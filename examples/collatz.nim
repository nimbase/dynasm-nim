# collatz — Collatz step count compiled at runtime with dynasm.
#
# Run with:
#   nim r examples/collatz.nim
#
# JIT signature (SysV AMD64): steps(n: int64): int64.
# Even n halves with `shr`, odd n uses 3n+1 via mov/shl/add so the
# example also shows shifts. Note: `and`, `shr`, `shl` are Nim
# keywords, hence the backticks inside the dynasm block.

import dynasm
import benchutil

type StepsFn = proc(n: int64): int64 {.cdecl.}

proc buildSteps(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: first arg arrives in RDI (use RCX on Windows x64).
    alias n, rdi
    mov rax, n
    mov rcx, 0
    label loop
    cmp rax, 1
    je fwd("done")
    mov rdx, rax
    `and` rdx, 1
    cmp rdx, 0
    jne fwd("odd")
    `shr` rax, 1
    add rcx, 1
    jmp bwd("loop")
    label odd
    mov rdx, rax
    `shl` rdx, 1
    add rax, rdx
    add rax, 1
    add rcx, 1
    jmp bwd("loop")
    label done
    mov rax, rcx
    ret()
  a.finalize()

proc stepsRef(n: int64): int64 =
  var x = n
  while x != 1:
    if x mod 2 == 0: x = x div 2
    else: x = 3 * x + 1
    inc result

when isMainModule:
  let bt0 = getMonoTime()
  var buf = buildSteps()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let steps = cast[StepsFn](buf.ptrAt(AssemblyOffset(0)))
  for n in [1'i64, 2, 3, 6, 27, 97, 871]:
    assert steps(n) == stepsRef(n), "mismatch at " & $n
  let iters = benchIters(300_000)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += steps(27)
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == stepsRef(27) * iters
  echo "collatz steps(27) = ", steps(27), " x", iters, " iters: ", rep
  buf.destroy()
