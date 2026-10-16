import unittest
import dynasm

# AArch64 SIMD/FP tests: byte-exact golden vectors.
#
# Every expected word was produced by Apple clang 16 targeting
# aarch64 (`clang -target aarch64 -c`), which serves as the
# ground-truth oracle. The vector arrangement syntax vN.s4 follows
# dynasm-rs (element letter first; ARM's lane-first `vN.4s` is
# unparseable in both Rust and Nim).
#
# NOTE: this host is x86_64, so emitted code is verified by bytes
# only, never executed. The nimsimd-oracle execution test at the
# bottom runs only on AArch64 hardware (needs `nimsimd` installed).

proc word(code: seq[byte], idx: int): uint32 =
  uint32(code[idx]) or (uint32(code[idx+1]) shl 8) or
    (uint32(code[idx+2]) shl 16) or (uint32(code[idx+3]) shl 24)

test "aarch64 fmov forms":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    fmov s0, s1
    fmov d2, d3
    fmov s4, 1.0
    fmov d5, 2.5
    fmov s0, w0
    fmov w1, s2
    fmov d0, x0
    fmov x1, d2
    fmov s6, 1
    ret()
  let code = ops.finalize()
  check code.len == 10 * 4
  check word(code, 0) == 0x1E204020'u32
  check word(code, 4) == 0x1E604062'u32
  check word(code, 8) == 0x1E2E1004'u32
  check word(code, 12) == 0x1E609005'u32
  check word(code, 16) == 0x1E270000'u32
  check word(code, 20) == 0x1E260041'u32
  check word(code, 24) == 0x9E670000'u32
  check word(code, 28) == 0x9E660041'u32
  check word(code, 32) == 0x1E2E1006'u32 # int 1 coerced to 1.0f
  check word(code, 36) == 0xD65F03C0'u32

test "aarch64 scalar FP arithmetic":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    fadd s0, s1, s2
    fadd d0, d1, d2
    fsub s0, s1, s2
    fmul d0, d1, d2
    fdiv s0, s1, s2
    fmax d0, d1, d2
    fmin s0, s1, s2
    fneg s0, s1
    fabs d0, d1
    fsqrt s0, s1
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x1E222820'u32
  check word(code, 4) == 0x1E622820'u32
  check word(code, 8) == 0x1E223820'u32
  check word(code, 12) == 0x1E620820'u32
  check word(code, 16) == 0x1E221820'u32
  check word(code, 20) == 0x1E624820'u32
  check word(code, 24) == 0x1E225820'u32
  check word(code, 28) == 0x1E214020'u32
  check word(code, 32) == 0x1E60C020'u32
  check word(code, 36) == 0x1E21C020'u32
  check word(code, 40) == 0xD65F03C0'u32

test "aarch64 fcmp and conversions":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    fcmp s0, s1
    fcmp d0, 0.0
    fcmpe s0, s1
    scvtf s0, w0
    scvtf d0, x1
    ucvtf s0, w0
    ucvtf d0, x1
    fcvtzs w0, s0
    fcvtzs x1, d2
    fcvtzu w0, s0
    fcvt s0, d0
    fcvt d0, s0
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x1E212000'u32
  check word(code, 4) == 0x1E602008'u32
  check word(code, 8) == 0x1E212010'u32
  check word(code, 12) == 0x1E220000'u32
  check word(code, 16) == 0x9E620020'u32
  check word(code, 20) == 0x1E230000'u32
  check word(code, 24) == 0x9E630020'u32
  check word(code, 28) == 0x1E380000'u32
  check word(code, 32) == 0x9E780041'u32
  check word(code, 36) == 0x1E390000'u32
  check word(code, 40) == 0x1E624000'u32
  check word(code, 44) == 0x1E22C000'u32
  check word(code, 48) == 0xD65F03C0'u32

test "aarch64 dup and movi":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    dup v0.s4, w0
    dup v1.d2, x1
    movi v0.s4, 0xFF
    movi v0.s4, 0xFF, lsl, 8
    movi v0.s4, 0xFF, lsl, 16
    movi v2.d2, 0xFF00FF00FF00FF00
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x4E040C00'u32
  check word(code, 4) == 0x4E080C21'u32
  check word(code, 8) == 0x4F0707E0'u32
  check word(code, 12) == 0x4F0727E0'u32
  check word(code, 16) == 0x4F0747E0'u32
  check word(code, 20) == 0x6F05E542'u32
  check word(code, 24) == 0xD65F03C0'u32

