import unittest
import dynasm

# AArch64 backend tests: byte-exact golden vectors.
#
# Every word below was derived from the opmap bases in
# references/dynasm-rs/plugin/src/arch/aarch64/opmap.rs (all 184
# bases in aarch64data.nim were cross-checked against it), with
# spot checks against well-known encodings (ret = D65F03C0,
# stp x29,x30,[sp,#-16]! = A9BF7BFD, sub sp,sp,#16 = D10043FF).
#
# NOTE: this host is x86_64, so emitted AArch64 code is verified by
# bytes only, never executed. Execution tests belong on ARM CI.

proc word(code: seq[byte], idx: int): uint32 =
  uint32(code[idx]) or (uint32(code[idx+1]) shl 8) or
    (uint32(code[idx+2]) shl 16) or (uint32(code[idx+3]) shl 24)

test "aarch64 mov forms":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    mov x0, x1
    mov w2, w3
    movz x0, 0x1234
    movz x5, 0xAB, lsl, 16
    movn w0, 0
    movk x0, 0xFF, lsl, 32
    mov x6, 0x1234
    ret()
  let code = ops.finalize()
  check code.len == 8 * 4
  check word(code, 0) == 0xAA0103E0'u32  # orr x0, xzr, x1
  check word(code, 4) == 0x2A0303E2'u32
  check word(code, 8) == 0xD2824680'u32
  check word(code, 12) == 0xD2A01565'u32
  check word(code, 16) == 0x12800000'u32
  check word(code, 20) == 0xF2C01FE0'u32
  check word(code, 24) == 0xD2824686'u32 # smart mov picks movz
  check word(code, 28) == 0xD65F03C0'u32

test "aarch64 add/sub/cmp":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    add x0, x1, x2
    add x0, x1, 5
    add x0, x1, 5, lsl, 12
    sub sp, sp, 16
    sub x2, x2, 1
    cmp x0, 1
    cmp x0, x1
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x8B020020'u32
  check word(code, 4) == 0x91001420'u32
  check word(code, 8) == 0x91401420'u32
  check word(code, 12) == 0xD10043FF'u32
  check word(code, 16) == 0xD1000442'u32 # sub imm form
  check word(code, 20) == 0xF100041F'u32
  check word(code, 24) == 0xEB01001F'u32
  check word(code, 28) == 0xD65F03C0'u32

test "aarch64 logical + shifts":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    orr x0, x1, x2
    eor x0, x1, x2
    tst x0, x1
    mvn x0, x1
    neg x3, x4
    lsl x0, x1, 5
    lsr x2, x3, 10
    mul x0, x1, x2
    madd x0, x1, x2, x3
    sdiv w0, w1, w2
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0xAA020020'u32
  check word(code, 4) == 0xCA020020'u32
  check word(code, 8) == 0xEA01001F'u32
  check word(code, 12) == 0xAA2103E0'u32
  check word(code, 16) == 0xCB0403E3'u32
  check word(code, 20) == 0xD37BE820'u32
  check word(code, 24) == 0xD34AFC62'u32
  check word(code, 28) == 0x9B027C20'u32
  check word(code, 32) == 0x9B020C20'u32
  check word(code, 36) == 0x1AC20C20'u32
  check word(code, 40) == 0xD65F03C0'u32

test "aarch64 loads/stores/pairs":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    ldr x0, [sp, 8]
    str w1, [x2, 4]
    ldr x3, [x4], 16
    str x5, [x6, 32], pre
    stp x29, x30, [sp, -16], pre
    ldp x0, x1, [x2]
    ldr x0, [x1, x2, lsl, 3]
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0xF94007E0'u32
  check word(code, 4) == 0xB9000441'u32
  check word(code, 8) == 0xF8410483'u32
  check word(code, 12) == 0xF8020CC5'u32
  check word(code, 16) == 0xA9BF7BFD'u32
  check word(code, 20) == 0xA9400440'u32
  check word(code, 24) == 0xF8627820'u32
  check word(code, 28) == 0xD65F03C0'u32

