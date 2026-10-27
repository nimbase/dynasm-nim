## x64/x86 instruction encoder (common subset).
## Covers integer moves, ALU, stack, jumps/calls, enough for hello-world/bf-jit.

import ./types
import ./relocations
import ./registers
import ./labels

template emitRexIfNeeded*(a: untyped, w, r, x, b: bool,
    extraForce: bool = false) =
  if w or r or x or b or extraForce:
    var v = 0x40'u8
    if w: v = v or 8'u8
    if r: v = v or 4'u8
    if x: v = v or 2'u8
    if b: v = v or 1'u8
    a.push(v)

proc modrmByte(m, reg, rm: uint8): byte =
  cast[uint8]((m shl 6) or ((reg and 7) shl 3) or (rm and 7))

proc sibByte(scale, index, base: uint8): byte =
  cast[uint8]((scale shl 6) or ((index and 7) shl 3) or (base and 7))

proc scaleBits(scale: int): uint8 =
  case scale
  of 1: 0
  of 2: 1
  of 4: 2
  of 8: 3
  else:
    raise impossibleRelocation("bad scale")

proc isHigh8(reg: Register): bool = reg.cls == rcHigh8
proc isLow8NeedingRex(reg: Register): bool =
  reg.cls == rcGpr and reg.code >= 4 and reg.code <= 7

# --------------------------------------------------------------------------
# Memory operand emission
# --------------------------------------------------------------------------