test "aarch64 vector integer ALU":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    add v0.s4, v1.s4, v2.s4
    add v0.d2, v1.d2, v2.d2
    add v0.b16, v1.b16, v2.b16
    sub v0.h8, v1.h8, v2.h8
    mul v0.s4, v1.s4, v2.s4
    `and` v0.b16, v1.b16, v2.b16
    orr v0.b16, v1.b16, v2.b16
    eor v0.b16, v1.b16, v2.b16
    bic v0.b16, v1.b16, v2.b16
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x4EA28420'u32
  check word(code, 4) == 0x4EE28420'u32
  check word(code, 8) == 0x4E228420'u32
  check word(code, 12) == 0x6E628420'u32
  check word(code, 16) == 0x4EA29C20'u32
  check word(code, 20) == 0x4E221C20'u32
  check word(code, 24) == 0x4EA21C20'u32
  check word(code, 28) == 0x6E221C20'u32
  check word(code, 32) == 0x4E621C20'u32
  check word(code, 36) == 0xD65F03C0'u32

test "aarch64 vector FP ALU":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    fadd v0.s4, v1.s4, v2.s4
    fadd v0.d2, v1.d2, v2.d2
    fsub v0.h8, v1.h8, v2.h8
    fmul v0.s4, v1.s4, v2.s4
    fdiv v0.s4, v1.s4, v2.s4
    fmax v0.d2, v1.d2, v2.d2
    fmin v0.s4, v1.s4, v2.s4
    ret()
  let code = ops.finalize()
  # NOTE: half-precision (h8 here) needs ARMv8.2+FP16 hardware.
  check word(code, 0) == 0x4E22D420'u32
  check word(code, 4) == 0x4E62D420'u32
  check word(code, 8) == 0x4EC21420'u32
  check word(code, 12) == 0x6E22DC20'u32
  check word(code, 16) == 0x6E22FC20'u32
  check word(code, 20) == 0x4E62F420'u32
  check word(code, 24) == 0x4EA2F420'u32
  check word(code, 28) == 0xD65F03C0'u32

test "aarch64 SIMD loads and stores":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    ldr q0, [x0]
    ldr q0, [x0, 16]
    str q1, [x0, 16], pre
    str q1, [x0], 16
    ldr s0, [x0, 4]
    str d1, [x0, 8]
    ldr d0, [x0, x1, lsl, 3]
    ldr b0, [x0]
    str h1, [x0, 2]
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x3DC00000'u32
  check word(code, 4) == 0x3DC00400'u32
  check word(code, 8) == 0x3C810C01'u32
  check word(code, 12) == 0x3C810401'u32
  check word(code, 16) == 0xBD400400'u32
  check word(code, 20) == 0xFD000401'u32
  check word(code, 24) == 0xFC617800'u32
  check word(code, 28) == 0x3D400000'u32
  check word(code, 32) == 0x7D000401'u32
  check word(code, 36) == 0xD65F03C0'u32

test "aarch64 float immediate helpers":
  check encodeFloatImm(0x3F800000'u32) == 0x70 # 1.0f
  check encodeFloatImm(0x40000000'u32) >= 0     # 2.0f
  check encodeFloatImm(0x3F800001'u32) < 0     # not encodable
  check encodeStretchedImm(0x00FF00FFFF00FF00'u64) == 0x5A
  check encodeStretchedImm(0x123456789ABCDEF'u64) < 0

when defined(arm64):
  # Execution tests against the nimsimd oracle (needs nimsimd
  # installed). They only compile on AArch64 hardware. Everything
  # else (assembler, registers, exec buffer) comes from the top
  # `import dynasm`.
  import nimsimd/neon

  test "aarch64 JIT fadd matches nimsimd":
    proc buildFadd(): ExecutableBuffer =
      var a = newAssembler(akAarch64)
      dynasm a:
        arch aarch64
        ldr q0, [x0]
        ldr q1, [x1]
        fadd v2.s4, v0.s4, v1.s4
        str q2, [x2]
        ret()
      a.finalize()
    var buf = buildFadd()
    let f = cast[proc(a, b, c: pointer) {.cdecl.}](buf.ptrAt(
      AssemblyOffset(0)))
    var x = [1.5'f32, -2.0, 3.25, 4.5]
    var y = [0.5'f32, 2.0, -1.25, 8.0]
    var z = [0'f32, 0, 0, 0]
    f(addr x[0], addr y[0], addr z[0])
    let want = vaddq_f32(vld1q_f32(addr x[0]), vld1q_f32(addr y[0]))
    var w = [0'f32, 0, 0, 0]
    vst1q_f32(addr w[0], want)
    check z == w
    buf.destroy()
