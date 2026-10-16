# heapsort_big — heapsort over 200k elements.
#
# Run with:
#   nim r examples/heapsort_big.nim
#
# Same JIT kernel shape as heapsort.nim (see that file for the
# commented version); here a single 200k-element array stresses
# cache behavior during sift-down.

import dynasm
import benchutil
import std/algorithm
import std/random

type HsortFn = proc(arr: pointer, n: int64) {.cdecl.}

proc buildHsort(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    alias arr, rdi
    alias n, rsi
    mov r9, n
    `shr` r9, 1
    sub r9, 1
    cmp r9, 0
    jl fwd("sortphase")
    label heaploop
    mov r10, r9
    mov r11, n
    call fwd("sift")
    sub r9, 1
    cmp r9, 0
    jge bwd("heaploop")
    label sortphase
    mov r9, n
    sub r9, 1
    label sortloop
    cmp r9, 1
    jl fwd("done")
    mov rax, [arr]
    mov rcx, [arr + r9*8]
    mov [arr], rcx
    mov [arr + r9*8], rax
    mov r10, 0
    mov r11, r9
    call fwd("sift")
    sub r9, 1
    jmp bwd("sortloop")
    label done
    ret()
    label sift
    push r8
    push r9
    label siftloop
    mov rax, r10
    add rax, rax
    add rax, 1
    cmp rax, r11
    jge fwd("siftdone")
    mov rcx, rax
    add rcx, 1
    cmp rcx, r11
    jge fwd("noright")
    mov rdx, [arr + rax*8]
    cmp rdx, [arr + rcx*8]
    jge fwd("noright")
    mov rax, rcx
    label noright
    mov rdx, [arr + r10*8]
    cmp rdx, [arr + rax*8]
    jge fwd("siftdone")
    mov rcx, [arr + r10*8]
    mov rdx, [arr + rax*8]
    mov [arr + r10*8], rdx
    mov [arr + rax*8], rcx
    mov r10, rax
    jmp bwd("siftloop")
    label siftdone
    pop r9
    pop r8
    ret()
  a.finalize()

when isMainModule:
  const N = 200_000
  randomize(7)
  var base = newSeq[int64](N)
  for i in 0..<N: base[i] = rand(-1000000..1000000).int64
  let expected = sorted(base)
  var buf = buildHsort()
  let hsort = cast[HsortFn](buf.ptrAt(AssemblyOffset(0)))
  var data = newSeq[int64](N)
  for i in 0..<N: data[i] = base[i]
  hsort(cast[pointer](addr data[0]), int64(N))
  assert data == expected, "mismatch"
  let iters = benchIters(1)
  for _ in 0..<iters:
    for i in 0..<N: data[i] = base[i]
    hsort(cast[pointer](addr data[0]), int64(N))
    assert data == expected
  echo "heapsort(200k) ok x", iters, " iters"
  buf.destroy()
