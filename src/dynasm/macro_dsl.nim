## Nim AST DSL: `dynasm ops: ...`
## Pure Nim syntax, no string parsing.
##
## Compile-time safety: unknown mnemonics (with "did you mean" hints),
## wrong arities and every statically detectable operand-shape mistake
## are reported with `error()` while the block expands, so broken
## assembly never reaches codegen. Structured Nim statements
## (let/var/if/for/...) still pass through untouched.
##
## Debugging: compile with -d:dynasmDebug to print each block's
## generated Nim code at compile time.

import std/macros
import std/tables
import std/strutils
import ./aarch64data
import ./aarch64match

# Integer literal node kinds. The parser picks IntLit vs Int64Lit (and
# the suffixed nnkInt8Lit..nnkUInt64Lit forms) by magnitude, so every
# literal check must cover the whole set, not just nnkIntLit.
const intLitKinds = {nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit,
  nnkInt64Lit, nnkUIntLit, nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit,
  nnkUInt64Lit}

# --------------------------------------------------------------------------
# Compile-time register table
# --------------------------------------------------------------------------

type RegInfo = tuple[code: int, size: string, cls: string]

proc regTable(): Table[string, RegInfo] =
  result = initTable[string, RegInfo]()
  # 64-bit
  for (n, c) in [("rax",0),("rcx",1),("rdx",2),("rbx",3),("rsp",4),
      ("rbp",5),("rsi",6),("rdi",7),("r8",8),("r9",9),("r10",10),
      ("r11",11),("r12",12),("r13",13),("r14",14),("r15",15)]:
    result[n] = (c, "sz64", "rcGpr")
  # 32-bit
  for (n, c) in [("eax",0),("ecx",1),("edx",2),("ebx",3),("esp",4),
      ("ebp",5),("esi",6),("edi",7),("r8d",8),("r9d",9),("r10d",10),
      ("r11d",11),("r12d",12),("r13d",13),("r14d",14),("r15d",15)]:
    result[n] = (c, "sz32", "rcGpr")
  # 16-bit
  for (n, c) in [("ax",0),("cx",1),("dx",2),("bx",3),("sp",4),
      ("bp",5),("si",6),("di",7),("r8w",8),("r9w",9),("r10w",10),
      ("r11w",11),("r12w",12),("r13w",13),("r14w",14),("r15w",15)]:
    result[n] = (c, "sz16", "rcGpr")
  # 8-bit low
  for (n, c) in [("al",0),("cl",1),("dl",2),("bl",3),("spl",4),
      ("bpl",5),("sil",6),("dil",7),("r8b",8),("r9b",9),("r10b",10),
      ("r11b",11),("r12b",12),("r13b",13),("r14b",14),("r15b",15)]:
    result[n] = (c, "sz8", "rcGpr")
  # high-byte
  for (n, c) in [("ah",4),("ch",5),("dh",6),("bh",7)]:
    result[n] = (c, "sz8", "rcHigh8")
  # xmm
  for i in 0..15:
    result["xmm" & $i] = (i, "szNone", "rcXmm")

proc getMn(node: NimNode): string =
  if node.kind == nnkIdent:
    node.strVal.toLowerAscii
  elif node.kind == nnkAccQuoted and node.len > 0:
    node[0].strVal.toLowerAscii
  else:
    ""

proc isRegName(name: string, aliases: Table[string, string],
    a64mode: bool = false): bool =
  let n = name.toLowerAscii
  if n in aliases: return true
  if a64mode:
    return a64IsReg(n, aliases)
  n in regTable()

proc resolveRegName(name: string,
    aliases: Table[string, string]): RegInfo =
  let n = name.toLowerAscii
  if n in aliases:
    return resolveRegName(aliases[n], aliases)
  regTable()[n]

# --------------------------------------------------------------------------
# Operand construction (returns NimNode evaluating to Operand)
# --------------------------------------------------------------------------

proc operandAst(node: NimNode, aliases: Table[string, string]): NimNode

