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
mode/examples/iters inputs). The same sources run on System V and
Win64 (argument registers selected per ABI); AArch64 hosts build-only
(the examples emit x86-64 machine code, which cannot execute there).

### macOS x86-64 (macos-15-intel)

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 53.44 us | 14.35 ms | 0.014s | 28.7 ns/call |
| loop_sum | 42 | 52.88 us | 23.90 ms | 0.024s | 239.00 us/call |
| collatz | 80 | 56.52 us | 32.94 ms | 0.033s | 109.8 ns/call |
| primes | 99 | 61.55 us | 43.67 ms | 0.044s | 727.8 ns/call |
| mandel | 106 | 60.94 us | 24.28 ms | 0.024s | 121.4 ns/call |
| sieve | 133 | 66.57 us | 3.88 ms | 0.004s | 77.5 ns/call |
| bubble_sort | 95 | 53.56 us | 5.00 ms | 0.005s | 416.7 ns/call |
| nested_loops | 59 | 57.97 us | 24.35 ms | 0.024s | 121.74 us/call |
| tail_recursive | 30 | 50.75 us | 7.12 ms | 0.007s | 17.8 ns/call |
| array_sum | 35 | 43.97 us | 17.48 ms | 0.017s | 34.95 us/call |
| gcd | 37 | 52.26 us | 15.02 ms | 0.015s | 18.8 ns/call |
| dot_product | 40 | 45.02 us | 14.05 ms | 0.014s | 7.03 us/call |
| nbody | 147 | 63.68 us | 105.72 ms | 0.106s | 105.721 ms/call |
| matmul | 129 | 79.85 us | 191.61 ms | 0.192s | 95.807 ms/call |
| saxpy | 38 | 65.67 us | 159.16 ms | 0.159s | 7.958 ms/call |
| histogram | 32 | 52.44 us | 14.43 ms | 0.014s | 480.96 us/call |
| histogram_big | 32 | 53.34 us | 48.51 ms | 0.049s | 16.171 ms/call |
| fannkuch | 254 | 87.65 us | 380.62 ms | 0.381s | 190.308 ms/call |
| queens | 199 | 89.50 us | 652.68 ms | 0.653s | 652.678 ms/call |
| heapsort | 211 | 59.16 us | 12.28 ms | 0.012s | 307.06 us/call |
| heapsort_big | 211 | 67.77 us | 19.43 ms | 0.019s | 19.431 ms/call |
| strings | 150 | 56.49 us | 39.40 ms | 0.039s | 131.34 us/call |
| nbody_float | 141 | 65.14 us | 108.59 ms | 0.109s | 36.198 ms/call |

### Windows x86-64 (windows-latest)

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 75.70 us | 15.45 ms | 0.015s | 30.9 ns/call |
| loop_sum | 42 | 80.90 us | 32.74 ms | 0.033s | 327.43 us/call |
| collatz | 80 | 91.80 us | 24.56 ms | 0.024s | 81.9 ns/call |
| primes | 99 | 85.70 us | 30.21 ms | 0.030s | 503.5 ns/call |
| mandel | 106 | 86.90 us | 27.56 ms | 0.027s | 137.8 ns/call |
| sieve | 131 | 92.60 us | 5.22 ms | 0.006s | 104.5 ns/call |
| bubble_sort | 95 | 80.00 us | 3.46 ms | 0.003s | 288.2 ns/call |
| nested_loops | 59 | 115.20 us | 24.94 ms | 0.024s | 124.68 us/call |
| tail_recursive | 30 | 77.20 us | 9.33 ms | 0.009s | 23.3 ns/call |
| array_sum | 35 | 89.10 us | 18.42 ms | 0.018s | 36.84 us/call |
| gcd | 37 | 79.10 us | 5.61 ms | 0.005s | 7.0 ns/call |
| dot_product | 40 | 100.20 us | 11.17 ms | 0.011s | 5.59 us/call |
| nbody | 147 | 90.50 us | 102.45 ms | 0.102s | 102.453 ms/call |
| matmul | 129 | 92.40 us | 191.19 ms | 0.192s | 95.596 ms/call |
| saxpy | 38 | 81.80 us | 69.34 ms | 0.069s | 3.467 ms/call |
| histogram | 32 | 66.80 us | 10.40 ms | 0.010s | 346.53 us/call |
| histogram_big | 32 | 83.90 us | 33.20 ms | 0.033s | 11.065 ms/call |
| fannkuch | 254 | 129.10 us | 387.91 ms | 0.388s | 193.957 ms/call |
| queens | 199 | 112.70 us | 657.27 ms | 0.657s | 657.272 ms/call |
| heapsort | 211 | 117.40 us | 13.39 ms | 0.014s | 334.70 us/call |
| heapsort_big | 211 | 91.40 us | 20.71 ms | 0.021s | 20.712 ms/call |
| strings | 150 | 130.20 us | 45.47 ms | 0.045s | 151.57 us/call |
| nbody_float | 154 | 136.50 us | 60.61 ms | 0.060s | 20.204 ms/call |

