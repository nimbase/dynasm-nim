# nbody_float — float64 n-body with an inlined inner loop on x64.
#
# Run with:
#   nim r examples/nbody_float.nim
#
# The x64 kernel JITs the whole step/pair nest with scalar SSE2
# (movsd/addsd/mulsd/divsd/sqrtsd); gravity softening (1e-6) and the
# 0.1 factor live in a constant pool after the trailing ret,
# addressed RIP-relative. With no calls there is no shadow space and
# no stack slot (the inner counter J stays in R14); loop state lives
# in callee-saved registers pushed once at entry. The AArch64 kernel
# instead owns the loop nest and calls Nim {.cdecl.} callbacks per
# pair/step (`blr`), with X19-X22 plus LR saved in a 48 byte frame.

import dynasm
import benchutil
import std/math

const
  Bodies = 5
  Stride = 4 # x, y, vx, vy doubles per body

type
  InteractFn = proc(bodies: pointer, i, j: int64) {.cdecl.}
  IntegrateFn = proc(bodies: pointer) {.cdecl.}
  NbodyFloatFn = proc(bodies: pointer, steps: int64, interact,
    integrate: pointer) {.cdecl.}

proc buildNbodyFloat*(): ExecutableBuffer =
  when defined(arm64) or defined(aarch64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # AAPCS64: args arrive in X0-X3 and indirect calls go through
      # `blr` with no shadow space. Loop state that must survive the
      # callbacks lives in callee-saved X19-X23 (saved once at entry
      # with LR); the inner counter J lives in a stack slot. The 64
      # byte frame keeps SP 16-byte aligned at every `blr`.
      sub sp, sp, 64
      str x19, [sp]
      str x20, [sp, 8]
      str x21, [sp, 16]
      str x22, [sp, 24]
      str x23, [sp, 32]
      str x30, [sp, 40]
      mov x19, x0 # bodies
      mov x20, x1 # steps left
      mov x21, x2 # interact fn
      mov x22, x3 # integrate fn
      label step
      cbz x20, fwd("done")
      mov x23, xzr # i = 0
      label outer
      cmp x23, 5
      b.ge fwd("integrate")
      add x10, x23, 1
      str x10, [sp, 48] # j = i+1
      label inner
      ldr x10, [sp, 48]
      cmp x10, 5
      b.ge fwd("nexti")
      mov x0, x19
      mov x1, x23
      mov x2, x10
      blr x21
      ldr x10, [sp, 48]
      add x10, x10, 1
      str x10, [sp, 48]
      b bwd("inner")
      label nexti
      add x23, x23, 1
      b bwd("outer")
      label integrate
      mov x0, x19
      blr x22
      sub x20, x20, 1
      b bwd("step")
      label done
      ldr x19, [sp]
      ldr x20, [sp, 8]
      ldr x21, [sp, 16]
      ldr x22, [sp, 24]
      ldr x23, [sp, 32]
      ldr x30, [sp, 40]
      add sp, sp, 64
      ret()
    a.finalize()
  else:
    # x64 scalar-SSE2 kernel: the whole nest is inlined (no callbacks).
    # Bodies hold 5 x (x, y, vx, vy) doubles, 32 bytes per body.
    # Softening (1e-6) and gravity (0.1) live in a constant pool after
    # the trailing ret, addressed RIP-relative. One block covers both
    # ABIs via alias (System V: RDI/RSI, Win64: RCX/RDX); with no
    # calls there is no shadow space and no stack slot (j stays in R14).
    # Scratch GPRs (RAX/RCX/RDX) and XMM0-4 are volatile on both ABIs;
    # loop state lives in callee-saved RBX/R12-R15 (pushed at entry).
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      alias bodies, rdi, rcx
      alias steps, rsi, rdx
      push rbx
      push r12
      push r13
      push r14
      push r15
      mov rbx, bodies
      mov r12, steps
      label step
      cmp r12, 0
      je fwd("done")
      `xor` r13, r13 # i = 0
      label outer
      cmp r13, 5
      jge fwd("integrate")
      mov r14, r13
      add r14, 1 # j = i+1
      label inner
      cmp r14, 5
      jge fwd("nexti")
      # interact pair (i in R13, j in R14); byte offsets in RAX/RDX.
      mov rax, r13
      `shl` rax, 5
      mov rdx, r14
      `shl` rdx, 5
      movsd xmm0, [rbx + rdx*1]
      subsd xmm0, [rbx + rax*1] # dx
      movsd xmm1, [rbx + rdx*1 + 8]
      subsd xmm1, [rbx + rax*1 + 8] # dy
      movsd xmm2, xmm0
      mulsd xmm2, xmm2 # dx*dx
      movsd xmm3, xmm1
      mulsd xmm3, xmm3 # dy*dy
      addsd xmm2, xmm3
      addsd xmm2, [glob("eps")] # +1e-6
      sqrtsd xmm2, xmm2 # r
      movsd xmm3, xmm2
      mulsd xmm2, xmm2 # r*r
      mulsd xmm2, xmm3 # r*r*r
      movsd xmm3, [glob("grav")] # 0.1
      divsd xmm3, xmm2 # f
      movsd xmm2, xmm3
      mulsd xmm2, xmm0 # f*dx
      movsd xmm4, [rbx + rax*1 + 16]
      addsd xmm4, xmm2
      movsd [rbx + rax*1 + 16], xmm4 # b[i].vx +=
      movsd xmm4, [rbx + rdx*1 + 16]
      subsd xmm4, xmm2
      movsd [rbx + rdx*1 + 16], xmm4 # b[j].vx -=
      mulsd xmm3, xmm1 # f*dy
      movsd xmm4, [rbx + rax*1 + 24]
      addsd xmm4, xmm3
      movsd [rbx + rax*1 + 24], xmm4 # b[i].vy +=
      movsd xmm4, [rbx + rdx*1 + 24]
      subsd xmm4, xmm3
      movsd [rbx + rdx*1 + 24], xmm4 # b[j].vy -=
      add r14, 1
      jmp bwd("inner")
      label nexti
      add r13, 1
      jmp bwd("outer")
      label integrate
      `xor` r13, r13 # k = 0
      label iloop
      cmp r13, 5
      jge fwd("inext")
      mov rax, r13
      `shl` rax, 5
      movsd xmm0, [rbx + rax*1]
      addsd xmm0, [rbx + rax*1 + 16] # x += vx
      movsd [rbx + rax*1], xmm0
      movsd xmm0, [rbx + rax*1 + 8]
      addsd xmm0, [rbx + rax*1 + 24] # y += vy
      movsd [rbx + rax*1 + 8], xmm0
      add r13, 1
      jmp bwd("iloop")
      label inext
      sub r12, 1
      jmp bwd("step")
      label done
      pop r15
      pop r14
      pop r13
      pop r12
      pop rbx
      ret()
      global eps
      f64 1e-6
      global grav
      f64 0.1
    a.finalize()

proc interact(bodies: pointer, i, j: int64) {.cdecl.} =
  let b = cast[ptr UncheckedArray[float64]](bodies)
  let dx = b[j * Stride] - b[i * Stride]
  let dy = b[j * Stride + 1] - b[i * Stride + 1]
  let r = sqrt(dx * dx + dy * dy + 1e-6)
  let f = 0.1 / (r * r * r)
  b[i * Stride + 2] += f * dx
  b[j * Stride + 2] -= f * dx
  b[i * Stride + 3] += f * dy
  b[j * Stride + 3] -= f * dy

proc integrate(bodies: pointer) {.cdecl.} =
  let b = cast[ptr UncheckedArray[float64]](bodies)
  for k in 0..<Bodies:
    b[k * Stride] += b[k * Stride + 2]
    b[k * Stride + 1] += b[k * Stride + 3]

proc initBodies(): seq[float64] =
  result = newSeq[float64](Bodies * Stride)
  for i in 0..<Bodies:
    result[i * Stride] = float64(i * 100 - 200) * 0.01
    result[i * Stride + 1] = float64(i * 70 - 140) * 0.01
    result[i * Stride + 2] = float64(i - 2) * 0.1
    result[i * Stride + 3] = float64(2 - i) * 0.1

proc runRef(s: var seq[float64], steps: int) =
  let p = cast[pointer](addr s[0])
  for _ in 0..<steps:
    for i in 0..<Bodies:
      for j in i + 1..<Bodies:
        interact(p, int64(i), int64(j))
    integrate(p)

when isMainModule:
  const Steps = 200_000'i64
  var interactP: InteractFn = interact
  var integrateP: IntegrateFn = integrate
  let bt0 = getMonoTime()
  var buf = buildNbodyFloat()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let nbodyf = cast[NbodyFloatFn](buf.ptrAt(AssemblyOffset(0)))
  # correctness on a short run
  var st = initBodies()
  var rf = initBodies()
  nbodyf(cast[pointer](addr st[0]), 500, cast[pointer](interactP),
    cast[pointer](integrateP))
  runRef(rf, 500)
  assert st == rf, "mismatch after 500 steps"
  let iters = benchIters(3)
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    st = initBodies()
    nbodyf(cast[pointer](addr st[0]), Steps,
      cast[pointer](interactP), cast[pointer](integrateP))
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  var chk = 0.0
  for v in st: chk += v
  rf = initBodies()
  runRef(rf, int(Steps))
  var chkRef = 0.0
  for v in rf: chkRef += v
  assert chk == chkRef
  echo "nbody_float(5 bodies, ", Steps, " steps) checksum ", chk,
    " x", iters, " iters: ", rep
  buf.destroy()
