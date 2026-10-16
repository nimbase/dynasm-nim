## AArch64 compile-time matching, validation and emission.
## Used by the `dynasm` macro for `arch aarch64` blocks. Mirrors
## dynasm-rs parser.rs (operand shapes), matching.rs (opdata selection
## with `instruction format mismatch` errors) and the static half of
## compiler.rs (literal range checks at expansion time; dynamic values
## are re-checked at runtime by aarch64.nim).

import std/macros
import std/tables
import std/strutils
import ./registers
import ./aarch64data
import ./aarch64

type
  A64RegInfo = tuple[code: int, is64: bool, sp, zero: bool]

proc a64RegTable(): Table[string, A64RegInfo] =
  result = initTable[string, A64RegInfo]()
  for i in 0..30:
    result["x" & $i] = (i, true, false, false)
    result["w" & $i] = (i, false, false, false)
  result["xzr"] = (31, true, false, true)
  result["wzr"] = (31, false, false, true)
  result["sp"] = (31, true, true, false)
  result["wsp"] = (31, false, true, false)

type
  A64FpInfo = tuple[code: int, size: int] ## size in bytes: b1 h2 s4 d8 q16

proc a64FpRegTable(): Table[string, A64FpInfo] =
  ## Scalar SIMD registers, mirroring rs AARCH64_REGISTERS b/h/s/d/q.
  result = initTable[string, A64FpInfo]()
  for i in 0..31:
    result["b" & $i] = (i, 1)
    result["h" & $i] = (i, 2)
    result["s" & $i] = (i, 4)
    result["d" & $i] = (i, 8)
    result["q" & $i] = (i, 16)

proc a64Arrangement(suffix: string): tuple[shape: A64Shape, size: int,
    is128: bool] =
  ## Vector arrangement suffix, e.g. "s4" -> (asVeS, 4, true).
  ## rs writes element letter first + lane count (ARM's lane-first
  ## form is unparseable); total 64 bits -> Q=0, 128 -> Q=1.
  case suffix
  of "b8": (asVeB, 1, false)
  of "b16": (asVeB, 1, true)
  of "h4": (asVeH, 2, false)
  of "h8": (asVeH, 2, true)
  of "s2": (asVeS, 4, false)
  of "s4": (asVeS, 4, true)
  of "d1": (asVeD, 8, false)
  of "d2": (asVeD, 8, true)
  else: (asVeB, 0, false)

proc a64IsBareV*(name: string): bool =
  ## Bare `vN` without an arrangement suffix (invalid; needs `.b8` etc).
  if name.len < 2 or name[0] != 'v': return false
  for c in name[1..^1]:
    if c notin {'0'..'9'}: return false
  true

proc a64ResolveIdent(name: string,
    aliases: Table[string, string]): string =
  var n = name.toLowerAscii
  var guard = 0
  while n in aliases and guard < 64:
    n = aliases[n]
    inc guard
  n

proc a64IsReg*(name: string, aliases: Table[string, string]): bool =
  let n = a64ResolveIdent(name, aliases)
  n in a64RegTable() or n in a64FpRegTable()

proc a64RegInfoOf*(name: string,
    aliases: Table[string, string]): A64RegInfo =
  a64RegTable()[a64ResolveIdent(name, aliases)]

# --------------------------------------------------------------------------
# Literal helpers
# --------------------------------------------------------------------------

proc intLitVal(node: NimNode): tuple[isLit: bool, v: int64] =
  ## Static integer value, or not-a-literal (dynamic expr).
  ## Huge uint64 literals that don't fit int64 count as dynamic so the
  ## runtime encoder (which works on uint64) can still accept them.
  const intKinds = {nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit,
    nnkInt64Lit, nnkUIntLit, nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit,
    nnkUInt64Lit}
  if node.kind in intKinds:
    let v = node.intVal
    if node.kind == nnkUInt64Lit and v < 0:
      return (false, 0)
    return (true, v)
  if node.kind == nnkPrefix and node.len == 2 and
      node[0].kind == nnkIdent and node[0].strVal == "-" and
      node[1].kind in intKinds:
    return (true, -node[1].intVal)
  (false, 0)

proc rejectA64BadLiteral(mn: string, node: NimNode) =
  if node.kind == nnkFloatLit:
    error("dynasm: '" & mn & "' needs integer operands, got float " &
      "literal", node)
  elif node.kind == nnkStrLit:
    error("dynasm: '" & mn & "' got a string literal", node)
  elif node.kind == nnkCharLit:
    error("dynasm: '" & mn & "' got a character literal; use ord('x')",
      node)

proc checkU(mn: string, lit: int64, lo, hi: int64, what: string,
    node: NimNode) =
  if lit < lo:
    error("dynasm: '" & mn & "' " & what & " too low", node)
  if lit > hi:
    error("dynasm: '" & mn & "' " & what & " too high", node)

# --------------------------------------------------------------------------
# Memory operand parsing: [base], [base, off], [base, idx (, ext (, amt))]
# --------------------------------------------------------------------------

type
  A64MemInfo = object
    shape: A64Shape ## asMemBase/asMemOff/asMemIdx
    base: NimNode
    baseIsX: bool
    off: NimNode   ## imm expr, nil when base-only
    idx: NimNode   ## index reg, nil unless indexed
    idxIs64: bool
    extName: string ## "" when none
    extAmt: NimNode ## nil when none

