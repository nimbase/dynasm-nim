## Register definitions for x64/x86.
## Runtime codes match references/dynasm-rs/runtime/src/x64.rs and x86.rs.

import ./types

type
  RegClass* = enum
    rcGpr       ## general purpose (size encoded separately)
    rcHigh8     ## AH/CH/DH/BH
    rcFpu       ## ST0..7
    rcMmx
    rcXmm
    rcSeg
    rcControl
    rcDebug
    rcBound

  Register* = object
    code*: uint8
    cls*: RegClass

proc regCode*(r: Register): uint8 = r.code

proc Rq*(idx: int): Register = Register(code: uint8(idx and 0xF), cls: rcGpr)
proc Rd*(idx: int): Register = Register(code: uint8(idx and 0xF), cls: rcGpr)
proc Rx*(idx: int): Register = Register(code: uint8(idx and 0xF), cls: rcXmm)

# GPR 64-bit names (also usable as 32/16/8 with size context)
const
  rax* = Register(code: 0, cls: rcGpr)
  rcx* = Register(code: 1, cls: rcGpr)
  rdx* = Register(code: 2, cls: rcGpr)
  rbx* = Register(code: 3, cls: rcGpr)
  rsp* = Register(code: 4, cls: rcGpr)
  rbp* = Register(code: 5, cls: rcGpr)
  rsi* = Register(code: 6, cls: rcGpr)
  rdi* = Register(code: 7, cls: rcGpr)
  r8*  = Register(code: 8, cls: rcGpr)
  r9*  = Register(code: 9, cls: rcGpr)
  r10* = Register(code: 10, cls: rcGpr)
  r11* = Register(code: 11, cls: rcGpr)
  r12* = Register(code: 12, cls: rcGpr)
  r13* = Register(code: 13, cls: rcGpr)
  r14* = Register(code: 14, cls: rcGpr)
  r15* = Register(code: 15, cls: rcGpr)

  # 32-bit aliases share codes
  eax* = Register(code: 0, cls: rcGpr)
  ecx* = Register(code: 1, cls: rcGpr)
  edx* = Register(code: 2, cls: rcGpr)
  ebx* = Register(code: 3, cls: rcGpr)
  esp* = Register(code: 4, cls: rcGpr)
  ebp* = Register(code: 5, cls: rcGpr)
  esi* = Register(code: 6, cls: rcGpr)
  edi* = Register(code: 7, cls: rcGpr)
  r8d* = Register(code: 8, cls: rcGpr)
  r9d* = Register(code: 9, cls: rcGpr)
  r10d* = Register(code: 10, cls: rcGpr)
  r11d* = Register(code: 11, cls: rcGpr)
  r12d* = Register(code: 12, cls: rcGpr)
  r13d* = Register(code: 13, cls: rcGpr)
  r14d* = Register(code: 14, cls: rcGpr)
  r15d* = Register(code: 15, cls: rcGpr)

  # 16-bit aliases
  ax* = Register(code: 0, cls: rcGpr)
  cx* = Register(code: 1, cls: rcGpr)
  dx* = Register(code: 2, cls: rcGpr)
  bx* = Register(code: 3, cls: rcGpr)
  sp* = Register(code: 4, cls: rcGpr)
  bp* = Register(code: 5, cls: rcGpr)
  si* = Register(code: 6, cls: rcGpr)
  di* = Register(code: 7, cls: rcGpr)

  # 8-bit low
  al* = Register(code: 0, cls: rcGpr)
  cl* = Register(code: 1, cls: rcGpr)
  dl* = Register(code: 2, cls: rcGpr)
  bl* = Register(code: 3, cls: rcGpr)
  spl* = Register(code: 4, cls: rcGpr)
  bpl* = Register(code: 5, cls: rcGpr)
  sil* = Register(code: 6, cls: rcGpr)
  dil* = Register(code: 7, cls: rcGpr)
  r8b* = Register(code: 8, cls: rcGpr)
  r9b* = Register(code: 9, cls: rcGpr)
  r10b* = Register(code: 10, cls: rcGpr)
  r11b* = Register(code: 11, cls: rcGpr)
  r12b* = Register(code: 12, cls: rcGpr)
  r13b* = Register(code: 13, cls: rcGpr)
  r14b* = Register(code: 14, cls: rcGpr)
  r15b* = Register(code: 15, cls: rcGpr)

  # high-byte
  ah* = Register(code: 4, cls: rcHigh8)
  ch* = Register(code: 5, cls: rcHigh8)
  dh* = Register(code: 6, cls: rcHigh8)
  bh* = Register(code: 7, cls: rcHigh8)

  # XMM
  xmm0* = Register(code: 0, cls: rcXmm)
  xmm1* = Register(code: 1, cls: rcXmm)
  xmm2* = Register(code: 2, cls: rcXmm)
  xmm3* = Register(code: 3, cls: rcXmm)
  xmm4* = Register(code: 4, cls: rcXmm)
  xmm5* = Register(code: 5, cls: rcXmm)
  xmm6* = Register(code: 6, cls: rcXmm)
  xmm7* = Register(code: 7, cls: rcXmm)
  xmm8* = Register(code: 8, cls: rcXmm)
  xmm9* = Register(code: 9, cls: rcXmm)
  xmm10* = Register(code: 10, cls: rcXmm)
  xmm11* = Register(code: 11, cls: rcXmm)
  xmm12* = Register(code: 12, cls: rcXmm)
  xmm13* = Register(code: 13, cls: rcXmm)
  xmm14* = Register(code: 14, cls: rcXmm)
  xmm15* = Register(code: 15, cls: rcXmm)

