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

proc buildMatmul(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI, RDX, RCX.
    alias aa, rdi
    alias bb, rsi
    alias cc, rdx
    alias n, rcx
    push r12
    push r13
    `xor` r8, r8 # i
    label outer
    cmp r8, n
    jge fwd("done")
    `xor` r9, r9 # j
    label mid
    cmp r9, n
    jge fwd("nexti")
    mov r10, r8
    imul r10, n # i*n
    mov rax, r10
    add rax, r9 # i*n+j
    lea rax, [cc + rax*8] # &C[i,j]
    push rax # spill cell address
    push r9 # spill j
    mov r13, r9 # bOff = j
    `xor` r9, r9 # k = 0 (j dead from here)
    `xor` r12, r12 # acc = 0 (r10 = aOff = i*n still holds)
    label inner
    cmp r9, n
    jge fwd("endinner")
    mov rax, [aa + r10*8]
    imul rax, [bb + r13*8]
    add r12, rax
    add r10, 1
    add r13, n
    add r9, 1
    jmp bwd("inner")
    label endinner
    pop r9 # j
    pop r13 # cell address
    mov [r13], r12
    add r9, 1 # j++
    jmp bwd("mid")
    label nexti
    add r8, 1 # i++
    jmp bwd("outer")
    label done
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
  var buf = buildMatmul()
  let matmul = cast[MatmulFn](buf.ptrAt(AssemblyOffset(0)))
  matmul(cast[pointer](addr aa[0]), cast[pointer](addr bb[0]),
    cast[pointer](addr cc[0]), int64(N))
  assert cc == refC, "mismatch"
  let iters = benchIters(2)
  for _ in 0..<iters:
    for v in cc.mitems: v = 0
    matmul(cast[pointer](addr aa[0]), cast[pointer](addr bb[0]),
      cast[pointer](addr cc[0]), int64(N))
    assert cc == refC
  var chk = 0'i64
  for v in cc: chk += v
  echo "matmul(480) checksum ", chk, " x", iters, " iters"
  buf.destroy()
