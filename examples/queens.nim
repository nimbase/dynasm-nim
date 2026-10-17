# queens — 13-queens solver by backtracking in JIT code.
#
# Run with:
#   nim r examples/queens.nim
#
# JIT signature (SysV AMD64): queens(cols: ptr int64, n: int64): int64.
# cols[] holds the placed column per row (-1 = empty); the search
# resumes each row after its last-tried column, so backtracking needs
# no extra stack. Known answer: queens(13) = 73712.

import dynasm
import benchutil

type QueensFn = proc(cols: pointer, n: int64): int64 {.cdecl.}

const N = 13

proc buildQueens(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
    alias cols, rdi, rcx
    alias n, rsi, rdx
    # R12 (row) and R13 (t) are callee-saved on both ABIs: preserve.
    push r12
    push r13
    # cols[i] = -1; count = 0; row = 0
    `xor` r12d, r12d
    label init
    cmp r12, n
    jge fwd("search")
    mov qword [cols + r12*8], -1
    add r12, 1
    jmp bwd("init")
    label search
    `xor` r8, r8 # count
    `xor` r12d, r12d # row
    label trycol
    mov r9, [cols + r12*8] # col = last tried + 1
    add r9, 1
    label retest
    cmp r9, n
    jge fwd("backtrack")
    `xor` r10, r10 # r = 0
    label check
    cmp r10, r12
    jge fwd("place")
    mov rax, [cols + r10*8] # cols[r]
    mov r11, r9
    sub r11, rax # d = col - cols[r]
    je fwd("conflict")
    mov r13, r12
    sub r13, r10 # t = row - r (> 0)
    cmp r13, r11
    je fwd("conflict")
    neg r11 # -d
    cmp r13, r11
    je fwd("conflict")
    add r10, 1
    jmp bwd("check")
    label conflict
    add r9, 1
    jmp bwd("retest")
    label place
    mov [cols + r12*8], r9
    add r12, 1 # row++
    cmp r12, n
    jge fwd("found")
    jmp bwd("trycol")
    label found
    add r8, 1
    sub r12, 1 # step back, trycol resumes after cols[n-1]
    jmp bwd("trycol")
    label backtrack
    mov qword [cols + r12*8], -1
    cmp r12, 0
    je fwd("done")
    sub r12, 1
    jmp bwd("trycol")
    label done
    mov rax, r8
    pop r13
    pop r12
    ret()
  a.finalize()

proc queensRef(n: int): int =
  var cols = newSeq[int](n)
  for i in 0..<n: cols[i] = -1
  var count = 0
  var row = 0
  while true:
    var col = cols[row] + 1
    var placed = false
    while col < n:
      var ok = true
      for r in 0..<row:
        let d = col - cols[r]
        let t = row - r
        if d == 0 or t == d or t == -d:
          ok = false
          break
      if ok:
        placed = true
        break
      inc col
    if not placed:
      cols[row] = -1
      if row == 0: break
      dec row
    else:
      cols[row] = col
      inc row
      if row == n:
        inc count
        dec row
  count

when isMainModule:
  assert queensRef(N) == 73712
  let bt0 = getMonoTime()
  var buf = buildQueens()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let queens = cast[QueensFn](buf.ptrAt(AssemblyOffset(0)))
  var cols = newSeq[int64](N)
  let v = queens(cast[pointer](addr cols[0]), int64(N))
  assert v == 73712, "got " & $v
  let iters = benchIters(1)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc += queens(cast[pointer](addr cols[0]), int64(N))
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == 73712 * iters
  echo "queens(13) = ", v, " x", iters, " iters: ", rep
  buf.destroy()
