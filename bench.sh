#!/usr/bin/env bash
# bench.sh — build the dynasm examples and benchmark them with hyperfine.
#
# Usage:
#   ./bench.sh                  # bench all examples (release builds)
#   ./bench.sh fib collatz       # bench only the given examples
#   MODE=debug ./bench.sh        # bench debug builds instead of release
#   RUNS=30 WARMUP=5 ./bench.sh  # tune hyperfine run counts
#   RESULTS=bench/custom ./bench.sh  # change export directory
#
# Each example binary assembles its JIT function, verifies it once against
# a native Nim reference, then hammers the hot call BENCH_ITERS times
# (env override, per-example default) with a checksum assert, so
# hyperfine measures steady-state JIT throughput instead of process
# startup. Results are exported as Markdown and JSON next to the binaries.

set -euo pipefail

cd "$(dirname "$0")"

EXAMPLES=(fib loop_sum collatz primes mandel sieve bubble_sort nested_loops
  tail_recursive array_sum gcd dot_product nbody matmul saxpy histogram
  histogram_big fannkuch queens heapsort heapsort_big strings nbody_float)
MODE="${MODE:-release}"
RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-3}"
OUT="${OUT:-bin}"
RESULTS="${RESULTS:-bench/results}"

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "error: hyperfine not found. Install it first:" >&2
  echo "  brew install hyperfine   # macOS" >&2
  echo "  cargo install hyperfine  # anywhere with Rust" >&2
  exit 1
fi

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

echo "==> building ${#EXAMPLES[@]} example(s) [mode=$MODE]"
for ex in "${EXAMPLES[@]}"; do
  if [ ! -f "examples/$ex.nim" ]; then
    echo "error: unknown example '$ex' (no examples/$ex.nim)" >&2
    exit 1
  fi
  echo "  - $ex"
  clue build "examples/$ex.nim" "${BUILD_FLAGS[@]}" --out:"$OUT/$ex" >/dev/null
done

echo "==> benchmarking [runs=$RUNS warmup=$WARMUP]"
for ex in "${EXAMPLES[@]}"; do
  echo "  - $ex"
  hyperfine \
    --shell=none \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    --export-markdown "$RESULTS/$ex.md" \
    --export-json "$RESULTS/$ex.json" \
    "$OUT/$ex"
done

echo "==> results in $RESULTS/ (.md + .json per example)"
