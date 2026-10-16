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
- Pure-Nim dynamic assembler for x64 and x86, no C preprocessor or external tools
- Macro DSL that lets you write assembly inline in Nim code
- Labels, global symbols and relocations resolved at assembly time
- Strict compile-time validation with suggestions on typos
- Executable memory buffers you can call as plain function pointers
- Debug mode that dumps the generated machine code

## Examples
- `examples/fib.nim` — recursive Fibonacci in JIT code
- `examples/sieve.nim` — Sieve of Eratosthenes inner marking loop
- `examples/heapsort.nim` — heapsort with an internal called sift-down
- `examples/nbody.nim` — integer N-body simulation stride loop

Run one with `clue build examples/fib.nim --release --out:/tmp/fib && /tmp/fib`,
or build and run all 23 with `./bench.sh`, which prints a Markdown table of
per-call timings.

Latest results (`./bench.sh`):

| example | bytes | assembled in | wall | cpu | per call |
|---|---|---|---|---|---|
| fib | 73 | 45.60 us | 8.44 ms | 0.008s | 16.9 ns/call |
| loop_sum | 42 | 43.04 us | 25.93 ms | 0.026s | 259.33 us/call |
| collatz | 80 | 48.45 us | 17.15 ms | 0.017s | 57.2 ns/call |
| primes | 99 | 72.08 us | 15.37 ms | 0.015s | 256.1 ns/call |
| mandel | 104 | 52.87 us | 20.87 ms | 0.021s | 104.4 ns/call |
| sieve | 132 | 56.29 us | 3.73 ms | 0.004s | 74.5 ns/call |
| bubble_sort | 95 | 49.11 us | 2.37 ms | 0.002s | 197.5 ns/call |
| nested_loops | 59 | 47.88 us | 15.29 ms | 0.015s | 76.44 us/call |
| tail_recursive | 30 | 46.36 us | 5.96 ms | 0.006s | 14.9 ns/call |
| array_sum | 34 | 41.55 us | 13.49 ms | 0.013s | 26.97 us/call |
| gcd | 34 | 52.04 us | 4.05 ms | 0.004s | 5.1 ns/call |
| dot_product | 39 | 41.52 us | 8.62 ms | 0.009s | 4.31 us/call |
| nbody | 145 | 54.99 us | 86.18 ms | 0.086s | 86.184 ms/call |
| matmul | 125 | 65.78 us | 152.57 ms | 0.152s | 76.284 ms/call |
| saxpy | 38 | 54.76 us | 68.10 ms | 0.068s | 3.405 ms/call |
| histogram | 31 | 35.04 us | 9.36 ms | 0.009s | 312.16 us/call |
| histogram_big | 31 | 45.38 us | 29.24 ms | 0.029s | 9.746 ms/call |
| fannkuch | 246 | 69.43 us | 310.96 ms | 0.310s | 155.482 ms/call |
| queens | 189 | 67.68 us | 436.90 ms | 0.436s | 436.896 ms/call |
| heapsort | 204 | 50.66 us | 10.78 ms | 0.011s | 269.56 us/call |
| heapsort_big | 204 | 52.16 us | 16.34 ms | 0.016s | 16.345 ms/call |
| strings | 146 | 46.94 us | 36.67 ms | 0.036s | 122.23 us/call |
| nbody_float | 141 | 59.24 us | 32.85 ms | 0.033s | 10.950 ms/call |

## Roadmap
- [x] Pure-Nim macro DSL assembler for x64 and x86
- [x] Executable memory runtime with callable function pointers
- [x] Strict compile-time validation with suggestions
- [x] 23 verified JIT examples with self-reported wall/cpu timings
- [ ] AArch64 backend alongside the current x64/x86 support
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
MIT license | Nim Community.
