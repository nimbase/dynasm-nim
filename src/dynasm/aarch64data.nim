## AArch64 op tables: the Nim counterpart of dynasm-rs opmap.rs.
## Each entry is (base template bits, operand shapes, encoder form,
## relocation id). The macro matches operand shapes statically (like
## rs matching.rs) and emits a call to one runtime form in aarch64.nim
## (like rs compiler.rs commands). Bases below are transcribed from
## plugin/src/arch/aarch64/opmap.rs.

import ./relocations

type
  A64Shape* = enum
    asX     ## 64-bit integer reg (incl. xzr, dynamic Xreg)
    asW     ## 32-bit integer reg (incl. wzr, dynamic Wreg)
    asXSP   ## asX plus sp
    asWSP   ## asW plus wsp
    asB     ## scalar SIMD byte reg b0-b31
    asH     ## scalar SIMD halfword reg h0-h31
    asS     ## scalar SIMD single reg s0-s31
    asD     ## scalar SIMD double reg d0-d31
    asQ     ## scalar SIMD quad reg q0-q31
    asVeB   ## vector reg with byte elements: vN.b8/b16
    asVeH   ## vector reg with halfword elements: vN.h4/h8
    asVeS   ## vector reg with single elements: vN.s2/s4
    asVeD   ## vector reg with double elements: vN.d1/d2
    asImm   ## immediate: int literal or Nim expression
    asFImm  ## float immediate: float literal (fmov)
    asFZero ## fcmp #0.0 marker (float literal 0.0)
    asMemBase   ## [base]
    asMemOff    ## [base, imm]
    asMemPre    ## [base, imm], pre-indexed (trailing `pre`)
    asMemPost   ## [base], imm (post-indexed)
    asMemIdx    ## [base, index (, extend (, amount))]
    asLbl   ## label reference (fwd/bwd/glob/dyn/extaddr-free)
    asMod   ## shift/extend modifier ident (lsl/lsr/asr/ror/...)
    asPre   ## trailing `pre` marker
    asCond  ## condition name ident (eq/ne/cs/... for cset)

  A64Form* = enum
    fRRR      ## R(0), R(5), R(16)
    fRR       ## R(0), R(16): mov reg, mvn
    fRRn      ## R(0), R(5): two-operand FP forms
    fXRR      ## R(5), R(16): cmp/tst reg (XZR dest in base)
    fRRRR     ## +R(10): madd/msub
    fRRI12    ## add/sub imm: Ubits(10,12) + lsl12 flag
    fLogicI   ## logical imm: Special LOGICAL_IMMEDIATE
    fMovI     ## plain mov imm: MOVZ pattern (WIDE_IMMEDIATE)
    fMovInv   ## mov.inverted: MOVN pattern over complement
    fMovLogic ## mov.logical: ORR bitmask pattern
    fMovWide  ## movz/movn/movk: Ubits(5,16) + hw
    fBfmI     ## lsl/lsr/asr imm aliases
    fMemU     ## unsigned-offset ldr/str: Uscaled(10,12,s)
    fMem9     ## pre/post-index ldr/str: Sbits(12,9)
    fPair     ## ldp/stp: Sscaled(15,7,s)
    fMemX     ## register-offset ldr/str: ExtendsX + S bit
    fBr       ## b/bl/b.cond/ldr-literal + relocation
    fCbx      ## cbz/cbnz: R(0) + BCOND relocation
    fTbx      ## tbz/tbnz: split bit + TBZ relocation
    fAdr      ## adr/adrp: R(0) + ADR/ADRP relocation
    fBrReg    ## br/blr/ret reg: R(5)
    fMisc     ## fixed word: nop, ret
    fHlt      ## hlt/svc: Ubits(5,16)
    fFmovI    ## fmov S/D, #imm: Special FLOAT_IMMEDIATE at 13
    fFcmp0    ## fcmp/fcmpe with #0.0: Rn only
    fVecRRR   ## vector ALU: RRR + Q bit
    fVecMovi     ## movi Vn.4S/2S/H/B, #imm8 (, lsl)
    fVecMoviD    ## movi Dn/2D, #stretched
    fDupG     ## dup Vn.<arr>, Rn/Wn: R(0), R(5), Q bit
    fCSet     ## cset: R(0) + inverted cond bits ORed in by matcher

  A64Entry* = tuple
    base: uint32
    shapes: seq[A64Shape]
    form: A64Form
    rel: int ## -1, else AarchB/AarchBCond/AarchAdr/AarchAdrp/AarchTbz

const
  a64CondNames* = ["eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl",
    "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"]
  a64CondBits* = [0, 1, 2, 2, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
    13, 14, 15]

  a64ShiftMods* = ["lsl", "lsr", "asr", "ror"]
  a64ExtendMods* = ["uxtb", "uxth", "uxtw", "uxtx", "sxtb", "sxth",
    "sxtw", "sxtx", "lsl"]

