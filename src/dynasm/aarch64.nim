## AArch64 instruction encoders (integer core).
## Mirrors dynasm-rs plugin/src/arch/aarch64/opmap.rs bases + compiler.rs
## command semantics, and runtime/src/aarch64.rs immediate helpers.
## Fixed 32-bit little-endian words; PC-relative relocations use the
## arch-specific codes in relocations.nim (B/BCOND/ADR/ADRP/TBZ).

import std/bitops
import ./types
import ./relocations
import ./registers

proc rotR32(v: uint32, n: int): uint32 =
  (v shr (n and 31)) or (v shl ((32 - n) and 31))

proc rotL32(v: uint32, n: int): uint32 =
  (v shl (n and 31)) or (v shr ((32 - n) and 31))

proc rotR64(v: uint64, n: int): uint64 =
  (v shr (n and 63)) or (v shl ((64 - n) and 63))

proc rotL64(v: uint64, n: int): uint64 =
  (v shl (n and 63)) or (v shr ((64 - n) and 63))

proc emitWord(a: var auto, w: uint32) =
  a.pushU32(w)

proc rcode(r: Register): uint32 = uint32(r.code and 31)

proc badImm*(msg: string): ref DynasmError =
  impossibleRelocation(msg)

proc encodeFloatImm*(bits: uint32): int =
  ## Floating-point immediate (fmov), or -1. Port of dynasm-rs
  ## encode_floating_point_immediate: abcdefgh =>
  ## aBbbbbbc defgh000 ... with B = !b.
  let check = (bits shr 25) and 0x3F
  if (check == 0b100000 or check == 0b011111) and
      (bits and 0x7FFFF'u32) == 0:
    int(((bits shr 24) and 0x80) or ((bits shr 19) and 0x7F))
  else:
    -1

proc encodeStretchedImm*(value: uint64): int =
  ## 64-bit vector (movi d2) immediate, or -1. Port of dynasm-rs
  ## encode_stretched_immediate.
  var test = value and 0x0101010101010101'u64
  test = test or (test shl 1)
  test = test or (test shl 2)
  test = test or (test shl 4)
  if test != value:
    return -1
  var masked = value and 0x8040201008040201'u64
  masked = masked or (masked shr 32)
  masked = masked or (masked shr 16)
  masked = masked or (masked shr 8)
  int(uint32(masked) and 0xFF'u32)

# --------------------------------------------------------------------------
# Immediate helpers (port of dynasm-rs runtime/src/aarch64.rs)
# --------------------------------------------------------------------------

proc encodeWide64*(value: uint64): int =
  ## MOVZ/MOVK-style 64-bit immediate, or -1. Encoded as
  ## imm16 | hw-shift (rs encode_wide_immediate_64bit).
  let offset = int(countTrailingZeroBits(value) and 0b110000)
  let masked = 0xFFFF'u64 and (value shr offset)
  if (masked shl offset) == value:
    int(masked) or (offset shl 12)
  else:
    -1

proc encodeWide32*(value: uint32): int =
  let offset = int(countTrailingZeroBits(value) and 0b010000)
  let masked = 0xFFFF'u32 and (value shr offset)
  if (masked shl offset) == value:
    int(masked) or (offset shl 12)
  else:
    -1

proc encodeLogical32*(value: uint32): int =
  ## Logical (ORR/AND/EOR) 32-bit immediate N:immr:imms, or -1.
  let transitions = value xor rotR32(value, 1)
  let ones = int(countSetBits(transitions))
  if ones == 0: return -1
  let elementSize = int(64'u32 div uint32(ones))
  if value != rotL32(value, elementSize mod 32): return -1
  let element =
    if elementSize >= 32: value
    else: value and ((1'u32 shl elementSize) - 1)
  let nOnes = int(countSetBits(element))
  if nOnes == 0: return -1
  let imms = int((not ((uint32(elementSize) shl 1) - 1) and 0x3F'u32) or
    uint32(nOnes - 1))
  var immr: int
  if (element and 1) != 0:
    immr = nOnes - int(countTrailingZeroBits(not element))
  else:
    immr = elementSize - int(countTrailingZeroBits(element))
  (immr shl 6) or imms

proc encodeLogical64*(value: uint64): int =
  ## 64-bit logical immediate N:immr:imms packed in 13 bits, or -1.
  let transitions = value xor rotR64(value, 1)
  let ones = int(countSetBits(transitions))
  if ones == 0: return -1
  let elementSize = int(128'u64 div uint64(ones))
  if value != rotL64(value, elementSize mod 64): return -1
  let element =
    if elementSize >= 64: value
    else: value and ((1'u64 shl elementSize) - 1)
  let nOnes = int(countSetBits(element))
  if nOnes == 0: return -1
  var imms = int((not ((uint64(elementSize) shl 1) - 1) and 0x7F'u64) or
    uint64(nOnes - 1))
  var immr: int
  if (element and 1) != 0:
    immr = nOnes - int(countTrailingZeroBits(not element))
  else:
    immr = elementSize - int(countTrailingZeroBits(element))
  let n = (imms and 0x40) == 0
  imms = imms and 0x3F
  ((if n: 1 else: 0) shl 12) or (immr shl 6) or imms

# --------------------------------------------------------------------------
# Relocation emission (Offset command)
# --------------------------------------------------------------------------

proc a64Reloc*(a: var auto, lr: LabelRef, rel: int) =
  ## Register a PC-relative fixup on the just-emitted word.
  ## fieldOffset=4, refOffset=4: value = target - instruction address.
  let enc = encodeAarchReloc(rel)
  case lr.lkind
  of lrForward: a.forwardReloc(lr.lname, lr.loff, 4, 4, enc)
  of lrBackward: a.backwardReloc(lr.lname, lr.loff, 4, 4, enc)
  of lrGlobal: a.globalReloc(lr.lname, lr.loff, 4, 4, enc)
  of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, 4, 4, enc)
  of lrAbsolute:
    raise impossibleRelocation(
      "aarch64 branches need label targets, not absolute addresses")

# --------------------------------------------------------------------------
# Register forms: R(0), R(5), R(16), R(10)
# --------------------------------------------------------------------------

proc a64RRR*(a: var auto, base: uint32, rd, rn, rm: Register) =
  emitWord(a, base or rcode(rd) or (rcode(rn) shl 5) or
    (rcode(rm) shl 16))

proc a64RR*(a: var auto, base: uint32, rd, rm: Register) =
  ## R(0), R(16): mov (ORR), mvn.
  emitWord(a, base or rcode(rd) or (rcode(rm) shl 16))

proc a64RRn*(a: var auto, base: uint32, rd, rn: Register) =
  ## R(0), R(5): two-operand FP (fmov, fneg, scvtf, ...).
  emitWord(a, base or rcode(rd) or (rcode(rn) shl 5))

proc a64XRR*(a: var auto, base: uint32, rn, rm: Register) =
  ## R(5), R(16): cmp/tst (shifted register, XZR dest baked in base).
  emitWord(a, base or (rcode(rn) shl 5) or (rcode(rm) shl 16))

proc a64RRRR*(a: var auto, base: uint32, rd, rn, rm, ra: Register) =
  ## +R(10): madd/msub.
  emitWord(a, base or rcode(rd) or (rcode(rn) shl 5) or
    (rcode(rm) shl 16) or (rcode(ra) shl 10))

# --------------------------------------------------------------------------
# Data-processing immediates
# --------------------------------------------------------------------------

proc a64RRI12*(a: var auto, base: uint32, rd, rn: Register, imm: int64,
    shift: int64) =
  ## ADD/SUB (immediate): Ubits(10,12) + Ulist(22,[0,12]).
  if imm < 0 or imm > 4095:
    raise badImm("add/sub immediate " & $imm & " out of range 0-4095")
  if shift != 0 and shift != 12:
    raise badImm("add/sub shift must be lsl #0 or lsl #12")
  var w = base or rcode(rd) or (rcode(rn) shl 5) or
    ((uint32(imm) and 0xFFF'u32) shl 10)
  if shift == 12: w = w or (1'u32 shl 22)
  emitWord(a, w)

proc a64RRSh*(a: var auto, base: uint32, rd, rn, rm: Register,
    shift, amt: int64, is64: bool) =
  ## Shifted/rotated register: Rotates(22) + Ubits(10,6/5).
  ## shift: 0=lsl, 1=lsr, 2=asr, 3=ror.
  let top: int64 = if is64: 63 else: 31
  if shift < 0 or shift > 3:
    raise badImm("bad shift kind")
  if amt < 0 or amt > top:
    raise badImm("shift amount " & $amt & " out of range 0-" & $top)
  emitWord(a, base or rcode(rd) or (rcode(rn) shl 5) or
    (rcode(rm) shl 16) or (uint32(shift) shl 22) or
    ((uint32(amt) and 0x3F'u32) shl 10))

proc a64LogicI*(a: var auto, base: uint32, rd, rn: Register,
    imm: uint64, is64: bool) =
  ## AND/ORR/EOR (immediate): Special LOGICAL_IMMEDIATE.
  let enc =
    if is64: encodeLogical64(imm)
    else: encodeLogical32(uint32(imm and 0xFFFFFFFF'u64))
  if enc < 0:
    raise badImm("unrepresentable logical immediate")
  emitWord(a, base or rcode(rd) or (rcode(rn) shl 5) or
    ((uint32(enc) and 0x1FFF'u32) shl 10))

proc a64MovI*(a: var auto, rd: Register, imm: uint64, is64: bool) =
  ## Plain `mov` with immediate: MOVZ pattern only (rs WIDE_IMMEDIATE),
  ## i.e. a single 16-bit halfword slice. Anything else is an error
  ## (use mov.logical / explicit movz+movk for the rest).
  let enc =
    if is64: encodeWide64(imm)
    else: encodeWide32(uint32(imm and 0xFFFFFFFF'u64))
  if enc < 0:
    raise badImm("mov immediate needs a single 16-bit slice; " &
      "use movz+movk or mov.logical")
  let base = if is64: 0xD2800000'u32 else: 0x52800000'u32
  emitWord(a, base or rcode(rd) or ((uint32(enc) and 0x1FFFFF'u32) shl 5))

proc a64MovInv*(a: var auto, rd: Register, imm: uint64, is64: bool) =
  ## `mov.inverted`: MOVN pattern over the bitwise complement.
  let enc =
    if is64: encodeWide64(not imm)
    else: encodeWide32(not uint32(imm and 0xFFFFFFFF'u64))
  if enc < 0:
    raise badImm("mov.inverted immediate complement needs a single " &
      "16-bit slice")
  let base = if is64: 0x92800000'u32 else: 0x12800000'u32
  emitWord(a, base or rcode(rd) or ((uint32(enc) and 0x1FFFFF'u32) shl 5))

proc a64MovLogic*(a: var auto, rd: Register, imm: uint64, is64: bool) =
  ## `mov.logical`: ORR with a bitmask immediate (Rn=XZR baked in
  ## the base; the passed XZR ORs back to the same bits).
  let base = if is64: 0xB20003E0'u32 else: 0x330003E0'u32
  a64LogicI(a, base, rd,
    Register(code: 31, cls: rcGpr), imm, is64)

proc a64MovWide*(a: var auto, base: uint32, rd: Register,
    imm16: uint64, shiftAmt: int64, is64: bool) =
  ## movz/movn/movk: Ubits(5,16) + Ulist(21,[0,16(,32,48)]).
  if imm16 > 0xFFFF'u64:
    raise badImm("movz/movn/movk immediate out of range 0-65535")
  if shiftAmt != 0 and shiftAmt != 16 and
      not (is64 and (shiftAmt == 32 or shiftAmt == 48)):
    raise badImm("movz/movn/movk shift must be lsl #0/16" &
      (if is64: "/32/48" else: ""))
  let hw = int(shiftAmt div 16)
  emitWord(a, base or rcode(rd) or
    ((uint32(imm16) and 0xFFFF'u32) shl 5) or (uint32(hw) shl 21))

# --------------------------------------------------------------------------
# Scalar FP and SIMD
# --------------------------------------------------------------------------

proc a64FmovI*(a: var auto, base: uint32, rd: Register,
    bits: uint32) =
  ## fmov S/D, #imm: Special FLOAT_IMMEDIATE at 13.
  let enc = encodeFloatImm(bits)
  if enc < 0:
    raise badImm("unrepresentable fmov immediate")
  emitWord(a, base or rcode(rd) or ((uint32(enc) and 0xFF'u32) shl 13))

proc a64Fcmp0*(a: var auto, base: uint32, rn: Register) =
  ## fcmp/fcmpe with #0.0: Rm field stays zero.
  emitWord(a, base or (rcode(rn) shl 5))

proc a64VecRRR*(a: var auto, base: uint32, rd, rn, rm: Register,
    is128: bool) =
  ## Vector ALU (add/sub/mul/and/orr/eor/bic, fadd/...): RRR + Q bit.
  var w = base or rcode(rd) or (rcode(rn) shl 5) or
    (rcode(rm) shl 16)
  if is128: w = w or (1'u32 shl 30)
  emitWord(a, w)

proc a64VecRR*(a: var auto, base: uint32, rd, rn: Register,
    is128: bool) =
  ## Vector 2-operand (fneg/fabs/fsqrt scalar uses fRR; vector
  ## forms go through here for the Q bit).
  var w = base or rcode(rd) or (rcode(rn) shl 5)
  if is128: w = w or (1'u32 shl 30)
  emitWord(a, w)

proc a64Movi*(a: var auto, base: uint32, rd: Register, imm: uint64,
    shift: int64, isH: bool, is128: bool) =
  ## movi Vn.4S/2S/H, #imm8 (, lsl): imm split over [9:5]+[18:16],
  ## shift/8 index at [14:13], Q bit at 30. H takes lsl #0/#8,
  ## S takes lsl #0/#8/#16/#24 (rs Ulist rows).
  if imm > 0xFF'u64:
    raise badImm("movi immediate out of range 0-255")
  if isH:
    if shift != 0 and shift != 8:
      raise badImm("movi shift must be lsl #0 or lsl #8")
  elif shift != 0 and shift != 8 and shift != 16 and shift != 24:
    raise badImm("movi shift must be lsl #0/#8/#16/#24")
  let u = uint32(imm)
  var w = base or rcode(rd) or ((u and 0x1F'u32) shl 5) or
    (((u shr 5) and 0x7'u32) shl 16) or
    ((uint32(shift div 8) and 3'u32) shl 13)
  if is128: w = w or (1'u32 shl 30)
  emitWord(a, w)

proc a64MoviD*(a: var auto, base: uint32, rd: Register, imm: uint64,
    is128: bool) =
  ## movi Dn/2D, #stretched: STRETCHED_IMMEDIATE split over
  ## [9:5]+[18:16], Q bit at 30.
  let enc = encodeStretchedImm(imm)
  if enc < 0:
    raise badImm("unrepresentable movi 64-bit immediate")
  let u = uint32(enc)
  var w = base or rcode(rd) or ((u and 0x1F'u32) shl 5) or
    (((u shr 5) and 0x7'u32) shl 16)
  if is128: w = w or (1'u32 shl 30)
  emitWord(a, w)

proc a64DupG*(a: var auto, base: uint32, rd, rn: Register,
    is128: bool) =
  ## dup Vn.<arr>, Rn/Wn: R(0), R(5), Q bit.
  var w = base or rcode(rd) or (rcode(rn) shl 5)
  if is128: w = w or (1'u32 shl 30)
  emitWord(a, w)

# --------------------------------------------------------------------------
# Bitfield shifts (lsl/lsr/asr immediate aliases)
# --------------------------------------------------------------------------

proc a64BfmI*(a: var auto, base: uint32, rd, rn: Register, amt: int64,
    is64: bool, op: int) =
  ## op: 0=lsl (Usubmod+Usubzero), 1=lsr, 2=asr (Ubits, imms in base).
  let n: int64 = if is64: 64 else: 32
  let mask: int64 = n - 1
  var immr, imms: int64
  if op == 0:
    if amt < 1 or amt > n:
      raise badImm("lsl amount out of range 1-" & $n)
    immr = (n - amt) and mask
    imms = (n - amt - 1) and mask
  else:
    if amt < 0 or amt > mask:
      raise badImm("lsr/asr amount out of range 0-" & $mask)
    immr = amt
    imms = -1 # baked into base; ignored
  var w = base or rcode(rd) or (rcode(rn) shl 5) or
    ((uint32(immr) and 0x3F'u32) shl 16)
  if op == 0:
    w = w or ((uint32(imms) and 0x3F'u32) shl 10)
  emitWord(a, w)

# --------------------------------------------------------------------------
# Loads, stores, pairs
# --------------------------------------------------------------------------

proc a64MemU*(a: var auto, base: uint32, rt, rn: Register, off: int64,
    scale: int) =
  ## Unsigned-offset ldr/str: Uscaled(10,12,scale). Scale is 3 for
  ## 64-bit transfers, 2 for 32-bit (picked statically by the macro).
  if off < 0 or (off and int64((1 shl scale) - 1)) != 0 or
      (off shr scale) > 4095:
    raise badImm("load/store offset out of range or misaligned")
  emitWord(a, base or rcode(rt) or (rcode(rn) shl 5) or
    ((uint32(off shr scale) and 0xFFF'u32) shl 10))

proc a64Mem9*(a: var auto, base: uint32, rt, rn: Register, off: int64) =
  ## Pre/post-index ldr/str: Sbits(12,9), range -256..255.
  if off < -256 or off > 255:
    raise badImm("pre/post-index offset out of range -256..255")
  emitWord(a, base or rcode(rt) or (rcode(rn) shl 5) or
    ((uint32(off) and 0x1FF'u32) shl 12))

proc a64Pair*(a: var auto, base: uint32, rt1, rt2, rn: Register,
    off: int64, scale: int) =
  ## ldp/stp: Sscaled(15,7,scale), range +-64 scaled units
  ## (scale picked statically by the macro: 3 for X, 2 for W).
  if (off and int64((1 shl scale) - 1)) != 0 or
      (off shr scale) < -64 or (off shr scale) > 63:
    raise badImm("pair offset out of range or misaligned")
  emitWord(a, base or rcode(rt1) or (rcode(rt2) shl 10) or
    (rcode(rn) shl 5) or ((uint32(off shr scale) and 0x7F'u32) shl 15))

proc a64MemX*(a: var auto, base: uint32, rt, rn, rm: Register,
    ext, amt: int64, scale: int) =
  ## Register-offset ldr/str: ExtendsX(13) + S bit at 12.
  ## ext: 0=lsl, 1=sxtx (64-bit index); 2=sxtw, 4=uxtw (32-bit index).
  let opt =
    case ext
    of 0: 0b011'u32
    of 1: 0b111'u32
    of 2: 0b110'u32
    of 4: 0b010'u32
    else:
      raise badImm("bad extend for register offset")
  if amt != 0 and amt != scale:
    raise badImm("register offset amount must be 0 or " & $scale)
  let s = if amt != 0: 1'u32 else: 0'u32
  emitWord(a, base or rcode(rt) or (rcode(rn) shl 5) or
    (rcode(rm) shl 16) or (opt shl 13) or (s shl 12))

# --------------------------------------------------------------------------
# Branches, calls, system
# --------------------------------------------------------------------------

proc a64BrLbl*(a: var auto, base: uint32, lr: LabelRef, rel: int) =
  ## b/bl/b.cond/ldr-literal: Offset(B/BCOND) on a zero field.
  emitWord(a, base)
  a64Reloc(a, lr, rel)

proc a64Cbx*(a: var auto, base: uint32, rt: Register, lr: LabelRef) =
  ## cbz/cbnz: R(0) + Offset(BCOND).
  emitWord(a, base or rcode(rt))
  a64Reloc(a, lr, AarchBCond)

proc a64Tbx*(a: var auto, base: uint32, rt: Register, bit: int64,
    lr: LabelRef, is64: bool) =
  ## tbz/tbnz: bit split over 19-23 (+31 for 64-bit).
  let top: int64 = if is64: 63 else: 31
  if bit < 0 or bit > top:
    raise badImm("tbz/tbnz bit out of range 0-" & $top)
  var w = base or rcode(rt) or ((uint32(bit and 31)) shl 19)
  if is64:
    w = w or ((uint32((bit shr 5) and 1)) shl 31)
  emitWord(a, w)
  a64Reloc(a, lr, AarchTbz)

proc a64Adr*(a: var auto, base: uint32, rd: Register, lr: LabelRef,
    isAdrp: bool) =
  emitWord(a, base or rcode(rd))
  a64Reloc(a, lr, if isAdrp: AarchAdrp else: AarchAdr)

proc a64BrReg*(a: var auto, base: uint32, rn: Register) =
  ## br/blr/ret reg: R(5).
  emitWord(a, base or (rcode(rn) shl 5))

proc a64Misc*(a: var auto, base: uint32) =
  emitWord(a, base)

proc a64Hlt*(a: var auto, base: uint32, imm: int64) =
  ## hlt/svc: Ubits(5,16).
  if imm < 0 or imm > 0xFFFF:
    raise badImm("hlt/svc immediate out of range 0-65535")
  emitWord(a, base or ((uint32(imm) and 0xFFFF'u32) shl 5))