proc a64RegNode(n: NimNode, aliases: Table[string, string],
    wantX: bool, what: string, stmt: NimNode): tuple[expr: NimNode,
    is64: bool] =
  if n.kind == nnkIdent:
    let resolved = a64ResolveIdent(n.strVal, aliases)
    if resolved in a64FpRegTable():
      error("dynasm: " & what & " must be an integer register", n)
    if not a64IsReg(n.strVal, aliases):
      error("dynasm: " & what & " must be a register", n)
    let ri = a64RegInfoOf(n.strVal, aliases)
    if wantX and not ri.is64:
      error("dynasm: " & what & " must be a 64-bit register", n)
    let codeLit = newLit(ri.code)
    let e = quote do: Register(code: uint8(`codeLit`), cls: rcGpr)
    return (e, ri.is64)
  if n.kind == nnkCall and n.len == 2:
    let fn = n[0].strVal.toLowerAscii
    if fn == "xreg":
      return (n, true)
    if fn == "wreg":
      if wantX:
        error("dynasm: " & what & " must be a 64-bit register", n)
      return (n, false)
  error("dynasm: " & what & " must be a register", n)

proc a64ParseMem(mn: string, br: NimNode,
    aliases: Table[string, string], stmt: NimNode): A64MemInfo =
  if br.len == 0:
    error("dynasm: empty []", br)
  if br[0].kind == nnkIdent:
    let bn = a64ResolveIdent(br[0].strVal, aliases)
    if bn in ["xzr", "wzr"]:
      error("dynasm: memory base cannot be the zero register", br[0])
  let (baseExpr, baseIsX) = a64RegNode(br[0], aliases, true,
    "memory base", stmt)
  result.base = baseExpr
  result.baseIsX = baseIsX
  if br.len == 1:
    result.shape = asMemBase
    return
  let second = br[1]
  # index register?
  var isIdxReg = false
  var idxIs64 = false
  if second.kind == nnkIdent and a64IsReg(second.strVal, aliases):
    let ri = a64RegInfoOf(second.strVal, aliases)
    isIdxReg = true
    idxIs64 = ri.is64
  elif second.kind == nnkCall and second.len == 2 and
      second[0].strVal.toLowerAscii in ["xreg", "wreg"]:
    isIdxReg = true
    idxIs64 = second[0].strVal.toLowerAscii == "xreg"
  if isIdxReg:
    result.shape = asMemIdx
    let (idxExpr, _) = a64RegNode(second, aliases, false,
      "index register", stmt)
    result.idx = idxExpr
    result.idxIs64 = idxIs64
    if br.len == 2:
      return
    # Remaining children: the extend modifier, either as one item
    # (`lsl 3`, `uxtw`) or two (`lsl, 3`).
    var modName = ""
    var amt: NimNode = nil
    var tail: seq[NimNode] = @[]
    for k in 2..<br.len: tail.add(br[k])
    if tail.len == 1:
      let m = tail[0]
      if m.kind == nnkIdent:
        modName = m.strVal.toLowerAscii
      elif m.kind in {nnkCall, nnkCommand} and
          m[0].kind == nnkIdent:
        modName = m[0].strVal.toLowerAscii
        if m.len == 2: amt = m[1]
        elif m.len > 2:
          error("dynasm: bad extend modifier", m)
      else:
        error("dynasm: bad extend modifier, use lsl/sxtx/sxtw/uxtw " &
          "with an optional amount", m)
    elif tail.len == 2 and tail[0].kind == nnkIdent:
      modName = tail[0].strVal.toLowerAscii
      amt = tail[1]
    else:
      error("dynasm: too many items in []", br)
    if modName notin a64ExtendMods:
      error("dynasm: bad extend modifier '" & modName & "'", br[2])
    result.extName = modName
    result.extAmt = amt
    return
  # otherwise: offset immediate
  if br.len > 2:
    error("dynasm: too many items in []", br)
  rejectA64BadLiteral(mn, second)
  result.shape = asMemOff
  result.off = second

# --------------------------------------------------------------------------
# Argument classification
# --------------------------------------------------------------------------

type
  A64Arg = object
    shape: A64Shape
    node: NimNode
    mem: A64MemInfo  ## valid when shape is a mem shape
    isZero: bool     ## statically the zero register (xzr/wzr)
    vElem: int       ## vector element size in bytes (0 when N/A)
    vIs128: bool     ## vector arrangement totals 128 bits

proc a64FloatVal(node: NimNode): tuple[isLit: bool, v: float64] =
  ## Static float value, with rs-style negation (as_float).
  if node.kind == nnkFloatLit:
    return (true, node.floatVal)
  if node.kind == nnkPrefix and node.len == 2 and
      node[0].kind == nnkIdent and node[0].strVal == "-" and
      node[1].kind == nnkFloatLit:
    return (true, -node[1].floatVal)
  (false, 0.0)

