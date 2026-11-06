## High-level dispatch used by `dynasm` macro.
## Takes runtime Operand values and calls correct encoder.

import ./types
import ./relocations
import ./registers
import ./encoder

proc defaultRegSizeForMem*(explicit: OpSize, other: OpSize): OpSize =
  if explicit != szNone: explicit
  else: other

proc dynasmMov*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    let sz = if dst.regSize != szNone: dst.regSize
             elif src.regSize != szNone: src.regSize
             else: sz64
    if dst.reg.cls != rcGpr or src.reg.cls != rcGpr:
      raise impossibleRelocation("mov only supports GPR here")
    encMovRegReg(a, dst.reg, src.reg, sz)
  elif dst.kind == okReg and src.kind == okImm:
    let sz = if dst.regSize != szNone: dst.regSize
             elif src.immSize != szNone: src.immSize
             else: sz64
    encMovRegImm(a, dst.reg, src.imm, sz)
  elif dst.kind == okReg and src.kind == okMem:
    let sz = if dst.regSize != szNone: dst.regSize
             elif src.memSize != szNone: src.memSize
             else: sz64
    encMovRegMem(a, dst.reg, src.mem, sz, isX64)
  elif dst.kind == okMem and src.kind == okReg:
    let sz = if dst.memSize != szNone: dst.memSize
             elif src.regSize != szNone: src.regSize
             else: sz64
    encMovMemReg(a, dst.mem, src.reg, sz, isX64)
  elif dst.kind == okMem and src.kind == okImm:
    let sz = if dst.memSize != szNone: dst.memSize
             elif src.immSize != szNone: src.immSize
             else: sz32
    if sz == szNone:
      raise impossibleRelocation("mov mem,imm needs size")
    encMovMemImm(a, dst.mem, src.imm, sz, isX64)
  elif dst.kind == okReg and src.kind == okLabelRef:
    # mov reg, label address: lea for RIP-relative, or movabs for absolute
    let sz = if dst.regSize != szNone: dst.regSize else: sz64
    let lr = src.lbl
    if lr.lkind == lrAbsolute:
      # movabs reg, imm64
      if sz != sz64:
        raise impossibleRelocation("movabs needs 64-bit")
      let w = true
      let b = (dst.reg.code and 8) != 0
      emitRexIfNeeded(a, w, false, false, b)
      a.push(cast[uint8](0xB8 or (dst.reg.code and 7)))
      let u = cast[uint64](lr.dynId)
      for i in 0..<8:
        a.push(cast[uint8]((u shr (i * 8)) and 0xFF))
    else:
      var mem = MemOp(hasBase: false, base: Register(code: 0, cls: rcGpr),
        hasIndex: false, index: Register(code: 0, cls: rcGpr), scale: 1,
        disp: 0, hasDisp: false,
        hasRip: true, addrSizeOverride: false, ripLabel: lr)
      encLeaSized(a, dst.reg, sz, mem, isX64)
  else:
    raise impossibleRelocation("unsupported mov operands")

proc dynasmLea*(a: var auto, dst: Operand, src: Operand, isX64: bool) =
  if dst.kind != okReg:
    raise impossibleRelocation("lea needs reg dst")
  if src.kind != okMem:
    raise impossibleRelocation("lea needs mem src")
  let sz = if dst.regSize != szNone: dst.regSize else: sz64
  encLeaSized(a, dst.reg, sz, src.mem, isX64)