proc emitMemModRMSIB(a: var auto, mem: MemOp, regField: uint8,
    isX64: bool) =
  if mem.hasRip:
    a.push(modrmByte(0, regField, 5))
    a.push(0'u8); a.push(0'u8); a.push(0'u8); a.push(0'u8)
    let enc = encodeKind(rkRelative, rsDWord)
    let lr = mem.ripLabel
    case lr.lkind
    of lrForward: a.forwardReloc(lr.lname, lr.loff, 4, 0, enc)
    of lrBackward: a.backwardReloc(lr.lname, lr.loff, 4, 0, enc)
    of lrGlobal: a.globalReloc(lr.lname, lr.loff, 4, 0, enc)
    of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, 4, 0, enc)
    of lrAbsolute:
      let enc2 = encodeKind(rkRelToAbs, rsDWord)
      a.valueReloc(lr.dynId, 4, 0, enc2)
    return

  let hasBase = mem.hasBase
  let hasIndex = mem.hasIndex
  let baseCode =
    if hasBase: mem.base.code and 7 else: 0'u8
  let indexCode =
    if hasIndex: mem.index.code and 7 else: 0'u8

  if not hasBase and not hasIndex:
    a.push(modrmByte(0, regField, 4))
    a.push(sibByte(0, 4, 5))
    a.pushU32(uint32(cast[int32](mem.disp)))
    return

  if not hasBase and hasIndex:
    raise impossibleRelocation("index without base")

  let needSib = hasIndex or ((mem.base.code and 7) == 4)
  var m: uint8 = 0
  var useDisp8 = false
  var useDisp32 = false
  if mem.hasDisp:
    if mem.disp >= -128 and mem.disp <= 127:
      useDisp8 = true
      m = 1
    else:
      useDisp32 = true
      m = 2
  else:
    if (mem.base.code and 7) == 5:
      useDisp8 = true
      m = 1
    else:
      m = 0

  if needSib:
    a.push(modrmByte(m, regField, 4))
    let sc: uint8 =
      if hasIndex: scaleBits(mem.scale) else: 0'u8
    let idx: uint8 =
      if hasIndex: indexCode else: 4'u8
    a.push(sibByte(sc, idx, baseCode))
  else:
    a.push(modrmByte(m, regField, baseCode))

  if useDisp8:
    let d: int8 =
      if mem.hasDisp: int8(mem.disp) else: 0'i8
    a.push(cast[uint8](d))
  elif useDisp32:
    a.pushU32(uint32(cast[int32](mem.disp)))
  elif m == 1 and not mem.hasDisp:
    a.push(0'u8)

proc rexForRM(w: bool, reg, rm: Register, mem: MemOp,
    usesMem: bool): tuple[w, r, x, b: bool, force: bool] =
  var r = (reg.code and 8) != 0
  var b, x: bool
  var force = false
  if usesMem:
    if mem.hasBase and (mem.base.code and 8) != 0: b = true
    if mem.hasIndex and (mem.index.code and 8) != 0: x = true
    if mem.hasBase and isLow8NeedingRex(mem.base): force = true
    if mem.hasIndex and isLow8NeedingRex(mem.index): force = true
    if isLow8NeedingRex(reg): force = true
    if isHigh8(reg) or (mem.hasBase and isHigh8(mem.base)) or
        (mem.hasIndex and isHigh8(mem.index)):
      if w or r or x or b or force:
        raise impossibleRelocation("AH/CH/DH/BH cannot use REX")
  else:
    b = (rm.code and 8) != 0
    if isLow8NeedingRex(reg) or isLow8NeedingRex(rm): force = true
    if isHigh8(reg) or isHigh8(rm):
      if w or r or b or force:
        raise impossibleRelocation("high-byte reg with REX")
  (w, r, x, b, force)

# --------------------------------------------------------------------------
# Instruction encoders
# --------------------------------------------------------------------------

proc encNop*(a: var auto) =
  a.push(0x90'u8)

proc encRet*(a: var auto) =
  a.push(0xC3'u8)

proc encInt3*(a: var auto) =
  a.push(0xCC'u8)

proc encPushReg*(a: var auto, reg: Register, isX64: bool) =
  let b = (reg.code and 8) != 0
  if isHigh8(reg):
    raise impossibleRelocation("cannot push high-byte reg")
  if isX64 and b:
    a.push(0x41'u8)
  a.push(cast[uint8](0x50 or (reg.code and 7)))

proc encPushMem*(a: var auto, mem: MemOp, size: OpSize, isX64: bool) =
  ## PUSH m16/m64: FF /6. 8/32-bit memory pushes do not exist.
  if size != sz16 and size != sz64:
    raise impossibleRelocation("push memory needs 16/64-bit size")
  if size == sz16:
    a.push(0x66'u8)
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  emitRexIfNeeded(a, false, false, x, b)
  a.push(0xFF'u8)
  emitMemModRMSIB(a, mem, 6, isX64)

proc encPopReg*(a: var auto, reg: Register, isX64: bool) =
  let b = (reg.code and 8) != 0
  if isX64 and b:
    a.push(0x41'u8)
  a.push(cast[uint8](0x58 or (reg.code and 7)))

proc encMovRegReg*(a: var auto, dst, src: Register, size: OpSize) =
  let w = size == sz64
  if size == sz16:
    a.push(0x66'u8)
  let t = rexForRM(w, dst, src, MemOp(hasBase: false), false)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x8B'u8)
  a.push(modrmByte(3, dst.code and 7, src.code and 7))

proc encMovRegImmAbs*(a: var auto, dst: Register, imm: int64) =
  ## Unconditional 10-byte REX.W B8+rd io form (true movabs).
  ## Used for explicit `movabs`; plain `mov` prefers the shorter
  ## zero/sign-extended forms below when the value allows it.
  let b = (dst.code and 8) != 0
  emitRexIfNeeded(a, true, false, false, b)
  a.push(cast[uint8](0xB8 or (dst.code and 7)))
  let u = cast[uint64](imm)
  a.push(cast[uint8](u and 0xFF))
  a.push(cast[uint8]((u shr 8) and 0xFF))
  a.push(cast[uint8]((u shr 16) and 0xFF))
  a.push(cast[uint8]((u shr 24) and 0xFF))
  a.push(cast[uint8]((u shr 32) and 0xFF))
  a.push(cast[uint8]((u shr 40) and 0xFF))
  a.push(cast[uint8]((u shr 48) and 0xFF))
  a.push(cast[uint8]((u shr 56) and 0xFF))

proc encMovRegImm*(a: var auto, dst: Register, imm: int64, size: OpSize) =
  if size == sz8:
    let b = (dst.code and 8) != 0
    let force = isLow8NeedingRex(dst)
    if not isHigh8(dst):
      emitRexIfNeeded(a, false, false, false, b, force)
    a.push(cast[uint8](0xB0 or (dst.code and 7)))
    a.push(cast[uint8](imm))
  elif size == sz64 and imm >= 0 and imm <= 0xFFFF_FFFF'i64:
    # mov r32, imm32 zero-extends into the full register, so for
    # non-negative values fitting in 32 bits this 5-byte form is
    # semantically identical to the 10-byte movabs (and, unlike
    # xor-zeroing, never touches flags).
    let b = (dst.code and 8) != 0
    emitRexIfNeeded(a, false, false, false, b)
    a.push(cast[uint8](0xB8 or (dst.code and 7)))
    a.pushU32(cast[uint32](imm))
  elif size == sz64 and imm >= -0x8000_0000'i64 and imm < 0:
    # mov r/m64, imm32 sign-extends: identical 7-byte form for
    # negative values fitting in int32.
    let b = (dst.code and 8) != 0
    emitRexIfNeeded(a, true, false, false, b)
    a.push(0xC7'u8)
    a.push(modrmByte(3, 0, dst.code and 7))
    a.pushU32(cast[uint32](imm))
  else:
    if size == sz16:
      a.push(0x66'u8)
    let w = size == sz64
    let b = (dst.code and 8) != 0
    emitRexIfNeeded(a, w, false, false, b)
    a.push(cast[uint8](0xB8 or (dst.code and 7)))
    case size
    of sz16:
      a.pushU16(cast[uint16](imm))
    of sz32:
      a.pushU32(cast[uint32](imm))
    of sz64:
      # Only reachable for values needing all 64 bits (the fast
      # paths above handle the rest); REX.W + B8 already emitted.
      let u = cast[uint64](imm)
      a.push(cast[uint8](u and 0xFF))
      a.push(cast[uint8]((u shr 8) and 0xFF))
      a.push(cast[uint8]((u shr 16) and 0xFF))
      a.push(cast[uint8]((u shr 24) and 0xFF))
      a.push(cast[uint8]((u shr 32) and 0xFF))
      a.push(cast[uint8]((u shr 40) and 0xFF))
      a.push(cast[uint8]((u shr 48) and 0xFF))
      a.push(cast[uint8]((u shr 56) and 0xFF))
    else:
      discard

proc encMovRegMem*(a: var auto, dst: Register, mem: MemOp, size: OpSize,
    isX64: bool) =
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, dst, Register(code: 0, cls: rcGpr), mem, true)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  if size == sz8:
    a.push(0x8A'u8)
  else:
    a.push(0x8B'u8)
  emitMemModRMSIB(a, mem, dst.code and 7, isX64)

proc encMovMemReg*(a: var auto, mem: MemOp, src: Register, size: OpSize,
    isX64: bool) =
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, src, Register(code: 0, cls: rcGpr), mem, true)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  if size == sz8:
    a.push(0x88'u8)
  else:
    a.push(0x89'u8)
  emitMemModRMSIB(a, mem, src.code and 7, isX64)

proc encMovMemImm*(a: var auto, mem: MemOp, imm: int64, size: OpSize,
    isX64: bool) =
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  var b, x: bool
  var force = false
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  if mem.hasBase and isLow8NeedingRex(mem.base): force = true
  if mem.hasIndex and isLow8NeedingRex(mem.index): force = true
  emitRexIfNeeded(a, w, false, x, b, force)
  if size == sz8:
    a.push(0xC6'u8)
  else:
    a.push(0xC7'u8)
  emitMemModRMSIB(a, mem, 0, isX64)
  case size
  of sz8:
    a.push(cast[uint8](imm))
  of sz16:
    a.pushU16(cast[uint16](imm))
  of sz32:
    a.pushU32(cast[uint32](imm))
  of sz64:
    a.pushU32(cast[uint32](imm))
  else:
    discard

proc encLeaSized*(a: var auto, dst: Register, dstSize: OpSize, mem: MemOp,
    isX64: bool) =
  if dstSize == sz16:
    a.push(0x66'u8)
  let w = dstSize == sz64 and isX64
  let t = rexForRM(w, dst, Register(code: 0, cls: rcGpr), mem, true)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x8D'u8)
  emitMemModRMSIB(a, mem, dst.code and 7, isX64)

proc aluCodes(mn: string): tuple[mr: byte, digit: uint8] =
  case mn
  of "add": (0x01'u8, 0'u8)
  of "or": (0x09'u8, 1'u8)
  of "and": (0x21'u8, 4'u8)
  of "sub": (0x29'u8, 5'u8)
  of "xor": (0x31'u8, 6'u8)
  of "cmp": (0x39'u8, 7'u8)
  else:
    raise impossibleRelocation("unknown ALU " & mn)

proc encAluRegReg*(a: var auto, mn: string, dst, src: Register, size: OpSize) =
  let c = aluCodes(mn)
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, src, dst, MemOp(hasBase: false), false)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  if size == sz8:
    a.push(cast[uint8](c.mr - 1))
  else:
    a.push(c.mr)
  a.push(modrmByte(3, src.code and 7, dst.code and 7))

proc encAluRegImm*(a: var auto, mn: string, dst: Register, imm: int64,
    size: OpSize) =
  let c = aluCodes(mn)
  if size == sz8:
    let force = isLow8NeedingRex(dst)
    if not isHigh8(dst):
      emitRexIfNeeded(a, false, false, false,
        (dst.code and 8) != 0, force)
    a.push(0x80'u8)
    a.push(modrmByte(3, c.digit, dst.code and 7))
    a.push(cast[uint8](imm))
  else:
    if size == sz16:
      a.push(0x66'u8)
    let w = size == sz64
    let b = (dst.code and 8) != 0
    emitRexIfNeeded(a, w, false, false, b)
    if imm >= -128 and imm <= 127:
      a.push(0x83'u8)
      a.push(modrmByte(3, c.digit, dst.code and 7))
      a.push(cast[uint8](imm))
    else:
      a.push(0x81'u8)
      a.push(modrmByte(3, c.digit, dst.code and 7))
      case size
      of sz16:
        a.pushU16(cast[uint16](imm))
      else:
        a.pushU32(cast[uint32](imm))

proc encAluMemReg*(a: var auto, mn: string, mem: MemOp, src: Register,
    size: OpSize, isX64: bool) =
  let c = aluCodes(mn)
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, src, Register(code: 0, cls: rcGpr), mem, true)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  if size == sz8:
    a.push(cast[uint8](c.mr - 1))
  else:
    a.push(c.mr)
  emitMemModRMSIB(a, mem, src.code and 7, isX64)

proc encAluRegMem*(a: var auto, mn: string, dst: Register, mem: MemOp,
    size: OpSize, isX64: bool) =
  let c = aluCodes(mn)
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, dst, Register(code: 0, cls: rcGpr), mem, true)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  if size == sz8:
    a.push(cast[uint8](c.mr + 1))
  else:
    a.push(cast[uint8](c.mr + 2))
  emitMemModRMSIB(a, mem, dst.code and 7, isX64)

proc encAluMemImm*(a: var auto, mn: string, mem: MemOp, imm: int64,
    size: OpSize, isX64: bool) =
  let c = aluCodes(mn)
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  emitRexIfNeeded(a, w, false, x, b)
  if size == sz8:
    a.push(0x80'u8)
    emitMemModRMSIB(a, mem, c.digit, isX64)
    a.push(cast[uint8](imm))
  else:
    if imm >= -128 and imm <= 127:
      a.push(0x83'u8)
      emitMemModRMSIB(a, mem, c.digit, isX64)
      a.push(cast[uint8](imm))
    else:
      a.push(0x81'u8)
      emitMemModRMSIB(a, mem, c.digit, isX64)
      case size
      of sz16:
        a.pushU16(cast[uint16](imm))
      else:
        a.pushU32(cast[uint32](imm))

proc encIncDec*(a: var auto, mn: string, reg: Register, size: OpSize) =
  let digit: uint8 =
    if mn == "inc": 0 else: 1
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let b = (reg.code and 8) != 0
  emitRexIfNeeded(a, w, false, false, b)
  if size == sz8:
    a.push(0xFE'u8)
  else:
    a.push(0xFF'u8)
  a.push(modrmByte(3, digit, reg.code and 7))

proc encIncDecMem*(a: var auto, mn: string, mem: MemOp, size: OpSize,
    isX64: bool) =
  let digit: uint8 =
    if mn == "inc": 0 else: 1
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  emitRexIfNeeded(a, w, false, x, b)
  if size == sz8:
    a.push(0xFE'u8)
  else:
    a.push(0xFF'u8)
  emitMemModRMSIB(a, mem, digit, isX64)

proc encTestRegReg*(a: var auto, lhs, rhs: Register, size: OpSize) =
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, rhs, lhs, MemOp(hasBase: false), false)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  if size == sz8:
    a.push(0x84'u8)
  else:
    a.push(0x85'u8)
  a.push(modrmByte(3, rhs.code and 7, lhs.code and 7))

proc encJmpShort*(a: var auto, lr: LabelRef)
proc encJccShort*(a: var auto, mn: string, lr: LabelRef)

proc backwardFits8(a: var auto, lr: LabelRef, shortLen: int): bool =
  ## Auto short-jump eligibility: a backward label reference is already
  ## bound at emit time, so when the distance from the end of a
  ## `shortLen`-byte instruction at the current offset fits in int8 we
  ## can emit the 2-byte short form instead of the 5/6-byte long form.
  ## Forward/global/dynamic targets are unknown here: callers keep the
  ## long form for those (single-pass emission, no relaxation).
  if lr.lkind != lrBackward:
    return false
  let pl = a.labels.placeLocalReference(lr.lname)
  if not pl.found:
    return false # invalid code: existing error path reports it below
  var target = 0
  try:
    target = int(a.labels.resolveStatic(pl.label)) + lr.loff
  except DynasmError:
    return false
  let delta = target - (int(a.offset()) + shortLen)
  delta >= -128 and delta <= 127

proc encJmpRel*(a: var auto, lr: LabelRef) =
  if backwardFits8(a, lr, 2):
    encJmpShort(a, lr)
    return
  a.push(0xE9'u8)
  a.push(0'u8); a.push(0'u8); a.push(0'u8); a.push(0'u8)
  let enc = encodeKind(rkRelative, rsDWord)
  case lr.lkind
  of lrForward: a.forwardReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrBackward: a.backwardReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrGlobal: a.globalReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, 4, 0, enc)
  of lrAbsolute:
    raise impossibleRelocation("jmp to absolute needs reg")

proc encJmpShort*(a: var auto, lr: LabelRef) =
  a.push(0xEB'u8)
  a.push(0'u8)
  let enc = encodeKind(rkRelative, rsByte)
  case lr.lkind
  of lrForward: a.forwardReloc(lr.lname, lr.loff, 1, 0, enc)
  of lrBackward: a.backwardReloc(lr.lname, lr.loff, 1, 0, enc)
  of lrGlobal: a.globalReloc(lr.lname, lr.loff, 1, 0, enc)
  of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, 1, 0, enc)
  of lrAbsolute:
    raise impossibleRelocation("jmp short absolute")

proc encJmpReg*(a: var auto, reg: Register) =
  let b = (reg.code and 8) != 0
  emitRexIfNeeded(a, false, false, false, b)
  a.push(0xFF'u8)
  a.push(modrmByte(3, 4, reg.code and 7))

proc encJmpMem*(a: var auto, mem: MemOp, isX64: bool) =
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  emitRexIfNeeded(a, false, false, x, b)
  a.push(0xFF'u8)
  emitMemModRMSIB(a, mem, 4, isX64)

proc jccCode(mn: string): uint8 =
  case mn
  of "jo": 0
  of "jno": 1
  of "jb", "jnae", "jc": 2
  of "jnb", "jae", "jnc": 3
  of "jz", "je": 4
  of "jnz", "jne": 5
  of "jbe", "jna": 6
  of "ja", "jnbe": 7
  of "js": 8
  of "jns": 9
  of "jp", "jpe": 10
  of "jnp", "jpo": 11
  of "jl", "jnge": 12
  of "jge", "jnl": 13
  of "jle", "jng": 14
  of "jg", "jnle": 15
  else:
    raise impossibleRelocation("unknown jcc " & mn)

proc encJcc*(a: var auto, mn: string, lr: LabelRef) =
  let cc = jccCode(mn)
  if backwardFits8(a, lr, 2):
    encJccShort(a, mn, lr)
    return
  a.push(0x0F'u8)
  a.push(cast[uint8](0x80 or cc))
  a.push(0'u8); a.push(0'u8); a.push(0'u8); a.push(0'u8)
  let enc = encodeKind(rkRelative, rsDWord)
  case lr.lkind
  of lrForward: a.forwardReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrBackward: a.backwardReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrGlobal: a.globalReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, 4, 0, enc)
  of lrAbsolute:
    raise impossibleRelocation("jcc absolute")

proc encJccShort*(a: var auto, mn: string, lr: LabelRef) =
  let cc = jccCode(mn)
  a.push(cast[uint8](0x70 or cc))
  a.push(0'u8)
  let enc = encodeKind(rkRelative, rsByte)
  case lr.lkind
  of lrForward: a.forwardReloc(lr.lname, lr.loff, 1, 0, enc)
  of lrBackward: a.backwardReloc(lr.lname, lr.loff, 1, 0, enc)
  of lrGlobal: a.globalReloc(lr.lname, lr.loff, 1, 0, enc)
  of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, 1, 0, enc)
  of lrAbsolute:
    raise impossibleRelocation("jcc short absolute")

proc setccCode(mn: string): uint8 =
  ## SETcc shares condition encodings with Jcc: map setXX -> jXX.
  if mn.len > 3 and mn[0..2] == "set":
    return jccCode("j" & mn[3..^1])
  raise impossibleRelocation("unknown setcc " & mn)

proc encSetccReg*(a: var auto, mn: string, reg: Register) =
  ## SETcc r8: 0F 9x /0. REX.B for r8b-r15b, forced REX for
  ## spl/bpl/sil/dil; AH/CH/DH/BH encode without REX.
  let cc = setccCode(mn)
  var force = isLow8NeedingRex(reg)
  if isHigh8(reg):
    force = false
  let b = (reg.code and 8) != 0
  emitRexIfNeeded(a, false, false, false, b, force)
  a.push(0x0F'u8)
  a.push(cast[uint8](0x90 or cc))
  a.push(modrmByte(3, 0, reg.code and 7))

proc encSetccMem*(a: var auto, mn: string, mem: MemOp, isX64: bool) =
  ## SETcc m8: 0F 9x /0 with a ModRM/SIB memory operand.
  let cc = setccCode(mn)
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  emitRexIfNeeded(a, false, false, x, b)
  a.push(0x0F'u8)
  a.push(cast[uint8](0x90 or cc))
  emitMemModRMSIB(a, mem, 0, isX64)

proc encCallRel*(a: var auto, lr: LabelRef) =
  a.push(0xE8'u8)
  a.push(0'u8); a.push(0'u8); a.push(0'u8); a.push(0'u8)
  let enc = encodeKind(rkRelative, rsDWord)
  case lr.lkind
  of lrForward: a.forwardReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrBackward: a.backwardReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrGlobal: a.globalReloc(lr.lname, lr.loff, 4, 0, enc)
  of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, 4, 0, enc)
  of lrAbsolute:
    raise impossibleRelocation("call absolute needs reg")

proc encCallReg*(a: var auto, reg: Register) =
  let b = (reg.code and 8) != 0
  emitRexIfNeeded(a, false, false, false, b)
  a.push(0xFF'u8)
  a.push(modrmByte(3, 2, reg.code and 7))

proc encCallMem*(a: var auto, mem: MemOp, isX64: bool) =
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  emitRexIfNeeded(a, false, false, x, b)
  a.push(0xFF'u8)
  emitMemModRMSIB(a, mem, 2, isX64)

# --------------------------------------------------------------------------
# Shifts: shl/sal, shr, sar — reg/mem by imm8, by 1, or by cl
# Group 2: /4 shl, /5 shr, /7 sar
# --------------------------------------------------------------------------

proc shiftDigit(mn: string): uint8 =
  case mn
  of "shl", "sal": 4'u8
  of "shr": 5'u8
  of "sar": 7'u8
  else:
    raise impossibleRelocation("unknown shift " & mn)

proc encShiftRegImm*(a: var auto, mn: string, reg: Register, count: int64,
    size: OpSize) =
  let digit = shiftDigit(mn)
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let b = (reg.code and 8) != 0
  var force = isLow8NeedingRex(reg)
  if isHigh8(reg) and (w or b or force):
    raise impossibleRelocation("high-byte reg with REX")
  emitRexIfNeeded(a, w, false, false, b, force)
  if size == sz8:
    a.push(0xC0'u8)
  else:
    a.push(0xC1'u8)
  a.push(modrmByte(3, digit, reg.code and 7))
  a.push(cast[uint8](count and 0xFF))

proc encShiftMemImm*(a: var auto, mn: string, mem: MemOp, count: int64,
    size: OpSize, isX64: bool) =
  let digit = shiftDigit(mn)
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  emitRexIfNeeded(a, w, false, x, b)
  if size == sz8:
    a.push(0xC0'u8)
  else:
    a.push(0xC1'u8)
  emitMemModRMSIB(a, mem, digit, isX64)
  a.push(cast[uint8](count and 0xFF))

proc encShiftRegCl*(a: var auto, mn: string, reg: Register, size: OpSize) =
  let digit = shiftDigit(mn)
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let b = (reg.code and 8) != 0
  var force = isLow8NeedingRex(reg)
  if isHigh8(reg) and (w or b or force):
    raise impossibleRelocation("high-byte reg with REX")
  emitRexIfNeeded(a, w, false, false, b, force)
  if size == sz8:
    a.push(0xD2'u8)
  else:
    a.push(0xD3'u8)
  a.push(modrmByte(3, digit, reg.code and 7))

# --------------------------------------------------------------------------
# IMUL 2-operand: imul dst, src (reg/reg or reg/mem). 0F AF /r
# --------------------------------------------------------------------------

proc encImulRegReg*(a: var auto, dst, src: Register, size: OpSize) =
  if size == sz8 or size == sz16 and false:
    raise impossibleRelocation("imul needs 16/32/64-bit")
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, dst, src, MemOp(hasBase: false), false)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(0xAF'u8)
  a.push(modrmByte(3, dst.code and 7, src.code and 7))

proc encImulRegMem*(a: var auto, dst: Register, mem: MemOp, size: OpSize,
    isX64: bool) =
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, dst, Register(code: 0, cls: rcGpr), mem, true)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(0xAF'u8)
  emitMemModRMSIB(a, mem, dst.code and 7, isX64)

proc encImulRegImm*(a: var auto, dst, src: Register, imm: int64,
    size: OpSize) =
  ## 3-operand imul dst, src, imm8/32: 6B /r ib or 69 /r id
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let t = rexForRM(w, dst, src, MemOp(hasBase: false), false)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  if imm >= -128 and imm <= 127:
    a.push(0x6B'u8)
    a.push(modrmByte(3, dst.code and 7, src.code and 7))
    a.push(cast[uint8](imm))
  else:
    a.push(0x69'u8)
    a.push(modrmByte(3, dst.code and 7, src.code and 7))
    a.pushU32(cast[uint32](imm))

# --------------------------------------------------------------------------
# DIV/IDIV/MUL group (F7 /4 mul, /5 imul1, /6 div, /7 idiv) + NEG/NOT + CQO
# --------------------------------------------------------------------------

proc divDigit(mn: string): uint8 =
  case mn
  of "mul": 4'u8
  of "div": 6'u8
  of "idiv": 7'u8
  of "neg": 3'u8
  of "not": 2'u8
  else:
    raise impossibleRelocation("unknown div-group " & mn)

proc encDivReg*(a: var auto, mn: string, reg: Register, size: OpSize) =
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  let b = (reg.code and 8) != 0
  var force = isLow8NeedingRex(reg)
  if mn in ["neg", "not"] and size == sz8 and isHigh8(reg):
    force = false
  emitRexIfNeeded(a, w, false, false, b, force)
  if size == sz8:
    a.push(0xF6'u8)
  else:
    a.push(0xF7'u8)
  a.push(modrmByte(3, divDigit(mn), reg.code and 7))

proc encDivMem*(a: var auto, mn: string, mem: MemOp, size: OpSize,
    isX64: bool) =
  if size == sz16:
    a.push(0x66'u8)
  let w = size == sz64
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  emitRexIfNeeded(a, w, false, x, b)
  if size == sz8:
    a.push(0xF6'u8)
  else:
    a.push(0xF7'u8)
  emitMemModRMSIB(a, mem, divDigit(mn), isX64)

proc encCqo*(a: var auto, size: OpSize) =
  if size == sz16:
    a.push(0x66'u8)
    a.push(0x99'u8)
  elif size == sz64:
    a.push(0x48'u8)
    a.push(0x99'u8)
  else:
    a.push(0x99'u8)

# --------------------------------------------------------------------------
# MOVZX/MOVSX: zero/sign-extend byte/word mem/reg into wider reg
# --------------------------------------------------------------------------

proc encMovzxRegReg*(a: var auto, dst, src: Register, srcSize: OpSize,
    dstSize: OpSize) =
  if dstSize == sz16:
    a.push(0x66'u8)
  let w = dstSize == sz64
  let r = (dst.code and 8) != 0
  let b = (src.code and 8) != 0
  var force = false
  if isLow8NeedingRex(src): force = true
  if isLow8NeedingRex(dst): force = true
  if isHigh8(src) or isHigh8(dst):
    raise impossibleRelocation("movzx with high-byte reg")
  emitRexIfNeeded(a, w, r, false, b, force)
  a.push(0x0F'u8)
  if srcSize == sz8:
    a.push(0xB6'u8)
  else:
    a.push(0xB7'u8)
  a.push(modrmByte(3, dst.code and 7, src.code and 7))

proc encMovzxRegMem*(a: var auto, dst: Register, mem: MemOp,
    srcSize: OpSize, dstSize: OpSize, isX64: bool) =
  if dstSize == sz16:
    a.push(0x66'u8)
  let w = dstSize == sz64
  var r = (dst.code and 8) != 0
  var b, x: bool
  if mem.hasBase and (mem.base.code and 8) != 0: b = true
  if mem.hasIndex and (mem.index.code and 8) != 0: x = true
  var force = false
  if isLow8NeedingRex(dst): force = true
  if mem.hasBase and isLow8NeedingRex(mem.base): force = true
  if mem.hasIndex and isLow8NeedingRex(mem.index): force = true
  emitRexIfNeeded(a, w, r, x, b, force)
  a.push(0x0F'u8)
  if srcSize == sz8:
    a.push(0xB6'u8)
  else:
    a.push(0xB7'u8)
  emitMemModRMSIB(a, mem, dst.code and 7, isX64)

# --------------------------------------------------------------------------
# SSE scalar double: movsd, addsd/subsd/mulsd/divsd/sqrtsd, ucomisd,
# cvtsi2sd/cvttsd2si, xorpd.
#
# REX.W stays clear (these opcodes ignore it) except in the cvt forms
# where W selects the 32/64-bit integer side. REX.R extends the xmm
# reg field, REX.B/X the GPR r/m side. Memory operands reuse the
# shared ModRM/SIB path, including RIP-relative globals.
# --------------------------------------------------------------------------

proc encSseRegReg*(a: var auto, prefix: uint8, opcode: uint8, dst,
    src: Register) =
  ## Scalar-double ALU / movsd-reg / ucomisd / xorpd reg,reg form.
  ## Canonical byte order: legacy prefix, then REX, then 0F escape.
  let t = rexForRM(false, dst, src, MemOp(hasBase: false), false)
  a.push(prefix)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(opcode)
  a.push(modrmByte(3, dst.code and 7, src.code and 7))

proc encSseRegMem*(a: var auto, prefix: uint8, opcode: uint8, dst: Register,
    mem: MemOp, isX64: bool) =
  ## Scalar-double load / ALU reg,m64 form (also ucomisd reg,m64).
  let t = rexForRM(false, dst, Register(code: 0, cls: rcGpr), mem, true)
  a.push(prefix)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(opcode)
  emitMemModRMSIB(a, mem, dst.code and 7, isX64)

proc encSseMemReg*(a: var auto, prefix: uint8, opcode: uint8, mem: MemOp,
    src: Register, isX64: bool) =
  ## Scalar-double store form (movsd m64, xmm): the ModRM.reg field
  ## holds the xmm source.
  let t = rexForRM(false, src, Register(code: 0, cls: rcGpr), mem, true)
  a.push(prefix)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(opcode)
  emitMemModRMSIB(a, mem, src.code and 7, isX64)

proc sseAluOpcode(mn: string): uint8 =
  case mn
  of "addsd": 0x58'u8
  of "subsd": 0x5C'u8
  of "mulsd": 0x59'u8
  of "divsd": 0x5E'u8
  of "sqrtsd": 0x51'u8
  else:
    raise impossibleRelocation("unknown scalar-double ALU " & mn)

proc encSseAluRegReg*(a: var auto, mn: string, dst, src: Register) =
  encSseRegReg(a, 0xF2'u8, sseAluOpcode(mn), dst, src)

proc encSseAluRegMem*(a: var auto, mn: string, dst: Register, mem: MemOp,
    isX64: bool) =
  encSseRegMem(a, 0xF2'u8, sseAluOpcode(mn), dst, mem, isX64)

proc encMovsdRegReg*(a: var auto, dst, src: Register) =
  encSseRegReg(a, 0xF2'u8, 0x10'u8, dst, src)

proc encMovsdRegMem*(a: var auto, dst: Register, mem: MemOp, isX64: bool) =
  encSseRegMem(a, 0xF2'u8, 0x10'u8, dst, mem, isX64)

proc encMovsdMemReg*(a: var auto, mem: MemOp, src: Register, isX64: bool) =
  encSseMemReg(a, 0xF2'u8, 0x11'u8, mem, src, isX64)

proc encUcomisdRegReg*(a: var auto, lhs, rhs: Register) =
  encSseRegReg(a, 0x66'u8, 0x2E'u8, lhs, rhs)

proc encUcomisdRegMem*(a: var auto, lhs: Register, mem: MemOp,
    isX64: bool) =
  encSseRegMem(a, 0x66'u8, 0x2E'u8, lhs, mem, isX64)

proc encXorpdRegReg*(a: var auto, dst, src: Register) =
  encSseRegReg(a, 0x66'u8, 0x57'u8, dst, src)

proc encCvtsi2sdRegReg*(a: var auto, dst: Register, src: Register,
    srcSize: OpSize) =
  ## int32/int64 -> double. REX.W selects the integer width.
  let w = srcSize == sz64
  let t = rexForRM(w, dst, src, MemOp(hasBase: false), false)
  a.push(0xF2'u8)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(0x2A'u8)
  a.push(modrmByte(3, dst.code and 7, src.code and 7))

proc encCvtsi2sdRegMem*(a: var auto, dst: Register, mem: MemOp,
    memSize: OpSize, isX64: bool) =
  let w = memSize == sz64
  let t = rexForRM(w, dst, Register(code: 0, cls: rcGpr), mem, true)
  a.push(0xF2'u8)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(0x2A'u8)
  emitMemModRMSIB(a, mem, dst.code and 7, isX64)

proc encCvttsd2siRegReg*(a: var auto, dst: Register, dstSize: OpSize,
    src: Register) =
  ## double -> int32/int64 with truncation. REX.W selects the result.
  let w = dstSize == sz64
  let t = rexForRM(w, dst, src, MemOp(hasBase: false), false)
  a.push(0xF2'u8)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(0x2C'u8)
  a.push(modrmByte(3, dst.code and 7, src.code and 7))

proc encCvttsd2siRegMem*(a: var auto, dst: Register, dstSize: OpSize,
    mem: MemOp, isX64: bool) =
  let w = dstSize == sz64
  let t = rexForRM(w, dst, Register(code: 0, cls: rcGpr), mem, true)
  a.push(0xF2'u8)
  emitRexIfNeeded(a, t.w, t.r, t.x, t.b, t.force)
  a.push(0x0F'u8)
  a.push(0x2C'u8)
  emitMemModRMSIB(a, mem, dst.code and 7, isX64)
