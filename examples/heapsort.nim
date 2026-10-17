# heapsort — heapsort with an internal `call`ed sift-down.
#
# Run with:
#   nim r examples/heapsort.nim
#
# JIT signature (SysV AMD64): hsort(arr: ptr int64, n: int64).
# The sift-down routine is a local `fwd` label called from both the
# heap-build and the extraction loops (root in R10, size in R11);
# it preserves R8/R9 across the call with push/pop. See
# heapsort_big.nim for the large-input sibling.

import dynasm
import benchutil
import std/algorithm
import std/random

type HsortFn = proc(arr: pointer, n: int64) {.cdecl.}

proc buildHsort*(): ExecutableBuffer =
  when defined(arm64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # AAPCS64: args arrive in X0, X1. N lives in callee-saved X19
      # (saved once with the link register, since both loops `bl`
      # into sift); the loop index survives the calls because sift
      # only touches X10-X15.
      alias arr, x0
      alias n, x1
      stp x19, x30, [sp, -16], pre
      mov x19, n
      # heapify: i = n/2 - 1 down to 0
      lsr x9, x19, 1
      sub x9, x9, 1
      cmp x9, 0
      b.lt fwd("sortphase")
      label heaploop
      mov x10, x9 # root
      mov x11, x19 # size
      bl fwd("sift")
      sub x9, x9, 1
      cmp x9, 0
      b.ge bwd("heaploop")
      label sortphase
      sub x9, x19, 1 # end
      label sortloop
      cmp x9, 1
      b.lt fwd("done")
      # swap arr[0], arr[end]
      ldr x12, [arr]
      ldr x13, [arr, x9, lsl, 3]
      str x13, [arr]
      str x12, [arr, x9, lsl, 3]
      mov x10, xzr # root
      mov x11, x9 # size = end
      bl fwd("sift")
      sub x9, x9, 1
      b bwd("sortloop")
      label done
      ldp x19, x30, [sp], 16
      ret()
      # sift-down: root in X10, size in X11; temps in X12-X15
      label sift
      label siftloop
      lsl x12, x10, 1
      add x12, x12, 1 # child = 2*root+1
      cmp x12, x11
      b.ge fwd("siftdone")
      add x13, x12, 1 # right = child+1
      cmp x13, x11
      b.ge fwd("noright")
      ldr x14, [arr, x12, lsl, 3]
      ldr x15, [arr, x13, lsl, 3]
      cmp x14, x15
      b.ge fwd("noright")
      mov x12, x13 # child = right
      label noright
      ldr x14, [arr, x10, lsl, 3] # a[root]
      ldr x15, [arr, x12, lsl, 3] # vs a[child]
      cmp x14, x15
      b.ge fwd("siftdone")
      str x15, [arr, x10, lsl, 3]
      str x14, [arr, x12, lsl, 3]
      mov x10, x12 # root = child
      b bwd("siftloop")
      label siftdone
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # SysV: args arrive in RDI, RSI.
      alias arr, rdi, rcx
      alias n, rsi, rdx
      # n lives in callee-saved R15: sift uses RDX as
      # scratch, which carries n on Win64.
      push r15
      mov r15, n
      # heapify: i = n/2 - 1 down to 0
      mov r9, r15
      `shr` r9, 1
      sub r9, 1
      cmp r9, 0
      jl fwd("sortphase")
      label heaploop
      mov r10, r9 # root
      mov r11, r15 # size
      call fwd("sift")
      sub r9, 1
      cmp r9, 0
      jge bwd("heaploop")
      label sortphase
      mov r9, r15
      sub r9, 1 # end
      label sortloop
      cmp r9, 1
      jl fwd("done")
      # swap arr[0], arr[end]
      mov rax, [arr]
      mov r8, [arr + r9*8]
      mov [arr], r8
      mov [arr + r9*8], rax
      mov r10, 0 # root
      mov r11, r9 # size = end
      call fwd("sift")
      sub r9, 1
      jmp bwd("sortloop")
      label done
      pop r15
      ret()
      # sift-down: root in R10, size in R11; preserves R8/R9
      label sift
      push r8
      push r9
      label siftloop
      mov rax, r10
      add rax, rax
      add rax, 1 # child = 2*root+1
      cmp rax, r11
      jge fwd("siftdone")
      mov r8, rax
      add r8, 1 # right = child+1
      cmp r8, r11
      jge fwd("noright")
      mov rdx, [arr + rax*8]
      cmp rdx, [arr + r8*8]
      jge fwd("noright")
      mov rax, r8 # child = right
      label noright
      mov rdx, [arr + r10*8] # a[root]
      cmp rdx, [arr + rax*8] # vs a[child]
      jge fwd("siftdone")
      mov r8, [arr + r10*8]
      mov rdx, [arr + rax*8]
      mov [arr + r10*8], rdx
      mov [arr + rax*8], r8
      mov r10, rax # root = child
      jmp bwd("siftloop")
      label siftdone
      pop r9
      pop r8
      ret()
    a.finalize()

proc runCases(hsort: HsortFn, cases: seq[seq[int64]]) =
  for t in 0..<cases.len:
    var data = newSeq[int64](cases[t].len)
    for i in 0..<data.len: data[i] = cases[t][i]
    let expected = sorted(data)
    hsort(cast[pointer](addr data[0]), int64(data.len))
    assert data == expected, "mismatch on case " & $t

when isMainModule:
  randomize(99)
  var cases = newSeq[seq[int64]](8)
  for t in 0..<8:
    cases[t] = newSeq[int64](5000)
    for i in 0..<5000: cases[t][i] = rand(-100000..100000).int64
  let bt0 = getMonoTime()
  var buf = buildHsort()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let hsort = cast[HsortFn](buf.ptrAt(AssemblyOffset(0)))
  runCases(hsort, cases)
  var mins = 0'i64
  for t in 0..<cases.len:
    var m = cases[t][0]
    for v in cases[t]:
      if v < m: m = v
    mins += m
  let iters = benchIters(5)
  let perIter = cases.len
  let chunkLen = cases[0].len
  let totalCalls = iters * perIter
  # One fresh input per timed call, staged before t0: the JIT sort
  # mutates its buffer in place.
  var want = newSeq[seq[int64]](perIter)
  for t in 0..<perIter: want[t] = sorted(cases[t])
  var scratch = newSeq[int64](totalCalls * chunkLen)
  for k in 0..<totalCalls:
    let src = cases[k mod perIter]
    for i in 0..<chunkLen: scratch[k * chunkLen + i] = src[i]
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for k in 0..<totalCalls:
    hsort(cast[pointer](addr scratch[k * chunkLen]), int64(chunkLen))
    acc += scratch[k * chunkLen] # minimum element, invariant under sorting
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, totalCalls)
  assert acc == mins * iters
  for k in 0..<totalCalls:
    let w = want[k mod perIter]
    for i in 0..<chunkLen:
      assert scratch[k * chunkLen + i] == w[i], "unsorted on call " & $k
  echo "heapsort(8x5000) ok x", iters, " iters x", perIter, " sorts (",
    totalCalls, " pure-JIT calls): ", rep
  buf.destroy()