proc a64Entries*(mn: string): seq[A64Entry] =
  ## All forms for a mnemonic, most specific first.
  case mn
  of "mov":
    @[
      (0xAA0003E0'u32, @[asX, asX], fRR, -1),
      (0x2A0003E0'u32, @[asW, asW], fRR, -1),
      # mov to/from sp is ADD with #0
      (0x91000000'u32, @[asXSP, asXSP], fRRI12, -1),
      (0x11000000'u32, @[asWSP, asWSP], fRRI12, -1),
      (0'u32, @[asX, asImm], fMovI, -1),
      (0'u32, @[asW, asImm], fMovI, -1),
    ]
  of "mov.inverted":
    @[
      (0'u32, @[asX, asImm], fMovInv, -1),
      (0'u32, @[asW, asImm], fMovInv, -1),
    ]
  of "mov.logical":
    @[
      (0'u32, @[asX, asImm], fMovLogic, -1),
      (0'u32, @[asW, asImm], fMovLogic, -1),
    ]
  of "movz":
    @[
      (0xD2800000'u32, @[asX, asImm], fMovWide, -1),
      (0xD2800000'u32, @[asX, asImm, asMod, asImm], fMovWide, -1),
      (0x52800000'u32, @[asW, asImm], fMovWide, -1),
      (0x52800000'u32, @[asW, asImm, asMod, asImm], fMovWide, -1),
    ]
  of "movn":
    @[
      (0x92800000'u32, @[asX, asImm], fMovWide, -1),
      (0x92800000'u32, @[asX, asImm, asMod, asImm], fMovWide, -1),
      (0x12800000'u32, @[asW, asImm], fMovWide, -1),
      (0x12800000'u32, @[asW, asImm, asMod, asImm], fMovWide, -1),
    ]
  of "movk":
    @[
      (0xF2800000'u32, @[asX, asImm], fMovWide, -1),
      (0xF2800000'u32, @[asX, asImm, asMod, asImm], fMovWide, -1),
      (0x72800000'u32, @[asW, asImm], fMovWide, -1),
      (0x72800000'u32, @[asW, asImm, asMod, asImm], fMovWide, -1),
    ]
  of "add":
    @[
      (0x0E208400'u32, @[asVeB, asVeB, asVeB], fVecRRR, -1),
      (0x0E608400'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x0EA08400'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x0EE08400'u32, @[asVeD, asVeD, asVeD], fVecRRR, -1),
      (0x8B000000'u32, @[asX, asX, asX], fRRR, -1),
      (0x8B000000'u32, @[asX, asX, asX, asMod], fRRR, -1),
      (0x8B000000'u32, @[asX, asX, asX, asMod, asImm], fRRR, -1),
      (0x0B000000'u32, @[asW, asW, asW], fRRR, -1),
      (0x0B000000'u32, @[asW, asW, asW, asMod], fRRR, -1),
      (0x0B000000'u32, @[asW, asW, asW, asMod, asImm], fRRR, -1),
      # SP is legal in Rd/Rn (not Rm) of ADD shifted-register.
      (0x8B000000'u32, @[asXSP, asXSP, asX], fRRR, -1),
      (0x91000000'u32, @[asXSP, asXSP, asImm], fRRI12, -1),
      (0x91000000'u32, @[asXSP, asXSP, asImm, asMod, asImm], fRRI12, -1),
      (0x11000000'u32, @[asWSP, asWSP, asImm], fRRI12, -1),
      (0x11000000'u32, @[asWSP, asWSP, asImm, asMod, asImm], fRRI12, -1),
    ]
  of "adds":
    @[
      (0xAB000000'u32, @[asX, asX, asX], fRRR, -1),
      (0xAB000000'u32, @[asX, asX, asX, asMod, asImm], fRRR, -1),
      (0x2B000000'u32, @[asW, asW, asW], fRRR, -1),
      (0x2B000000'u32, @[asW, asW, asW, asMod, asImm], fRRR, -1),
      (0xB1000000'u32, @[asX, asX, asImm], fRRI12, -1),
      (0xB1000000'u32, @[asX, asX, asImm, asMod, asImm], fRRI12, -1),
      (0x31000000'u32, @[asW, asW, asImm], fRRI12, -1),
      (0x31000000'u32, @[asW, asW, asImm, asMod, asImm], fRRI12, -1),
    ]
  of "sub":
    @[
      (0x2E208400'u32, @[asVeB, asVeB, asVeB], fVecRRR, -1),
      (0x2E608400'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x2EA08400'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x2EE08400'u32, @[asVeD, asVeD, asVeD], fVecRRR, -1),
      (0xCB000000'u32, @[asX, asX, asX], fRRR, -1),
      (0xCB000000'u32, @[asX, asX, asX, asMod, asImm], fRRR, -1),
      (0x4B000000'u32, @[asW, asW, asW], fRRR, -1),
      (0x4B000000'u32, @[asW, asW, asW, asMod], fRRR, -1),
      (0x4B000000'u32, @[asW, asW, asW, asMod, asImm], fRRR, -1),
      # SP is legal in Rd/Rn (not Rm) of SUB shifted-register.
      (0xCB000000'u32, @[asXSP, asXSP, asX], fRRR, -1),
      (0xD1000000'u32, @[asXSP, asXSP, asImm], fRRI12, -1),
      (0xD1000000'u32, @[asXSP, asXSP, asImm, asMod, asImm], fRRI12, -1),
      (0x51000000'u32, @[asWSP, asWSP, asImm], fRRI12, -1),
      (0x51000000'u32, @[asWSP, asWSP, asImm, asMod, asImm], fRRI12, -1),
    ]
  of "subs":
    @[
      (0xEB000000'u32, @[asX, asX, asX], fRRR, -1),
      (0xEB000000'u32, @[asX, asX, asX, asMod, asImm], fRRR, -1),
      (0x6B000000'u32, @[asW, asW, asW], fRRR, -1),
      (0x6B000000'u32, @[asW, asW, asW, asMod, asImm], fRRR, -1),
      (0xF1000000'u32, @[asX, asX, asImm], fRRI12, -1),
      (0xF1000000'u32, @[asX, asX, asImm, asMod, asImm], fRRI12, -1),
      (0x71000000'u32, @[asW, asW, asImm], fRRI12, -1),
      (0x71000000'u32, @[asW, asW, asImm, asMod, asImm], fRRI12, -1),
    ]
  of "cmp":
    @[
      (0xEB00001F'u32, @[asX, asX], fXRR, -1),
      (0xEB00001F'u32, @[asX, asX, asMod, asImm], fXRR, -1),
      (0x6B00001F'u32, @[asW, asW], fXRR, -1),
      (0x6B00001F'u32, @[asW, asW, asMod, asImm], fXRR, -1),
      (0xF100001F'u32, @[asXSP, asImm], fRRI12, -1),
      (0xF100001F'u32, @[asXSP, asImm, asMod, asImm], fRRI12, -1),
      (0x7100001F'u32, @[asWSP, asImm], fRRI12, -1),
      (0x7100001F'u32, @[asWSP, asImm, asMod, asImm], fRRI12, -1),
    ]
  of "cmn":
    @[
      (0xAB00001F'u32, @[asX, asX], fXRR, -1),
      (0xAB00001F'u32, @[asX, asX, asMod, asImm], fXRR, -1),
      (0x2B00001F'u32, @[asW, asW], fXRR, -1),
      (0x2B00001F'u32, @[asW, asW, asMod, asImm], fXRR, -1),
      (0xB100001F'u32, @[asXSP, asImm], fRRI12, -1),
      (0xB100001F'u32, @[asXSP, asImm, asMod, asImm], fRRI12, -1),
      (0x3100001F'u32, @[asWSP, asImm], fRRI12, -1),
      (0x3100001F'u32, @[asWSP, asImm, asMod, asImm], fRRI12, -1),
    ]
  of "and":
    @[
      (0x0E201C00'u32, @[asVeB, asVeB, asVeB], fVecRRR, -1),
      (0x8A000000'u32, @[asX, asX, asX], fRRR, -1),
      (0x8A000000'u32, @[asX, asX, asX, asMod, asImm], fRRR, -1),
      (0x0A000000'u32, @[asW, asW, asW], fRRR, -1),
      (0x0A000000'u32, @[asW, asW, asW, asMod, asImm], fRRR, -1),
      (0x92000000'u32, @[asXSP, asX, asImm], fLogicI, -1),
      (0x12000000'u32, @[asWSP, asW, asImm], fLogicI, -1),
    ]
  of "orr":
    @[
      (0x0EA01C00'u32, @[asVeB, asVeB, asVeB], fVecRRR, -1),
      (0xAA000000'u32, @[asX, asX, asX], fRRR, -1),
      (0xAA000000'u32, @[asX, asX, asX, asMod, asImm], fRRR, -1),
      (0x2A000000'u32, @[asW, asW, asW], fRRR, -1),
      (0x2A000000'u32, @[asW, asW, asW, asMod, asImm], fRRR, -1),
      (0xB2000000'u32, @[asXSP, asX, asImm], fLogicI, -1),
      (0x32000000'u32, @[asWSP, asW, asImm], fLogicI, -1),
    ]
  of "eor":
    @[
      (0x2E201C00'u32, @[asVeB, asVeB, asVeB], fVecRRR, -1),
      (0xCA000000'u32, @[asX, asX, asX], fRRR, -1),
      (0xCA000000'u32, @[asX, asX, asX, asMod, asImm], fRRR, -1),
      (0x4A000000'u32, @[asW, asW, asW], fRRR, -1),
      (0x4A000000'u32, @[asW, asW, asW, asMod, asImm], fRRR, -1),
      (0xD2000000'u32, @[asXSP, asX, asImm], fLogicI, -1),
      (0x52000000'u32, @[asWSP, asW, asImm], fLogicI, -1),
    ]
  of "bic":
    @[
      (0x0E601C00'u32, @[asVeB, asVeB, asVeB], fVecRRR, -1),
    ]
  of "ands":
    @[
      (0xEA000000'u32, @[asX, asX, asX], fRRR, -1),
      (0xEA000000'u32, @[asX, asX, asX, asMod, asImm], fRRR, -1),
      (0x6A000000'u32, @[asW, asW, asW], fRRR, -1),
      (0x6A000000'u32, @[asW, asW, asW, asMod, asImm], fRRR, -1),
      (0xF2000000'u32, @[asX, asX, asImm], fLogicI, -1),
      (0x72000000'u32, @[asW, asW, asImm], fLogicI, -1),
    ]
  of "tst":
    @[
      (0xEA00001F'u32, @[asX, asX], fXRR, -1),
      (0xEA00001F'u32, @[asX, asX, asMod, asImm], fXRR, -1),
      (0x6A00001F'u32, @[asW, asW], fXRR, -1),
      (0x6A00001F'u32, @[asW, asW, asMod, asImm], fXRR, -1),
      (0xF200001F'u32, @[asX, asImm], fLogicI, -1),
      (0x7200001F'u32, @[asW, asImm], fLogicI, -1),
    ]
  of "mvn":
    @[
      (0xAA2003E0'u32, @[asX, asX], fRR, -1),
      (0xAA2003E0'u32, @[asX, asX, asMod, asImm], fRR, -1),
      (0x2A2003E0'u32, @[asW, asW], fRR, -1),
      (0x2A2003E0'u32, @[asW, asW, asMod, asImm], fRR, -1),
    ]
  of "neg":
    @[
      (0xCB0003E0'u32, @[asX, asX], fRR, -1),
      (0xCB0003E0'u32, @[asX, asX, asMod, asImm], fRR, -1),
      (0x4B0003E0'u32, @[asW, asW], fRR, -1),
      (0x4B0003E0'u32, @[asW, asW, asMod, asImm], fRR, -1),
    ]
  of "lsl":
    @[
      (0x9AC02000'u32, @[asX, asX, asX], fRRR, -1),
      (0x1AC02000'u32, @[asW, asW, asW], fRRR, -1),
      (0xD3400000'u32, @[asX, asX, asImm], fBfmI, -1),
      (0x53000000'u32, @[asW, asW, asImm], fBfmI, -1),
    ]
  of "lsr":
    @[
      (0x9AC02400'u32, @[asX, asX, asX], fRRR, -1),
      (0x1AC02400'u32, @[asW, asW, asW], fRRR, -1),
      (0xD340FC00'u32, @[asX, asX, asImm], fBfmI, -1),
      (0x53007C00'u32, @[asW, asW, asImm], fBfmI, -1),
    ]
  of "asr":
    @[
      (0x9AC02800'u32, @[asX, asX, asX], fRRR, -1),
      (0x1AC02800'u32, @[asW, asW, asW], fRRR, -1),
      (0x9340FC00'u32, @[asX, asX, asImm], fBfmI, -1),
      (0x13007C00'u32, @[asW, asW, asImm], fBfmI, -1),
    ]
  of "mul":
    @[
      (0x0E209C00'u32, @[asVeB, asVeB, asVeB], fVecRRR, -1),
      (0x0E609C00'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x0EA09C00'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x9B007C00'u32, @[asX, asX, asX], fRRR, -1),
      (0x1B007C00'u32, @[asW, asW, asW], fRRR, -1),
    ]
  of "madd":
    @[
      (0x9B000000'u32, @[asX, asX, asX, asX], fRRRR, -1),
      (0x1B000000'u32, @[asW, asW, asW, asW], fRRRR, -1),
    ]
  of "msub":
    @[
      (0x9B008000'u32, @[asX, asX, asX, asX], fRRRR, -1),
      (0x1B008000'u32, @[asW, asW, asW, asW], fRRRR, -1),
    ]
  of "sdiv":
    @[
      (0x9AC00C00'u32, @[asX, asX, asX], fRRR, -1),
      (0x1AC00C00'u32, @[asW, asW, asW], fRRR, -1),
    ]
  of "udiv":
    @[
      (0x9AC00800'u32, @[asX, asX, asX], fRRR, -1),
      (0x1AC00800'u32, @[asW, asW, asW], fRRR, -1),
    ]
  of "ldr":
    @[
      (0xF9400000'u32, @[asX, asMemOff], fMemU, -1),
      (0xF9400000'u32, @[asX, asMemBase], fMemU, -1),
      (0xB9400000'u32, @[asW, asMemOff], fMemU, -1),
      (0xB9400000'u32, @[asW, asMemBase], fMemU, -1),
      (0xF8400C00'u32, @[asX, asMemPre], fMem9, -1),
      (0xB8400C00'u32, @[asW, asMemPre], fMem9, -1),
      (0xF8400400'u32, @[asX, asMemBase, asImm], fMem9, -1),
      (0xB8400400'u32, @[asW, asMemBase, asImm], fMem9, -1),
      (0xF8600800'u32, @[asX, asMemIdx], fMemX, -1),
      (0xB8600800'u32, @[asW, asMemIdx], fMemX, -1),
      (0x58000000'u32, @[asX, asLbl], fBr, AarchBCond),
      (0x18000000'u32, @[asW, asLbl], fBr, AarchBCond),
      # SIMD&FP: unsigned-offset scales are the access log2 size
      # (B unscaled, H/1, S/2, D/3, Q/4).
      (0x3D400000'u32, @[asB, asMemOff], fMemU, -1),
      (0x3D400000'u32, @[asB, asMemBase], fMemU, -1),
      (0x7D400000'u32, @[asH, asMemOff], fMemU, -1),
      (0x7D400000'u32, @[asH, asMemBase], fMemU, -1),
      (0xBD400000'u32, @[asS, asMemOff], fMemU, -1),
      (0xBD400000'u32, @[asS, asMemBase], fMemU, -1),
      (0xFD400000'u32, @[asD, asMemOff], fMemU, -1),
      (0xFD400000'u32, @[asD, asMemBase], fMemU, -1),
      (0x3DC00000'u32, @[asQ, asMemOff], fMemU, -1),
      (0x3DC00000'u32, @[asQ, asMemBase], fMemU, -1),
      (0x3C400C00'u32, @[asB, asMemPre], fMem9, -1),
      (0x7C400C00'u32, @[asH, asMemPre], fMem9, -1),
      (0xBC400C00'u32, @[asS, asMemPre], fMem9, -1),
      (0xFC400C00'u32, @[asD, asMemPre], fMem9, -1),
      (0x3CC00C00'u32, @[asQ, asMemPre], fMem9, -1),
      (0x3C400400'u32, @[asB, asMemBase, asImm], fMem9, -1),
      (0x7C400400'u32, @[asH, asMemBase, asImm], fMem9, -1),
      (0xBC400400'u32, @[asS, asMemBase, asImm], fMem9, -1),
      (0xFC400400'u32, @[asD, asMemBase, asImm], fMem9, -1),
      (0x3CC00400'u32, @[asQ, asMemBase, asImm], fMem9, -1),
      (0x3C600800'u32, @[asB, asMemIdx], fMemX, -1),
      (0x7C600800'u32, @[asH, asMemIdx], fMemX, -1),
      (0xBC600800'u32, @[asS, asMemIdx], fMemX, -1),
      (0xFC600800'u32, @[asD, asMemIdx], fMemX, -1),
      (0x3CE00800'u32, @[asQ, asMemIdx], fMemX, -1),
      (0x1C000000'u32, @[asS, asLbl], fBr, AarchBCond),
      (0x5C000000'u32, @[asD, asLbl], fBr, AarchBCond),
      (0x9C000000'u32, @[asQ, asLbl], fBr, AarchBCond),
    ]
  of "str":
    @[
      (0xF9000000'u32, @[asX, asMemOff], fMemU, -1),
      (0xF9000000'u32, @[asX, asMemBase], fMemU, -1),
      (0xB9000000'u32, @[asW, asMemOff], fMemU, -1),
      (0xB9000000'u32, @[asW, asMemBase], fMemU, -1),
      (0xF8000C00'u32, @[asX, asMemPre], fMem9, -1),
      (0xB8000C00'u32, @[asW, asMemPre], fMem9, -1),
      (0xF8000400'u32, @[asX, asMemBase, asImm], fMem9, -1),
      (0xB8000400'u32, @[asW, asMemBase, asImm], fMem9, -1),
      (0xF8200800'u32, @[asX, asMemIdx], fMemX, -1),
      (0xB8200800'u32, @[asW, asMemIdx], fMemX, -1),
      (0x3D000000'u32, @[asB, asMemOff], fMemU, -1),
      (0x3D000000'u32, @[asB, asMemBase], fMemU, -1),
      (0x7D000000'u32, @[asH, asMemOff], fMemU, -1),
      (0x7D000000'u32, @[asH, asMemBase], fMemU, -1),
      (0xBD000000'u32, @[asS, asMemOff], fMemU, -1),
      (0xBD000000'u32, @[asS, asMemBase], fMemU, -1),
      (0xFD000000'u32, @[asD, asMemOff], fMemU, -1),
      (0xFD000000'u32, @[asD, asMemBase], fMemU, -1),
      (0x3D800000'u32, @[asQ, asMemOff], fMemU, -1),
      (0x3D800000'u32, @[asQ, asMemBase], fMemU, -1),
      (0x3C000C00'u32, @[asB, asMemPre], fMem9, -1),
      (0x7C000C00'u32, @[asH, asMemPre], fMem9, -1),
      (0xBC000C00'u32, @[asS, asMemPre], fMem9, -1),
      (0xFC000C00'u32, @[asD, asMemPre], fMem9, -1),
      (0x3C800C00'u32, @[asQ, asMemPre], fMem9, -1),
      (0x3C000400'u32, @[asB, asMemBase, asImm], fMem9, -1),
      (0x7C000400'u32, @[asH, asMemBase, asImm], fMem9, -1),
      (0xBC000400'u32, @[asS, asMemBase, asImm], fMem9, -1),
      (0xFC000400'u32, @[asD, asMemBase, asImm], fMem9, -1),
      (0x3C800400'u32, @[asQ, asMemBase, asImm], fMem9, -1),
      (0x3C200800'u32, @[asB, asMemIdx], fMemX, -1),
      (0x7C200800'u32, @[asH, asMemIdx], fMemX, -1),
      (0xBC200800'u32, @[asS, asMemIdx], fMemX, -1),
      (0xFC200800'u32, @[asD, asMemIdx], fMemX, -1),
      (0x3CA00800'u32, @[asQ, asMemIdx], fMemX, -1),
    ]
  of "ldp":
    @[
      (0xA9400000'u32, @[asX, asX, asMemOff], fPair, -1),
      (0xA9400000'u32, @[asX, asX, asMemBase], fPair, -1),
      (0x29400000'u32, @[asW, asW, asMemOff], fPair, -1),
      (0x29400000'u32, @[asW, asW, asMemBase], fPair, -1),
      (0xA9C00000'u32, @[asX, asX, asMemPre], fPair, -1),
      (0x29C00000'u32, @[asW, asW, asMemPre], fPair, -1),
      (0xA8C00000'u32, @[asX, asX, asMemBase, asImm], fPair, -1),
      (0x28C00000'u32, @[asW, asW, asMemBase, asImm], fPair, -1),
    ]
  of "stp":
    @[
      (0xA9000000'u32, @[asX, asX, asMemOff], fPair, -1),
      (0xA9000000'u32, @[asX, asX, asMemBase], fPair, -1),
      (0x29000000'u32, @[asW, asW, asMemOff], fPair, -1),
      (0x29000000'u32, @[asW, asW, asMemBase], fPair, -1),
      (0xA9800000'u32, @[asX, asX, asMemPre], fPair, -1),
      (0x29800000'u32, @[asW, asW, asMemPre], fPair, -1),
      (0xA8800000'u32, @[asX, asX, asMemBase, asImm], fPair, -1),
      (0x28800000'u32, @[asW, asW, asMemBase, asImm], fPair, -1),
    ]
  of "b":
    @[
      (0x14000000'u32, @[asLbl], fBr, AarchB),
    ]
  of "b.cond":
    @[
      # base ORed with the 4-bit condition at macro expansion time;
      # rel id filled in by the matcher (always BCOND here).
      (0x54000000'u32, @[asLbl], fBr, AarchBCond),
    ]
  of "bl":
    @[
      (0x94000000'u32, @[asLbl], fBr, AarchB),
    ]
  of "br":
    @[
      (0xD61F0000'u32, @[asX], fBrReg, -1),
    ]
  of "blr":
    @[
      (0xD63F0000'u32, @[asX], fBrReg, -1),
    ]
  of "ret":
    @[
      (0xD65F0000'u32, @[asX], fBrReg, -1),
      (0xD65F03C0'u32, @[], fMisc, -1),
    ]
  of "cbz":
    @[
      (0xB4000000'u32, @[asX, asLbl], fCbx, AarchBCond),
      (0x34000000'u32, @[asW, asLbl], fCbx, AarchBCond),
    ]
  of "cbnz":
    @[
      (0xB5000000'u32, @[asX, asLbl], fCbx, AarchBCond),
      (0x35000000'u32, @[asW, asLbl], fCbx, AarchBCond),
    ]
  of "cset":
    @[
      # CSET Wd, cond = CSINC Wd, WZR, WZR, !cond. The inverted cond
      # field is ORed into the zero cond slot by the matcher (fCSet).
      (0x1A9F07E0'u32, @[asW, asCond], fCSet, -1),
      (0x9A9F07E0'u32, @[asX, asCond], fCSet, -1),
    ]
  of "tbz":
    @[
      (0x36000000'u32, @[asX, asImm, asLbl], fTbx, AarchTbz),
      (0x36000000'u32, @[asW, asImm, asLbl], fTbx, AarchTbz),
    ]
  of "tbnz":
    @[
      (0x37000000'u32, @[asX, asImm, asLbl], fTbx, AarchTbz),
      (0x37000000'u32, @[asW, asImm, asLbl], fTbx, AarchTbz),
    ]
  of "adr":
    @[
      (0x10000000'u32, @[asX, asLbl], fAdr, AarchAdr),
    ]
  of "adrp":
    @[
      (0x90000000'u32, @[asX, asLbl], fAdr, AarchAdrp),
    ]
  of "fmov":
    @[
      (0x1E204000'u32, @[asS, asS], fRRn, -1),
      (0x1E604000'u32, @[asD, asD], fRRn, -1),
      (0x1E201000'u32, @[asS, asFImm], fFmovI, -1),
      (0x1E601000'u32, @[asD, asFImm], fFmovI, -1),
      (0x1E270000'u32, @[asS, asW], fRRn, -1),
      (0x9E670000'u32, @[asD, asX], fRRn, -1),
      (0x1E260000'u32, @[asW, asS], fRRn, -1),
      (0x9E660000'u32, @[asX, asD], fRRn, -1),
    ]
  of "fadd":
    @[
      (0x1E202800'u32, @[asS, asS, asS], fRRR, -1),
      (0x1E602800'u32, @[asD, asD, asD], fRRR, -1),
      (0x0E401400'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x0E20D400'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x0E60D400'u32, @[asVeD, asVeD, asVeD], fVecRRR, -1),
    ]
  of "fsub":
    @[
      (0x1E203800'u32, @[asS, asS, asS], fRRR, -1),
      (0x1E603800'u32, @[asD, asD, asD], fRRR, -1),
      (0x0EC01400'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x0EA0D400'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x0EE0D400'u32, @[asVeD, asVeD, asVeD], fVecRRR, -1),
    ]
  of "fmul":
    @[
      (0x1E200800'u32, @[asS, asS, asS], fRRR, -1),
      (0x1E600800'u32, @[asD, asD, asD], fRRR, -1),
      (0x2E401C00'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x2E20DC00'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x2E60DC00'u32, @[asVeD, asVeD, asVeD], fVecRRR, -1),
    ]
  of "fdiv":
    @[
      (0x1E201800'u32, @[asS, asS, asS], fRRR, -1),
      (0x1E601800'u32, @[asD, asD, asD], fRRR, -1),
      (0x2E403C00'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x2E20FC00'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x2E60FC00'u32, @[asVeD, asVeD, asVeD], fVecRRR, -1),
    ]
  of "fmax":
    @[
      (0x1E204800'u32, @[asS, asS, asS], fRRR, -1),
      (0x1E604800'u32, @[asD, asD, asD], fRRR, -1),
      (0x0E403400'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x0E20F400'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x0E60F400'u32, @[asVeD, asVeD, asVeD], fVecRRR, -1),
    ]
  of "fmin":
    @[
      (0x1E205800'u32, @[asS, asS, asS], fRRR, -1),
      (0x1E605800'u32, @[asD, asD, asD], fRRR, -1),
      (0x0EC03400'u32, @[asVeH, asVeH, asVeH], fVecRRR, -1),
      (0x0EA0F400'u32, @[asVeS, asVeS, asVeS], fVecRRR, -1),
      (0x0EE0F400'u32, @[asVeD, asVeD, asVeD], fVecRRR, -1),
    ]
  of "fneg":
    @[
      (0x1E214000'u32, @[asS, asS], fRRn, -1),
      (0x1E614000'u32, @[asD, asD], fRRn, -1),
    ]
  of "fabs":
    @[
      (0x1E20C000'u32, @[asS, asS], fRRn, -1),
      (0x1E60C000'u32, @[asD, asD], fRRn, -1),
    ]
  of "fsqrt":
    @[
      (0x1E21C000'u32, @[asS, asS], fRRn, -1),
      (0x1E61C000'u32, @[asD, asD], fRRn, -1),
    ]
  of "fcmp":
    @[
      (0x1E202000'u32, @[asS, asS], fXRR, -1),
      (0x1E602000'u32, @[asD, asD], fXRR, -1),
      (0x1E202008'u32, @[asS, asFZero], fFcmp0, -1),
      (0x1E602008'u32, @[asD, asFZero], fFcmp0, -1),
    ]
  of "fcmpe":
    @[
      (0x1E202010'u32, @[asS, asS], fXRR, -1),
      (0x1E602010'u32, @[asD, asD], fXRR, -1),
      (0x1E202018'u32, @[asS, asFZero], fFcmp0, -1),
      (0x1E602018'u32, @[asD, asFZero], fFcmp0, -1),
    ]
  of "scvtf":
    @[
      (0x1E220000'u32, @[asS, asW], fRRn, -1),
      (0x9E220000'u32, @[asS, asX], fRRn, -1),
      (0x1E620000'u32, @[asD, asW], fRRn, -1),
      (0x9E620000'u32, @[asD, asX], fRRn, -1),
    ]
  of "ucvtf":
    @[
      (0x1E230000'u32, @[asS, asW], fRRn, -1),
      (0x9E230000'u32, @[asS, asX], fRRn, -1),
      (0x1E630000'u32, @[asD, asW], fRRn, -1),
      (0x9E630000'u32, @[asD, asX], fRRn, -1),
    ]
  of "fcvtzs":
    @[
      (0x1E380000'u32, @[asW, asS], fRRn, -1),
      (0x9E380000'u32, @[asX, asS], fRRn, -1),
      (0x1E780000'u32, @[asW, asD], fRRn, -1),
      (0x9E780000'u32, @[asX, asD], fRRn, -1),
    ]
  of "fcvtzu":
    @[
      (0x1E390000'u32, @[asW, asS], fRRn, -1),
      (0x9E390000'u32, @[asX, asS], fRRn, -1),
      (0x1E790000'u32, @[asW, asD], fRRn, -1),
      (0x9E790000'u32, @[asX, asD], fRRn, -1),
    ]
  of "fcvt":
    @[
      (0x1E624000'u32, @[asS, asD], fRRn, -1),
      (0x1E22C000'u32, @[asD, asS], fRRn, -1),
    ]
  of "dup":
    @[
      (0x0E010C00'u32, @[asVeB, asW], fDupG, -1),
      (0x0E010C00'u32, @[asVeB, asX], fDupG, -1),
      (0x0E020C00'u32, @[asVeH, asW], fDupG, -1),
      (0x0E020C00'u32, @[asVeH, asX], fDupG, -1),
      (0x0E040C00'u32, @[asVeS, asW], fDupG, -1),
      (0x0E040C00'u32, @[asVeS, asX], fDupG, -1),
      (0x0E080C00'u32, @[asVeD, asW], fDupG, -1),
      (0x0E080C00'u32, @[asVeD, asX], fDupG, -1),
    ]
  of "movi":
    @[
      (0x0F000400'u32, @[asVeS, asImm], fVecMovi, -1),
      (0x0F000400'u32, @[asVeS, asImm, asMod, asImm], fVecMovi, -1),
      (0x0F008400'u32, @[asVeH, asImm], fVecMovi, -1),
      (0x0F008400'u32, @[asVeH, asImm, asMod, asImm], fVecMovi, -1),
      (0x0F00E400'u32, @[asVeB, asImm], fVecMovi, -1),
      (0x2F00E400'u32, @[asVeD, asImm], fVecMoviD, -1),
    ]
  of "nop":
    @[
      (0xD503201F'u32, @[], fMisc, -1),
    ]
  of "hlt":
    @[
      (0xD4400000'u32, @[asImm], fHlt, -1),
    ]
  of "svc":
    @[
      (0xD4000001'u32, @[asImm], fHlt, -1),
    ]
  else:
    @[]

proc a64Mnemonics*(): seq[string] =
  @["mov", "mov.inverted", "mov.logical", "movz", "movn", "movk",
    "add", "adds", "sub", "subs", "cmp", "cmn",
    "and", "orr", "eor", "ands", "tst", "mvn", "neg",
    "lsl", "lsr", "asr", "mul", "madd", "msub", "sdiv", "udiv",
    "ldr", "str", "ldp", "stp",
    "b", "bl", "br", "blr", "ret", "cbz", "cbnz", "tbz", "tbnz",
    "adr", "adrp", "nop", "hlt", "svc", "fmov", "fadd", "fsub",
    "fmul", "fdiv", "fmax", "fmin", "fneg", "fabs", "fsqrt",
    "fcmp", "fcmpe", "scvtf", "ucvtf", "fcvtzs", "fcvtzu", "fcvt",
    "dup", "movi", "bic"]
