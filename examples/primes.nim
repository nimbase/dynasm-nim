# primes — JIT trial-division primality test with `div`.
#
# Run with:
#   nim r examples/primes.nim
#
# JIT signature (SysV AMD64): isPrime(n: int64): int64 (1 or 0).
# Uses 64-bit `div` (dividend in RDX:RAX, quotient in RAX,
# remainder in RDX) plus `imul` for the d*d bound. `div` and `xor`
# are Nim keywords, hence the backticks.

import dynasm
import benchutil

type IsPrimeFn = proc(n: int64): int64 {.cdecl.}

proc buildIsPrime(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: first arg arrives in RDI (use RCX on Windows x64).
    alias n, rdi
    mov r8, n
    cmp r8, 2
    jl fwd("no")
    je fwd("yes")
    # even numbers > 2 are composite
    mov rax, r8
    `and` rax, 1
    cmp rax, 0
    je fwd("no")
    mov r10, 3
    label loop
    # if r10*r10 > n, n is prime
    mov rax, r10
    imul rax, r10
    cmp rax, r8
    jg fwd("yes")
    # rdx:rax / r10, remainder lands in rdx
    mov rax, r8
    `xor` rdx, rdx
    `div` r10
    cmp rdx, 0
    je fwd("no")
    add r10, 2
    jmp bwd("loop")
    label yes
    mov eax, 1
    ret()
    label no
    `xor` eax, eax
    ret()
  a.finalize()

proc isPrimeRef(n: int64): bool =
  if n < 2: return false
  if n == 2: return true
  if n mod 2 == 0: return false
  var d = 3'i64
  while d * d <= n:
    if n mod d == 0: return false
    d += 2
  true

when isMainModule:
  let bt0 = getMonoTime()
  var buf = buildIsPrime()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let isPrime = cast[IsPrimeFn](buf.ptrAt(AssemblyOffset(0)))
  var count = 0
  for n in 0'i64..99'i64:
    let jit = isPrime(n) == 1
    assert jit == isPrimeRef(n), "mismatch at " & $n
    if jit: inc count
  assert count == 25
  let iters = benchIters(60_000)
  var acc = 0
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    for n in 0'i64..99'i64:
      acc += int(isPrime(n))
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  assert acc == 25 * iters
  echo "primes below 100: ", count, " x", iters, " iters: ", rep # 25
  buf.destroy()
