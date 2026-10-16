# bubble_sort — bubble sort over int64 elements in JIT code.
#
# Run with:
#   nim r examples/bubble_sort.nim
#
# JIT signature (SysV AMD64): bsort(arr: ptr int64, n: int64).
# Two nested local-label loops plus indexed addressing with stride 8
# (`[base + index*8]`). Swap uses a caller-saved scratch register.

import dynasm
import benchutil
import std/algorithm
import std/random

type BsortFn = proc(arr: pointer, n: int64) {.cdecl.}

proc buildBsort(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI (use RCX, RDX on Windows x64).
    alias arr, rdi
    alias n, rsi
    label outer
    mov rdx, 0 # swapped flag
    mov rcx, 0 # i
    label inner
    mov rax, rcx
    add rax, 1
    cmp rax, n
    jge fwd("endinner")
    mov rax, [arr + rcx*8]
    cmp rax, [arr + rcx*8 + 8]
    jle fwd("noswap")
    mov r8, [arr + rcx*8 + 8]
    mov [arr + rcx*8], r8
    mov [arr + rcx*8 + 8], rax
    mov rdx, 1
    label noswap
    add rcx, 1
    jmp bwd("inner")
    label endinner
    cmp rdx, 0
    jne bwd("outer")
    ret()
  a.finalize()

when isMainModule:
  randomize(1234)
  var buf = buildBsort()
  let bsort = cast[BsortFn](buf.ptrAt(AssemblyOffset(0)))
  var cases = newSeq[seq[int64]](20)
  for t in 0..<20:
    let n = rand(1..30)
    cases[t] = newSeq[int64](n)
    for i in 0..<n: cases[t][i] = rand(-1000..1000).int64
  for t in 0..<cases.len:
    var data = newSeq[int64](cases[t].len)
    for i in 0..<data.len: data[i] = cases[t][i]
    let expected = sorted(data)
    bsort(cast[pointer](addr data[0]), int64(data.len))
    assert data == expected, "mismatch on trial " & $t
  var mins = 0'i64
  for t in 0..<cases.len:
    var m = cases[t][0]
    for v in cases[t]:
      if v < m: m = v
    mins += m
  let iters = benchIters(600)
  var acc = 0'i64
  for _ in 0..<iters:
    for t in 0..<cases.len:
      var data = newSeq[int64](cases[t].len)
      for i in 0..<data.len: data[i] = cases[t][i]
      bsort(cast[pointer](addr data[0]), int64(data.len))
      acc += data[0] # minimum element, invariant under sorting
  assert acc == mins * iters
  var demo = @[5'i64, 1, 4, 2, 8, 0, 2]
  bsort(cast[pointer](addr demo[0]), int64(demo.len))
  echo "sorted: ", demo, " x", iters, " iters" # @[0, 1, 2, 2, 4, 5, 8]
  buf.destroy()
