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
  let bt0 = getMonoTime()
  var buf = buildBsort()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
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
  let perIter = cases.len
  let totalCalls = iters * perIter
  # Pre-stage one fresh copy per timed call before t0: the JIT sort
  # mutates its buffer, so reusing one buffer would time sorting
  # already-sorted input after the first call.
  var want = newSeq[seq[int64]](perIter)
  for t in 0..<perIter: want[t] = sorted(cases[t])
  var offs = newSeq[int](totalCalls + 1)
  var total = 0
  for k in 0..<totalCalls:
    offs[k] = total
    total += cases[k mod perIter].len
  offs[totalCalls] = total
  var scratch = newSeq[int64](total)
  for k in 0..<totalCalls:
    let src = cases[k mod perIter]
    for i in 0..<src.len: scratch[offs[k] + i] = src[i]
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  var k = 0
  for _ in 0..<iters:
    for t in 0..<perIter:
      bsort(cast[pointer](addr scratch[offs[k]]), int64(cases[t].len))
      acc += scratch[offs[k]] # minimum element, invariant under sorting
      inc k
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, totalCalls)
  assert acc == mins * iters
  for k2 in 0..<totalCalls:
    let w = want[k2 mod perIter]
    for i in 0..<w.len:
      assert scratch[offs[k2] + i] == w[i], "unsorted on call " & $k2
  var demo = @[5'i64, 1, 4, 2, 8, 0, 2]
  bsort(cast[pointer](addr demo[0]), int64(demo.len))
  echo "sorted: ", demo, " x", iters, " iters x", perIter, " sorts (",
    totalCalls, " pure-JIT calls): ", rep # @[0, 1, 2, 2, 4, 5, 8]
  buf.destroy()
