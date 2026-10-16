# fannkuch — Fannkuch Redux permutation flips in JIT code.
#
# Run with:
#   nim r examples/fannkuch.nim
#
# JIT signature (SysV AMD64): fannkuch(perm, tmp, cnt: ptr int64,
# n: int64): int64. Enumerates all n! permutations with factorial-
# number-system rotations; flips are counted on a scratch copy so
# the enumeration order is undisturbed. N stays pinned in RCX while
# R8-R11 recycle as indices and swap temporaries (all caller-saved).
# Known answer: fannkuch(10) = 38.

import dynasm
import benchutil

type FannkuchFn = proc(perm, tmp, cnt: pointer, n: int64): int64 {.cdecl.}

const N = 10

proc buildFannkuch(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI, RDX, RCX.
    alias perm, rdi
    alias tmp, rsi
    alias cnt, rdx
    alias n, rcx
    # maxFlip lives in callee-saved R12 (R9 doubles as swap temp).
    # NOTE: zero it before the init loop — anything between the
    # loop's exit jump and its target label would be skipped.
    push r12
    `xor` r12, r12 # maxFlip = 0 (init below only touches RAX)
    # init perm[i] = i, cnt[i] = 0
    `xor` eax, eax
    label init
    cmp rax, n
    jge fwd("mainloop")
    mov [perm + rax*8], rax
    mov qword [cnt + rax*8], 0
    add rax, 1
    jmp bwd("init")
    label mainloop
    # copy perm -> tmp
    `xor` eax, eax
    label copy
    cmp rax, n
    jge fwd("flipstart")
    mov r8, [perm + rax*8]
    mov [tmp + rax*8], r8
    add rax, 1
    jmp bwd("copy")
    label flipstart
    `xor` r8, r8 # flips = 0
    label fliploop
    mov rax, [tmp] # first = tmp[0]
    cmp rax, 0
    je fwd("flipdone")
    `xor` r11, r11 # i = 0
    mov r10, rax # j = first
    label rev
    cmp r11, r10
    jge fwd("revend")
    mov rax, [tmp + r11*8]
    mov r9, [tmp + r10*8]
    mov [tmp + r11*8], r9
    mov [tmp + r10*8], rax
    add r11, 1
    sub r10, 1
    jmp bwd("rev")
    label revend
    add r8, 1
    jmp bwd("fliploop")
    label flipdone
    cmp r8, r12
    jle fwd("skipmax")
    mov r12, r8
    label skipmax
    mov r10, 1 # r = 1
    label nextperm
    cmp r10, n
    jge fwd("alldone")
    # rotate perm[0..r] left by one
    mov rax, [perm]
    `xor` r11, r11 # i = 0
    label rot
    cmp r11, r10
    jge fwd("rotend")
    mov r9, [perm + r11*8 + 8] # perm[i+1]
    mov [perm + r11*8], r9
    add r11, 1
    jmp bwd("rot")
    label rotend
    mov [perm + r10*8], rax
    mov rax, [cnt + r10*8]
    add rax, 1
    mov [cnt + r10*8], rax
    cmp rax, r10
    jle bwd("mainloop")
    mov qword [cnt + r10*8], 0
    add r10, 1
    jmp bwd("nextperm")
    label alldone
    mov rax, r12
    pop r12
    ret()
  a.finalize()

proc fannkuchRef(n: int): int =
  var perm = newSeq[int](n)
  for i in 0..<n: perm[i] = i
  var count = newSeq[int](n)
  var work = newSeq[int](n)
  var maxFlip = 0
  while true:
    for i in 0..<n: work[i] = perm[i]
    var flips = 0
    while work[0] != 0:
      let k = work[0]
      var i = 0
      var j = k
      while i < j:
        swap(work[i], work[j])
        inc i
        dec j
      inc flips
    maxFlip = max(maxFlip, flips)
    var r = 1
    while r < n:
      let tmp = perm[0]
      for i in 0..<r: perm[i] = perm[i + 1]
      perm[r] = tmp
      count[r] += 1
      if count[r] <= r: break
      count[r] = 0
      inc r
    if r == n: break
  maxFlip

proc runJit(fannkuch: FannkuchFn, n: int): int64 =
  var perm = newSeq[int64](n)
  var tmp = newSeq[int64](n)
  var cnt = newSeq[int64](n)
  fannkuch(cast[pointer](addr perm[0]), cast[pointer](addr tmp[0]),
    cast[pointer](addr cnt[0]), int64(n))

when isMainModule:
  assert fannkuchRef(N) == 38
  let bt0 = getMonoTime()
  var buf = buildFannkuch()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let fannkuch = cast[FannkuchFn](buf.ptrAt(AssemblyOffset(0)))
  assert runJit(fannkuch, N) == 38
  let iters = benchIters(2)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += runJit(fannkuch, N)
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == 38 * iters
  echo "fannkuch(10) = 38 x", iters, " iters: ", rep
  buf.destroy()
