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

| example | bytes | assembled in | result | wall | cpu | per call |
|---|---|---|---|---|---|---|
| fib | 73 | 45.60 us | fib(30) = 832040 x500000 iters | 8.44 ms | 0.008s | 16.9 ns/call |
| loop_sum | 42 | 43.04 us | sumTo(1000000) = 500000500000 x100 iters | 25.93 ms | 0.026s | 259.33 us/call |
| collatz | 80 | 48.45 us | collatz steps(27) = 111 x300000 iters | 17.15 ms | 0.017s | 57.2 ns/call |
| primes | 99 | 72.08 us | primes below 100: 25 x60000 iters | 15.37 ms | 0.015s | 256.1 ns/call |
| mandel | 104 | 52.87 us | mandel(0,0) x200000 iters | 20.87 ms | 0.021s | 104.4 ns/call |
| sieve | 132 | 56.29 us | primes below 100: 25 x50000 pure-JIT calls | 3.73 ms | 0.004s | 74.5 ns/call |
| bubble_sort | 95 | 49.11 us | sorted: @[0, 1, 2, 2, 4, 5, 8] x600 iters x20 sorts (12000 pure-JIT calls) | 2.37 ms | 0.002s | 197.5 ns/call |
| nested_loops | 59 | 47.88 us | nested(500,500) = 15562562500 x200 iters | 15.29 ms | 0.015s | 76.44 us/call |
| tail_recursive | 30 | 46.36 us | fact(20) = 2432902008176640000 x400000 iters of fact(15) | 5.96 ms | 0.006s | 14.9 ns/call |
| array_sum | 34 | 41.55 us | asum(1..100000) = 5000050000 x500 iters | 13.49 ms | 0.013s | 26.97 us/call |
| gcd | 34 | 52.04 us | gcd(123456789,987654321) = 9 x800000 iters | 4.05 ms | 0.004s | 5.1 ns/call |
| dot_product | 39 | 41.52 us | dot(10k) = 26450000 x2000 iters | 8.62 ms | 0.009s | 4.31 us/call |
| nbody | 145 | 54.99 us | nbody(5 bodies, 5000000 steps) checksum 7 x1 iters | 86.18 ms | 0.086s | 86.184 ms/call |
| matmul | 125 | 65.78 us | matmul(480) checksum 1354752000 x2 iters | 152.57 ms | 0.152s | 76.284 ms/call |
| saxpy | 38 | 54.76 us | saxpy(1M) ok x20 iters | 68.10 ms | 0.068s | 3.405 ms/call |
| histogram | 31 | 35.04 us | histogram(1M) total 1000000 x30 iters | 9.36 ms | 0.009s | 312.16 us/call |
| histogram_big | 31 | 45.38 us | histogram_big(32M) ok x3 iters | 29.24 ms | 0.029s | 9.746 ms/call |
| fannkuch | 246 | 69.43 us | fannkuch(10) = 38 x2 iters | 310.96 ms | 0.310s | 155.482 ms/call |
| queens | 189 | 67.68 us | queens(13) = 73712 x1 iters | 436.90 ms | 0.436s | 436.896 ms/call |
| heapsort | 204 | 50.66 us | heapsort(8x5000) ok x5 iters x8 sorts (40 pure-JIT calls) | 10.78 ms | 0.011s | 269.56 us/call |
| heapsort_big | 204 | 52.16 us | heapsort(200k) ok x1 pure-JIT iters | 16.34 ms | 0.016s | 16.345 ms/call |
| strings | 146 | 46.94 us | strings(64k) ok x300 iters | 36.67 ms | 0.036s | 122.23 us/call |
| nbody_float | 141 | 59.24 us | nbody_float(5 bodies, 200000 steps) checksum -3.776412516032224e-11 x3 iters | 32.85 ms | 0.033s | 10.950 ms/call |

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