test "aarch64 branches patch relocations":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    label top
    nop()
    b bwd("top")
    cbz x0, fwd("t")
    nop()
    label t
    tbz w1, 5, fwd("t2")
    nop()
    label t2
    b.eq bwd("top")
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0xD503201F'u32
  check word(code, 4) == 0x17FFFFFF'u32  # b -4
  check word(code, 8) == 0xB4000040'u32  # cbz +8
  check word(code, 12) == 0xD503201F'u32
  check word(code, 16) == 0x36280041'u32 # tbz w1, #5, +8
  check word(code, 20) == 0xD503201F'u32
  # b.eq top: from 24 back to 0 = -24, (-24>>2)&0x7FFFF<<5
  check word(code, 24) == 0x54FFFF40'u32
  check word(code, 28) == 0xD65F03C0'u32

test "aarch64 adr/adrp relocations":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    adr x0, fwd("t")
    nop()
    nop()
    nop()
    nop()
    label t
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x100000A0'u32 # adr x0, +20
  var ops2 = initVecAssembler(0)
  dynasm ops2:
    arch aarch64
    adrp x0, fwd("t2")
    align 4096
    align 8192
    label t2
    ret()
  let code2 = ops2.finalize()
  check word(code2, 0) == 0xD0000000'u32 # adrp x0, +8192 (page 2)

test "aarch64 bl/ret-reg/nop/hlt":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    bl fwd("fn")
    nop()
    label fn
    ret x30
    hlt 0xF000
    ret()
  let code = ops.finalize()
  # bl +8: (8>>2) = 2
  check word(code, 0) == 0x94000002'u32
  check word(code, 4) == 0xD503201F'u32
  check word(code, 8) == 0xD65F03C0'u32
  check word(code, 12) == 0xD45E0000'u32 # hlt #0xF000
  check word(code, 16) == 0xD65F03C0'u32

test "aarch64 dynamic regs and values":
  var ops = initVecAssembler(0)
  let r = 7
  let n = 8
  dynasm ops:
    arch aarch64
    add Xreg(r), Xreg(0), Xreg(1)
    movz Wreg(2), 9
    ldr x0, [sp, n]
    ret()
  let code = ops.finalize()
  check word(code, 0) == (0x8B000000'u32 or 7'u32 or
    (0'u32 shl 5) or (1'u32 shl 16))
  check word(code, 4) == (0x52800000'u32 or 2'u32 or
    (9'u32 shl 5))
  check word(code, 8) == (0xF9400000'u32 or 0'u32 or
    (31'u32 shl 5) or (1'u32 shl 10))
  check word(code, 12) == 0xD65F03C0'u32

test "aarch64 logical immediates":
  check encodeLogical64(0xFF'u64) == 0x1007
  check encodeLogical32(0xFF'u32) >= 0
  check encodeLogical64(0x123456789ABCDEF'u64) < 0
  check encodeWide64(0x12340000'u64) >= 0
  check encodeWide64(0x12345678'u64) < 0
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    `and` x0, x1, 0xFF
    mov.logical x0, 0xFF
    mov.inverted x0, 0xFFFF1234FFFFFFFF'u64
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x92401C20'u32 # Rn=x1
  check word(code, 4) == 0xB2401FE0'u32
  # movn x0, #0xEDCB, lsl #32 over ~0xFFFF1234FFFFFFFF
  check word(code, 8) == (0x92800000'u32 or
    ((0xEDCB'u32) shl 5) or (2'u32 shl 21))
  check word(code, 12) == 0xD65F03C0'u32

test "aarch64 cset":
  var ops = initVecAssembler(0)
  dynasm ops:
    arch aarch64
    cset w9, eq
    cset w9, lt
    cset w9, gt
    cset x5, ne
    cset w1, hs
    ret()
  let code = ops.finalize()
  check word(code, 0) == 0x1A9F17E9'u32  # cset w9, eq (clang-verified)
  check word(code, 4) == 0x1A9FA7E9'u32  # cset w9, lt (clang-verified)
  check word(code, 8) == 0x1A9FD7E9'u32  # cset w9, gt (clang-verified)
  check word(code, 12) == 0x9A9F07E5'u32 # cset x5, ne (clang-verified)
  check word(code, 16) == 0x1A9F37E1'u32 # cset w1, hs (clang-verified)
  check word(code, 20) == 0xD65F03C0'u32
