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

proc buildFact*(): ExecutableBuffer =
  when defined(arm64) or defined(aarch64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slots (AAPCS64: X0, X1). `bl` overwrites the link
      # register, so each recursive frame spills N together with LR
      # in one 16-byte slot (keeps SP aligned). After the call only
      # LR comes back: the result already sits in X0 (which also
      # homes N), so the N slot is discarded — like the x64 `pop n`,
      # which only balances the stack after the result lands in RAX.
      alias n, x0
      alias acc, x1
      label fact
      cmp n, 1
      b.le fwd("base")
      stp n, x30, [sp, -16], pre
      mul acc, acc, n
      sub n, n, 1
      bl bwd("fact")
      ldr x30, [sp], 16
      ret()
      label base
      mov x0, acc
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
      alias n, rdi, rcx
      alias acc, rsi, rdx
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
