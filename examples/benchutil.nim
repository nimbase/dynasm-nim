# benchutil — shared harness for the dynasm examples.
#
# Each example runs its JIT function once for correctness, then repeats
# the hot call BENCH_ITERS times (env override) accumulating a checksum
# so hyperfine measures steady-state JIT throughput instead of process
# startup. The checksum is asserted against the native reference to
# keep the optimizer honest.

import std/os
import std/strutils

proc benchIters*(defaultIters: int): int =
  let s = getEnv("BENCH_ITERS", "")
  if s.len == 0:
    return defaultIters
  try:
    let v = parseInt(s)
    if v > 0: v else: defaultIters
  except ValueError:
    defaultIters
