# nested_loops — doubly-nested accumulation in JIT code.
#
# Run with:
#   nim r examples/nested_loops.nim
#
# JIT signature (SysV AMD64): nested(n, m: int64): int64.
# Computes sum(i*j for i in 0..<n for j in 0..<m) with two nested
# local-label loops and `imul` in the hot inner body. Closed form:
# (n*(n-1)/2) * (m*(m-1)/2).

import dynasm
import benchutil

type NestedFn = proc(n, m: int64): int64 {.cdecl.}

proc buildNested(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI (use RCX, RDX on Windows x64).
    alias n, rdi
    alias m, rsi
    `xor` r8, r8 # total
    `xor` r9, r9 # i
    label outer
    cmp r9, n
    jge fwd("done")
    `xor` r10, r10 # j
    label inner
    cmp r10, m
    jge fwd("next")
    mov rax, r9
    imul rax, r10
    add r8, rax
    add r10, 1
    jmp bwd("inner")
    label next
    add r9, 1
    jmp bwd("outer")
    label done
    mov rax, r8
    ret()
  a.finalize()

proc nestedRef(n, m: int64): int64 =
  (n * (n - 1) div 2) * (m * (m - 1) div 2)

when isMainModule:
  let bt0 = getMonoTime()
  var buf = buildNested()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let nested = cast[NestedFn](buf.ptrAt(AssemblyOffset(0)))
  for (n, m) in [(0'i64, 0'i64), (1, 10), (10, 10), (37, 41)]:
    assert nested(n, m) == nestedRef(n, m), "mismatch at " & $n & "," & $m
  let iters = benchIters(200)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += nested(500, 500)
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == nestedRef(500, 500) * iters
  echo "nested(500,500) = ", nested(500, 500), " x", iters, " iters: ", rep
  buf.destroy()