proc dynasmAlu*(a: var auto, mn: string, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    let sz = if dst.regSize != szNone: dst.regSize
             elif src.regSize != szNone: src.regSize
             else: sz64
    encAluRegReg(a, mn, dst.reg, src.reg, sz)
  elif dst.kind == okReg and src.kind == okImm:
    let sz = if dst.regSize != szNone: dst.regSize
             elif src.immSize != szNone: src.immSize
             else: sz32
    encAluRegImm(a, mn, dst.reg, src.imm, sz)
  elif dst.kind == okMem and src.kind == okReg:
    let sz = if dst.memSize != szNone: dst.memSize
             elif src.regSize != szNone: src.regSize
             else: sz32
    encAluMemReg(a, mn, dst.mem, src.reg, sz, isX64)
  elif dst.kind == okReg and src.kind == okMem:
    let sz = if dst.regSize != szNone: dst.regSize
             elif src.memSize != szNone: src.memSize
             else: sz32
    encAluRegMem(a, mn, dst.reg, src.mem, sz, isX64)
  elif dst.kind == okMem and src.kind == okImm:
    let sz = if dst.memSize != szNone: dst.memSize
             elif src.immSize != szNone: src.immSize
             else: sz32
    encAluMemImm(a, mn, dst.mem, src.imm, sz, isX64)
  else:
    raise impossibleRelocation("unsupported " & mn & " operands")

proc dynasmTest*(a: var auto, lhs, rhs: Operand) =
  if lhs.kind == okReg and rhs.kind == okReg:
    let sz = if lhs.regSize != szNone: lhs.regSize
             elif rhs.regSize != szNone: rhs.regSize
             else: sz64
    encTestRegReg(a, lhs.reg, rhs.reg, sz)
  else:
    raise impossibleRelocation("test only supports reg,reg here")

proc dynasmIncDec*(a: var auto, mn: string, op: Operand, isX64: bool) =
  if op.kind == okReg:
    let sz = if op.regSize != szNone: op.regSize else: sz64
    encIncDec(a, mn, op.reg, sz)
  elif op.kind == okMem:
    let sz = if op.memSize != szNone: op.memSize else: sz32
    encIncDecMem(a, mn, op.mem, sz, isX64)
  else:
    raise impossibleRelocation(mn & " needs reg/mem")

proc dynasmPush*(a: var auto, op: Operand, isX64: bool) =
  if op.kind == okReg:
    encPushReg(a, op.reg, isX64)
  elif op.kind == okImm:
    let v = op.imm
    if v >= -128 and v <= 127:
      a.push(0x6A'u8)
      a.push(cast[uint8](v))
    else:
      a.push(0x68'u8)
      a.pushU32(cast[uint32](v))
  elif op.kind == okMem:
    let sz = if op.memSize != szNone: op.memSize else: sz64
    encPushMem(a, op.mem, sz, isX64)
  else:
    raise impossibleRelocation("push only reg/imm/mem here")

proc dynasmPop*(a: var auto, op: Operand, isX64: bool) =
  if op.kind == okReg:
    encPopReg(a, op.reg, isX64)
  else:
    raise impossibleRelocation("pop only reg here")

proc dynasmJmp*(a: var auto, op: Operand, isShort: bool) =
  if op.kind == okLabelRef:
    if isShort: encJmpShort(a, op.lbl)
    else: encJmpRel(a, op.lbl)
  elif op.kind == okReg:
    encJmpReg(a, op.reg)
  elif op.kind == okMem:
    encJmpMem(a, op.mem, true)
  else:
    raise impossibleRelocation("jmp needs label/reg/mem")

proc dynasmJcc*(a: var auto, mn: string, op: Operand, isShort: bool) =
  if op.kind != okLabelRef:
    raise impossibleRelocation(mn & " needs label")
  if isShort: encJccShort(a, mn, op.lbl)
  else: encJcc(a, mn, op.lbl)

proc dynasmSetcc*(a: var auto, mn: string, op: Operand, isX64: bool) =
  if op.kind == okReg:
    let sz = if op.regSize != szNone: op.regSize else: sz8
    if sz != sz8:
      raise impossibleRelocation(mn & " needs a byte register")
    encSetccReg(a, mn, op.reg)
  elif op.kind == okMem:
    let sz = if op.memSize != szNone: op.memSize else: sz8
    if sz != sz8:
      raise impossibleRelocation(mn & " needs byte-sized memory")
    encSetccMem(a, mn, op.mem, isX64)
  else:
    raise impossibleRelocation(mn & " needs a byte register or memory")

proc dynasmCmovcc*(a: var auto, mn: string, dst, src: Operand,
    isX64: bool) =
  if dst.kind != okReg:
    raise impossibleRelocation(mn & " needs reg dst")
  let dstSz = if dst.regSize != szNone: dst.regSize else: sz64
  if dstSz == sz8:
    raise impossibleRelocation(mn & " needs 16/32/64-bit dst")
  if src.kind == okReg:
    let srcSz = if src.regSize != szNone: src.regSize else: dstSz
    if srcSz != dstSz:
      raise impossibleRelocation(mn & " dst/src size mismatch")
    encCmovRegReg(a, mn, dst.reg, src.reg, dstSz)
  elif src.kind == okMem:
    let srcSz = if src.memSize != szNone: src.memSize else: dstSz
    if srcSz != dstSz:
      raise impossibleRelocation(mn & " dst/src size mismatch")
    encCmovRegMem(a, mn, dst.reg, src.mem, dstSz, isX64)
  else:
    raise impossibleRelocation(mn & " needs reg/mem src")

proc dynasmShift*(a: var auto, mn: string, dst: Operand, count: Operand,
    isX64: bool) =
  let sz = if dst.kind == okReg and dst.regSize != szNone: dst.regSize
           elif dst.kind == okMem and dst.memSize != szNone: dst.memSize
           else: sz64
  if count.kind == okImm:
    if dst.kind == okReg:
      encShiftRegImm(a, mn, dst.reg, count.imm, sz)
    elif dst.kind == okMem:
      encShiftMemImm(a, mn, dst.mem, count.imm, sz, isX64)
    else:
      raise impossibleRelocation(mn & " needs reg/mem dst")
  elif count.kind == okReg:
    # only cl supported as register count
    if count.reg.code != 1 or count.reg.cls != rcGpr:
      raise impossibleRelocation(mn & " reg count must be cl")
    if dst.kind == okReg:
      encShiftRegCl(a, mn, dst.reg, sz)
    else:
      raise impossibleRelocation(mn & " cl-count only supports reg dst here")
  else:
    raise impossibleRelocation(mn & " needs imm/cl count")

proc dynasmImul*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    let sz = if dst.regSize != szNone: dst.regSize
             elif src.regSize != szNone: src.regSize
             else: sz64
    if sz == sz8:
      raise impossibleRelocation("imul needs 16/32/64-bit")
    encImulRegReg(a, dst.reg, src.reg, sz)
  elif dst.kind == okReg and src.kind == okMem:
    let sz = if dst.regSize != szNone: dst.regSize
             elif src.memSize != szNone: src.memSize
             else: sz64
    encImulRegMem(a, dst.reg, src.mem, sz, isX64)
  elif dst.kind == okReg and src.kind == okImm:
    # 2-operand imul dst, dst, imm shorthand via macro: imul dst, imm
    # is lowered by the macro to 3 args; here require explicit src instead.
    raise impossibleRelocation("imul dst, imm needs explicit src: imul dst, src, imm")
  else:
    raise impossibleRelocation("unsupported imul operands")

proc dynasmImul3*(a: var auto, dst, src: Operand, imm: int64) =
  if dst.kind != okReg or src.kind != okReg:
    raise impossibleRelocation("imul dst, src, imm needs regs")
  let sz = if dst.regSize != szNone: dst.regSize
           elif src.regSize != szNone: src.regSize
           else: sz64
  encImulRegImm(a, dst.reg, src.reg, imm, sz)

proc dynasmDivMul*(a: var auto, mn: string, op: Operand, isX64: bool) =
  let sz =
    if op.kind == okReg and op.regSize != szNone: op.regSize
    elif op.kind == okMem and op.memSize != szNone: op.memSize
    else: sz64
  if op.kind == okReg:
    encDivReg(a, mn, op.reg, sz)
  elif op.kind == okMem:
    encDivMem(a, mn, op.mem, sz, isX64)
  else:
    raise impossibleRelocation(mn & " needs reg/mem")

proc dynasmMovzx*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind != okReg:
    raise impossibleRelocation("movzx needs reg dst")
  let dstSz = if dst.regSize != szNone: dst.regSize else: sz32
  if src.kind == okReg:
    let srcSz = if src.regSize != szNone: src.regSize else: sz8
    if srcSz != sz8 and srcSz != sz16:
      raise impossibleRelocation("movzx src must be byte/word")
    encMovzxRegReg(a, dst.reg, src.reg, srcSz, dstSz)
  elif src.kind == okMem:
    let srcSz = if src.memSize != szNone: src.memSize else: sz8
    if srcSz != sz8 and srcSz != sz16:
      raise impossibleRelocation("movzx src must be byte/word")
    encMovzxRegMem(a, dst.reg, src.mem, srcSz, dstSz, isX64)
  else:
    raise impossibleRelocation("movzx needs reg/mem src")

proc dynasmCall*(a: var auto, op: Operand, isX64: bool) =
  if op.kind == okLabelRef:
    encCallRel(a, op.lbl)
  elif op.kind == okReg:
    encCallReg(a, op.reg)
  elif op.kind == okMem:
    encCallMem(a, op.mem, isX64)
  else:
    raise impossibleRelocation("call needs label/reg/mem")

proc dynasmBytes*(a: var auto, data: openArray[byte]) =
  for b in data:
    a.push(b)

proc dynasmBytesStr*(a: var auto, s: string) =
  for c in s:
    a.push(cast[uint8](c))

proc dynasmRel*(a: var auto, size: RelocationSize, lr: LabelRef) =
  case size
  of rsByte:
    a.push(0'u8)
  of rsWord:
    a.pushU16(0)
  of rsDWord:
    a.pushU32(0)
  of rsQWord:
    a.pushU64(0)
  let enc = encodeKind(rkRelative, size)
  let f = int(size)
  case lr.lkind
  of lrForward: a.forwardReloc(lr.lname, lr.loff, f, 0, enc)
  of lrBackward: a.backwardReloc(lr.lname, lr.loff, f, 0, enc)
  of lrGlobal: a.globalReloc(lr.lname, lr.loff, f, 0, enc)
  of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, f, 0, enc)
  of lrAbsolute:
    let enc2 = encodeKind(rkRelToAbs, size)
    a.valueReloc(lr.dynId, f, 0, enc2)

proc dynasmAbs*(a: var auto, size: RelocationSize, lr: LabelRef) =
  case size
  of rsByte:
    a.push(0'u8)
  of rsWord:
    a.pushU16(0)
  of rsDWord:
    a.pushU32(0)
  of rsQWord:
    a.pushU64(0)
  let enc = encodeKind(rkAbsolute, size)
  let f = int(size)
  case lr.lkind
  of lrForward: a.forwardReloc(lr.lname, lr.loff, f, 0, enc)
  of lrBackward: a.backwardReloc(lr.lname, lr.loff, f, 0, enc)
  of lrGlobal: a.globalReloc(lr.lname, lr.loff, f, 0, enc)
  of lrDynamic: a.dynamicReloc(DynamicLabel(lr.dynId), lr.loff, f, 0, enc)
  of lrAbsolute:
    let enc2 = encodeKind(rkAbsolute, size)
    a.valueReloc(lr.dynId, f, 0, enc2)

# --------------------------------------------------------------------------
# SSE scalar double + packed double. Sizes are implied by the mnemonic
# (m64 for sd, m128 for pd); the only explicit sizes involved are the
# integer sides of the cvt forms and the optional dqword/oword marker
# for m128. Validation (macro) guarantees xmm/GPR shapes; the encoders
# trust it like the GPR paths do.
# --------------------------------------------------------------------------

proc dynasmMovsd*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encMovsdRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encMovsdRegMem(a, dst.reg, src.mem, isX64)
  elif dst.kind == okMem and src.kind == okReg:
    encMovsdMemReg(a, dst.mem, src.reg, isX64)
  else:
    raise impossibleRelocation("unsupported movsd operands")

proc dynasmAluSd*(a: var auto, mn: string, dst, src: Operand,
    isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encSseAluRegReg(a, mn, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encSseAluRegMem(a, mn, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported " & mn & " operands")

proc dynasmUcomisd*(a: var auto, lhs, rhs: Operand, isX64: bool) =
  if lhs.kind == okReg and rhs.kind == okReg:
    encUcomisdRegReg(a, lhs.reg, rhs.reg)
  elif lhs.kind == okReg and rhs.kind == okMem:
    encUcomisdRegMem(a, lhs.reg, rhs.mem, isX64)
  else:
    raise impossibleRelocation("unsupported ucomisd operands")

proc dynasmCvtsi2sd*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind != okReg:
    raise impossibleRelocation("cvtsi2sd needs xmm dst")
  if src.kind == okReg:
    let sz = if src.regSize != szNone: src.regSize else: sz64
    encCvtsi2sdRegReg(a, dst.reg, src.reg, sz)
  elif src.kind == okMem:
    let sz = if src.memSize != szNone: src.memSize else: sz32
    encCvtsi2sdRegMem(a, dst.reg, src.mem, sz, isX64)
  else:
    raise impossibleRelocation("unsupported cvtsi2sd operands")

proc dynasmCvttsd2si*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind != okReg:
    raise impossibleRelocation("cvttsd2si needs gpr dst")
  let sz = if dst.regSize != szNone: dst.regSize else: sz64
  if src.kind == okReg:
    encCvttsd2siRegReg(a, dst.reg, sz, src.reg)
  elif src.kind == okMem:
    encCvttsd2siRegMem(a, dst.reg, sz, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported cvttsd2si operands")

proc dynasmXorpd*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encXorpdRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encXorpdRegMem(a, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported xorpd operands")

proc dynasmMovApd*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encMovApdRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encMovApdRegMem(a, dst.reg, src.mem, isX64)
  elif dst.kind == okMem and src.kind == okReg:
    encMovApdMemReg(a, dst.mem, src.reg, isX64)
  else:
    raise impossibleRelocation("unsupported movapd operands")

proc dynasmMovUpd*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encMovUpdRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encMovUpdRegMem(a, dst.reg, src.mem, isX64)
  elif dst.kind == okMem and src.kind == okReg:
    encMovUpdMemReg(a, dst.mem, src.reg, isX64)
  else:
    raise impossibleRelocation("unsupported movupd operands")

proc dynasmAluPd*(a: var auto, mn: string, dst, src: Operand,
    isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encSsePdAluRegReg(a, mn, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encSsePdAluRegMem(a, mn, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported " & mn & " operands")

proc dynasmAndpd*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encAndpdRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encAndpdRegMem(a, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported andpd operands")

proc dynasmOrpd*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encOrpdRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encOrpdRegMem(a, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported orpd operands")

# --------------------------------------------------------------------------
# AES-NI + integer-SSE moves/logic for AES kernels. Shapes mirror the
# packed-double paths: dst is always xmm, src is xmm or m128.
# --------------------------------------------------------------------------

proc dynasmAes*(a: var auto, mn: string, dst, src: Operand,
    isX64: bool) =
  if dst.kind != okReg:
    raise impossibleRelocation(mn & " needs xmm dst")
  if src.kind == okReg:
    encAes38RegReg(a, mn, dst.reg, src.reg)
  elif src.kind == okMem:
    encAes38RegMem(a, mn, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported " & mn & " operands")

proc dynasmAesKeyGen*(a: var auto, dst, src: Operand, imm: int64,
    isX64: bool) =
  if imm < 0 or imm > 255:
    raise impossibleRelocation("aeskeygenassist imm8 out of range 0-255")
  let ib = cast[uint8](imm)
  if dst.kind != okReg:
    raise impossibleRelocation("aeskeygenassist needs xmm dst")
  if src.kind == okReg:
    encAesKeyGenRegReg(a, dst.reg, src.reg, ib)
  elif src.kind == okMem:
    encAesKeyGenRegMem(a, dst.reg, src.mem, ib, isX64)
  else:
    raise impossibleRelocation("unsupported aeskeygenassist operands")

proc dynasmPxor*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encPxorRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encPxorRegMem(a, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported pxor operands")

proc dynasmMovdqa*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encMovdqaRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encMovdqaRegMem(a, dst.reg, src.mem, isX64)
  elif dst.kind == okMem and src.kind == okReg:
    encMovdqaMemReg(a, dst.mem, src.reg, isX64)
  else:
    raise impossibleRelocation("unsupported movdqa operands")

proc dynasmMovdqu*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encMovdquRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encMovdquRegMem(a, dst.reg, src.mem, isX64)
  elif dst.kind == okMem and src.kind == okReg:
    encMovdquMemReg(a, dst.mem, src.reg, isX64)
  else:
    raise impossibleRelocation("unsupported movdqu operands")

# --------------------------------------------------------------------------
# GHASH SSE set (PCLMULQDQ era). Shapes mirror the packed-double paths:
# dst is always xmm, src is xmm or m128; pshufd/pclmulqdq/shifts carry
# an imm8 (runtime range-checked like aeskeygenassist).
# --------------------------------------------------------------------------

proc dynasmPshufb*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind != okReg:
    raise impossibleRelocation("pshufb needs xmm dst")
  if src.kind == okReg:
    encPshufbRegReg(a, dst.reg, src.reg)
  elif src.kind == okMem:
    encPshufbRegMem(a, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported pshufb operands")

proc dynasmPclmul*(a: var auto, dst, src: Operand, imm: int64,
    isX64: bool) =
  if imm < 0 or imm > 255:
    raise impossibleRelocation("pclmulqdq imm8 out of range 0-255")
  let ib = cast[uint8](imm)
  if dst.kind != okReg:
    raise impossibleRelocation("pclmulqdq needs xmm dst")
  if src.kind == okReg:
    encPclmulRegReg(a, dst.reg, src.reg, ib)
  elif src.kind == okMem:
    encPclmulRegMem(a, dst.reg, src.mem, ib, isX64)
  else:
    raise impossibleRelocation("unsupported pclmulqdq operands")

proc dynasmPshufd*(a: var auto, dst, src: Operand, imm: int64,
    isX64: bool) =
  if imm < 0 or imm > 255:
    raise impossibleRelocation("pshufd imm8 out of range 0-255")
  let ib = cast[uint8](imm)
  if dst.kind != okReg:
    raise impossibleRelocation("pshufd needs xmm dst")
  if src.kind == okReg:
    encPshufdRegReg(a, dst.reg, src.reg, ib)
  elif src.kind == okMem:
    encPshufdRegMem(a, dst.reg, src.mem, ib, isX64)
  else:
    raise impossibleRelocation("unsupported pshufd operands")

proc dynasmPunpcklqdq*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encPunpcklqdqRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encPunpcklqdqRegMem(a, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported punpcklqdq operands")

proc dynasmPor*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encPorRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encPorRegMem(a, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported por operands")

proc dynasmPadd*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    encPaddRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    encPaddRegMem(a, dst.reg, src.mem, isX64)
  else:
    raise impossibleRelocation("unsupported paddd operands")

proc dynasmShiftQ*(a: var auto, mn: string, dst: Operand, imm: int64) =
  if imm < 0 or imm > 255:
    raise impossibleRelocation(mn & " imm8 out of range 0-255")
  if dst.kind != okReg:
    raise impossibleRelocation(mn & " needs xmm dst")
  encSseShiftImmReg(a, mn, dst.reg, cast[uint8](imm))

# --------------------------------------------------------------------------
# VEX (AVX/AVX2/BMI2). Runtime guards mirror the macro validators so
# dynamic (non-static) operands cannot misassemble.
# --------------------------------------------------------------------------

proc vexCheckReg(op: Operand, what: string) =
  if op.kind == okReg and op.reg.cls != rcXmm and op.reg.cls != rcYmm:
    raise impossibleRelocation(what & " needs XMM/YMM registers")

proc vexCheckAgree(dst, s1, s2: Operand, mn: string) =
  var cls = rcGpr # placeholder; only vector classes participate
  var have = false
  for op in [dst, s1, s2]:
    if op.kind == okReg and
        (op.reg.cls == rcXmm or op.reg.cls == rcYmm):
      if not have:
        cls = op.reg.cls
        have = true
      elif op.reg.cls != cls:
        raise impossibleRelocation(mn & " cannot mix XMM and YMM")

proc dynasmVexArith*(a: var auto, mn: string, dst, s1, s2: Operand,
    isX64: bool) =
  vexCheckReg(dst, mn & " dst")
  vexCheckReg(s1, mn & " src1")
  vexCheckAgree(dst, s1, s2, mn)
  if dst.kind != okReg or s1.kind != okReg:
    raise impossibleRelocation(mn & " needs register dst/src1")
  if s2.kind == okReg:
    vexCheckReg(s2, mn & " src2")
    encVexArithRegRegReg(a, mn, dst.reg, s1.reg, s2.reg)
  elif s2.kind == okMem:
    encVexArithRegMem(a, mn, dst.reg, s1.reg, s2.mem, isX64)
  else:
    raise impossibleRelocation("unsupported " & mn & " operands")

proc dynasmVexShufd*(a: var auto, dst, src: Operand, imm: int64,
    isX64: bool) =
  if imm < 0 or imm > 255:
    raise impossibleRelocation("vpshufd imm8 out of range 0-255")
  let ib = cast[uint8](imm)
  vexCheckReg(dst, "vpshufd dst")
  if dst.kind != okReg:
    raise impossibleRelocation("vpshufd needs vector dst")
  if src.kind == okReg:
    vexCheckReg(src, "vpshufd src")
    encVexShufdRegReg(a, dst.reg, src.reg, ib)
  elif src.kind == okMem:
    encVexShufdRegMem(a, dst.reg, src.mem, ib, isX64)
  else:
    raise impossibleRelocation("unsupported vpshufd operands")

proc dynasmVexShift*(a: var auto, mn: string, dst, src: Operand,
    imm: int64) =
  if imm < 0 or imm > 255:
    raise impossibleRelocation(mn & " imm8 out of range 0-255")
  let ib = cast[uint8](imm)
  vexCheckReg(dst, mn & " dst")
  vexCheckReg(src, mn & " src")
  if dst.kind != okReg or src.kind != okReg:
    raise impossibleRelocation(mn & " needs vector regs (no mem form)")
  if dst.reg.cls != src.reg.cls:
    raise impossibleRelocation(mn & " cannot mix XMM and YMM")
  encVexShiftRegReg(a, mn, dst.reg, src.reg, ib)

proc dynasmVmovdqu*(a: var auto, dst, src: Operand, isX64: bool) =
  if dst.kind == okReg and src.kind == okReg:
    vexCheckReg(dst, "vmovdqu dst")
    vexCheckReg(src, "vmovdqu src")
    if dst.reg.cls != src.reg.cls:
      raise impossibleRelocation("vmovdqu cannot mix XMM and YMM")
    encVexMovRegReg(a, dst.reg, src.reg)
  elif dst.kind == okReg and src.kind == okMem:
    vexCheckReg(dst, "vmovdqu dst")
    encVexMovRegMem(a, dst.reg, src.mem, isX64)
  elif dst.kind == okMem and src.kind == okReg:
    vexCheckReg(src, "vmovdqu src")
    encVexMovMemReg(a, dst.mem, src.reg, isX64)
  else:
    raise impossibleRelocation("unsupported vmovdqu operands")

proc dynasmVzeroupper*(a: var auto) =
  encVzeroupper(a)

proc dynasmCpuid*(a: var auto) =
  encCpuid(a)

proc dynasmXgetbv*(a: var auto) =
  encXgetbv(a)

proc dynasmMulx*(a: var auto, hi, lo, src: Operand, isX64: bool) =
  if hi.kind != okReg or lo.kind != okReg:
    raise impossibleRelocation("mulx needs GPR dst regs")
  for op in [hi, lo]:
    if op.reg.cls != rcGpr:
      raise impossibleRelocation("mulx needs GPR dst regs")
  let is64 =
    if hi.regSize == sz32 or lo.regSize == sz32: false
    else: true
  if src.kind == okReg:
    if src.reg.cls != rcGpr:
      raise impossibleRelocation("mulx needs a GPR/mem source")
    encMulxRegRegReg(a, hi.reg, lo.reg, src.reg, is64)
  elif src.kind == okMem:
    encMulxRegMem(a, hi.reg, lo.reg, src.mem, is64, isX64)
  else:
    raise impossibleRelocation("unsupported mulx operands")
