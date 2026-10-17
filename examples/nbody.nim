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

proc buildNbody*(): ExecutableBuffer =
  when defined(arm64) or defined(aarch64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slots (AAPCS64: X0, X1). AArch64 has no
      # base+index*scale+displacement form, so each pair address is
      # materialized (lsl + add) and the lane offset (+0/+40/+80/+120)
      # rides as the unsigned immediate instead.
      alias st, x0
      alias left, x1
      label step
      cbz left, fwd("done")
      mov x9, xzr # i
      label outer
      cmp x9, 5
      b.ge fwd("integrate")
      add x10, x9, 1 # j = i+1
      label inner
      cmp x10, 5
      b.ge fwd("nexti")
      # dx = x[j]-x[i]; vx[i] += dx; vx[j] -= dx
      lsl x12, x10, 3
      add x12, st, x12 # &x[j]
      lsl x13, x9, 3
      add x13, st, x13 # &x[i]
      ldr x11, [x12]
      ldr x14, [x13]
      sub x11, x11, x14 # dx
      ldr x14, [x13, 80]
      add x14, x14, x11
      str x14, [x13, 80]
      ldr x14, [x12, 80]
      sub x14, x14, x11
      str x14, [x12, 80]
      # dy = y[j]-y[i]; vy[i] += dy; vy[j] -= dy
      ldr x11, [x12, 40]
      ldr x14, [x13, 40]
      sub x11, x11, x14 # dy
      ldr x14, [x13, 120]
      add x14, x14, x11
      str x14, [x13, 120]
      ldr x14, [x12, 120]
      sub x14, x14, x11
      str x14, [x12, 120]
      add x10, x10, 1
      b bwd("inner")
      label nexti
      add x9, x9, 1
      b bwd("outer")
      label integrate
      mov x9, xzr
      label integ
      cmp x9, 5
      b.ge fwd("nextstep")
      lsl x12, x9, 3
      add x12, st, x12 # &body[i]
      ldr x11, [x12, 80]
      ldr x14, [x12]
      add x14, x14, x11
      str x14, [x12]
      ldr x11, [x12, 120]
      ldr x14, [x12, 40]
      add x14, x14, x11
      str x14, [x12, 40]
      add x9, x9, 1
      b bwd("integ")
      label nextstep
      sub left, left, 1
      b bwd("step")
      label done
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
      alias st, rdi, rcx
      alias left, rsi, rdx
      label step
      cmp left, 0
      je fwd("done")
      `xor` r10d, r10d # i (r10: scratch on both ABIs)
      label outer
      cmp r10, 5
      jge fwd("integrate")
      mov r11, r10
      add r11, 1 # j = i+1 (r11: scratch on both ABIs)
      label inner
      cmp r11, 5
      jge fwd("nexti")
      # dx = x[j]-x[i]; vx[i] += dx; vx[j] -= dx
      mov rax, [st + r11*8]
      sub rax, [st + r10*8]
      add [st + r10*8 + 80], rax
      sub [st + r11*8 + 80], rax
      # dy = y[j]-y[i]; vy[i] += dy; vy[j] -= dy
      mov rax, [st + r11*8 + 40]
      sub rax, [st + r10*8 + 40]
      add [st + r10*8 + 120], rax
      sub [st + r11*8 + 120], rax
      add r11, 1
      jmp bwd("inner")
      label nexti
      add r10, 1
      jmp bwd("outer")
      label integrate
      `xor` r10d, r10d
      label integ
      cmp r10, 5
      jge fwd("nextstep")
      mov rax, [st + r10*8 + 80]
      add [st + r10*8], rax
      mov rax, [st + r10*8 + 120]
      add [st + r10*8 + 40], rax
      add r10, 1
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
  let bt0 = getMonoTime()
  var buf = buildNbody()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let nbody = cast[NbodyFn](buf.ptrAt(AssemblyOffset(0)))
  # correctness on a short run
  var st = initState()
  var rf = initState()
  nbody(cast[pointer](addr st[0]), 1000)
  for _ in 0..<1000: stepRef(rf)
  assert st == rf, "mismatch after 1000 steps"
  # timed full run
  let iters = benchIters(1)
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    st = initState()
    nbody(cast[pointer](addr st[0]), Steps)
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  var chk = 0'i64
  for v in st: chk = chk +% v
  var rf2 = initState()
  for _ in 0..<Steps div 1000:
    for _ in 0..<1000: stepRef(rf2)
  var chkRef = 0'i64
  for v in rf2: chkRef = chkRef +% v
  assert chk == chkRef
  echo "nbody(5 bodies, ", Steps, " steps) checksum ", chk,
    " x", iters, " iters: ", rep
  buf.destroy()
