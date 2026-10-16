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
    # SysV: args arrive in RDI, RSI (use RCX, RDX on Windows x64).
    alias buf, rdi
    alias n, rsi
    # fill buf[0..n) with 1
    `xor` ecx, ecx
    label fill
    cmp rcx, n
    jge fwd("start")
    mov byte [buf + rcx*1], 1
    add rcx, 1
    jmp bwd("fill")
    label start
    cmp n, 0
    jle fwd("done")
    mov byte [buf], 0
    cmp n, 1
    jle fwd("done")
    mov byte [buf + 1], 0
    mov rcx, 2
    label outer
    # if rcx*rcx >= n, we are done
    mov rax, rcx
    imul rax, rcx
    cmp rax, n
    jge fwd("done")
    # skip composites
    movzx eax, byte [buf + rcx*1]
    cmp eax, 0
    je fwd("next")
    # mark j = 2*rcx, 3*rcx, ... as 0
    mov rdx, rcx
    add rdx, rcx
    label mark
    cmp rdx, n
    jge fwd("next")
    mov byte [buf + rdx*1], 0
    add rdx, rcx
    jmp bwd("mark")
    label next
    add rcx, 1
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
  var buf = buildSieve()
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
  let iters = benchIters(50_000)
  var acc = 0
  for _ in 0..<iters:
    for i in 0..<N: flags[i] = 1'u8
    sieve(cast[pointer](addr flags[0]), int64(N))
    for f in flags:
      if f != 0: inc acc
  assert acc == 25 * iters
  echo "primes below 100: ", count, " x", iters, " iters" # via sieve
  buf.destroy()
