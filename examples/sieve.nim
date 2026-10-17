# sieve — Sieve of Eratosthenes inner marking in JIT code.
#
# Run with:
#   nim r examples/sieve.nim
#
# JIT signature (SysV AMD64): sieve(buf: ptr byte, n: int64).
# The buffer holds one flag byte per number; the JIT fills it with 1,
# clears 0 and 1, then clears every multiple of each prime. Memory
# operands use the `[base + index*scale]` form (an index always needs
# an explicit scale, even `*1`).

import dynasm
import benchutil

type SieveFn = proc(buf: pointer, n: int64) {.cdecl.}

proc buildSieve(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
    alias buf, rdi, rcx
    alias n, rsi, rdx
    # fill buf[0..n) with 1 (i/j in R10/R11: scratch on both ABIs)
    `xor` r10d, r10d
    label fill
    cmp r10, n
    jge fwd("start")
    mov byte [buf + r10*1], 1
    add r10, 1
    jmp bwd("fill")
    label start
    cmp n, 0
    jle fwd("done")
    mov byte [buf], 0
    cmp n, 1
    jle fwd("done")
    mov byte [buf + 1], 0
    mov r10, 2
    label outer
    # if r10*r10 >= n, we are done
    mov rax, r10
    imul rax, r10
    cmp rax, n
    jge fwd("done")
    # skip composites
    movzx eax, byte [buf + r10*1]
    cmp eax, 0
    je fwd("next")
    # mark j = 2*r10, 3*r10, ... as 0
    mov r11, r10
    add r11, r10
    label mark
    cmp r11, n
    jge fwd("next")
    mov byte [buf + r11*1], 0
    add r11, r10
    jmp bwd("mark")
    label next
    add r10, 1
    jmp bwd("outer")
    label done
    ret()
  a.finalize()

proc sieveRef(n: int): seq[bool] =
  result = newSeq[bool](n) # all false; 0 and 1 stay non-prime
  if n <= 2: return
  for i in 2..<n: result[i] = true
  var p = 2
  while p * p < n:
    if result[p]:
      var j = 2 * p
      while j < n:
        result[j] = false
        j += p
    inc p

when isMainModule:
  const N = 100
  let bt0 = getMonoTime()
  var buf = buildSieve()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let sieve = cast[SieveFn](buf.ptrAt(AssemblyOffset(0)))
  # NOTE: use uint8, not byte — dynasm exports size-marker procs
  # named byte/word/dword/qword that shadow the builtin type.
  var flags = newSeq[uint8](N)
  for i in 0..<N: flags[i] = 0'u8
  sieve(cast[pointer](addr flags[0]), int64(N))
  let expected = sieveRef(N)
  for i in 0..<N:
    assert (flags[i] != 0) == expected[i], "mismatch at " & $i
  var count = 0
  for f in flags:
    if f != 0: inc count
  assert count == 25
  # The JIT fill loop rewrites every flag itself, so no reset is needed:
  # the timed loop below holds only pure sieve calls plus one O(1)
  # liveness witness per call. Full verification runs after the loop.
  let iters = benchIters(50_000)
  var acc = 0
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    sieve(cast[pointer](addr flags[0]), int64(N))
    acc += int(flags[2]) # 2 is prime; keeps every call live
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == iters
  for i in 0..<N:
    assert (flags[i] != 0) == expected[i], "mismatch at " & $i
  echo "primes below 100: ", count, " x", iters, " pure-JIT calls: ", rep
  buf.destroy()
