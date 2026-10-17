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

proc buildIsPrime*(): ExecutableBuffer =
  when defined(arm64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slot (AAPCS64: X0). `udiv` + `msub` replace the
      # x64 `div` (quotient discarded, remainder tested directly).
      alias n, x0
      mov x9, n
      cmp x9, 2
      b.lt fwd("no")
      b.eq fwd("yes")
      # even numbers > 2 are composite
      tbz x9, 0, fwd("no")
      mov x10, 3 # d
      label loop
      # if d*d > n, n is prime
      mul x11, x10, x10
      cmp x11, x9
      b.gt fwd("yes")
      # rem = n - (n/d)*d
      udiv x11, x9, x10
      msub x11, x11, x10, x9
      cbz x11, fwd("no")
      add x10, x10, 2
      b bwd("loop")
      label yes
      mov x0, 1
      ret()
      label no
      mov x0, xzr
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # Args: first slot (System V: RDI / Win64: RCX).
      alias n, rdi, rcx
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