### Linux x86-64 (ubuntu-latest)

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 59.86 us | 11.03 ms | 0.011s | 22.1 ns/call |
| loop_sum | 42 | 58.87 us | 33.48 ms | 0.033s | 334.79 us/call |
| collatz | 80 | 64.09 us | 22.11 ms | 0.022s | 73.7 ns/call |
| primes | 99 | 109.11 us | 24.65 ms | 0.025s | 410.8 ns/call |
| mandel | 106 | 70.73 us | 27.65 ms | 0.028s | 138.3 ns/call |
| sieve | 133 | 80.33 us | 5.53 ms | 0.006s | 110.5 ns/call |
| bubble_sort | 95 | 62.89 us | 3.28 ms | 0.003s | 273.5 ns/call |
| nested_loops | 59 | 61.54 us | 16.36 ms | 0.016s | 81.78 us/call |
| tail_recursive | 30 | 58.94 us | 8.47 ms | 0.008s | 21.2 ns/call |
| array_sum | 35 | 58.31 us | 16.71 ms | 0.017s | 33.42 us/call |
| gcd | 37 | 65.25 us | 5.31 ms | 0.005s | 6.6 ns/call |
| dot_product | 40 | 51.01 us | 10.55 ms | 0.011s | 5.28 us/call |
| nbody | 147 | 78.07 us | 99.45 ms | 0.099s | 99.453 ms/call |
| matmul | 129 | 101.55 us | 189.35 ms | 0.189s | 94.673 ms/call |
| saxpy | 38 | 119.04 us | 71.70 ms | 0.072s | 3.585 ms/call |
| histogram | 32 | 58.85 us | 10.55 ms | 0.011s | 351.68 us/call |
| histogram_big | 32 | 74.94 us | 33.11 ms | 0.033s | 11.035 ms/call |
| fannkuch | 254 | 135.85 us | 386.02 ms | 0.386s | 193.009 ms/call |
| queens | 199 | 109.66 us | 634.31 ms | 0.634s | 634.314 ms/call |
| heapsort | 211 | 77.70 us | 13.36 ms | 0.013s | 333.92 us/call |
| heapsort_big | 211 | 96.04 us | 21.23 ms | 0.021s | 21.226 ms/call |
| strings | 150 | 76.59 us | 44.12 ms | 0.044s | 147.08 us/call |
| nbody_float | 141 | 77.22 us | 55.20 ms | 0.055s | 18.401 ms/call |

### Windows ARM64 (windows-11-arm, x86-64 under emulation)

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 3.63 ms | 10.23 ms | 0.010s | 20.5 ns/call |
| loop_sum | 42 | 3.49 ms | 47.47 ms | 0.048s | 474.66 us/call |
| collatz | 80 | 3.91 ms | 24.33 ms | 0.024s | 81.1 ns/call |
| primes | 99 | 4.07 ms | 27.16 ms | 0.027s | 452.7 ns/call |
| mandel | 106 | 4.12 ms | 21.43 ms | 0.022s | 107.1 ns/call |
| sieve | 131 | 4.36 ms | 5.94 ms | 0.006s | 118.7 ns/call |
| bubble_sort | 95 | 4.05 ms | 3.34 ms | 0.003s | 278.6 ns/call |
| nested_loops | 59 | 3.74 ms | 26.93 ms | 0.027s | 134.65 us/call |
| tail_recursive | 30 | 3.60 ms | 12.79 ms | 0.013s | 32.0 ns/call |
| array_sum | 35 | 3.44 ms | 32.16 ms | 0.032s | 64.31 us/call |
| gcd | 37 | 3.65 ms | 6.50 ms | 0.007s | 8.1 ns/call |
| dot_product | 40 | 3.38 ms | 15.52 ms | 0.015s | 7.76 us/call |
| nbody | 147 | 4.40 ms | 179.82 ms | 0.180s | 179.818 ms/call |
| matmul | 129 | 4.44 ms | 284.58 ms | 0.285s | 142.289 ms/call |
| saxpy | 38 | 3.67 ms | 70.17 ms | 0.071s | 3.508 ms/call |
| histogram | 32 | 3.25 ms | 23.26 ms | 0.023s | 775.42 us/call |
| histogram_big | 32 | 3.41 ms | 74.00 ms | 0.074s | 24.667 ms/call |
| fannkuch | 254 | 4.72 ms | 325.55 ms | 0.326s | 162.776 ms/call |
| queens | 199 | 4.46 ms | 530.00 ms | 0.530s | 529.998 ms/call |
| heapsort | 211 | 4.44 ms | 11.42 ms | 0.012s | 285.58 us/call |
| heapsort_big | 211 | 4.59 ms | 18.55 ms | 0.018s | 18.545 ms/call |
| strings | 150 | 4.24 ms | 56.19 ms | 0.056s | 187.31 us/call |
| nbody_float | 154 | 4.43 ms | 109.43 ms | 0.109s | 36.476 ms/call |

### Linux ARM64 (ubuntu-24.04-arm, build-only)

| example | build |
|---|---|
| fib | ok |
| loop_sum | ok |
| collatz | ok |
| primes | ok |
| mandel | ok |
| sieve | ok |
| bubble_sort | ok |
| nested_loops | ok |
| tail_recursive | ok |
| array_sum | ok |
| gcd | ok |
| dot_product | ok |
| nbody | ok |
| matmul | ok |
| saxpy | ok |
| histogram | ok |
| histogram_big | ok |
| fannkuch | ok |
| queens | ok |
| heapsort | ok |
| heapsort_big | ok |
| strings | ok |
| nbody_float | ok |

## Roadmap
- [x] Pure-Nim macro DSL assembler for x64 and x86
- [x] Executable memory runtime with callable function pointers
- [x] Strict compile-time validation with suggestions
- [x] 23 verified JIT examples with self-reported wall/cpu timings
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
