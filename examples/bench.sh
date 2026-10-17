#!/usr/bin/env bash
# bench.sh — build the dynasm examples and run them.
#
# Usage (from the repo root):
#   ./examples/bench.sh                  # build + run all examples (release builds)
#   ./examples/bench.sh fib collatz       # run only the given examples
#   MODE=debug ./examples/bench.sh        # use debug builds instead of release
#   BENCH_ITERS=10 ./examples/bench.sh    # scale every example's hot loop
#   RESULTS=bench/custom ./examples/bench.sh  # change log directory
#
# Each example binary assembles its JIT function (timed), verifies it once
# against a native Nim reference, then hammers the hot call BENCH_ITERS
# times (env override, per-example default) while stamping std/monotimes
# wall time and std/times cpuTime around the loop. The binaries therefore
# self-report spawn-free per-call throughput; this script just builds
# them and runs them, saving each binary's output to a log file.
#
# On AArch64 hosts (or with BUILD_ONLY=1) the examples only build: they
# emit x86-64 machine code, which cannot execute there. The script still
# exits 0 and prints a build-status table instead of timings.

set -euo pipefail

cd "$(dirname "$0")/.."

case "$(uname -m)" in
  x86_64|amd64) CAN_RUN=1 ;;
  *) CAN_RUN=0 ;;
esac

EXAMPLES=(fib loop_sum collatz primes mandel sieve bubble_sort nested_loops
  tail_recursive array_sum gcd dot_product nbody matmul saxpy histogram
  histogram_big fannkuch queens heapsort heapsort_big strings nbody_float)
MODE="${MODE:-release}"
OUT="${OUT:-bin}"
RESULTS="${RESULTS:-bench/results}"

if [ "$#" -gt 0 ]; then
  EXAMPLES=("$@")
fi

BUILD_FLAGS=()
if [ "$MODE" = "release" ]; then
  BUILD_FLAGS+=(--release)
elif [ "$MODE" != "debug" ]; then
  echo "error: MODE must be 'release' or 'debug', got '$MODE'" >&2
  exit 1
fi

mkdir -p "$OUT" "$RESULTS"

# Builder: clue when available, else plain nim (e.g. ARM runners with
# no clue binary). Examples import only dynasm + sibling benchutil,
# so --path:src suffices for the fallback.
build_one() {
  if command -v clue >/dev/null 2>&1; then
    clue build "examples/$1.nim" "${BUILD_FLAGS[@]}" --out:"$OUT/$1" >/dev/null
  else
    nim c "${BUILD_FLAGS[@]}" --path:src --out:"$OUT/$1" "examples/$1.nim" >/dev/null
  fi
}

echo "==> building ${#EXAMPLES[@]} example(s) [mode=$MODE]"
for ex in "${EXAMPLES[@]}"; do
  if [ ! -f "examples/$ex.nim" ]; then
    echo "error: unknown example '$ex' (no examples/$ex.nim)" >&2
    exit 1
  fi
  echo "  - $ex"
  build_one "$ex"
done

if [ "$CAN_RUN" = "0" ] || [ "${BUILD_ONLY:-0}" = "1" ]; then
  # x86-64 code cannot execute here; report build status only.
  TABLE="| example | build |
|---|---|---|"
  for ex in "${EXAMPLES[@]}"; do
    TABLE="$TABLE
| $ex | ok |"
  done
  echo "$TABLE" | tee "$RESULTS/SUMMARY.md"
  echo "==> build-only (host is $(uname -m)): binaries in $OUT/, no timings"
  exit 0
fi

echo "==> running [BENCH_ITERS=${BENCH_ITERS:-<per-example default>}]"
for ex in "${EXAMPLES[@]}"; do
  echo "  - $ex"
  "$OUT/$ex" | tee "$RESULTS/$ex.log"
done

# Collect each binary's self-reported numbers into a Markdown table.
TABLE="| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|"
for ex in "${EXAMPLES[@]}"; do
  log="$RESULTS/$ex.log"
  asm="$(grep -m1 '^assembled ' "$log" || true)"
  bytes="$(echo "$asm" | awk '{print $2}')"
  asmtime="$(echo "$asm" | awk '{print $5, $6}')"
  line="$(tail -n 1 "$log")"
  # Split at the trailing "<wall> wall, <cpu> cpu, <per>/call" suffix;
  # result details may themselves contain colons (e.g. sieve).
  timing="$(echo "$line" | sed 's/^.*: \([0-9.]* [a-z]* wall, .*\/call\)$/\1/')"
  wall="${timing%% wall,*}"
  rest="${timing#*, }"
  cpu="${rest%% cpu,*}"
  per="${rest##*, }"
  TABLE="$TABLE
| $ex | $bytes | $asmtime | $wall | $cpu | $per |"
done

echo "$TABLE" | tee "$RESULTS/SUMMARY.md"

echo "==> logs in $RESULTS/ (.log per example + SUMMARY.md)"