# --------------------------------------------------------------------------
# Operand model used by encoder + macro
# --------------------------------------------------------------------------

type
  OpSize* = enum
    szNone
    sz8
    sz16
    sz32
    sz64

  LabelRefKind* = enum
    lrForward
    lrBackward
    lrGlobal
    lrDynamic
    lrAbsolute

  LabelRef* = object
    case isLabel*: bool
    of true:
      lkind*: LabelRefKind
      lname*: string
      dynExpr*: string  ## placeholder, real expr handled in macro via id
      dynId*: int       ## resolved at macro expansion when possible
      loff*: int
    of false:
      discard

  MemOp* = object
    hasBase*: bool
    base*: Register
    hasIndex*: bool
    index*: Register
    scale*: int
    disp*: int64
    hasDisp*: bool
    ripLabel*: LabelRef  ## for [glob(..)] / [fwd(..)] RIP-relative
    hasRip*: bool
    addrSizeOverride*: bool

  OperandKind* = enum
    okReg
    okImm
    okMem
    okLabelRef

  Operand* = object
    case kind*: OperandKind
    of okReg:
      reg*: Register
      regSize*: OpSize
    of okImm:
      imm*: int64
      immSize*: OpSize
    of okMem:
      mem*: MemOp
      memSize*: OpSize
    of okLabelRef:
      lbl*: LabelRef

proc regOp*(r: Register, s: OpSize = szNone): Operand =
  Operand(kind: okReg, reg: r, regSize: s)

proc immOp*(v: int64, s: OpSize = szNone): Operand =
  Operand(kind: okImm, imm: v, immSize: s)

proc memOp*(m: MemOp, s: OpSize = szNone): Operand =
  Operand(kind: okMem, mem: m, memSize: s)

proc labelOp*(l: LabelRef): Operand =
  Operand(kind: okLabelRef, lbl: l)

proc fwd*(name: string, off: int = 0): LabelRef =
  LabelRef(isLabel: true, lkind: lrForward, lname: name, loff: off)
proc bwd*(name: string, off: int = 0): LabelRef =
  LabelRef(isLabel: true, lkind: lrBackward, lname: name, loff: off)
proc glob*(name: string, off: int = 0): LabelRef =
  LabelRef(isLabel: true, lkind: lrGlobal, lname: name, loff: off)
proc dynLbl*(id: int, off: int = 0): LabelRef =
  LabelRef(isLabel: true, lkind: lrDynamic, lname: "", dynId: id, loff: off)
proc extAddr*(a: int, off: int = 0): LabelRef =
  LabelRef(isLabel: true, lkind: lrAbsolute, lname: "", dynId: a, loff: off)

# Size marker helpers usable in DSL: byte(x), word(x), dword(x), qword(x)
# return Operand so `mov dl, byte(5)` works at runtime too.

proc byte*(v: int64): Operand = immOp(v, sz8)
proc word*(v: int64): Operand = immOp(v, sz16)
proc dword*(v: int64): Operand = immOp(v, sz32)
proc qword*(v: int64): Operand = immOp(v, sz64)

proc dynLbl*(id: DynamicLabel, off: int = 0): LabelRef =
  LabelRef(isLabel: true, lkind: lrDynamic, lname: "", dynId: int(id),
    loff: off)
proc dyn*(id: DynamicLabel, off: int = 0): LabelRef {.inline.} =
  dynLbl(id, off)
proc dyn*(id: int, off: int = 0): LabelRef {.inline.} =
  dynLbl(id, off)
proc extAddrPtr*(a: pointer, off: int = 0): LabelRef =
  LabelRef(isLabel: true, lkind: lrAbsolute, lname: "", dynId: cast[int](a),
    loff: off)

proc byte*(r: Register): Operand = regOp(r, sz8)
proc word*(r: Register): Operand = regOp(r, sz16)
proc dword*(r: Register): Operand = regOp(r, sz32)
proc qword*(r: Register): Operand = regOp(r, sz64)

proc byte*(m: MemOp): Operand = memOp(m, sz8)
proc word*(m: MemOp): Operand = memOp(m, sz16)
proc dword*(m: MemOp): Operand = memOp(m, sz32)
proc qword*(m: MemOp): Operand = memOp(m, sz64)