proc a64Classify(mn: string, node: NimNode,
    aliases: Table[string, string], stmt: NimNode): A64Arg =
  if node.kind == nnkIdent:
    let n = a64ResolveIdent(node.strVal, aliases)
    if n in a64RegTable():
      let ri = a64RegTable()[n]
      let sh =
        if ri.sp: (if ri.is64: asXSP else: asWSP)
        elif ri.is64: asX
        else: asW
      return A64Arg(shape: sh, node: node, isZero: ri.zero)
    if n in a64FpRegTable():
      let fi = a64FpRegTable()[n]
      let sh =
        case fi.size
        of 1: asB
        of 2: asH
        of 4: asS
        of 8: asD
        else: asQ
      return A64Arg(shape: sh, node: node)
    if a64IsBareV(n):
      error("dynasm: vector register '" & node.strVal &
        "' needs an arrangement suffix, e.g. v0.s4 or v0.b16", node)
    if n in a64ShiftMods or n in a64ExtendMods:
      return A64Arg(shape: asMod, node: node)
    if n == "pre":
      return A64Arg(shape: asPre, node: node)
    # Anything else: a dynamic immediate expression (a bare Nim
    # identifier evaluates at runtime). Matches rs, where unknown
    # idents fall into the dynamic-immediate path.
    return A64Arg(shape: asImm, node: node)
  if node.kind == nnkDotExpr and node.len == 2 and
      node[0].kind == nnkIdent and node[1].kind == nnkIdent:
    # Vector register vN.<suffix>, e.g. v0.s4 (rs writes the
    # element letter first since ARM's lane-first form is
    # unparseable, and so is Nim's).
    let base = a64ResolveIdent(node[0].strVal, aliases)
    if a64IsBareV(base):
      let (sh, size, is128) = a64Arrangement(
        node[1].strVal.toLowerAscii)
      if size == 0:
        error("dynasm: bad vector arrangement '" & node[1].strVal &
          "'; use b8/b16, h4/h8, s2/s4 or d1/d2", node[1])
      let codeLit = newLit(parseInt(base[1..^1]))
      let regNode = quote do:
        Register(code: uint8(`codeLit`), cls: rcGpr)
      return A64Arg(shape: sh, node: regNode, vElem: size,
        vIs128: is128)
  let (isLit, _) = intLitVal(node)
  if isLit:
    # rs coerces int literals for fmov-imm (float32 conversion);
    # everything else takes integer immediates.
    if mn == "fmov":
      return A64Arg(shape: asFImm, node: node)
    return A64Arg(shape: asImm, node: node)
  let (isFlt, _) = a64FloatVal(node)
  if isFlt:
    # Only fmov-imm and fcmp-zero take floats (validated at emit).
    if mn in ["fmov"]:
      return A64Arg(shape: asFImm, node: node)
    if mn in ["fcmp", "fcmpe"]:
      return A64Arg(shape: asFZero, node: node)
    rejectA64BadLiteral(mn, node)
    return A64Arg(shape: asImm, node: node)
  if node.kind in {nnkStrLit, nnkCharLit}:
    rejectA64BadLiteral(mn, node)
    return A64Arg(shape: asImm, node: node)
  if node.kind == nnkCall and node.len >= 1:
    let fn =
      if node[0].kind == nnkIdent: node[0].strVal.toLowerAscii
      elif node[0].kind == nnkAccQuoted and node[0].len > 0:
        node[0][0].strVal.toLowerAscii
      else: ""
    if fn in ["xreg", "wreg"]:
      if node.len != 2:
        error("dynasm: '" & fn & "' needs 1 arg: the register number",
          node)
      return A64Arg(
        shape: if fn == "xreg": asX else: asW, node: node)
    if fn in ["fwd", "forward", "bwd", "backward", "glob",
        "globalref", "dyn", "dynlbl", "dynamic"]:
      return A64Arg(shape: asLbl, node: node)
    if fn in ["extaddr", "externaddr"]:
      error("dynasm: extAddr is not supported in aarch64 mode; use " &
        "adr/adrp with a label", node)
  if node.kind == nnkInfix and node.len == 3 and
      node[0].kind == nnkIdent and node[0].strVal in ["+", "-"]:
    # label +/- literal: fold the offset into the LabelRef
    for side in [node[1], node[2]]:
      if side.kind == nnkCall and side.len >= 1:
        let fn = side[0].strVal.toLowerAscii
        if fn in ["fwd", "bwd", "glob", "dyn", "dynlbl"]:
          return A64Arg(shape: asLbl, node: node)
  if node.kind == nnkBracket:
    let mem = a64ParseMem(mn, node, aliases, stmt)
    return A64Arg(shape: mem.shape, node: node, mem: mem)
  # Fallback: dynamic immediate expression.
  A64Arg(shape: asImm, node: node)

# --------------------------------------------------------------------------
# Matching + mismatch diagnostics (rs matching.rs)
# --------------------------------------------------------------------------

proc a64ShapeName(s: A64Shape): string =
  case s
  of asX: "X"
  of asW: "W"
  of asXSP: "X|SP"
  of asWSP: "W|SP"
  of asB: "B"
  of asH: "H"
  of asS: "S"
  of asD: "D"
  of asQ: "Q"
  of asVeB: "Vb"
  of asVeH: "Vh"
  of asVeS: "Vs"
  of asVeD: "Vd"
  of asImm: "imm"
  of asFImm: "fimm"
  of asFZero: "0.0"
  of asMemBase: "[base]"
  of asMemOff: "[base, imm]"
  of asMemPre: "[base, imm] + pre"
  of asMemPost: "[base] + imm"
  of asMemIdx: "[base, index]"
  of asLbl: "label"
  of asMod: "mod"
  of asPre: "pre"

proc a64ShapesFit(entry: seq[A64Shape], cls: seq[A64Arg]): bool =
  ## Entry shapes accept the classified args. Like rs Matcher::XSP,
  ## an SP slot also accepts a non-zero plain X/W register.
  if entry.len != cls.len: return false
  for i in 0..<entry.len:
    if entry[i] == cls[i].shape: continue
    if entry[i] == asXSP and cls[i].shape == asX and
        not cls[i].isZero:
      continue
    if entry[i] == asWSP and cls[i].shape == asW and
        not cls[i].isZero:
      continue
    return false
  true

proc a64Mismatch(mn: string, shapes: seq[A64Shape], stmt: NimNode) =
  var forms = ""
  for e in a64Entries(mn):
    if forms != "": forms.add("\n")
    forms.add("  " & mn & " ")
    var first = true
    for s in e.shapes:
      if not first: forms.add(", ")
      first = false
      forms.add(a64ShapeName(s))
  var got = ""
  for i, s in shapes:
    if i > 0: got.add(", ")
    got.add(a64ShapeName(s))
  error("dynasm: '" & mn & "': instruction format mismatch " &
    "(got " & got & "), expected one of the following forms:\n" &
    forms, stmt)

