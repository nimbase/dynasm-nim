# benchutil — shared harness for the dynasm examples.
#
# Each example runs its JIT function once for correctness, then repeats
# the hot call BENCH_ITERS times (env override) accumulating a checksum
# so the steady-state JIT throughput is measured instead of process
# startup. The checksum is asserted against the native reference to
# keep the optimizer honest.
#
# Mutating kernels (sorts, sieve) pre-stage one fresh input per timed
# call before stamping t0/c0, so the hot loop holds only JIT calls plus
# an O(1) liveness witness; full verification runs after the loop.
# benchReport's third argument is the total number of JIT calls timed
# (iters * callsPerIter for batched loops), so "ns/call" is per call.
#
# Timing uses std/monotimes (monotonic wall clock) plus std/times
# cpuTime (CPU seconds consumed). Both are re-exported so examples can
# stamp t0/c0 around their hot loops with no extra imports; pass the
# deltas to benchReport for a one-line summary.

import std/os
import std/strutils
import std/monotimes
import std/times
import std/strformat

export monotimes
export times

proc benchIters*(defaultIters: int): int =
  let s = getEnv("BENCH_ITERS", "")
  if s.len == 0:
    return defaultIters
  try:
    let v = parseInt(s)
    if v > 0: v else: defaultIters
  except ValueError:
    defaultIters

proc shortDur*(d: Duration): string =
  ## Compact duration: "12.45 ms" instead of Duration's long `$`.
  let ns = d.inNanoseconds
  if ns < 1_000: $ns & " ns"
  elif ns < 1_000_000: fmt"{float64(ns) / 1000.0:.2f} us"
  elif ns < 1_000_000_000: fmt"{float64(ns) / 1_000_000.0:.2f} ms"
  else: fmt"{float64(ns) / 1_000_000_000.0:.3f} s"

proc benchReport*(wall: Duration, cpuSecs: float, iters: int): string =
  ## One-line hot-loop summary, e.g.
  ## "11.83 ms wall, 9.210s cpu, 23.7 ns/call".
  ## iters is the total number of JIT calls timed (for batched loops
  ## pass iters * callsPerIter) so the per-call figure is per call.
  let ns =
    if iters > 0: float64(wall.inNanoseconds) / float64(iters)
    else: 0.0
  let per =
    if ns < 1000.0: fmt"{ns:.1f} ns/call"
    elif ns < 1_000_000.0: fmt"{ns / 1000.0:.2f} us/call"
    else: fmt"{ns / 1_000_000.0:.3f} ms/call"
  shortDur(wall) & " wall, " & fmt"{cpuSecs:.3f}s cpu, " & per
