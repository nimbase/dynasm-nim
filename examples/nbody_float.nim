# nbody_float — float64 n-body with host callbacks in the loop.
#
# Run with:
#   nim r examples/nbody_float.nim
#
# The assembler has no SSE backend, so floating-point work stays in
# Nim: the JIT owns the step/pair loop nest and `call`s a Nim
# {.cdecl.} callback per body pair (gravity with sqrt) plus one
# integrate callback per step. Loop state that must survive calls
# lives in callee-saved registers (pushed once at entry); the inner
# counter J lives in a 16-byte stack slot. Five pushes plus the slot
# keep RSP 16-byte aligned at every `call`. On Win64 the callbacks
# additionally need 32 bytes of shadow space and RCX/RDX/R8 args,
# so the Windows block below mirrors the SysV one with that layout.

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

proc buildNbodyFloat(): ExecutableBuffer =
  var a = newAssembler(akX64)
  when defined(windows):
    dynasm a:
      arch x64
      # Win64: args arrive in RCX, RDX, R8, R9; callbacks take
      # RCX/RDX/R8 and require 32 bytes of shadow space above RSP.
      push rbx
      push r12
      push r13
      push r14
      push r15
      sub rsp, 16 # one 8-byte slot for J (+8 padding keeps alignment)
      sub rsp, 32 # shadow space for the callback calls
      mov rbx, rcx # bodies
      mov r12, rdx # steps left
      mov r13, r8 # interact fn
      mov r14, r9 # integrate fn
      label step
      cmp r12, 0
      je fwd("done")
      `xor` r15, r15 # i = 0
      label outer
      cmp r15, 5
      jge fwd("integrate")
      mov rax, r15
      add rax, 1
      mov [rsp + 32], rax # j = i+1 (past the shadow space)
      label inner
      mov rax, [rsp + 32]
      cmp rax, 5
      jge fwd("nexti")
      mov rcx, rbx
      mov rdx, r15
      mov r8, [rsp + 32]
      call r13
      mov rax, [rsp + 32]
      add rax, 1
      mov [rsp + 32], rax
      jmp bwd("inner")
      label nexti
      add r15, 1
      jmp bwd("outer")
      label integrate
      mov rcx, rbx
      call r14
      sub r12, 1
      jmp bwd("step")
      label done
      add rsp, 32
      add rsp, 16
      pop r15
      pop r14
      pop r13
      pop r12
      pop rbx
      ret()
  else:
    dynasm a:
      arch x64
      push rbx
      push r12
      push r13
      push r14
      push r15
      sub rsp, 16 # one 8-byte slot for J (+8 padding keeps alignment)
      mov rbx, rdi # bodies
      mov r12, rsi # steps left
      mov r13, rdx # interact fn
      mov r14, rcx # integrate fn
      label step
      cmp r12, 0
      je fwd("done")
      `xor` r15, r15 # i = 0
      label outer
      cmp r15, 5
      jge fwd("integrate")
      mov rax, r15
      add rax, 1
      mov [rsp], rax # j = i+1
      label inner
      mov rax, [rsp]
      cmp rax, 5
      jge fwd("nexti")
      mov rdi, rbx
      mov rsi, r15
      mov rdx, [rsp]
      call r13
      mov rax, [rsp]
      add rax, 1
      mov [rsp], rax
      jmp bwd("inner")
      label nexti
      add r15, 1
      jmp bwd("outer")
      label integrate
      mov rdi, rbx
      call r14
      sub r12, 1
      jmp bwd("step")
      label done
      add rsp, 16
      pop r15
      pop r14
      pop r13
      pop r12
      pop rbx
      ret()
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