# --------------------------------------------------------------------------
# Static literal validation (rs compiler.rs static_range_check half)
# --------------------------------------------------------------------------

proc a64CheckImm12(mn: string, arg: NimNode, stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit:
    checkU(mn, v, 0, 4095, "immediate", arg)

proc a64CheckShift12(mn: string, arg: NimNode, stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit and v != 0 and v != 12:
    error("dynasm: '" & mn & "' shift must be lsl #0 or lsl #12",
      arg)

proc a64CheckShiftAmt(mn: string, is64: bool, arg: NimNode,
    stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit:
    checkU(mn, v, 0, (if is64: 63 else: 31), "shift amount", arg)

proc a64CheckLogical(mn: string, is64: bool, arg: NimNode,
    stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if not isLit: return
  if is64:
    if encodeLogical64(cast[uint64](v)) < 0:
      error("dynasm: '" & mn & "' unrepresentable logical immediate",
        arg)
  else:
    if v < 0 or v > 0xFFFFFFFF'i64 or
        encodeLogical32(cast[uint32](v)) < 0:
      error("dynasm: '" & mn & "' unrepresentable logical immediate",
        arg)

proc a64CheckWide(mn: string, is64: bool, arg: NimNode,
    stmt: NimNode, inverted: bool) =
  let (isLit, v) = intLitVal(arg)
  if not isLit: return
  let u = cast[uint64](v)
  let ok =
    if inverted:
      if is64: encodeWide64(not u) >= 0
      else:
        v >= 0 and v <= 0xFFFFFFFF'i64 and
          encodeWide32(not cast[uint32](v)) >= 0
    else:
      if is64: encodeWide64(u) >= 0
      else:
        v >= 0 and v <= 0xFFFFFFFF'i64 and
          encodeWide32(cast[uint32](v)) >= 0
  if not ok:
    error("dynasm: '" & mn & "' unrepresentable immediate " &
      "(needs a single 16-bit slice)", arg)

proc a64CheckMovWideImm(mn: string, arg: NimNode, stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit:
    checkU(mn, v, 0, 0xFFFF, "immediate", arg)

proc a64CheckBfm(mn: string, is64: bool, isLsl: bool, arg: NimNode,
    stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if not isLit: return
  if isLsl:
    checkU(mn, v, 1, (if is64: 64 else: 32), "shift amount", arg)
  else:
    checkU(mn, v, 0, (if is64: 63 else: 31), "shift amount", arg)

proc a64CheckMemU(mn: string, scale: int, arg: NimNode,
    stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if not isLit: return
  if v < 0:
    error("dynasm: '" & mn & "' immediate too low", arg)
  if (v and int64((1 shl scale) - 1)) != 0:
    error("dynasm: '" & mn & "' unrepresentable immediate " &
      "(offset must be a multiple of " & $(1 shl scale) & ")", arg)
  if (v shr scale) > 4095:
    error("dynasm: '" & mn & "' immediate too high", arg)

proc a64CheckMem9(mn: string, arg: NimNode, stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit:
    checkU(mn, v, -256, 255, "offset", arg)

proc a64CheckPair(mn: string, scale: int, arg: NimNode,
    stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if not isLit: return
  if (v and int64((1 shl scale) - 1)) != 0:
    error("dynasm: '" & mn & "' unrepresentable immediate " &
      "(offset must be a multiple of " & $(1 shl scale) & ")", arg)
  checkU(mn, v shr scale, -64, 63, "offset", arg)

proc a64CheckTbz(mn: string, is64: bool, arg: NimNode,
    stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit:
    checkU(mn, v, 0, (if is64: 63 else: 31), "bit number", arg)

proc a64CheckHlt(mn: string, arg: NimNode, stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit:
    checkU(mn, v, 0, 0xFFFF, "immediate", arg)

proc a64CheckFloat(mn: string, arg: NimNode, stmt: NimNode) =
  ## fmov immediate: must be a representable float32 (rs as_float
  ## takes float literals; ints convert through float32). Note:
  ## float32() conversion, not cast[] — the VM rejects float bitcasts.
  let (isFlt, f) = a64FloatVal(arg)
  if isFlt:
    if encodeFloatImm(cast[uint32](float32(f))) < 0:
      error("dynasm: '" & mn & "' unrepresentable float immediate",
        arg)
    return
  let (isLit, v) = intLitVal(arg)
  if isLit:
    if encodeFloatImm(cast[uint32](float32(v))) < 0:
      error("dynasm: '" & mn & "' unrepresentable float immediate",
        arg)

proc a64CheckFZero(mn: string, arg: NimNode, stmt: NimNode) =
  let (isFlt, f) = a64FloatVal(arg)
  if isFlt and f != 0.0:
    error("dynasm: '" & mn & "' only takes #0.0 here", arg)

proc a64CheckMoviImm(mn: string, arg: NimNode, stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit:
    checkU(mn, v, 0, 0xFF, "immediate", arg)

proc a64CheckMoviShift(mn: string, isH: bool, arg: NimNode,
    stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if not isLit: return
  if isH:
    if v != 0 and v != 8:
      error("dynasm: '" & mn &
        "' shift must be lsl #0 or lsl #8", arg)
  elif v != 0 and v != 8 and v != 16 and v != 24:
    error("dynasm: '" & mn &
      "' shift must be lsl #0/#8/#16/#24", arg)

proc a64CheckStretched(mn: string, arg: NimNode, stmt: NimNode) =
  let (isLit, v) = intLitVal(arg)
  if isLit and encodeStretchedImm(cast[uint64](v)) < 0:
    error("dynasm: '" & mn & "' unrepresentable 64-bit immediate",
      arg)

proc a64MemScale(shape: A64Shape): int =
  ## Access log2 size for fMemU/fMemX: B unscaled, H/1, S/2, D/3,
  ## Q/4 (rs Ubits vs Uscaled per row).
  case shape
  of asB: 0
  of asH: 1
  of asS: 2
  of asD, asX: 3
  of asQ: 4
  else: 2 # asW

# --------------------------------------------------------------------------
# Emission: build the runtime encoder call
# --------------------------------------------------------------------------

proc regExpr(n: NimNode, aliases: Table[string, string]): NimNode =
  if n.kind == nnkIdent:
    let resolved = a64ResolveIdent(n.strVal, aliases)
    if resolved in a64FpRegTable():
      let codeLit = newLit(a64FpRegTable()[resolved].code)
      return quote do: Register(code: uint8(`codeLit`), cls: rcGpr)
    let ri = a64RegInfoOf(n.strVal, aliases)
    let codeLit = newLit(ri.code)
    return quote do: Register(code: uint8(`codeLit`), cls: rcGpr)
  # Xreg()/Wreg() dynamic call passes through (returns Register)
  n

proc immI64(n: NimNode): NimNode =
  quote do: cast[int64](`n`)

proc immU64(n: NimNode): NimNode =
  quote do: cast[uint64](`n`)

proc labelExpr(n: NimNode): NimNode =
  ## LabelRef expression: calls pass through (normalized), and
  ## label +/- literal folds the offset in (mirrors the x64 path).
  if n.kind == nnkCall and n.len >= 1:
    let fn = n[0].strVal.toLowerAscii
    var callNode = n
    if fn == "forward": callNode[0] = ident("fwd")
    elif fn == "backward": callNode[0] = ident("bwd")
    elif fn == "globalref": callNode[0] = ident("glob")
    elif fn in ["dyn", "dynamic"]: callNode[0] = ident("dynLbl")
    return callNode
  if n.kind == nnkInfix and n.len == 3:
    let op = n[0].strVal
    var labelSide: NimNode = nil
    var offNode: NimNode = nil
    var neg = op == "-"
    if n[1].kind == nnkCall: labelSide = n[1]; offNode = n[2]
    elif n[2].kind == nnkCall: labelSide = n[2]; offNode = n[1]
    if labelSide != nil:
      let fn = labelSide[0]
      var offExpr: NimNode
      let (isLit, v) = intLitVal(offNode)
      if isLit:
        offExpr = newLit(if neg: -v else: v)
      else:
        # Built with newTree (not quote): the same node feeds one
        # expression, and quote dislikes one var in sibling quotes.
        let casted = newTree(nnkCast, ident("int"),
          copyNimTree(offNode))
        if neg:
          offExpr = newTree(nnkPrefix, ident("-"), casted)
        else:
          offExpr = casted
      if labelSide.len == 2:
        let nm = labelSide[1]
        let newCall = newTree(nnkCall, fn, nm, offExpr)
        return newCall
  error("dynasm: branch needs a label like fwd(\"x\")", n)

proc modName(n: NimNode): string =
  n.strVal.toLowerAscii

proc shiftCode(name: string): int =
  case name
  of "lsl": 0
  of "lsr": 1
  of "asr": 2
  else: 3 # ror

proc extCode(name: string): int =
  case name
  of "lsl": A64ExtLsl
  of "sxtx": A64ExtSxtx
  of "sxtw": A64ExtSxtw
  of "uxtx": A64ExtUxtx
  else: A64ExtUxtw

proc vecReg(arg: A64Arg): NimNode =
  ## Register expression for a classified vector operand. Stored at
  ## classify time because the source is a DotExpr, not an ident.
  arg.node

proc a64CheckVecSame(mn: string, a, b, c: A64Arg, stmt: NimNode) =
  ## Vector ALU operands share one arrangement in practice; mixed
  ## arrangements would silently encode the wrong Q bit.
  if a.vElem != b.vElem or a.vElem != c.vElem or
      a.vIs128 != b.vIs128 or a.vIs128 != c.vIs128:
    error("dynasm: '" & mn &
      "' vector operands need the same arrangement, e.g. v0.s4, " &
      "v1.s4, v2.s4", stmt)

proc a64Emit*(mn: string, entry: A64Entry, args: seq[NimNode],
    argInfo: seq[A64Arg], ops: NimNode,
    aliases: Table[string, string], condBits: int,
    stmt: NimNode): NimNode =
  ## Build the runtime encoder call for a matched entry.
  let baseLit = newLit(int(entry.base) + condBits)
  let o = ops
  case entry.form
  of fRRR:
    let (d, s1, s2) = (regExpr(args[0], aliases),
      regExpr(args[1], aliases), regExpr(args[2], aliases))
    if args.len == 3:
      return quote do: a64RRR(`o`, `baseLit`, `d`, `s1`, `s2`)
    # optional shift modifier (+ optional amount)
    let sh = shiftCode(modName(args[3]))
    let rorOk = mn in ["and", "orr", "eor", "ands", "tst"]
    if modName(args[3]) notin a64ShiftMods and
        not (rorOk and modName(args[3]) == "ror"):
      error("dynasm: '" & mn & "' bad shift modifier '" &
        modName(args[3]) & "'", args[3])
    let is64 = argInfo[0].shape in {asX, asXSP}
    let is64Lit = newLit(is64)
    let amt = if args.len == 5: args[4] else: newLit(0)
    a64CheckShiftAmt(mn, is64, amt, stmt)
    let shLit = newLit(sh)
    let amtE = immI64(amt)
    return quote do:
      a64RRSh(`o`, `baseLit`, `d`, `s1`, `s2`, `shLit`, `amtE`,
        `is64Lit`)
  of fRR:
    let (d, s) = (regExpr(args[0], aliases),
      regExpr(args[1], aliases))
    if args.len == 2:
      return quote do: a64RR(`o`, `baseLit`, `d`, `s`)
    let sh = shiftCode(modName(args[2]))
    if modName(args[2]) notin a64ShiftMods:
      error("dynasm: '" & mn & "' bad shift modifier", args[2])
    let is64 = argInfo[0].shape == asX
    let is64Lit = newLit(is64)
    let amt = if args.len == 4: args[3] else: newLit(0)
    a64CheckShiftAmt(mn, is64, amt, stmt)
    let shLit = newLit(sh)
    let amtE = immI64(amt)
    # fRR has no Rn field; reuse fRRSh with XZR as Rn? No: mov/mvn
    # bases bake Rn=31. Encode manually via a64RR + separate shift
    # is impossible; instead route through a64RRSh with rn=xzr and
    # the ORN base. a64RRSh ORs rn<<5 = 31<<5 which matches Rn=31
    # baked in mov/mvn bases.
    let xzrE = quote do: Register(code: 31, cls: rcGpr)
    return quote do:
      a64RRSh(`o`, `baseLit`, `d`, `xzrE`, `s`, `shLit`, `amtE`,
        `is64Lit`)
  of fXRR:
    let (s1, s2) = (regExpr(args[0], aliases),
      regExpr(args[1], aliases))
    if args.len == 2:
      return quote do: a64XRR(`o`, `baseLit`, `s1`, `s2`)
    let sh = shiftCode(modName(args[2]))
    if modName(args[2]) notin a64ShiftMods:
      error("dynasm: '" & mn & "' bad shift modifier", args[2])
    let is64 = argInfo[0].shape == asX
    let is64Lit = newLit(is64)
    let amt = if args.len == 4: args[3] else: newLit(0)
    a64CheckShiftAmt(mn, is64, amt, stmt)
    let shLit = newLit(sh)
    let amtE = immI64(amt)
    let xzrE = quote do: Register(code: 31, cls: rcGpr)
    return quote do:
      a64RRSh(`o`, `baseLit`, `xzrE`, `s1`, `s2`, `shLit`, `amtE`,
        `is64Lit`)
  of fRRn:
    let (d, s) = (regExpr(args[0], aliases),
      regExpr(args[1], aliases))
    return quote do: a64RRn(`o`, `baseLit`, `d`, `s`)
  of fRRRR:
    let (d, s1, s2, s3) = (regExpr(args[0], aliases),
      regExpr(args[1], aliases), regExpr(args[2], aliases),
      regExpr(args[3], aliases))
    return quote do: a64RRRR(`o`, `baseLit`, `d`, `s1`, `s2`, `s3`)
  of fRRI12:
    var rd, rn, imm, shift, immNode: NimNode
    shift = newLit(0)
    if mn == "mov":
      # mov to/from sp: ADD #0
      rd = regExpr(args[0], aliases)
      rn = regExpr(args[1], aliases)
      imm = newLit(0)
      immNode = imm
    elif mn in ["cmp", "cmn"]:
      # XZR destination baked in base
      let xzrE = quote do: Register(code: 31, cls: rcGpr)
      rd = xzrE
      rn = regExpr(args[0], aliases)
      imm = immI64(args[1])
      immNode = args[1]
      if args.len == 4:
        if modName(args[2]) != "lsl":
          error("dynasm: '" & mn &
            "' shift must be lsl #0 or lsl #12", args[2])
        shift = immI64(args[3])
        a64CheckShift12(mn, args[3], stmt)
    else:
      rd = regExpr(args[0], aliases)
      rn = regExpr(args[1], aliases)
      imm = immI64(args[2])
      immNode = args[2]
      if args.len == 4:
        # `lsl` without amount means #0 (rs Default)
        if modName(args[3]) != "lsl":
          error("dynasm: '" & mn &
            "' shift must be lsl #0 or lsl #12", args[3])
      elif args.len == 5:
        if modName(args[3]) != "lsl":
          error("dynasm: '" & mn &
            "' shift must be lsl #0 or lsl #12", args[3])
        shift = immI64(args[4])
        a64CheckShift12(mn, args[4], stmt)
    a64CheckImm12(mn, immNode, stmt)
    return quote do: a64RRI12(`o`, `baseLit`, `rd`, `rn`, `imm`,
      `shift`)
  of fLogicI:
    var rd, rn, imm: NimNode
    var is64 = argInfo[0].shape in {asX, asXSP}
    let is64Lit = newLit(is64)
    if mn == "tst":
      let xzrE = quote do: Register(code: 31, cls: rcGpr)
      rd = xzrE
      rn = regExpr(args[0], aliases)
      imm = immU64(args[1])
      a64CheckLogical(mn, is64, args[1], stmt)
    else:
      rd = regExpr(args[0], aliases)
      rn = regExpr(args[1], aliases)
      imm = immU64(args[2])
      a64CheckLogical(mn, is64, args[2], stmt)
    return quote do:
      a64LogicI(`o`, `baseLit`, `rd`, `rn`, `imm`, `is64Lit`)
  of fMovI:
    let d = regExpr(args[0], aliases)
    let is64 = argInfo[0].shape == asX
    let is64Lit = newLit(is64)
    a64CheckWide(mn, is64, args[1], stmt, false)
    let imm = immU64(args[1])
    return quote do: a64MovI(`o`, `d`, `imm`, `is64Lit`)
  of fMovInv:
    let d = regExpr(args[0], aliases)
    let is64 = argInfo[0].shape == asX
    let is64Lit = newLit(is64)
    a64CheckWide(mn, is64, args[1], stmt, true)
    let imm = immU64(args[1])
    return quote do: a64MovInv(`o`, `d`, `imm`, `is64Lit`)
  of fMovLogic:
    let d = regExpr(args[0], aliases)
    let is64 = argInfo[0].shape == asX
    let is64Lit = newLit(is64)
    a64CheckLogical(mn, is64, args[1], stmt)
    let imm = immU64(args[1])
    return quote do: a64MovLogic(`o`, `d`, `imm`, `is64Lit`)
  of fMovWide:
    let d = regExpr(args[0], aliases)
    let is64 = argInfo[0].shape == asX
    let is64Lit = newLit(is64)
    a64CheckMovWideImm(mn, args[1], stmt)
    var shiftAmt: NimNode = newLit(0)
    if args.len == 4:
      if modName(args[2]) != "lsl":
        error("dynasm: '" & mn & "' shift must be lsl", args[2])
      shiftAmt = immI64(args[3])
      let (isLit, v) = intLitVal(args[3])
      if isLit:
        let top: int64 = if is64: 48 else: 16
        if v != 0 and v != 16 and v != 32 and v != top:
          error("dynasm: '" & mn &
            "' shift must be lsl #0/16" &
            (if is64: "/32/48" else: ""), args[3])
    let imm = immU64(args[1])
    return quote do:
      a64MovWide(`o`, `baseLit`, `d`, `imm`, `shiftAmt`,
        `is64Lit`)
  of fBfmI:
    let (d, s) = (regExpr(args[0], aliases),
      regExpr(args[1], aliases))
    let is64 = argInfo[0].shape == asX
    let is64Lit = newLit(is64)
    let op = case mn
      of "lsl": 0
      of "lsr": 1
      else: 2
    a64CheckBfm(mn, is64, op == 0, args[2], stmt)
    let amt = immI64(args[2])
    let opLit = newLit(op)
    return quote do:
      a64BfmI(`o`, `baseLit`, `d`, `s`, `amt`, `is64Lit`, `opLit`)
  of fFmovI:
    let d = regExpr(args[0], aliases)
    a64CheckFloat(mn, args[1], stmt)
    let (isFlt, f) = a64FloatVal(args[1])
    var bits: NimNode
    if isFlt:
      let b = newLit(int(cast[uint32](float32(f))))
      bits = quote do: uint32(`b`)
    else:
      let v = args[1]
      bits = quote do: cast[uint32](float32(cast[int64](`v`)))
    return quote do: a64FmovI(`o`, `baseLit`, `d`, `bits`)
  of fFcmp0:
    let s = regExpr(args[0], aliases)
    a64CheckFZero(mn, args[1], stmt)
    return quote do: a64Fcmp0(`o`, `baseLit`, `s`)
  of fVecRRR:
    let (d, s1, s2) = (vecReg(argInfo[0]), vecReg(argInfo[1]),
      vecReg(argInfo[2]))
    a64CheckVecSame(mn, argInfo[0], argInfo[1], argInfo[2], stmt)
    let qLit = newLit(argInfo[0].vIs128)
    return quote do: a64VecRRR(`o`, `baseLit`, `d`, `s1`, `s2`,
      `qLit`)
  of fVecMovi:
    let d = vecReg(argInfo[0])
    a64CheckMoviImm(mn, args[1], stmt)
    let isH = argInfo[0].vElem == 2
    var shiftAmt: NimNode = newLit(0)
    if args.len == 4:
      if modName(args[2]) != "lsl":
        error("dynasm: '" & mn & "' shift must be lsl", args[2])
      shiftAmt = immI64(args[3])
      a64CheckMoviShift(mn, isH, args[3], stmt)
    let imm = immU64(args[1])
    let hLit = newLit(isH)
    let qLit = newLit(argInfo[0].vIs128)
    return quote do:
      a64Movi(`o`, `baseLit`, `d`, `imm`, `shiftAmt`, `hLit`,
        `qLit`)
  of fVecMoviD:
    let d = vecReg(argInfo[0])
    a64CheckStretched(mn, args[1], stmt)
    let imm = immU64(args[1])
    let qLit = newLit(argInfo[0].vIs128)
    return quote do: a64MoviD(`o`, `baseLit`, `d`, `imm`, `qLit`)
  of fDupG:
    let d = vecReg(argInfo[0])
    let s = regExpr(args[1], aliases)
    let qLit = newLit(argInfo[0].vIs128)
    return quote do: a64DupG(`o`, `baseLit`, `d`, `s`, `qLit`)
  of fMemU:
    let rt = regExpr(args[0], aliases)
    let scale = a64MemScale(argInfo[0].shape)
    let rn = regExpr(argInfo[1].mem.base, aliases)
    var off: NimNode = newLit(0)
    if argInfo[1].shape == asMemOff:
      off = immI64(argInfo[1].mem.off)
      a64CheckMemU(mn, scale, argInfo[1].mem.off, stmt)
    let scaleLit = newLit(scale)
    return quote do:
      a64MemU(`o`, `baseLit`, `rt`, `rn`, `off`, `scaleLit`)
  of fMem9:
    let rt = regExpr(args[0], aliases)
    var rn, off: NimNode
    if argInfo[1].shape == asMemPre:
      # [base, imm] + pre (pre marker consumed at classify time)
      rn = regExpr(argInfo[1].mem.base, aliases)
      off = immI64(argInfo[1].mem.off)
      a64CheckMem9(mn, argInfo[1].mem.off, stmt)
    else:
      # [base] + trailing imm (post-index)
      rn = regExpr(argInfo[1].mem.base, aliases)
      off = immI64(args[2])
      a64CheckMem9(mn, args[2], stmt)
    return quote do: a64Mem9(`o`, `baseLit`, `rt`, `rn`, `off`)
  of fPair:
    let (t1, t2) = (regExpr(args[0], aliases),
      regExpr(args[1], aliases))
    let scale = if argInfo[0].shape == asX: 3 else: 2
    let rn = regExpr(argInfo[2].mem.base, aliases)
    var off: NimNode = newLit(0)
    if argInfo[2].shape == asMemBase and args.len == 4:
      # [base], imm post-index
      off = immI64(args[3])
      a64CheckPair(mn, scale, args[3], stmt)
    elif argInfo[2].shape != asMemBase:
      off = immI64(argInfo[2].mem.off)
      a64CheckPair(mn, scale, argInfo[2].mem.off, stmt)
    else:
      a64CheckPair(mn, scale, newLit(0), stmt)
    let scaleLit = newLit(scale)
    return quote do:
      a64Pair(`o`, `baseLit`, `t1`, `t2`, `rn`, `off`, `scaleLit`)
  of fMemX:
    let rt = regExpr(args[0], aliases)
    let mem = argInfo[1].mem
    let scale = a64MemScale(argInfo[0].shape)
    let rn = regExpr(mem.base, aliases)
    if mem.idx.kind == nnkIdent:
      let ix = a64ResolveIdent(mem.idx.strVal, aliases)
      if ix in ["sp", "wsp"]:
        error("dynasm: index register cannot be the stack pointer",
          mem.idx)
    let rm = regExpr(mem.idx, aliases)
    # extend/index-size compatibility (rs sanitize): 64-bit index
    # takes lsl/sxtx, 32-bit index takes sxtw/uxtw.
    let ext = if mem.extName == "": "lsl" else: mem.extName
    if mem.idxIs64:
      if ext notin ["lsl", "sxtx"]:
        error("dynasm: 64-bit index takes lsl or sxtx", args[1])
    else:
      if ext notin ["sxtw", "uxtw"]:
        error("dynasm: 32-bit index takes sxtw or uxtw", args[1])
    if ext == "lsl" and mem.extAmt == nil:
      error("dynasm: LSL reference modifier requires an immediate",
        args[1])
    var amt: NimNode = newLit(0)
    if mem.extAmt != nil:
      amt = immI64(mem.extAmt)
      let (isLit, v) = intLitVal(mem.extAmt)
      if isLit and v != 0 and v != scale:
        error("dynasm: register offset amount must be 0 or " &
          $scale, mem.extAmt)
    let extLit = newLit(extCode(ext))
    let scaleLit = newLit(scale)
    return quote do:
      a64MemX(`o`, `baseLit`, `rt`, `rn`, `rm`, `extLit`, `amt`,
        `scaleLit`)
  of fBr:
    let lr = labelExpr(args[0])
    let relLit = newLit(entry.rel)
    return quote do: a64BrLbl(`o`, `baseLit`, `lr`, `relLit`)
  of fCbx:
    let rt = regExpr(args[0], aliases)
    let lr = labelExpr(args[1])
    return quote do: a64Cbx(`o`, `baseLit`, `rt`, `lr`)
  of fTbx:
    let rt = regExpr(args[0], aliases)
    let is64 = argInfo[0].shape == asX
    let is64Lit = newLit(is64)
    a64CheckTbz(mn, is64, args[1], stmt)
    let bit = immI64(args[1])
    let lr = labelExpr(args[2])
    return quote do:
      a64Tbx(`o`, `baseLit`, `rt`, `bit`, `lr`, `is64Lit`)
  of fAdr:
    let rd = regExpr(args[0], aliases)
    let lr = labelExpr(args[1])
    let adrpLit = newLit(mn == "adrp")
    return quote do: a64Adr(`o`, `baseLit`, `rd`, `lr`, `adrpLit`)
  of fBrReg:
    let rn = regExpr(args[0], aliases)
    return quote do: a64BrReg(`o`, `baseLit`, `rn`)
  of fMisc:
    return quote do: a64Misc(`o`, `baseLit`)
  of fHlt:
    a64CheckHlt(mn, args[0], stmt)
    let imm = immI64(args[0])
    return quote do: a64Hlt(`o`, `baseLit`, `imm`)

proc isA64Mn*(mn: string): bool =
  a64Entries(mn).len > 0

proc a64CondBitsOf*(name: string): int =
  for i, n in a64CondNames:
    if n == name: return a64CondBits[i]
  -1

proc a64ProcessInstruction*(mn: string, args: seq[NimNode],
    ops: NimNode, aliases: Table[string, string], condBits: int,
    stmt: NimNode): NimNode =
  ## Classify args, select the op entry, statically validate
  ## literals, and build the runtime encoder call. Calls error()
  ## on any mismatch, like the x64 validators.
  var cls: seq[A64Arg] = @[]
  var effArgs = args[0..^1] # copy: appending must not touch caller seq
  if args.len == 0:
    effArgs = @[]
  var i = 0
  while i < effArgs.len:
    # fold trailing `pre` into the preceding [base, imm] operand
    if effArgs[i].kind == nnkIdent and
        effArgs[i].strVal.toLowerAscii == "pre" and cls.len > 0 and
        cls[^1].shape == asMemOff:
      cls[^1].shape = asMemPre
      inc i
      continue
    cls.add(a64Classify(mn, effArgs[i], aliases, stmt))
    inc i
  # A bare trailing shift/extend modifier means amount #0 (rs Default).
  # Bracket-internal modifiers are untouched: LSL there still needs
  # an explicit amount.
  if cls.len > 0 and cls[^1].shape == asMod:
    cls.add(A64Arg(shape: asImm, node: newLit(0)))
    effArgs.add(newLit(0))
  var shapes: seq[A64Shape] = @[]
  for c in cls: shapes.add(c.shape)
  for e in a64Entries(mn):
    if a64ShapesFit(e.shapes, cls):
      return a64Emit(mn, e, effArgs, cls, ops, aliases, condBits,
        stmt)
  a64Mismatch(mn, shapes, stmt)
  stmt
