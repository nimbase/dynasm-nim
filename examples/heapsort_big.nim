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

proc buildHsort*(): ExecutableBuffer =
  when defined(arm64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Same kernel shape as heapsort.nim (see that file for the
      # commented version).
      alias arr, x0
      alias n, x1
      stp x19, x30, [sp, -16], pre
      mov x19, n
      lsr x9, x19, 1
      sub x9, x9, 1
      cmp x9, 0
      b.lt fwd("sortphase")
      label heaploop
      mov x10, x9
      mov x11, x19
      bl fwd("sift")
      sub x9, x9, 1
      cmp x9, 0
      b.ge bwd("heaploop")
      label sortphase
      sub x9, x19, 1
      label sortloop
      cmp x9, 1
      b.lt fwd("done")
      ldr x12, [arr]
      ldr x13, [arr, x9, lsl, 3]
      str x13, [arr]
      str x12, [arr, x9, lsl, 3]
      mov x10, xzr
      mov x11, x9
      bl fwd("sift")
      sub x9, x9, 1
      b bwd("sortloop")
      label done
      ldp x19, x30, [sp], 16
      ret()
      label sift
      label siftloop
      lsl x12, x10, 1
      add x12, x12, 1
      cmp x12, x11
      b.ge fwd("siftdone")
      add x13, x12, 1
      cmp x13, x11
      b.ge fwd("noright")
      ldr x14, [arr, x12, lsl, 3]
      ldr x15, [arr, x13, lsl, 3]
      cmp x14, x15
      b.ge fwd("noright")
      mov x12, x13
      label noright
      ldr x14, [arr, x10, lsl, 3]
      ldr x15, [arr, x12, lsl, 3]
      cmp x14, x15
      b.ge fwd("siftdone")
      str x15, [arr, x10, lsl, 3]
      str x14, [arr, x12, lsl, 3]
      mov x10, x12
      b bwd("siftloop")
      label siftdone
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias arr, rdi, rcx
      alias n, rsi, rdx
      # n lives in callee-saved R15: sift uses RDX as
      # scratch, which carries n on Win64.
      push r15
      mov r15, n
      mov r9, r15
      `shr` r9, 1
      sub r9, 1
      cmp r9, 0
      jl fwd("sortphase")
      label heaploop
      mov r10, r9
      mov r11, r15
      call fwd("sift")
      sub r9, 1
      cmp r9, 0
      jge bwd("heaploop")
      label sortphase
      mov r9, r15
      sub r9, 1
      label sortloop
      cmp r9, 1
      jl fwd("done")
      mov rax, [arr]
      mov r8, [arr + r9*8]
      mov [arr], r8
      mov [arr + r9*8], rax
      mov r10, 0
      mov r11, r9
      call fwd("sift")
      sub r9, 1
      jmp bwd("sortloop")
      label done
      pop r15
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
      mov r8, rax
      add r8, 1
      cmp r8, r11
      jge fwd("noright")
      mov rdx, [arr + rax*8]
      cmp rdx, [arr + r8*8]
      jge fwd("noright")
      mov rax, r8
      label noright
      mov rdx, [arr + r10*8]
      cmp rdx, [arr + rax*8]
      jge fwd("siftdone")
      mov r8, [arr + r10*8]
      mov rdx, [arr + rax*8]
      mov [arr + r10*8], rdx
      mov [arr + rax*8], r8
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
  let bt0 = getMonoTime()
  var buf = buildHsort()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let hsort = cast[HsortFn](buf.ptrAt(AssemblyOffset(0)))
  var data = newSeq[int64](N)
  for i in 0..<N: data[i] = base[i]
  hsort(cast[pointer](addr data[0]), int64(N))
  assert data == expected, "mismatch"
  let iters = benchIters(1)
  # One fresh 200k copy per timed call, staged before t0; the full
  # equality check moves after the loop.
  var copies = newSeq[seq[int64]](iters)
  for k in 0..<iters:
    copies[k] = newSeq[int64](N)
    for i in 0..<N: copies[k][i] = base[i]
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for k in 0..<iters:
    hsort(cast[pointer](addr copies[k][0]), int64(N))
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  for k in 0..<iters:
    assert copies[k] == expected, "mismatch on copy " & $k
  echo "heapsort(200k) ok x", iters, " pure-JIT iters: ", rep
  buf.destroy()
