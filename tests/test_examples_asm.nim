import unittest
import dynasm
import fib
import loop_sum
import collatz
import primes
import mandel
import sieve
import bubble_sort
import nested_loops
import tail_recursive
import array_sum
import gcd
import dot_product
import nbody
import matmul
import saxpy
import histogram as histSmall
import histogram_big as histBig
import fannkuch
import queens
import heapsort as hsortSmall
import heapsort_big as hsortBig
import strings
import nbody_float

# Assemble-only validation for every bench example.
#
# Each build proc only emits machine code into an ExecutableBuffer;
# execution happens in the examples' `when isMainModule` blocks, which
# do not run on import. This test therefore exercises the real
# encoder + relocation paths for the host's native branch (x64 blocks
# on x86-64, AArch64 blocks on ARM) with zero execution, so it is
# safe on any runner.
#
# On AArch64 the assembled size is asserted byte-exact: there is a
# single calling convention (AAPCS64), so the goldens hold on every
# OS. x64 sizes differ per ABI (Win64 shadow space, arg registers),
# so those only assert non-empty. The cross-arch branch is covered by
# compiling this file with `--cpu:arm64` (validates the AArch64
# blocks' macro expansion + static checks on x86-64 hosts) or with
# `-d:arm64` + `-r` (assembles the AArch64 blocks without executing).
#
# NOTE: keep the example list in sync with examples/bench.sh.

proc armGolden(name: string): int =
  ## Expected AArch64 buffer size per example (4 bytes per instruction).
  case name
  of "fib": 60
  of "loop_sum": 36
  of "collatz": 60
  of "primes": 72
  of "mandel": 92
  of "sieve": 128
  of "bubble_sort": 72
  of "nested_loops": 60
  of "tail_recursive": 40
  of "array_sum": 40
  of "gcd": 32
  of "dot_product": 48
  of "nbody": 204
  of "matmul": 116
  of "saxpy": 44
  of "histogram": 52
  of "histogram_big": 52
  of "fannkuch": 228
  of "queens": 176
  of "heapsort": 188
  of "heapsort_big": 188
  of "strings": 192
  of "nbody_float": 168
  else: -1

proc checkAsm(name: string, b: var ExecutableBuffer) =
  when defined(arm64) or defined(aarch64):
    check b.len == armGolden(name)
  else:
    check b.len > 0
  b.destroy()

test "examples assemble: fib/loop_sum/collatz/primes":
  var b = buildFib()
  checkAsm("fib", b)
  b = buildSum()
  checkAsm("loop_sum", b)
  b = buildSteps()
  checkAsm("collatz", b)
  b = buildIsPrime()
  checkAsm("primes", b)

test "examples assemble: mandel/sieve/bubble_sort/nested_loops":
  var b = buildMandel()
  checkAsm("mandel", b)
  b = buildSieve()
  checkAsm("sieve", b)
  b = buildBsort()
  checkAsm("bubble_sort", b)
  b = buildNested()
  checkAsm("nested_loops", b)

test "examples assemble: tail_recursive/array_sum/gcd/dot_product":
  var b = buildFact()
  checkAsm("tail_recursive", b)
  b = buildAsum()
  checkAsm("array_sum", b)
  b = buildGcd()
  checkAsm("gcd", b)
  b = buildDot()
  checkAsm("dot_product", b)

test "examples assemble: nbody/matmul/saxpy/histogram":
  var b = buildNbody()
  checkAsm("nbody", b)
  b = buildMatmul()
  checkAsm("matmul", b)
  b = buildSaxpy()
  checkAsm("saxpy", b)
  b = histSmall.buildHist()
  checkAsm("histogram", b)
  b = histBig.buildHist()
  checkAsm("histogram_big", b)

test "examples assemble: fannkuch/queens/heapsort/strings/nbody_float":
  var b = buildFannkuch()
  checkAsm("fannkuch", b)
  b = buildQueens()
  checkAsm("queens", b)
  b = hsortSmall.buildHsort()
  checkAsm("heapsort", b)
  b = hsortBig.buildHsort()
  checkAsm("heapsort_big", b)
  var parts = buildStrings()
  checkAsm("strings", parts.buf)
  b = buildNbodyFloat()
  checkAsm("nbody_float", b)
