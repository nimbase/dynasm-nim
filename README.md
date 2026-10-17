<p align="center">
  dynasm &bullet; a dynamic assembler for Nim<br>
  inspired by DynASM from LuaJIT
</p>

<p align="center">
  <code>nimble install dynasm</code> / <code>clue install dynasm</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/dynasm-nim/">API reference</a><br>
  <img src="https://github.com/nimbase/dynasm-nim/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/dynasm-nim/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Features
- Pure-Nim dynamic assembler for x64, x86 and AArch64, no C preprocessor or external tools
- Macro DSL that lets you write assembly inline in Nim code (`arch x64` / `arch aarch64`)
- AArch64 SIMD/FP: scalar and vector floating-point, conversions, SIMD loads/stores
- Apple Silicon support: JIT execution via MAP_JIT with icache handling
- Labels, global symbols and relocations resolved at assembly time
- Strict compile-time validation with suggestions on typos
- Executable memory buffers you can call as plain function pointers
- Test suite runs everywhere with execution tests gated by host CPU
- Debug mode that dumps the generated machine code

### What's this?
This is a LLM-accelerated port of the DynASM from Rust/LuaJIT for Nim language. Basically, with this library you can dynamically JIT anything! VanCode is a good example how to integrate DynASM into a JIT compiler, [Check the emit_nim module](https://github.com/openpeeps/vancode/blob/main/src/vancode/interpreter/jit/emit_nim.nim). Contributions are welcome!

## Examples
- `examples/fib.nim` — recursive Fibonacci in JIT code
- `examples/sieve.nim` — Sieve of Eratosthenes inner marking loop
- `examples/heapsort.nim` — heapsort with an internal called sift-down
- `examples/nbody.nim` — integer N-body simulation stride loop

Run one with `clue build examples/fib.nim --release --out:/tmp/fib && /tmp/fib`,
or build and run all 23 with `./examples/bench.sh`, which prints a Markdown table of
per-call timings.

## Benchmarks

23 JIT examples (`examples/*.nim`), each self-verifying against a native
Nim reference before timing. Every binary reports assembled size/time,
then hammers its hot loop and prints wall/cpu/per-call throughput.
Generated with `./examples/bench.sh` (release builds); rerun per
platform from the `bench` workflow (push paths + manual dispatch with
mode/examples/iters inputs). Each example emits native code for its
host (`when defined(arm64) or defined(aarch64)` selects the AArch64
kernel, otherwise the x64 one — both spellings are needed since Nim
defines `aarch64`, not `arm64`, on Windows ARM), so every platform in
the matrix executes natively with no emulation. The x64 kernels run on System V and Win64 alike (argument
registers selected per ABI via `alias`); the AArch64 kernels follow
AAPCS64 on all three OSes.

### macOS x86-64 (macos-15-intel)

(`bench` run `39070459914`, all green.)

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 82.33 us | 23.62 ms | 0.024s | 47.2 ns/call |
| loop_sum | 42 | 98.59 us | 49.95 ms | 0.050s | 499.53 us/call |
| collatz | 80 | 109.88 us | 45.71 ms | 0.046s | 152.4 ns/call |
| primes | 99 | 135.17 us | 65.72 ms | 0.065s | 1.10 us/call |
| mandel | 106 | 95.14 us | 35.78 ms | 0.035s | 178.9 ns/call |
| sieve | 133 | 109.14 us | 4.76 ms | 0.005s | 95.1 ns/call |
| bubble_sort | 95 | 83.30 us | 8.62 ms | 0.009s | 718.7 ns/call |
| nested_loops | 59 | 102.51 us | 28.48 ms | 0.028s | 142.42 us/call |
| tail_recursive | 30 | 77.69 us | 8.35 ms | 0.008s | 20.9 ns/call |
| array_sum | 35 | 54.28 us | 22.47 ms | 0.022s | 44.93 us/call |
| gcd | 37 | 107.91 us | 17.60 ms | 0.018s | 22.0 ns/call |
| dot_product | 40 | 102.86 us | 17.22 ms | 0.017s | 8.61 us/call |
| nbody | 147 | 117.25 us | 177.56 ms | 0.178s | 177.558 ms/call |
| matmul | 129 | 157.94 us | 267.27 ms | 0.262s | 133.635 ms/call |
| saxpy | 38 | 85.28 us | 270.46 ms | 0.270s | 13.523 ms/call |
| histogram | 32 | 92.35 us | 28.50 ms | 0.029s | 949.90 us/call |
| histogram_big | 32 | 112.95 us | 68.40 ms | 0.068s | 22.801 ms/call |
| fannkuch | 254 | 151.15 us | 438.17 ms | 0.438s | 219.087 ms/call |
| queens | 199 | 114.96 us | 768.01 ms | 0.768s | 768.014 ms/call |
| heapsort | 211 | 84.35 us | 14.35 ms | 0.014s | 358.71 us/call |
| heapsort_big | 211 | 93.58 us | 25.01 ms | 0.025s | 25.014 ms/call |
| strings | 150 | 71.03 us | 60.95 ms | 0.061s | 203.17 us/call |
| nbody_float | 141 | 81.02 us | 125.09 ms | 0.125s | 41.697 ms/call |

### Windows x86-64 (windows-latest)

(`bench` run `39070459914`, all green.)

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 103.80 us | 11.21 ms | 0.011s | 22.4 ns/call |
| loop_sum | 42 | 72.40 us | 37.48 ms | 0.037s | 374.79 us/call |
| collatz | 80 | 136.10 us | 32.92 ms | 0.033s | 109.7 ns/call |
| primes | 99 | 94.00 us | 30.17 ms | 0.030s | 502.9 ns/call |
| mandel | 106 | 92.50 us | 28.27 ms | 0.028s | 141.3 ns/call |
| sieve | 131 | 98.00 us | 5.81 ms | 0.005s | 116.2 ns/call |
| bubble_sort | 95 | 89.00 us | 3.68 ms | 0.003s | 306.4 ns/call |
| nested_loops | 59 | 88.00 us | 18.20 ms | 0.018s | 91.02 us/call |
| tail_recursive | 30 | 88.50 us | 9.22 ms | 0.009s | 23.0 ns/call |
| array_sum | 35 | 96.20 us | 18.35 ms | 0.018s | 36.69 us/call |
| gcd | 37 | 88.50 us | 5.88 ms | 0.005s | 7.3 ns/call |
| dot_product | 40 | 69.00 us | 11.25 ms | 0.011s | 5.62 us/call |
| nbody | 147 | 150.70 us | 102.26 ms | 0.103s | 102.262 ms/call |
| matmul | 129 | 106.40 us | 185.96 ms | 0.186s | 92.981 ms/call |
| saxpy | 38 | 103.80 us | 73.94 ms | 0.074s | 3.697 ms/call |
| histogram | 32 | 81.30 us | 11.38 ms | 0.012s | 379.39 us/call |
| histogram_big | 32 | 101.80 us | 33.61 ms | 0.034s | 11.204 ms/call |
| fannkuch | 254 | 144.20 us | 388.56 ms | 0.388s | 194.278 ms/call |
| queens | 199 | 164.80 us | 647.82 ms | 0.648s | 647.819 ms/call |
| heapsort | 211 | 171.80 us | 13.45 ms | 0.013s | 336.14 us/call |
| heapsort_big | 211 | 145.50 us | 20.87 ms | 0.021s | 20.870 ms/call |
| strings | 150 | 89.20 us | 46.68 ms | 0.047s | 155.58 us/call |
| nbody_float | 154 | 130.50 us | 59.40 ms | 0.059s | 19.799 ms/call |

### Linux x86-64 (ubuntu-latest)

(`bench` run `39070459914`, all green.)

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 59.71 us | 10.99 ms | 0.011s | 22.0 ns/call |
| loop_sum | 42 | 69.13 us | 33.71 ms | 0.034s | 337.11 us/call |
| collatz | 80 | 86.61 us | 26.79 ms | 0.027s | 89.3 ns/call |
| primes | 99 | 66.40 us | 23.45 ms | 0.023s | 390.8 ns/call |
| mandel | 106 | 97.82 us | 27.64 ms | 0.028s | 138.2 ns/call |
| sieve | 133 | 76.95 us | 4.82 ms | 0.005s | 96.5 ns/call |
| bubble_sort | 95 | 64.81 us | 3.17 ms | 0.003s | 264.2 ns/call |
| nested_loops | 59 | 61.98 us | 16.31 ms | 0.016s | 81.57 us/call |
| tail_recursive | 30 | 56.01 us | 8.47 ms | 0.008s | 21.2 ns/call |
| array_sum | 35 | 52.55 us | 16.95 ms | 0.017s | 33.89 us/call |
| gcd | 37 | 56.34 us | 5.27 ms | 0.005s | 6.6 ns/call |
| dot_product | 40 | 51.22 us | 10.55 ms | 0.011s | 5.27 us/call |
| nbody | 147 | 72.42 us | 102.05 ms | 0.102s | 102.049 ms/call |
| matmul | 129 | 100.27 us | 188.35 ms | 0.188s | 94.177 ms/call |
| saxpy | 38 | 68.48 us | 69.34 ms | 0.069s | 3.467 ms/call |
| histogram | 32 | 50.47 us | 10.39 ms | 0.010s | 346.22 us/call |
| histogram_big | 32 | 76.73 us | 33.12 ms | 0.033s | 11.039 ms/call |
| fannkuch | 254 | 123.15 us | 386.54 ms | 0.386s | 193.270 ms/call |
| queens | 199 | 107.00 us | 635.16 ms | 0.635s | 635.159 ms/call |
| heapsort | 211 | 73.47 us | 13.33 ms | 0.013s | 333.24 us/call |
| heapsort_big | 211 | 59.88 us | 21.15 ms | 0.021s | 21.151 ms/call |
| strings | 150 | 66.79 us | 44.83 ms | 0.045s | 149.42 us/call |
| nbody_float | 141 | 80.97 us | 55.33 ms | 0.055s | 18.442 ms/call |

### Windows ARM64 (windows-11-arm, x64 kernels under emulation)

(`bench` run `39070459914`, all green.) Note the x64 byte sizes
(fib 73, tail_recursive 30): neither `arm64` nor `aarch64` is defined
for Nim on this runner, so it still selects the x64 kernels — treat
these as emulated-x64 numbers, not AArch64:

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 3.11 ms | 8.18 ms | 0.008s | 16.4 ns/call |
| loop_sum | 42 | 3.02 ms | 35.10 ms | 0.035s | 350.98 us/call |
| collatz | 80 | 3.37 ms | 24.56 ms | 0.024s | 81.9 ns/call |
| primes | 99 | 3.51 ms | 35.30 ms | 0.036s | 588.3 ns/call |
| mandel | 106 | 3.61 ms | 22.56 ms | 0.022s | 112.8 ns/call |
| sieve | 131 | 3.78 ms | 5.29 ms | 0.006s | 105.8 ns/call |
| bubble_sort | 95 | 3.56 ms | 6.56 ms | 0.007s | 546.4 ns/call |
| nested_loops | 59 | 3.31 ms | 19.65 ms | 0.020s | 98.26 us/call |
| tail_recursive | 30 | 3.16 ms | 8.45 ms | 0.008s | 21.1 ns/call |
| array_sum | 35 | 3.00 ms | 20.30 ms | 0.020s | 40.59 us/call |
| gcd | 37 | 3.19 ms | 6.13 ms | 0.006s | 7.7 ns/call |
| dot_product | 40 | 2.92 ms | 13.40 ms | 0.014s | 6.70 us/call |
| nbody | 147 | 3.86 ms | 1.298 s | 1.298s | 1298.208 ms/call |
| matmul | 129 | 3.82 ms | 174.01 ms | 0.174s | 87.005 ms/call |
| saxpy | 38 | 3.11 ms | 226.09 ms | 0.227s | 11.305 ms/call |
| histogram | 32 | 2.78 ms | 160.91 ms | 0.161s | 5.364 ms/call |
| histogram_big | 32 | 2.93 ms | 511.44 ms | 0.511s | 170.480 ms/call |
| fannkuch | 254 | 4.11 ms | 1.228 s | 1.228s | 614.211 ms/call |
| queens | 199 | 3.86 ms | 460.52 ms | 0.461s | 460.520 ms/call |
| heapsort | 211 | 3.85 ms | 15.00 ms | 0.015s | 375.03 us/call |
| heapsort_big | 211 | 3.98 ms | 21.95 ms | 0.022s | 21.945 ms/call |
| strings | 150 | 3.67 ms | 167.79 ms | 0.168s | 559.29 us/call |
| nbody_float | 154 | 3.84 ms | 43.42 ms | 0.043s | 14.474 ms/call |

### Linux ARM64 (ubuntu-24.04-arm, native AArch64)

Full 23-row native table (`bench` run `39070459914`, all green after
the tail_recursive frame fix):

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 60 | 40.83 us | 6.37 ms | 0.006s | 12.7 ns/call |
| loop_sum | 36 | 39.59 us | 29.61 ms | 0.030s | 296.08 us/call |
| collatz | 60 | 39.23 us | 17.18 ms | 0.017s | 57.3 ns/call |
| primes | 72 | 42.50 us | 12.86 ms | 0.013s | 214.3 ns/call |
| mandel | 92 | 42.18 us | 20.97 ms | 0.021s | 104.8 ns/call |
| sieve | 128 | 41.99 us | 3.82 ms | 0.004s | 76.3 ns/call |
| bubble_sort | 72 | 58.28 us | 2.62 ms | 0.003s | 218.1 ns/call |
| nested_loops | 60 | 38.38 us | 26.96 ms | 0.027s | 134.80 us/call |
| tail_recursive | 40 | 56.20 us | 4.31 ms | 0.004s | 10.8 ns/call |
| array_sum | 40 | 48.29 us | 20.03 ms | 0.020s | 40.06 us/call |
| gcd | 32 | 37.74 us | 5.53 ms | 0.006s | 6.9 ns/call |
| dot_product | 48 | 34.75 us | 9.37 ms | 0.009s | 4.68 us/call |
| nbody | 204 | 40.84 us | 107.93 ms | 0.108s | 107.930 ms/call |
| matmul | 116 | 78.68 us | 226.02 ms | 0.226s | 113.011 ms/call |
| saxpy | 44 | 56.16 us | 70.47 ms | 0.070s | 3.524 ms/call |
| histogram | 52 | 36.01 us | 19.04 ms | 0.019s | 634.67 us/call |
| histogram_big | 52 | 61.71 us | 61.02 ms | 0.061s | 20.341 ms/call |
| fannkuch | 228 | 56.75 us | 260.15 ms | 0.260s | 130.075 ms/call |
| queens | 176 | 71.78 us | 415.58 ms | 0.416s | 415.581 ms/call |
| heapsort | 188 | 41.89 us | 8.23 ms | 0.008s | 205.80 us/call |
| heapsort_big | 188 | 49.98 us | 13.84 ms | 0.014s | 13.838 ms/call |
| strings | 192 | 37.76 us | 44.77 ms | 0.045s | 149.23 us/call |
| nbody_float | 168 | 46.52 us | 65.75 ms | 0.066s | 21.917 ms/call |

### macOS ARM64 (macos-15, native AArch64)

Full 23-row native table (`bench` run `39070459914`, all green after
the tail_recursive frame fix):

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 60 | 24.12 us | 6.03 ms | 0.006s | 12.1 ns/call |
| loop_sum | 36 | 25.62 us | 34.96 ms | 0.035s | 349.62 us/call |
| collatz | 60 | 21.42 us | 24.08 ms | 0.024s | 80.3 ns/call |
| primes | 72 | 25.42 us | 12.95 ms | 0.013s | 215.8 ns/call |
| mandel | 92 | 21.88 us | 26.79 ms | 0.027s | 133.9 ns/call |
| sieve | 128 | 110.12 us | 4.85 ms | 0.005s | 97.1 ns/call |
| bubble_sort | 72 | 91.71 us | 3.38 ms | 0.003s | 281.4 ns/call |
| nested_loops | 60 | 23.46 us | 25.80 ms | 0.025s | 129.00 us/call |
| tail_recursive | 40 | 83.04 us | 5.02 ms | 0.005s | 12.5 ns/call |
| array_sum | 40 | 18.96 us | 21.04 ms | 0.020s | 42.09 us/call |
| gcd | 32 | 93.96 us | 2.84 ms | 0.003s | 3.6 ns/call |
| dot_product | 48 | 18.42 us | 13.16 ms | 0.013s | 6.58 us/call |
| nbody | 204 | 114.04 us | 116.80 ms | 0.115s | 116.796 ms/call |
| matmul | 116 | 171.96 us | 166.86 ms | 0.150s | 83.428 ms/call |
| saxpy | 44 | 42.00 us | 90.47 ms | 0.063s | 4.523 ms/call |
| histogram | 52 | 22.54 us | 18.24 ms | 0.017s | 608.16 us/call |
| histogram_big | 52 | 28.38 us | 56.53 ms | 0.056s | 18.843 ms/call |
| fannkuch | 228 | 286.00 us | 337.11 ms | 0.337s | 168.556 ms/call |
| queens | 176 | 313.29 us | 444.33 ms | 0.444s | 444.328 ms/call |
| heapsort | 188 | 223.17 us | 11.56 ms | 0.012s | 288.98 us/call |
| heapsort_big | 188 | 47.00 us | 15.99 ms | 0.016s | 15.992 ms/call |
| strings | 192 | 29.92 us | 47.02 ms | 0.047s | 156.74 us/call |
| nbody_float | 168 | 45.00 us | 115.93 ms | 0.116s | 38.643 ms/call |

## Roadmap
- [x] Pure-Nim macro DSL assembler for x64 and x86
- [x] Executable memory runtime with callable function pointers
- [x] Strict compile-time validation with suggestions
- [x] 23 verified JIT examples with self-reported wall/cpu timings
  (native x64 + AArch64 kernels, benchmarked without emulation)
- [x] AArch64 backend: integer core (mov/add/sub/logical/shifts/mul/div,
  ldr/str/ldp/stp, b/bl/br/cbz/tbz/adr, PC-relative relocations)
- [x] AArch64 SIMD/FP: scalar fmov/fadd/fcmp/scvtf/fcvt, vector
  add/mul/logical, dup/movi, SIMD loads/stores (byte-exact vs clang)
- [x] Apple Silicon CI: host-gated execution tests, AArch64 JIT executed on hardware
- [ ] AArch64 vector reg lists, lane-indexed forms, fixed-point converts
- [ ] Wider instruction coverage (SSE/AVX, more forms of existing mnemonics)
- [ ] Position-independent code helpers and jump tables
- [ ] Optional disassembly dump next to the debug code dump
- [ ] Published nimble release with API docs

Note: this package is a Nim port of the DynASM idea — dynamic assemblers that
encode machine code at runtime instead of shelling out to an assembler. See
[dynasm-rs](https://github.com/CensoredUsername/dynasm-rs) for the Rust
incarnation and the [LuaJIT DynASM](https://luajit.org/dynasm.html)
documentation for the original concept.

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/dynasm-nim/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/dynasm-nim/fork)

### 🎩 License
MPL-2.0, same as [dynasm-rs](https://github.com/CensoredUsername/dynasm-rs)
(which is (c) Alexander Stocko and CensoredUsername). This Source Code Form
is subject to the terms of the Mozilla Public License, v. 2.0. If a copy
of the MPL was not distributed with this package, you can obtain one at
http://mozilla.org/MPL/2.0/ (see LICENSE).
