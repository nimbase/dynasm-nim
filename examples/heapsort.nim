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

proc buildHsort(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI.
    alias arr, rdi
    alias n, rsi
    # heapify: i = n/2 - 1 down to 0
    mov r9, n
    `shr` r9, 1
    sub r9, 1
    cmp r9, 0
    jl fwd("sortphase")
    label heaploop
    mov r10, r9 # root
    mov r11, n # size
    call fwd("sift")
    sub r9, 1
    cmp r9, 0
    jge bwd("heaploop")
    label sortphase
    mov r9, n
    sub r9, 1 # end
    label sortloop
    cmp r9, 1
    jl fwd("done")
    # swap arr[0], arr[end]
    mov rax, [arr]
    mov rcx, [arr + r9*8]
    mov [arr], rcx
    mov [arr + r9*8], rax
    mov r10, 0 # root
    mov r11, r9 # size = end
    call fwd("sift")
    sub r9, 1
    jmp bwd("sortloop")
    label done
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
    mov rcx, rax
    add rcx, 1 # right = child+1
    cmp rcx, r11
    jge fwd("noright")
    mov rdx, [arr + rax*8]
    cmp rdx, [arr + rcx*8]
    jge fwd("noright")
    mov rax, rcx # child = right
    label noright
    mov rdx, [arr + r10*8] # a[root]
    cmp rdx, [arr + rax*8] # vs a[child]
    jge fwd("siftdone")
    mov rcx, [arr + r10*8]
    mov rdx, [arr + rax*8]
    mov [arr + r10*8], rdx
    mov [arr + rax*8], rcx
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
  var buf = buildHsort()
  let hsort = cast[HsortFn](buf.ptrAt(AssemblyOffset(0)))
  runCases(hsort, cases)
  var mins = 0'i64
  for t in 0..<cases.len:
    var m = cases[t][0]
    for v in cases[t]:
      if v < m: m = v
    mins += m
  let iters = benchIters(5)
  var acc = 0'i64
  for _ in 0..<iters:
    for t in 0..<cases.len:
      var data = newSeq[int64](cases[t].len)
      for i in 0..<data.len: data[i] = cases[t][i]
      hsort(cast[pointer](addr data[0]), int64(data.len))
      acc += data[0]
  assert acc == mins * iters
  echo "heapsort(8x5000) ok x", iters, " iters"
  buf.destroy()
