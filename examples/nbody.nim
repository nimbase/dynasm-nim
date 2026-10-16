# nbody — 5-body integer spring system, 5M steps.
#
# Run with:
#   nim r examples/nbody.nim
#
# JIT signature (SysV AMD64): nbody(state: ptr int64, steps: int64).
# State holds 5 bodies as struct-of-arrays: x[5], y[5], vx[5], vy[5]
# (offsets +0, +40, +80, +120). Forces are linear springs (F = dx),
# so no sqrt/divide is needed; velocities update in place per pair
# (Newton's third law) and positions integrate after all pairs.
# All arithmetic wraps mod 2^64 on both sides, so the Nim reference
# uses +% / -% to stay bit-identical.

import dynasm
import benchutil

type NbodyFn = proc(state: pointer, steps: int64) {.cdecl.}

const Bodies = 5

proc buildNbody(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI (use RCX, RDX on Windows x64).
    alias st, rdi
    alias left, rsi
    label step
    cmp left, 0
    je fwd("done")
    `xor` ecx, ecx # i
    label outer
    cmp rcx, 5
    jge fwd("integrate")
    mov rdx, rcx
    add rdx, 1 # j = i+1
    label inner
    cmp rdx, 5
    jge fwd("nexti")
    # dx = x[j]-x[i]; vx[i] += dx; vx[j] -= dx
    mov rax, [st + rdx*8]
    sub rax, [st + rcx*8]
    add [st + rcx*8 + 80], rax
    sub [st + rdx*8 + 80], rax
    # dy = y[j]-y[i]; vy[i] += dy; vy[j] -= dy
    mov rax, [st + rdx*8 + 40]
    sub rax, [st + rcx*8 + 40]
    add [st + rcx*8 + 120], rax
    sub [st + rdx*8 + 120], rax
    add rdx, 1
    jmp bwd("inner")
    label nexti
    add rcx, 1
    jmp bwd("outer")
    label integrate
    `xor` ecx, ecx
    label integ
    cmp rcx, 5
    jge fwd("nextstep")
    mov rax, [st + rcx*8 + 80]
    add [st + rcx*8], rax
    mov rax, [st + rcx*8 + 120]
    add [st + rcx*8 + 40], rax
    add rcx, 1
    jmp bwd("integ")
    label nextstep
    sub left, 1
    jmp bwd("step")
    label done
    ret()
  a.finalize()

proc initState(): seq[int64] =
  result = newSeq[int64](4 * Bodies)
  for i in 0..<Bodies:
    result[i] = int64(i * 100 - 200) # x
    result[Bodies + i] = int64(i * 70 - 140) # y
    result[2 * Bodies + i] = int64(i - 2) # vx
    result[3 * Bodies + i] = int64(2 - i) # vy
  # break the i <-> 4-i antisymmetry so the checksum is nonzero
  result[0] = result[0] +% 7

proc stepRef(s: var seq[int64]) =
  for i in 0..<Bodies:
    for j in i + 1..<Bodies:
      let dx = s[j] -% s[i]
      s[2 * Bodies + i] = s[2 * Bodies + i] +% dx
      s[2 * Bodies + j] = s[2 * Bodies + j] -% dx
      let dy = s[Bodies + j] -% s[Bodies + i]
      s[3 * Bodies + i] = s[3 * Bodies + i] +% dy
      s[3 * Bodies + j] = s[3 * Bodies + j] -% dy
  for i in 0..<Bodies:
    s[i] = s[i] +% s[2 * Bodies + i]
    s[Bodies + i] = s[Bodies + i] +% s[3 * Bodies + i]

when isMainModule:
  const Steps = 5_000_000'i64
  var buf = buildNbody()
  let nbody = cast[NbodyFn](buf.ptrAt(AssemblyOffset(0)))
  # correctness on a short run
  var st = initState()
  var rf = initState()
  nbody(cast[pointer](addr st[0]), 1000)
  for _ in 0..<1000: stepRef(rf)
  assert st == rf, "mismatch after 1000 steps"
  # timed full run
  let iters = benchIters(1)
  for _ in 0..<iters:
    st = initState()
    nbody(cast[pointer](addr st[0]), Steps)
  var chk = 0'i64
  for v in st: chk = chk +% v
  var rf2 = initState()
  for _ in 0..<Steps div 1000:
    for _ in 0..<1000: stepRef(rf2)
  var chkRef = 0'i64
  for v in rf2: chkRef = chkRef +% v
  assert chk == chkRef
  echo "nbody(5 bodies, ", Steps, " steps) checksum ", chk,
    " x", iters, " iters"
  buf.destroy()
