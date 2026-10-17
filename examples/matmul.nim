# matmul — 480x480 dense matrix multiply in JIT code.
#
# Run with:
#   nim r examples/matmul.nim
#
# JIT signature (SysV AMD64): matmul(a, b, c: ptr int64, n: int64).
# C = A*B with i/j/k loops. The inner kernel keeps the accumulator
# in R12 and the B-stream offset in R13 (both callee-saved, pushed
# once at entry); the C-cell address and the J counter spill to the
# stack once per (i,j) cell. C must be zeroed by the caller.

import dynasm
import benchutil

type MatmulFn = proc(a, b, c: pointer, n: int64) {.cdecl.}

const N = 480

proc buildMatmul*(): ExecutableBuffer =
  when defined(arm64) or defined(aarch64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slots (AAPCS64: X0-X3). No calls inside, so the
      # ten caller-saved temporaries cover every live value and no
      # stack is touched (the x64 pushes/spills only exist for
      # callee-saved R12-R14 and the cell/j spill slots).
      alias aa, x0
      alias bb, x1
      alias cc, x2
      alias n, x3
      # i in X9, j/k in X10, aOff in X11, acc in X12, bOff in X13,
      # cell in X17, product temps in X15/X16.
      mov x9, xzr # i
      label outer
      cmp x9, n
      b.ge fwd("done")
      mov x10, xzr # j
      label mid
      cmp x10, n
      b.ge fwd("nexti")
      mul x11, x9, n # aOff = i*n
      add x17, x11, x10 # i*n+j
      lsl x17, x17, 3
      add x17, cc, x17 # &C[i,j]
      mov x13, x10 # bOff = j
      mov x14, xzr # k = 0
      mov x12, xzr # acc = 0
      label inner
      cmp x14, n
      b.ge fwd("endinner")
      ldr x15, [aa, x11, lsl, 3]
      ldr x16, [bb, x13, lsl, 3]
      mul x15, x15, x16
      add x12, x12, x15
      add x11, x11, 1
      add x13, x13, n
      add x14, x14, 1
      b bwd("inner")
      label endinner
      str x12, [x17]
      add x10, x10, 1 # j++
      b bwd("mid")
      label nexti
      add x9, x9, 1 # i++
      b bwd("outer")
      label done
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # Args: first slots (System V: RDI, RSI, RDX, RCX / Win64: RCX, RDX, R8, R9).
      alias aa, rdi, rcx
      alias bb, rsi, rdx
      alias cc, rdx, r8
      alias n, rcx, r9
      push r12
      push r13
      push r14
      # i in R11, j/k in R10, aOff in R14: R11/R10 are scratch on both
      # ABIs, R14 is callee-saved (pushed). R8/R9 held i/j before but
      # carry args on Win64, so every home moves.
      `xor` r11, r11 # i
      label outer
      cmp r11, n
      jge fwd("done")
      `xor` r10, r10 # j
      label mid
      cmp r10, n
      jge fwd("nexti")
      mov r14, r11
      imul r14, n # aOff = i*n
      mov rax, r14
      add rax, r10 # i*n+j
      lea rax, [cc + rax*8] # &C[i,j]
      push rax # spill cell address
      push r10 # spill j
      mov r13, r10 # bOff = j
      `xor` r10, r10 # k = 0 (j dead from here)
      `xor` r12, r12 # acc = 0
      label inner
      cmp r10, n
      jge fwd("endinner")
      mov rax, [aa + r14*8]
      imul rax, [bb + r13*8]
      add r12, rax
      add r14, 1
      add r13, n
      add r10, 1
      jmp bwd("inner")
      label endinner
      pop r10 # j
      pop r13 # cell address
      mov [r13], r12
      add r10, 1 # j++
      jmp bwd("mid")
      label nexti
      add r11, 1 # i++
      jmp bwd("outer")
      label done
      pop r14
      pop r13
      pop r12
      ret()
    a.finalize()

when isMainModule:
  var aa = newSeq[int64](N * N)
  var bb = newSeq[int64](N * N)
  var cc = newSeq[int64](N * N)
  var refC = newSeq[int64](N * N)
  for i in 0..<N:
    for j in 0..<N:
      aa[i * N + j] = int64((i + j) mod 8)
      bb[i * N + j] = int64((i * 3 + j) mod 8)
  for i in 0..<N:
    for j in 0..<N:
      var s = 0'i64
      for k in 0..<N:
        s += aa[i * N + k] * bb[k * N + j]
      refC[i * N + j] = s
  let bt0 = getMonoTime()
  var buf = buildMatmul()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let matmul = cast[MatmulFn](buf.ptrAt(AssemblyOffset(0)))
  matmul(cast[pointer](addr aa[0]), cast[pointer](addr bb[0]),
    cast[pointer](addr cc[0]), int64(N))
  assert cc == refC, "mismatch"
  let iters = benchIters(2)
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    for v in cc.mitems: v = 0
    matmul(cast[pointer](addr aa[0]), cast[pointer](addr bb[0]),
      cast[pointer](addr cc[0]), int64(N))
    assert cc == refC
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  var chk = 0'i64
  for v in cc: chk += v
  echo "matmul(480) checksum ", chk, " x", iters, " iters: ", rep
  buf.destroy()