proc memAst(bracket: NimNode, aliases: Table[string, string]): NimNode =
  ## bracket is nnkBracket with 1 inner expr (or multiple?).
  if bracket.len == 0:
    error("empty []", bracket)
  let inner =
    if bracket.len == 1: bracket[0]
    else: bracket # shouldn't happen
  # RIP-relative: [glob(...)] etc directly
  if inner.kind == nnkCall and inner.len >= 1:
    let fn = getMn(inner[0])
    if fn in ["fwd", "bwd", "glob", "globallabel", "dynlbl", "dyn",
        "extaddr", "externaddr"]:
      let lrCall = inner
      return quote do:
        MemOp(hasBase: false, base: Register(code: 0, cls: rcGpr),
          hasIndex: false, index: Register(code: 0, cls: rcGpr), scale: 1,
          disp: 0, hasDisp: false,
          hasRip: true, addrSizeOverride: false,
          ripLabel: `lrCall`)
  # General: decompose +/- chain
  # Collect terms with sign
  var terms: seq[tuple[sign: int, n: NimNode]] = @[]
  proc collect(n: NimNode, sign: int) =
    if n.kind == nnkInfix:
      let op = n[0].strVal
      if op == "+":
        collect(n[1], sign)
        collect(n[2], sign)
      elif op == "-":
        collect(n[1], sign)
        collect(n[2], -sign)
      else:
        terms.add((sign, n))
    else:
      terms.add((sign, n))
  collect(inner, 1)

  var baseNode: NimNode = nil
  var indexNode: NimNode = nil
  var scaleVal = 1
  var dispParts: seq[NimNode] = @[]
  var negDisp: seq[bool] = @[]

  for (sg, t) in terms:
    if t.kind == nnkIdent and isRegName(t.strVal, aliases):
      if baseNode == nil:
        baseNode = t
        if sg == -1:
          error("negative base reg not supported", t)
      else:
        error("multiple base registers in mem", t)
    elif t.kind == nnkInfix and t[0].strVal == "*":
      # reg * scale or scale * reg
      var regN: NimNode = nil
      var sc = 0
      if t[1].kind == nnkIdent and isRegName(t[1].strVal, aliases) and
          t[2].kind in intLitKinds:
        regN = t[1]
        sc = int(t[2].intVal)
      elif t[2].kind == nnkIdent and isRegName(t[2].strVal, aliases) and
          t[1].kind in intLitKinds:
        regN = t[2]
        sc = int(t[1].intVal)
      else:
        error("bad scaled index, use reg*1/2/4/8", t)
      if sc notin [1, 2, 4, 8]:
        error("scale must be 1,2,4,8", t)
      if indexNode != nil:
        error("multiple index regs", t)
      if sg == -1:
        error("negative index not supported", t)
      indexNode = regN
      scaleVal = sc
    elif t.kind == nnkCall and t.len >= 1 and
        getMn(t[0]) in ["rq", "rd", "rx"]:
      # dynamic reg as base/index: treat as base if none else index*1
      if baseNode == nil and sg == 1:
        baseNode = t
      elif indexNode == nil and sg == 1:
        indexNode = t
        scaleVal = 1
      else:
        error("dynamic reg placement unsupported", t)
    else:
      # disp part (int lit or arbitrary Nim expr)
      dispParts.add(t)
      negDisp.add(sg == -1)

  # Build base/index Register exprs
  var baseExpr: NimNode
  var hasBaseExpr: NimNode
  if baseNode == nil:
    baseExpr = quote do: Register(code: 0, cls: rcGpr)
    hasBaseExpr = newLit(false)
  else:
    if baseNode.kind == nnkIdent:
      let ri = resolveRegName(baseNode.strVal, aliases)
      let codeLit = newLit(ri.code)
      let clsIdent = ident(ri.cls)
      baseExpr = quote do:
        Register(code: uint8(`codeLit`), cls: `clsIdent`)
    else:
      # dynamic Rq(expr) etc: pass through, wrap code extraction?
      # Rq returns Register already
      baseExpr = baseNode
    hasBaseExpr = newLit(true)

  var indexExpr: NimNode
  var hasIndexExpr: NimNode
  if indexNode == nil:
    indexExpr = quote do: Register(code: 0, cls: rcGpr)
    hasIndexExpr = newLit(false)
  else:
    if indexNode.kind == nnkIdent:
      let ri = resolveRegName(indexNode.strVal, aliases)
      let codeLit = newLit(ri.code)
      let clsIdent = ident(ri.cls)
      indexExpr = quote do:
        Register(code: uint8(`codeLit`), cls: `clsIdent`)
    else:
      indexExpr = indexNode
    hasIndexExpr = newLit(true)

  let scaleLit = newLit(scaleVal)
  var dispExpr: NimNode
  var hasDispExpr: NimNode
  if dispParts.len == 0:
    dispExpr = newLit(0'i64)
    hasDispExpr = newLit(false)
  elif dispParts.len == 1 and not negDisp[0]:
    let d = dispParts[0]
    if d.kind in intLitKinds:
      dispExpr = quote do: int64(`d`)
    else:
      dispExpr = quote do: cast[int64](`d`)
    hasDispExpr = newLit(true)
  else:
    # combine multiple disp parts with +/- at runtime
    var combined = dispParts[0]
    if negDisp[0]:
      combined = quote do: -(`combined`)
    for i in 1..<dispParts.len:
      let p = dispParts[i]
      if negDisp[i]:
        combined = quote do: `combined` - cast[int64](`p`)
      else:
        combined = quote do: `combined` + cast[int64](`p`)
    dispExpr = quote do: cast[int64](`combined`)
    hasDispExpr = newLit(true)

  result = quote do:
    MemOp(hasBase: `hasBaseExpr`, base: `baseExpr`,
      hasIndex: `hasIndexExpr`, index: `indexExpr`, scale: `scaleLit`,
      disp: `dispExpr`, hasDisp: `hasDispExpr`,
      hasRip: false, addrSizeOverride: false,
      ripLabel: LabelRef(isLabel: false))

proc operandAst(node: NimNode, aliases: Table[string, string]): NimNode =
  # byte/word/dword/qword wrappers, either `byte(x)` call form or
  # NASM-style `byte [x]` command form
  if (node.kind == nnkCall or node.kind == nnkCommand) and node.len == 2:
    let fn = getMn(node[0])
    if fn in ["byte", "word", "dword", "qword"]:
      let szName =
        case fn
        of "byte": "sz8"
        of "word": "sz16"
        of "dword": "sz32"
        else: "sz64"
      let szIdent = ident(szName)
      let inner = node[1]
      if inner.kind == nnkIdent and isRegName(inner.strVal, aliases):
        let ri = resolveRegName(inner.strVal, aliases)
        let codeLit = newLit(ri.code)
        let clsIdent = ident(ri.cls)
        return quote do:
          regOp(Register(code: uint8(`codeLit`), cls: `clsIdent`),
            `szIdent`)
      elif inner.kind == nnkBracket:
        let m = memAst(inner, aliases)
        return quote do:
          memOp(`m`, `szIdent`)
      elif inner.kind == nnkCall and inner.len >= 1 and
          getMn(inner[0]) in ["rq", "rd", "rx"]:
        return quote do:
          regOp(`inner`, `szIdent`)
      else:
        # imm expr, or labelref for short jumps: detect labelref
        if inner.kind == nnkCall and inner.len >= 1 and
            getMn(inner[0]) in ["fwd", "bwd", "glob", "dyn",
              "dynlbl", "extaddr"]:
          # short-jump marker: return label operand; caller detects wrapper
          # to choose short encoding. Mark via special call.
          return quote do:
            labelOp(`inner`)
        return quote do:
          immOp(cast[int64](`inner`), `szIdent`)
  # bare register
  if node.kind == nnkIdent and isRegName(node.strVal, aliases):
    let ri = resolveRegName(node.strVal, aliases)
    let codeLit = newLit(ri.code)
    let clsIdent = ident(ri.cls)
    let szIdent = ident(ri.size)
    return quote do:
      regOp(Register(code: uint8(`codeLit`), cls: `clsIdent`), `szIdent`)
  # dynamic reg Rq/Rd/Rx
  if node.kind == nnkCall and node.len == 2:
    let fn = getMn(node[0])
    if fn in ["rq", "rd", "rx"]:
      let szIdent =
        if fn == "rq": ident("sz64")
        elif fn == "rd": ident("sz32")
        else: ident("szNone")
      return quote do:
        regOp(`node`, `szIdent`)
  # label refs
  if node.kind == nnkCall and node.len >= 1:
    let fn = getMn(node[0])
    if fn in ["fwd", "forward", "bwd", "backward", "glob", "globalref",
        "dyn", "dynlbl", "dynamic", "extaddr", "externaddr"]:
      # normalize to runtime fwd/bwd/glob/dynLbl/extAddr
      var callNode = node
      if fn == "forward": callNode[0] = ident("fwd")
      elif fn == "backward": callNode[0] = ident("bwd")
      elif fn in ["globalref"]: callNode[0] = ident("glob")
      elif fn in ["dyn", "dynamic"]: callNode[0] = ident("dynLbl")
      elif fn in ["externaddr"]: callNode[0] = ident("extAddr")
      # dynLbl may take DynamicLabel; convert int() if needed at runtime?
      # Assume runtime overloads handle both int and DynamicLabel.
      return quote do:
        labelOp(`callNode`)
  # label ref with offset: fwd("x")+4
  if node.kind == nnkInfix:
    let op = node[0].strVal
    if op in ["+", "-"]:
      # try label side
      let lhs = node[1]
      let rhs = node[2]
      var labelSide: NimNode = nil
      var offNode: NimNode = nil
      var neg = false
      if lhs.kind == nnkCall and getMn(lhs[0]) in
          ["fwd", "bwd", "glob", "dyn", "dynlbl", "extaddr"]:
        labelSide = lhs
        offNode = rhs
        neg = op == "-"
      elif rhs.kind == nnkCall and getMn(rhs[0]) in
          ["fwd", "bwd", "glob", "dyn", "dynlbl", "extaddr"]:
        # unlikely, but support
        labelSide = rhs
        offNode = lhs
        neg = op == "-"
      if labelSide != nil:
        # rebuild label with offset: fwd(name, off)
        # labelSide is fwd("name") or fwd("name", off)? handle 1-2 args
        let fn = labelSide[0]
        if labelSide.len == 2:
          let nm = labelSide[1]
          var offExpr: NimNode
          if offNode.kind in intLitKinds:
            let v = int(offNode.intVal)
            offExpr = newLit(if neg: -v else: v)
          else:
            if neg:
              offExpr = quote do: -(cast[int](`offNode`))
            else:
              offExpr = quote do: cast[int](`offNode`)
          let newCall = newTree(nnkCall, fn, nm, offExpr)
          return quote do:
            labelOp(`newCall`)
  # memory bracket
  if node.kind == nnkBracket:
    let m = memAst(node, aliases)
    return quote do:
      memOp(`m`, szNone)
  # mem() helper? treat mem(x) as already MemOp?
  if node.kind == nnkCall and node.len >= 1 and getMn(node[0]) == "mem":
    return quote do:
      memOp(`node`, szNone)
  # immediate fallback: any Nim expr
  return quote do:
    immOp(cast[int64](`node`), szNone)

# --------------------------------------------------------------------------
# Compile-time validation helpers
# --------------------------------------------------------------------------

const aluMnemonics = ["add", "sub", "xor", "and", "or", "cmp"]
const shiftMnemonics = ["shl", "sal", "shr", "sar"]
const divMnemonics = ["mul", "div", "idiv", "neg", "not"]
const jccMnemonics = ["jo", "jno", "jb", "jnae", "jc", "jnb", "jae", "jnc",
  "jz", "je", "jnz", "jne", "jbe", "jna", "ja", "jnbe", "js", "jns",
  "jp", "jpe", "jnp", "jpo", "jl", "jnge", "jge", "jnl", "jle", "jng",
  "jg", "jnle"]
const setccMnemonics = ["seto", "setno", "setb", "setnae", "setc",
  "setnb", "setae", "setnc", "setz", "sete", "setnz", "setne",
  "setbe", "setna", "seta", "setnbe", "sets", "setns", "setp",
  "setpe", "setnp", "setpo", "setl", "setnge", "setge", "setnl",
  "setle", "setng", "setg", "setnle"]

const dynasmDirectiveWords = ["arch", "alias", "label", "locallabel",
  "global", "globallabel", "dynamiclabel", "binddyn", "dynlabel", "align",
  "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64",
  "bytes", "bytecode", "db", "rel8", "rel16", "rel32", "rel64",
  "abs8", "abs16", "abs32", "abs64", "feature"]

const dynasmInstrWords = ["mov", "movabs", "lea", "add", "sub", "xor",
  "and", "or", "cmp", "test", "inc", "dec", "push", "pop", "jmp",
  "jmp_short", "jmp8", "call", "ret", "retn", "nop", "int3", "leave",
  "hlt", "cqo", "cdq", "movzx", "imul", "mul", "div", "idiv", "neg",
  "not", "shl", "sal", "shr", "sar", "lock", "rep", "repe", "repz",
  "repne", "repnz"]

# AArch64 mnemonics for `arch aarch64` blocks (unified DSL: same
# macro, same directives, per-arch instruction tables). Dotted forms
# (b.eq, mov.inverted, mov.logical) are produced from DotExpr heads.
const a64InstrWords = ["mov", "mov.inverted", "mov.logical", "movz",
  "movn", "movk", "add", "adds", "sub", "subs", "cmp", "cmn", "and",
  "orr", "eor", "ands", "tst", "mvn", "neg", "lsl", "lsr", "asr",
  "mul", "madd", "msub", "sdiv", "udiv", "ldr", "str", "ldrb", "strb",
  "ldp", "stp",
  "b", "b.cond", "bl", "br", "blr", "ret", "cbz", "cbnz", "tbz",
  "tbnz", "adr", "adrp", "nop", "hlt", "svc", "fmov", "fadd",
  "fsub", "fmul", "fdiv", "fmax", "fmin", "fneg", "fabs", "fsqrt",
  "fcmp", "fcmpe", "scvtf", "ucvtf", "fcvtzs", "fcvtzu", "fcvt",
  "dup", "movi", "bic", "cset"]

# AArch64-only words (unknown to x86): used for "needs arch aarch64"
# diagnostics in x64/x86 blocks.
const a64OnlyWords = ["mov.inverted", "mov.logical", "movz", "movn",
  "movk", "adds", "subs", "cmn", "orr", "eor", "ands", "tst", "mvn",
  "lsl", "lsr", "asr", "madd", "msub", "sdiv", "udiv", "ldr", "str",
  "ldrb", "strb",
  "ldp", "stp", "b", "b.cond", "bl", "br", "blr", "cbz", "cbnz",
  "tbz",   "tbnz", "adr", "adrp", "svc", "fmov", "fadd", "fsub",
  "fmul", "fdiv", "fmax", "fmin", "fneg", "fabs", "fsqrt", "fcmp",
  "fcmpe", "scvtf", "ucvtf", "fcvtzs", "fcvtzu", "fcvt", "dup",
  "movi", "bic", "cset"]

# Statement heads that are Nim, not assembly (Command/Call form only;
# `let`/`if`/`for`/etc. have their own node kinds and pass through).
const nimStmtHeads = ["echo", "debugecho", "assert", "static", "asm"]

proc isDynasmWord(mn: string): bool =
  if mn in dynasmDirectiveWords or mn in dynasmInstrWords:
    return true
  if mn in a64InstrWords:
    return true
  if mn in aluMnemonics or mn in shiftMnemonics or mn in divMnemonics:
    return true
  if mn in jccMnemonics:
    return true
  if mn in setccMnemonics:
    return true
  if mn.endsWith("_short") and mn[0..^7] in jccMnemonics:
    return true
  if mn.endsWith("8") and mn.len > 1 and mn[0..^2] in jccMnemonics:
    return true
  false

proc hasUpperAscii(s: string): bool =
  for c in s:
    if c in {'A'..'Z'}:
      return true
  false

proc hasLowerAscii(s: string): bool =
  for c in s:
    if c in {'a'..'z'}:
      return true
  false

proc editDistance(a, b: string): int =
  if a == b:
    return 0
  var prev = newSeq[int](b.len + 1)
  var cur = newSeq[int](b.len + 1)
  for j in 0..b.len:
    prev[j] = j
  for i in 1..a.len:
    cur[0] = i
    for j in 1..b.len:
      let cost = if a[i-1] == b[j-1]: 0 else: 1
      cur[j] = min(min(prev[j] + 1, cur[j-1] + 1), prev[j-1] + cost)
    swap(prev, cur)
  prev[b.len]

proc suggestWord(mn: string): string =
  ## " Did you mean 'mov'?" / " Did you mean one of ...?" / "".
  if mn.len < 2:
    return ""
  let thresh = if mn.len <= 3: 1 else: 2
  var cands: seq[(int, string)] = @[]
  for w in dynasmDirectiveWords:
    let d = editDistance(mn, w)
    if d > 0 and d <= thresh:
      cands.add((d, w))
  for w in dynasmInstrWords:
    let d = editDistance(mn, w)
    if d > 0 and d <= thresh:
      cands.add((d, w))
  for w in a64InstrWords:
    let d = editDistance(mn, w)
    if d > 0 and d <= thresh:
      cands.add((d, w))
  for w in jccMnemonics:
    let d = editDistance(mn, w)
    if d > 0 and d <= thresh:
      cands.add((d, w))
  for w in setccMnemonics:
    let d = editDistance(mn, w)
    if d > 0 and d <= thresh:
      cands.add((d, w))
  if cands.len == 0:
    return ""
  let top = min(3, cands.len)
  # selection-sort the first `top` by (distance, name)
  for i in 0..<top:
    var m = i
    for j in i+1..<cands.len:
      if cands[j][0] < cands[m][0] or
          (cands[j][0] == cands[m][0] and cands[j][1] < cands[m][1]):
        m = j
    if m != i:
      let t = cands[i]
      cands[i] = cands[m]
      cands[m] = t
  if top == 1:
    return " Did you mean '" & cands[0][1] & "'?"
  var s = " Did you mean one of "
  for i in 0..<top:
    if i > 0:
      s.add(", ")
    s.add("'" & cands[i][1] & "'")
  s & "?"

proc unknownMnemonicError(rawHead, mn: string, stmt: NimNode) =
  error("dynasm: unknown instruction or directive '" & rawHead & "'." &
    suggestWord(mn) &
    " Only assembly plus let/var/if/for-style Nim statements may appear" &
    " inside dynasm blocks; call helpers outside the block.", stmt)

# Static operand shapes. Anything the macro cannot classify (arbitrary
# Nim expressions) is oskOther and left to codegen/runtime checks.
type
  OpStaticKind = enum
    oskReg, oskMem, oskImm, oskLabel, oskOther
  OpStatic = object
    kind: OpStaticKind
    code: int     # register code, -1 when dynamic/unknown
    size: string  # resolved size ("sz8"..) or ""
    cls: string   # register class or ""
    isLit: bool
    lit: int64
    lbl: string   # label kind or ""

proc labelKindDeep(node: NimNode): string =
  if node.kind == nnkCall and node.len >= 1:
    case getMn(node[0])
    of "fwd", "forward": return "forward"
    of "bwd", "backward": return "backward"
    of "glob", "globalref": return "global"
    of "dyn", "dynlbl", "dynamic": return "dynamic"
    of "extaddr", "externaddr": return "absolute"
    else: discard
  if node.kind == nnkInfix and node.len == 3 and
      node[0].kind == nnkIdent and node[0].strVal in ["+", "-"]:
    let a = labelKindDeep(node[1])
    if a != "":
      return a
    return labelKindDeep(node[2])
  if (node.kind == nnkCall or node.kind == nnkCommand) and node.len == 2 and
      getMn(node[0]) in ["byte", "word", "dword", "qword"]:
    return labelKindDeep(node[1])
  ""

proc isLabelRefNode(node: NimNode): bool =
  labelKindDeep(node) != ""

proc classifyOperand(node: NimNode,
    aliases: Table[string, string]): OpStatic =
  if (node.kind == nnkCall or node.kind == nnkCommand) and node.len == 2:
    let fn = getMn(node[0])
    if fn in ["byte", "word", "dword", "qword"]:
      let sz = case fn
        of "byte": "sz8"
        of "word": "sz16"
        of "dword": "sz32"
        else: "sz64"
      let inner = classifyOperand(node[1], aliases)
      case inner.kind
      of oskReg:
        return OpStatic(kind: oskReg, code: inner.code, size: sz,
          cls: inner.cls)
      of oskMem:
        return OpStatic(kind: oskMem, size: sz)
      of oskLabel:
        return inner
      of oskImm:
        if inner.isLit:
          return OpStatic(kind: oskImm, size: sz, isLit: true,
            lit: inner.lit)
        return OpStatic(kind: oskImm, size: sz)
      else:
        return OpStatic(kind: oskOther)
  if node.kind == nnkIdent and isRegName(node.strVal, aliases):
    let ri = resolveRegName(node.strVal, aliases)
    return OpStatic(kind: oskReg, code: ri.code, size: ri.size,
      cls: ri.cls)
  if node.kind == nnkCall and node.len == 2:
    case getMn(node[0])
    of "rq":
      return OpStatic(kind: oskReg, code: -1, size: "sz64", cls: "rcGpr")
    of "rd":
      return OpStatic(kind: oskReg, code: -1, size: "sz32", cls: "rcGpr")
    of "rx":
      return OpStatic(kind: oskReg, code: -1, size: "szNone",
        cls: "rcXmm")
    else: discard
  let lk = labelKindDeep(node)
  if lk != "":
    return OpStatic(kind: oskLabel, lbl: lk)
  if node.kind == nnkBracket:
    return OpStatic(kind: oskMem)
  if node.kind == nnkCall and node.len >= 1 and getMn(node[0]) == "mem":
    return OpStatic(kind: oskMem)
  if node.kind in intLitKinds:
    return OpStatic(kind: oskImm, isLit: true, lit: node.intVal)
  OpStatic(kind: oskOther)

proc rejectBadLiteral(mn: string, node: NimNode) =
  if node.kind == nnkFloatLit:
    error("dynasm: '" & mn & "' needs integer operands, got float " &
      "literal; use f32/f64 data directives for floats", node)
  elif node.kind == nnkStrLit:
    error("dynasm: '" & mn & "' got a string literal; strings belong " &
      "in `bytes`, not instructions", node)
  elif node.kind == nnkCharLit:
    error("dynasm: '" & mn & "' got a character literal; use ord('x') " &
      "for the code point", node)

proc checkArchNode(node: NimNode, aliases: Table[string, string],
    curIsX64: bool, stmt: NimNode) =
  ## x86-mode gate. Callers skip this entirely when curIsX64 is true.
  if curIsX64:
    return
  case node.kind
  of nnkIdent:
    if isRegName(node.strVal, aliases):
      let ri = resolveRegName(node.strVal, aliases)
      if ri.code >= 8:
        error("dynasm: register '" & node.strVal &
          "' needs .arch x64 (r8-r15 do not exist in x86)", node)
      if ri.size == "sz64":
        error("dynasm: 64-bit operands need .arch x64", node)
  of nnkCall, nnkCommand:
    if node.len == 0:
      return
    let fn = getMn(node[0])
    if fn == "qword":
      error("dynasm: 64-bit operands need .arch x64", node)
    elif fn in ["byte", "word", "dword"]:
      if node.len == 2:
        checkArchNode(node[1], aliases, curIsX64, stmt)
    elif fn == "rq":
      error("dynasm: Rq() registers need .arch x64", node)
    elif fn in ["rd", "rx", "fwd", "bwd", "glob", "globalref", "dyn",
        "dynlbl", "dynamic", "extaddr", "externaddr", "mem"]:
      discard
    else:
      for i in 1..<node.len:
        checkArchNode(node[i], aliases, curIsX64, stmt)
  of nnkBracket:
    for child in node:
      checkArchNode(child, aliases, curIsX64, stmt)
  of nnkInfix:
    for i in 1..<node.len:
      checkArchNode(node[i], aliases, curIsX64, stmt)
  else:
    discard

proc checkGprNode(mn: string, node: NimNode,
    aliases: Table[string, string], stmt: NimNode) =
  ## Our subset is integer-only: static XMM operands are rejected here
  ## instead of misassembling downstream.
  case node.kind
  of nnkIdent:
    if isRegName(node.strVal, aliases):
      if resolveRegName(node.strVal, aliases).cls != "rcGpr":
        error("dynasm: '" & mn &
          "' needs general-purpose registers (no SSE backend yet)", node)
  of nnkCall, nnkCommand:
    if node.len == 0:
      return
    let fn = getMn(node[0])
    if fn in ["byte", "word", "dword", "qword"]:
      if node.len == 2:
        checkGprNode(mn, node[1], aliases, stmt)
    elif fn in ["rq", "rd"]:
      discard
    elif fn == "rx":
      error("dynasm: '" & mn &
        "' needs general-purpose registers (no SSE backend yet)", node)
    elif fn in ["fwd", "bwd", "glob", "globalref", "dyn", "dynlbl",
        "dynamic", "extaddr", "externaddr", "mem"]:
      discard
    else:
      discard
  of nnkBracket:
    for child in node:
      checkGprNode(mn, child, aliases, stmt)
  of nnkInfix:
    for i in 1..<node.len:
      checkGprNode(mn, node[i], aliases, stmt)
  else:
    discard

proc rexNeedInfo(node: NimNode,
    aliases: Table[string, string]): tuple[known, isHigh,
    needsRex: bool] =
  ## Static REX analysis for the AH/CH/DH/BH conflict check.
  proc infoFor(code: int, cls, size: string): tuple[known, isHigh,
      needsRex: bool] =
    let high = cls == "rcHigh8"
    let need = code >= 8 or
      (cls == "rcGpr" and size == "sz8" and code >= 4 and code <= 7)
    (true, high, need)
  if node.kind == nnkIdent and isRegName(node.strVal, aliases):
    let ri = resolveRegName(node.strVal, aliases)
    return infoFor(ri.code, ri.cls, ri.size)
  if (node.kind == nnkCall or node.kind == nnkCommand) and node.len == 2:
    let fn = getMn(node[0])
    if fn in ["byte", "word", "dword", "qword"] and
        node[1].kind == nnkIdent and isRegName(node[1].strVal, aliases):
      let ri = resolveRegName(node[1].strVal, aliases)
      let sz = case fn
        of "byte": "sz8"
        of "word": "sz16"
        of "dword": "sz32"
        else: "sz64"
      return infoFor(ri.code, ri.cls, sz)
  if node.kind == nnkCall and node.len == 2 and
      getMn(node[0]) in ["rq", "rd", "rx"]:
    return (true, false, false)
  (false, false, false)

proc checkHighRexConflict(mn: string, a, b: NimNode,
    aliases: Table[string, string], stmt: NimNode) =
  let ia = rexNeedInfo(a, aliases)
  let ib = rexNeedInfo(b, aliases)
  if ia.known and ib.known and
      ((ia.isHigh and ib.needsRex) or (ib.isHigh and ia.needsRex)):
    error("dynasm: '" & mn &
      "' cannot mix AH/CH/DH/BH with r8-r15 (or SPL/BPL/SIL/DIL) " &
      "in one instruction: high-byte registers forbid REX", stmt)

proc immFits(size: string, v: int64): bool =
  case size
  of "sz8": v >= -128 and v <= 255
  of "sz16": v >= -32768 and v <= 65535
  of "sz32": v >= -2147483648 and v <= 4294967295
  of "sz64": true
  else: true

proc sizeName(size: string): string =
  case size
  of "sz8": "a byte"
  of "sz16": "a word"
  of "sz32": "a doubleword"
  else: "its operand size"

proc unwrapSize(node: NimNode): NimNode =
  ## Strip one byte/word/dword/qword wrapper layer for literal checks.
  if (node.kind == nnkCall or node.kind == nnkCommand) and node.len == 2 and
      getMn(node[0]) in ["byte", "word", "dword", "qword"]:
    node[1]
  else:
    node

proc checkSizedImm(mn: string, size: string, arg: NimNode,
    stmt: NimNode) =
  ## Range-check an IntLit immediate against a known size. sz64 and
  ## unknown sizes are unchecked here (callers special-case them).
  if (size == "" or size == "sz64") or arg.kind notin intLitKinds:
    return
  if not immFits(size, arg.intVal):
    error("dynasm: '" & mn & "' immediate " & $arg.intVal &
      " does not fit in " & sizeName(size), arg)

proc checkAlu64Imm(mn: string, arg: NimNode, stmt: NimNode) =
  ## 64-bit ALU forms only encode imm32 (0x81); anything wider would
  ## be silently truncated downstream.
  if arg.kind in intLitKinds and
      not (arg.intVal >= -2147483648 and arg.intVal <= 4294967295):
    error("dynasm: '" & mn & "' 64-bit immediate " & $arg.intVal &
      " does not fit in 32 bits; load it into a register first", arg)

proc validateCommon(mn: string, args: seq[NimNode],
    aliases: Table[string, string], curIsX64: bool, stmt: NimNode) =
  for a in args:
    rejectBadLiteral(mn, a)
    checkArchNode(a, aliases, curIsX64, stmt)
    checkGprNode(mn, a, aliases, stmt)

proc validateMov(args: seq[NimNode], aliases: Table[string, string],
    stmt: NimNode) =
  let d = classifyOperand(args[0], aliases)
  let s = classifyOperand(args[1], aliases)
  if d.kind == oskImm:
    error("dynasm: 'mov' destination must be a register or memory, " &
      "not an immediate", args[0])
  if d.kind == oskLabel:
    error("dynasm: 'mov' destination cannot be a label", args[0])
  if d.kind == oskMem and s.kind == oskMem:
    error("dynasm: 'mov' cannot move memory to memory; use a register " &
      "in between", stmt)
  if s.kind == oskLabel and s.lbl == "absolute":
    if d.kind != oskReg and d.kind != oskOther:
      error("dynasm: absolute address source needs a 64-bit register " &
        "destination (movabs form)", args[0])
  elif s.kind == oskLabel:
    if d.kind != oskReg and d.kind != oskOther:
      error("dynasm: 'mov' from a label address needs a register " &
        "destination (it becomes lea)", args[0])
  checkHighRexConflict("mov", args[0], args[1], aliases, stmt)
  if s.kind == oskImm and s.isLit:
    let sz = if d.size != "": d.size
      elif s.size != "": s.size
      else: ""
    checkSizedImm("mov", sz, unwrapSize(args[1]), stmt)

proc validateMovabs(args: seq[NimNode], aliases: Table[string, string],
    stmt: NimNode) =
  let d = classifyOperand(args[0], aliases)
  let s = classifyOperand(args[1], aliases)
  if d.kind != oskReg and d.kind != oskOther:
    error("dynasm: 'movabs' destination must be a register", args[0])
  if s.kind != oskImm and s.kind != oskOther:
    error("dynasm: 'movabs' source must be an address-sized immediate",
      args[1])

proc validateLea(args: seq[NimNode], aliases: Table[string, string],
    stmt: NimNode) =
  let d = classifyOperand(args[0], aliases)
  let s = classifyOperand(args[1], aliases)
  if d.kind != oskReg and d.kind != oskOther:
    error("dynasm: 'lea' destination must be a register", args[0])
  if s.kind == oskLabel:
    error("dynasm: 'lea' source must be a memory operand; wrap the " &
      "label in [...] for RIP-relative addressing, e.g. " &
      "lea rcx, [glob(\"x\")]", args[1])
  elif s.kind != oskMem and s.kind != oskOther:
    error("dynasm: 'lea' source must be a memory operand like " &
      "[rbx + 8]", args[1])

proc validateAlu(mn: string, args: seq[NimNode],
    aliases: Table[string, string], stmt: NimNode) =
  let d = classifyOperand(args[0], aliases)
  let s = classifyOperand(args[1], aliases)
  if d.kind != oskReg and d.kind != oskMem and d.kind != oskOther:
    error("dynasm: '" & mn &
      "' destination must be a register or memory", args[0])
  if s.kind == oskLabel:
    error("dynasm: '" & mn & "' cannot take a label operand", args[1])
  if d.kind == oskMem and s.kind == oskMem:
    error("dynasm: '" & mn &
      "' cannot combine two memory operands; use a register in " &
      "between", stmt)
  checkHighRexConflict(mn, args[0], args[1], aliases, stmt)
  if s.kind == oskImm and s.isLit:
    var sz = if d.size != "": d.size
      elif s.size != "": s.size
      else: ""
    if sz == "" and d.kind == oskMem:
      sz = "sz32" # matches the dispatch default for bare memory
    if sz == "sz64":
      checkAlu64Imm(mn, unwrapSize(args[1]), stmt)
    else:
      checkSizedImm(mn, sz, unwrapSize(args[1]), stmt)

proc validateTest(args: seq[NimNode], aliases: Table[string, string],
    stmt: NimNode) =
  for i in 0..1:
    let k = classifyOperand(args[i], aliases).kind
    if k != oskReg and k != oskOther:
      error("dynasm: 'test' only supports register, register " &
        "operands", args[i])
  checkHighRexConflict("test", args[0], args[1], aliases, stmt)

proc validateIncDec(mn: string, args: seq[NimNode],
    aliases: Table[string, string], stmt: NimNode) =
  let k = classifyOperand(args[0], aliases).kind
  if k != oskReg and k != oskMem and k != oskOther:
    error("dynasm: '" & mn & "' needs a register or memory operand",
      args[0])

proc validatePush(args: seq[NimNode], aliases: Table[string, string],
    stmt: NimNode) =
  let k = classifyOperand(args[0], aliases)
  if k.kind != oskReg and k.kind != oskImm and k.kind != oskMem and
      k.kind != oskOther:
    error("dynasm: 'push' supports registers, immediates and " &
      "memory only", args[0])
  if k.kind == oskMem and k.size != "sz16" and k.size != "sz64":
    error("dynasm: 'push' memory needs an explicit size, e.g. " &
      "push qword [rbx]", args[0])
  if k.kind == oskImm and k.isLit:
    let v = k.lit
    if not (v >= -128 and v <= 127) and
        not (v >= -2147483648 and v <= 4294967295):
      error("dynasm: 'push' immediate " & $v &
        " does not fit in 32 bits", args[0])

proc validatePop(args: seq[NimNode], aliases: Table[string, string],
    stmt: NimNode) =
  let k = classifyOperand(args[0], aliases).kind
  if k != oskReg and k != oskOther:
    error("dynasm: 'pop' needs a register operand", args[0])

proc validateJmpTarget(mn: string, arg: NimNode,
    aliases: Table[string, string], stmt: NimNode, cond: bool) =
  let k = classifyOperand(arg, aliases)
  if k.kind == oskImm:
    error("dynasm: '" & mn &
      "' needs a label, register or memory target, not an immediate" &
      "; use extAddr() for absolute addresses (via a register) or a " &
      "label for relative jumps", arg)
  if k.kind == oskLabel and k.lbl == "absolute":
    error("dynasm: '" & mn &
      "' cannot encode an absolute address directly; load it into " &
      "a register first (e.g. mov rax, extAddr(a); " & mn & " rax)",
      arg)
  if cond and k.kind != oskLabel and k.kind != oskOther:
    error("dynasm: '" & mn &
      "' needs a label target like fwd(\"loop\")", arg)
  if not cond and k.kind != oskLabel and k.kind != oskReg and
      k.kind != oskMem and k.kind != oskOther:
    error("dynasm: '" & mn & "' needs a label, register or memory " &
      "target", arg)

proc validateShift(mn: string, args: seq[NimNode],
    aliases: Table[string, string], stmt: NimNode) =
  let d = classifyOperand(args[0], aliases).kind
  if d != oskReg and d != oskMem and d != oskOther:
    error("dynasm: '" & mn &
      "' destination must be a register or memory", args[0])
  let c = unwrapSize(args[1])
  if c.kind in intLitKinds:
    if c.intVal < 0 or c.intVal > 63:
      error("dynasm: '" & mn & "' count " & $c.intVal &
        " is out of range 0-63 (x86 masks the count)", c)
  elif c.kind == nnkIdent and isRegName(c.strVal, aliases):
    if c.strVal.toLowerAscii != "cl":
      error("dynasm: '" & mn &
        "' register count must be cl; use an immediate otherwise", c)
  else:
    let k = classifyOperand(c, aliases).kind
    if k == oskMem or k == oskLabel:
      error("dynasm: '" & mn &
        "' count must be an immediate or cl", c)

proc validateImul(args: seq[NimNode], aliases: Table[string, string],
    stmt: NimNode) =
  if args.len == 2:
    let d = classifyOperand(args[0], aliases)
    let s = classifyOperand(args[1], aliases)
    if d.kind != oskReg and d.kind != oskOther:
      error("dynasm: 'imul' destination must be a register", args[0])
    if s.kind == oskImm:
      error("dynasm: 'imul' with an immediate needs the 3-operand " &
        "form: imul dst, src, imm", args[1])
    if s.kind != oskReg and s.kind != oskMem and s.kind != oskOther:
      error("dynasm: 'imul' source must be a register or memory",
        args[1])
    if d.kind == oskReg and d.size == "sz8":
      error("dynasm: 'imul' needs 16/32/64-bit registers", args[0])
    if args[0].kind == nnkIdent or args[1].kind == nnkIdent:
      checkHighRexConflict("imul", args[0], args[1], aliases, stmt)
  else:
    let d = classifyOperand(args[0], aliases)
    let s = classifyOperand(args[1], aliases)
    let im = classifyOperand(args[2], aliases)
    if d.kind != oskReg and d.kind != oskOther:
      error("dynasm: 'imul' destination must be a register", args[0])
    if s.kind != oskReg and s.kind != oskOther:
      error("dynasm: 'imul' source must be a register", args[1])
    if im.kind == oskMem or im.kind == oskLabel or im.kind == oskReg:
      error("dynasm: 'imul' third operand must be an immediate",
        args[2])
    if im.kind == oskImm and im.isLit:
      let v = im.lit
      if not (v >= -128 and v <= 127) and
          not (v >= -2147483648 and v <= 4294967295):
        error("dynasm: 'imul' immediate " & $v &
          " does not fit in 32 bits", args[2])

proc validateDivMul(mn: string, args: seq[NimNode],
    aliases: Table[string, string], stmt: NimNode) =
  let k = classifyOperand(args[0], aliases).kind
  if k != oskReg and k != oskMem and k != oskOther:
    error("dynasm: '" & mn & "' needs a register or memory operand",
      args[0])

proc validateMovzx(args: seq[NimNode], aliases: Table[string, string],
    stmt: NimNode) =
  let d = classifyOperand(args[0], aliases)
  let s = classifyOperand(args[1], aliases)
  if d.kind != oskReg and d.kind != oskOther:
    error("dynasm: 'movzx' destination must be a register", args[0])
  if d.kind == oskReg and d.size == "sz8":
    error("dynasm: 'movzx' destination must be 16/32/64-bit", args[0])
  if s.kind == oskReg:
    if s.size != "" and s.size != "sz8" and s.size != "sz16":
      error("dynasm: 'movzx' source must be a byte/word register " &
        "or memory", args[1])
  elif s.kind == oskMem:
    if s.size != "" and s.size != "sz8" and s.size != "sz16":
      error("dynasm: 'movzx' source must be byte/word sized, e.g. " &
        "movzx eax, byte [rdi]", args[1])
  elif s.kind != oskOther:
    error("dynasm: 'movzx' source must be a byte/word register or " &
      "memory", args[1])

proc validateSetcc(mn: string, args: seq[NimNode],
    aliases: Table[string, string], stmt: NimNode) =
  let d = classifyOperand(args[0], aliases)
  if d.kind == oskReg:
    if d.size != "" and d.size != "sz8" and d.size != "szNone":
      error("dynasm: '" & mn & "' needs a byte register like al, " &
        "spl or r8b", args[0])
  elif d.kind == oskMem:
    if d.size != "" and d.size != "sz8" and d.size != "szNone":
      error("dynasm: '" & mn & "' needs byte-sized memory, e.g. " &
        "sete byte [rdi]", args[0])
  elif d.kind != oskOther:
    error("dynasm: '" & mn & "' needs a byte register or memory",
      args[0])

proc validateLabelRefArg(mn: string, arg: NimNode, stmt: NimNode) =
  if not isLabelRefNode(arg):
    error("dynasm: '" & mn &
      "' needs a label reference like fwd(\"name\"), bwd(\"name\") " &
      "or glob(\"name\")", arg)

# --------------------------------------------------------------------------
# Main macro
# --------------------------------------------------------------------------

macro dynasm*(ops: untyped, body: untyped): untyped =
  var aliases = initTable[string, string]()
  var globalLabels = initTable[string, bool]()
  var curIsX64 = true
  var curArchA64 = false
  result = newStmtList()
  # Ensure needed symbols are visible in generated code scope:
  # caller must import dynasm/registers, dispatch, etc. We reference by name.

  # ops is untyped AST; copy each time via copyNimTree(ops) inline.
  # (do not wrap in nested proc: untyped cannot be captured reliably)

  if body.kind != nnkStmtList:
    error("dynasm body must be a statement list", body)

  for stmt in body:
    # Skip empty
    if stmt.kind == nnkDiscardStmt: continue
    # Handle nnkCommand / nnkCall. Anything else with its own node
    # kind (let/var/if/for/while/return/assignments/...) is Nim code
    # and passes through untouched.
    var mn = ""
    var args: seq[NimNode] = @[]
    var rawHead = ""
    # Condition for dotted b.eq (0-15); 0 = no condition to add.
    var a64CondBits = 0
    if stmt.kind == nnkCommand:
      if stmt[0].kind == nnkIdent:
        rawHead = stmt[0].strVal
      elif stmt[0].kind == nnkAccQuoted and stmt[0].len > 0 and
          stmt[0][0].kind == nnkIdent:
        rawHead = stmt[0][0].strVal
      elif stmt[0].kind == nnkDotExpr and stmt[0].len == 2 and
          stmt[0][0].kind == nnkIdent and
          stmt[0][1].kind == nnkIdent:
        # Dotted AArch64 mnemonics: b.eq, mov.inverted, mov.logical.
        # Anything else dotted stays Nim code (a.b() calls etc.).
        let dotBase = stmt[0][0].strVal.toLowerAscii
        let dotAttr = stmt[0][1].strVal.toLowerAscii
        if curArchA64 and dotBase == "b" and dotAttr in a64CondNames:
          rawHead = "b." & dotAttr
          mn = "b.cond"
          a64CondBits = a64CondBitsOf(dotAttr)
        elif curArchA64 and dotBase == "mov" and
            dotAttr in ["inverted", "logical"]:
          rawHead = "mov." & dotAttr
          mn = "mov." & dotAttr
        else:
          result.add(copyNimTree(stmt))
          continue
      if mn == "":
        mn = getMn(stmt[0])
      for i in 1..<stmt.len:
        args.add(stmt[i])
    elif stmt.kind == nnkCall:
      if stmt[0].kind == nnkIdent:
        rawHead = stmt[0].strVal
      elif stmt[0].kind == nnkAccQuoted and stmt[0].len > 0 and
          stmt[0][0].kind == nnkIdent:
        rawHead = stmt[0][0].strVal
      elif stmt[0].kind == nnkDotExpr and stmt[0].len == 2 and
          stmt[0][0].kind == nnkIdent and
          stmt[0][1].kind == nnkIdent:
        let dotBase = stmt[0][0].strVal.toLowerAscii
        let dotAttr = stmt[0][1].strVal.toLowerAscii
        if curArchA64 and dotBase == "b" and dotAttr in a64CondNames:
          rawHead = "b." & dotAttr
          mn = "b.cond"
          a64CondBits = a64CondBitsOf(dotAttr)
        elif curArchA64 and dotBase == "mov" and
            dotAttr in ["inverted", "logical"]:
          rawHead = "mov." & dotAttr
          mn = "mov." & dotAttr
        else:
          result.add(copyNimTree(stmt))
          continue
      if mn == "":
        mn = getMn(stmt[0])
      for i in 1..<stmt.len:
        args.add(stmt[i])
    elif stmt.kind == nnkIdent:
      rawHead = stmt.strVal
      mn = stmt.strVal.toLowerAscii
    elif stmt.kind in intLitKinds + {nnkFloatLit, nnkStrLit, nnkCharLit}:
      error("dynasm: unexpected literal in dynasm block", stmt)
    else:
      # Structured Nim statement — pass through untouched.
      result.add(copyNimTree(stmt))
      continue
    if stmt.kind == nnkCommand or stmt.kind == nnkCall:
      if mn == "":
        # Dotted/operator calls (ops.foo(), a.b()) can only be Nim.
        result.add(copyNimTree(stmt))
        continue
      if not isDynasmWord(mn):
        if mn in nimStmtHeads:
          result.add(copyNimTree(stmt))
          continue
        if not hasLowerAscii(mn):
          # No lowercase letters (operators like `+`): not an asm typo.
          result.add(copyNimTree(stmt))
          continue
        if hasUpperAscii(rawHead):
          # Nim naming convention (constructors, helpers): Nim code.
          result.add(copyNimTree(stmt))
          continue
        unknownMnemonicError(if rawHead != "": rawHead else: mn, mn,
          stmt)
    if stmt.kind == nnkIdent and not isDynasmWord(mn):
      # Bare word statement: a zero-arg mnemonic typo or Nim code.
      if hasUpperAscii(rawHead) or mn in nimStmtHeads or
          not hasLowerAscii(mn):
        result.add(copyNimTree(stmt))
        continue
      unknownMnemonicError(rawHead, mn, stmt)

    # Directives
    if mn == "arch":
      if args.len != 1:
        error("arch needs 1 arg: x64|x86|aarch64", stmt)
      let a = getMn(args[0])
      if a == "" and args[0].kind == nnkIdent:
        let s = args[0].strVal.toLowerAscii
        if s == "x64":
          curIsX64 = true
          curArchA64 = false
        elif s == "x86":
          curIsX64 = false
          curArchA64 = false
        elif s in ["aarch64", "arm64"]:
          curIsX64 = true
          curArchA64 = true
        else: error("arch must be x64, x86 or aarch64", stmt)
      else:
        if a == "x64":
          curIsX64 = true
          curArchA64 = false
        elif a == "x86":
          curIsX64 = false
          curArchA64 = false
        elif a in ["aarch64", "arm64"]:
          curIsX64 = true
          curArchA64 = true
        else: error("arch must be x64, x86 or aarch64", stmt)
      continue
    elif mn == "alias":
      if args.len != 2 and args.len != 3:
        error("alias needs name, reg (or name, sysv-reg, win-reg)", stmt)
      if args[0].kind != nnkIdent:
        error("alias name must be ident", stmt)
      for ai in 1 ..< args.len:
        if args[ai].kind != nnkIdent or
            not isRegName(args[ai].strVal, aliases, curArchA64):
          error("alias target must be register", stmt)
      let aliasName = args[0].strVal.toLowerAscii
      if isRegName(aliasName, aliases, curArchA64):
        error("dynasm: alias name '" & args[0].strVal &
          "' shadows a register; pick another name", args[0])
      if isDynasmWord(aliasName):
        error("dynasm: alias name '" & args[0].strVal &
          "' collides with an instruction or directive", args[0])
      # Three-form: first argument register per host ABI. Integer args
      # arrive in rdi,rsi,rdx,rcx (System V) but rcx,rdx,r8,r9 (Win64),
      # and a `when` cannot select inside the block (it passes through
      # unexpanded), so the macro picks by target here. Evaluated at
      # expansion time, which sees the compilation target's defines.
      var targetReg = args[1].strVal.toLowerAscii
      if args.len == 3:
        when defined(windows):
          targetReg = args[2].strVal.toLowerAscii
      aliases[aliasName] = targetReg
      continue
    elif mn in ["label", "locallabel"]:
      if args.len != 1 or args[0].kind != nnkIdent:
        error("label needs ident", stmt)
      let labelName = args[0].strVal.toLowerAscii
      if isDynasmWord(labelName):
        error("dynasm: label name '" & args[0].strVal &
          "' collides with an instruction or directive", args[0])
      if isRegName(labelName, aliases, curArchA64):
        error("dynasm: label name '" & args[0].strVal &
          "' collides with a register name", args[0])
      let nm = newLit(args[0].strVal)
      let o = copyNimTree(ops)
      result.add(quote do: `o`.localLabel(`nm`))
      continue
    elif mn in ["global", "globallabel"]:
      if args.len != 1 or args[0].kind != nnkIdent:
        error("global needs ident", stmt)
      let labelName = args[0].strVal.toLowerAscii
      if isDynasmWord(labelName):
        error("dynasm: label name '" & args[0].strVal &
          "' collides with an instruction or directive", args[0])
      if isRegName(labelName, aliases, curArchA64):
        error("dynasm: label name '" & args[0].strVal &
          "' collides with a register name", args[0])
      if labelName in globalLabels:
        error("dynasm: duplicate global label '" & args[0].strVal &
          "' in this block (globals may only be defined once; use " &
          "label for re-definable locals)", args[0])
      globalLabels[labelName] = true
      let nm = newLit(args[0].strVal)
      let o = copyNimTree(ops)
      result.add(quote do: `o`.globalLabel(`nm`))
      continue
    elif mn in ["dynamiclabel", "binddyn", "dynlabel"]:
      if args.len != 1:
        error("dynamicLabel needs DynamicLabel expr", stmt)
      let e = args[0]
      let o = copyNimTree(ops)
      result.add(quote do: `o`.dynamicLabel(`e`))
      continue
    elif mn == "align":
      let o = copyNimTree(ops)
      if args.len == 1:
        let n = args[0]
        result.add(quote do: `o`.align(cast[int](`n`)))
      elif args.len == 2:
        let n = args[0]
        let f = args[1]
        result.add(quote do: `o`.align(cast[int](`n`), cast[byte](`f`)))
      else:
        error("align needs 1-2 args", stmt)
      continue
    elif mn in ["u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64"]:
      if args.len == 0:
        error("dynasm: '" & mn & "' needs at least one value", stmt)
      let o = copyNimTree(ops)
      for a in args:
        if a.kind == nnkStrLit:
          error("dynasm: '" & mn &
            "' takes integer values; use `bytes` for strings", a)
        elif a.kind in {nnkFloatLit, nnkCharLit}:
          error("dynasm: '" & mn & "' takes integer values", a)
        else:
          let k = classifyOperand(a, aliases)
          if k.kind == oskMem or k.kind == oskLabel or k.kind == oskReg:
            error("dynasm: '" & mn &
              "' takes integer expressions, not operands", a)
        case mn
        of "u8", "i8":
          result.add(quote do: `o`.push(cast[byte](`a`)))
        of "u16", "i16":
          result.add(quote do: `o`.pushU16(cast[uint16](`a`)))
        of "u32", "i32":
          result.add(quote do: `o`.pushU32(cast[uint32](`a`)))
        else:
          result.add(quote do: `o`.pushU64(cast[uint64](`a`)))
      continue
    elif mn in ["f32"]:
      if args.len == 0:
        error("dynasm: 'f32' needs at least one value", stmt)
      let o = copyNimTree(ops)
      for a in args:
        if a.kind in {nnkStrLit, nnkCharLit}:
          error("dynasm: 'f32' takes float values", a)
        result.add(quote do:
          `o`.pushU32(cast[uint32](cast[float32](`a`))))
      continue
    elif mn in ["f64"]:
      if args.len == 0:
        error("dynasm: 'f64' needs at least one value", stmt)
      let o = copyNimTree(ops)
      for a in args:
        if a.kind in {nnkStrLit, nnkCharLit}:
          error("dynasm: 'f64' takes float values", a)
        result.add(quote do:
          `o`.pushU64(cast[uint64](cast[float64](`a`))))
      continue
    elif mn in ["bytes", "bytecode", "db"]:
      if args.len == 0:
        error("dynasm: '" & mn & "' needs at least one value", stmt)
      let o = copyNimTree(ops)
      for a in args:
        # string or seq[byte]/openArray
        result.add(quote do:
          block:
            let dynasmTmp = `a`
            when dynasmTmp is string:
              dynasmBytesStr(`o`, dynasmTmp)
            else:
              dynasmBytes(`o`, dynasmTmp))
      continue
    elif mn in ["rel8", "rel16", "rel32", "rel64"]:
      if args.len != 1:
        error(mn & " needs labelref", stmt)
      validateLabelRefArg(mn, args[0], stmt)
      let szIdent =
        case mn
        of "rel8": ident("rsByte")
        of "rel16": ident("rsWord")
        of "rel32": ident("rsDWord")
        else: ident("rsQWord")
      let lrNode = args[0]
      # lrNode should be fwd/bwd/glob/dyn...; build LabelRef expr
      # Reuse operandAst then extract lbl? Simpler: expect label call.
      # Generate dynasmRel with LabelRef built from call.
      # If user passed byte(...) wrapper, unwrap (short already implied).
      var lrExpr: NimNode = lrNode
      if lrNode.kind == nnkCall and getMn(lrNode[0]) in
          ["byte", "word", "dword", "qword"] and lrNode.len == 2:
        lrExpr = lrNode[1]
      let o = copyNimTree(ops)
      result.add(quote do: dynasmRel(`o`, `szIdent`, `lrExpr`))
      continue
    elif mn in ["abs32", "abs64", "abs8", "abs16"]:
      if args.len != 1:
        error(mn & " needs labelref", stmt)
      validateLabelRefArg(mn, args[0], stmt)
      let szIdent =
        case mn
        of "abs8": ident("rsByte")
        of "abs16": ident("rsWord")
        of "abs32": ident("rsDWord")
        else: ident("rsQWord")
      let lrExpr = args[0]
      let o = copyNimTree(ops)
      result.add(quote do: dynasmAbs(`o`, `szIdent`, `lrExpr`))
      continue
    elif mn in ["feature"]:
      # v1: validate but ignore (full feature gating later)
      continue

    # Prefix handling: lock/rep/segment as single-arg wrapping command
    if mn in ["lock", "rep", "repe", "repz", "repne", "repnz", "repnz"]:
      # args may be [Command(...), extra...] due to parsing
      # Emit prefix byte then recurse on remainder as new stmt
      let o = copyNimTree(ops)
      let prefByte =
        case mn
        of "lock": 0xF0
        of "rep", "repe", "repz": 0xF3
        else: 0xF2
      let pb = newLit(prefByte)
      result.add(quote do: `o`.push(cast[byte](`pb`)))
      # Reconstruct inner instruction stmt from args
      # Case A: args[0] is Command/Call -> inner mnemonic + inner args + rest
      if args.len >= 1 and args[0].kind in {nnkCommand, nnkCall}:
        var innerMn = getMn(args[0][0])
        var innerArgs: seq[NimNode] = @[]
        for i in 1..<args[0].len:
          innerArgs.add(args[0][i])
        for i in 1..<args.len:
          innerArgs.add(args[i])
        # Build synthetic stmt and process one iteration by re-dispatch:
        # Instead of duplicating logic, emit recursive dynasm call for one stmt?
        # Simpler: construct new Command node and push to result via re-entry.
        # We handle common case: inner is full instruction, so generate its
        # dispatch directly by synthesizing a stmt node.
        var synth: NimNode
        if innerArgs.len == 0:
          synth = ident(innerMn)
        else:
          synth = newTree(nnkCommand, ident(innerMn))
          for a in innerArgs:
            synth.add(a)
        # Re-process by appending to a temporary and handling via same loop?
        # To avoid complexity, just add a nested dynasm single-stmt block:
        # Fallback: emit raw handling for known inner mnemonics via direct call
        # below (duplicate minimal dispatch for mov/alu). For v1, support
        # cmpxchg/xchg as db fallback error.
        error("lock/rep prefix with embedded command needs manual split; " &
          "write prefix as `db 0xF0` + instruction on next line", stmt)
      else:
        error("lock/rep needs instruction after it", stmt)

    # AArch64 instructions: unified DSL, per-arch tables.
    if curArchA64:
      if not isA64Mn(mn):
        if mn in dynasmInstrWords or mn in aluMnemonics or
            mn in shiftMnemonics or mn in divMnemonics or
            mn in jccMnemonics or mn in setccMnemonics:
          error("dynasm: '" & mn &
            "' is an x86 instruction; use arch x64/x86 for it", stmt)
        error("dynasm: unhandled mnemonic '" & mn & "'", stmt)
      let oo = copyNimTree(ops)
      result.add(a64ProcessInstruction(mn, args, oo, aliases,
        a64CondBits, stmt))
      continue

    # Instructions
    let isX64Lit = newLit(curIsX64)
    let o = copyNimTree(ops)

    proc opAst(i: int): NimNode =
      operandAst(args[i], aliases)

    if mn == "mov" or mn == "movabs":
      if args.len != 2:
        error("mov needs 2 args", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      if mn == "mov":
        validateMov(args, aliases, stmt)
      else:
        validateMovabs(args, aliases, stmt)
      let d = opAst(0)
      let s = opAst(1)
      if mn == "movabs":
        # force 64-bit movabs reg,imm
        result.add(quote do:
          block:
            let dynasmD = `d`
            let dynasmS = `s`
            if dynasmD.kind != okReg:
              raise impossibleRelocation("movabs needs reg dst")
            var dynasmImm: int64
            if dynasmS.kind == okImm: dynasmImm = dynasmS.imm
            else: raise impossibleRelocation("movabs needs imm src")
            encMovRegImm(`o`, dynasmD.reg, dynasmImm, sz64))
      else:
        result.add(quote do:
          dynasmMov(`o`, `d`, `s`, `isX64Lit`))
      continue
    elif mn == "lea":
      if args.len != 2:
        error("lea needs 2 args", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateLea(args, aliases, stmt)
      let d = opAst(0)
      let s = opAst(1)
      result.add(quote do: dynasmLea(`o`, `d`, `s`, `isX64Lit`))
      continue
    elif mn in aluMnemonics:
      if args.len != 2:
        error(mn & " needs 2 args", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateAlu(mn, args, aliases, stmt)
      let d = opAst(0)
      let s = opAst(1)
      let mnLit = newLit(mn)
      result.add(quote do: dynasmAlu(`o`, `mnLit`, `d`, `s`, `isX64Lit`))
      continue
    elif mn == "test":
      if args.len != 2:
        error("test needs 2 args", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateTest(args, aliases, stmt)
      let d = opAst(0)
      let s = opAst(1)
      result.add(quote do: dynasmTest(`o`, `d`, `s`))
      continue
    elif mn in ["inc", "dec"]:
      if args.len != 1:
        error(mn & " needs 1 arg", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateIncDec(mn, args, aliases, stmt)
      let d = opAst(0)
      let mnLit = newLit(mn)
      result.add(quote do: dynasmIncDec(`o`, `mnLit`, `d`, `isX64Lit`))
      continue
    elif mn in ["push"]:
      if args.len != 1:
        error("push needs 1 arg", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validatePush(args, aliases, stmt)
      let d = opAst(0)
      result.add(quote do: dynasmPush(`o`, `d`, `isX64Lit`))
      continue
    elif mn in ["pop"]:
      if args.len != 1:
        error("pop needs 1 arg", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validatePop(args, aliases, stmt)
      let d = opAst(0)
      result.add(quote do: dynasmPop(`o`, `d`, `isX64Lit`))
      continue
    elif mn in ["jmp", "jmp_short", "jmp8"]:
      if args.len == 0:
        error("jmp needs target", stmt)
      # short detection: jmp byte(target) or jmp_short
      var isShort = mn in ["jmp_short", "jmp8"]
      var rawTarget: NimNode
      if args.len == 1:
        if args[0].kind == nnkCall and getMn(args[0][0]) == "byte":
          isShort = true
          rawTarget = args[0][1]
        else:
          rawTarget = args[0]
      elif args.len == 2 and getMn(args[0]) in ["byte"]:
        # `jmp byte, target`? unlikely
        isShort = true
        rawTarget = args[1]
      else:
        error("jmp needs 1 arg", stmt)
      validateCommon(mn, @[rawTarget], aliases, curIsX64, stmt)
      validateJmpTarget(mn, rawTarget, aliases, stmt, false)
      let targetNode: NimNode = operandAst(rawTarget, aliases)
      let shortLit = newLit(isShort)
      result.add(quote do: dynasmJmp(`o`, `targetNode`, `shortLit`))
      continue
    elif mn in jccMnemonics or
        (mn.endsWith("_short") and mn[0..^7] in jccMnemonics) or
        (mn.endsWith("8") and mn[0..^2] in jccMnemonics):
      var base = mn
      var isShort = false
      if mn.endsWith("_short"):
        base = mn[0..^7]
        isShort = true
      elif mn.endsWith("8") and mn[0..^2] in jccMnemonics:
        base = mn[0..^2]
        isShort = true
      if args.len != 1:
        error(base & " needs 1 arg", stmt)
      var rawTarget = args[0]
      if args[0].kind == nnkCall and getMn(args[0][0]) == "byte":
        isShort = true
        rawTarget = args[0][1]
      validateCommon(base, @[rawTarget], aliases, curIsX64, stmt)
      validateJmpTarget(base, rawTarget, aliases, stmt, true)
      let targetNode: NimNode = operandAst(rawTarget, aliases)
      let baseLit = newLit(base)
      let shortLit = newLit(isShort)
      result.add(quote do: dynasmJcc(`o`, `baseLit`, `targetNode`,
        `shortLit`))
      continue
    elif mn in setccMnemonics:
      if args.len != 1:
        error(mn & " needs 1 arg", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateSetcc(mn, args, aliases, stmt)
      let d = opAst(0)
      let mnLit = newLit(mn)
      result.add(quote do: dynasmSetcc(`o`, `mnLit`, `d`, `isX64Lit`))
      continue
    elif mn in shiftMnemonics:
      if args.len != 2:
        error(mn & " needs 2 args: dst, count", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateShift(mn, args, aliases, stmt)
      let d = opAst(0)
      let c = opAst(1)
      let mnLit = newLit(mn)
      result.add(quote do: dynasmShift(`o`, `mnLit`, `d`, `c`, `isX64Lit`))
      continue
    elif mn in ["imul"]:
      if args.len == 2:
        validateCommon(mn, args, aliases, curIsX64, stmt)
        validateImul(args, aliases, stmt)
        let d = opAst(0)
        let s = opAst(1)
        result.add(quote do: dynasmImul(`o`, `d`, `s`, `isX64Lit`))
      elif args.len == 3:
        validateCommon(mn, @[args[0], args[1]], aliases, curIsX64,
          stmt)
        validateImul(args, aliases, stmt)
        let d = opAst(0)
        let s = opAst(1)
        let immNode = args[2]
        result.add(quote do:
          block:
            let dynasmDst = `d`
            let dynasmSrc = `s`
            let dynasmImm = cast[int64](`immNode`)
            dynasmImul3(`o`, dynasmDst, dynasmSrc, dynasmImm))
      else:
        error("imul needs 2 or 3 args", stmt)
      continue
    elif mn in divMnemonics:
      if args.len != 1:
        error(mn & " needs 1 arg", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateDivMul(mn, args, aliases, stmt)
      let d = opAst(0)
      let mnLit = newLit(mn)
      result.add(quote do: dynasmDivMul(`o`, `mnLit`, `d`, `isX64Lit`))
      continue
    elif mn in ["cqo", "cdq"]:
      if args.len != 0:
        error("dynasm: '" & mn & "' takes no operands", stmt)
      let oo = copyNimTree(ops)
      let szLit =
        if mn == "cqo": ident("sz64")
        else: ident("sz32")
      result.add(quote do: encCqo(`oo`, `szLit`))
      continue
    elif mn in ["movzx"]:
      if args.len != 2:
        error("movzx needs 2 args", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateMovzx(args, aliases, stmt)
      let d = opAst(0)
      let s = opAst(1)
      result.add(quote do: dynasmMovzx(`o`, `d`, `s`, `isX64Lit`))
      continue
    elif mn in ["call"]:
      if args.len != 1:
        error("call needs 1 arg", stmt)
      validateCommon(mn, args, aliases, curIsX64, stmt)
      validateJmpTarget(mn, args[0], aliases, stmt, false)
      let d = opAst(0)
      result.add(quote do: dynasmCall(`o`, `d`, `isX64Lit`))
      continue
    elif mn in ["ret", "retn"]:
      if args.len != 0:
        error("dynasm: '" & mn & "' takes no operands", stmt)
      let oo = copyNimTree(ops)
      result.add(quote do: encRet(`oo`))
      continue
    elif mn in ["nop"]:
      if args.len != 0:
        error("dynasm: 'nop' takes no operands", stmt)
      let oo = copyNimTree(ops)
      result.add(quote do: encNop(`oo`))
      continue
    elif mn in ["int3"]:
      if args.len != 0:
        error("dynasm: 'int3' takes no operands", stmt)
      let oo = copyNimTree(ops)
      result.add(quote do: encInt3(`oo`))
      continue
    elif mn in ["leave"]:
      if args.len != 0:
        error("dynasm: 'leave' takes no operands", stmt)
      let oo = copyNimTree(ops)
      result.add(quote do: `oo`.push(0xC9'u8))
      continue
    elif mn in ["hlt"]:
      if args.len != 0:
        error("dynasm: 'hlt' takes no operands", stmt)
      let oo = copyNimTree(ops)
      result.add(quote do: `oo`.push(0xF4'u8))
      continue
    elif mn in ["db"]:
      if args.len == 0:
        error("dynasm: 'db' needs at least one value", stmt)
      let oo = copyNimTree(ops)
      for a in args:
        result.add(quote do: `oo`.push(cast[uint8](`a`)))
      continue
    else:
      # Unreachable: every known word is handled above, unknown words
      # are rejected at dispatch. Kept as a guard for future edits.
      if mn in a64OnlyWords:
        error("dynasm: '" & mn &
          "' is an AArch64 instruction; use arch aarch64 for it",
          stmt)
      error("dynasm: unhandled mnemonic '" & mn & "'", stmt)

  # -d:dynasmDebug support. The `when` is emitted into the generated
  # code on purpose: a `when defined()` inside this macro body would
  # see this module's own flags, while the generated `when` is
  # evaluated in the caller's context, so it honors the caller's
  # -d:dynasmDebug. `static: echo` prints at compile time with zero
  # runtime or codegen cost when the flag is absent.
  let dumpText = "dynasm(" & ops.repr & ") expansion (" &
    $result.len & " statements):\n" & result.repr
  let dumpLit = newLit(dumpText)
  let bodyStmts = result
  result = newStmtList()
  result.add(quote do:
    when defined(dynasmDebug):
      static:
        echo `dumpLit`)
  for s in bodyStmts:
    result.add(s)
