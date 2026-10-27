## Assemblers: SimpleAssembler, VecAssembler, Assembler (JIT).
## Mirrors runtime/src/lib.rs + components.rs (SimpleRelocation plus
## AArch64 arch-specific relocations).

import std/tables
import ./types
import ./relocations
import ./labels
import ./exec

# --------------------------------------------------------------------------
# PatchLoc
# --------------------------------------------------------------------------

type
  PatchLoc* = object
    location*: int      ## absolute offset just past the patched field
    fieldOffset*: int   ## bytes backwards to field start
    refOffset*: int     ## bytes backwards to reference point (usually end)
    relocation*: SimpleRelocation
    targetOffset*: int

proc newPatchLoc*(location, targetOffset, fieldOffset, refOffset: int,
    r: SimpleRelocation): PatchLoc =
  PatchLoc(location: location, targetOffset: targetOffset,
    fieldOffset: fieldOffset, refOffset: refOffset, relocation: r)

proc fieldStart*(loc: PatchLoc, bufOffset: int): int =
  loc.location - bufOffset - loc.fieldOffset

proc patchRange*(loc: PatchLoc, bufOffset: int): tuple[start, len: int] =
  (loc.fieldStart(bufOffset), relSize(loc.relocation.size))

proc relocValue*(loc: PatchLoc, target, bufAddr: int): int64 =
  let base =
    case loc.relocation.kind
    of rkRelative:
      target - (loc.location - loc.refOffset)
    of rkRelToAbs:
      target - (loc.location - loc.refOffset) - bufAddr
    of rkAbsToRel:
      target + bufAddr
    of rkAbsolute:
      target
  int64(base + loc.targetOffset)

proc patchAt*(loc: PatchLoc, buf: var openArray[byte], bufOffset: int,
    bufAddr, target: int) =
  let (start, len) = loc.patchRange(bufOffset)
  assert start >= 0 and start + len <= buf.len
  let v = loc.relocValue(target, bufAddr)
  # Stack scratch (max reloc size is 8): avoids a heap `newSeq`
  # per patched relocation on the hot assembly path.
  var tmp: array[8, byte]
  for i in 0..<len:
    tmp[i] = buf[start + i]
  if not loc.relocation.writeValue(tmp.toOpenArray(0, len - 1), v):
    raise impossibleRelocation("value out of range")
  for i in 0..<len:
    buf[start + i] = tmp[i]

proc adjustAt*(loc: PatchLoc, buf: var openArray[byte], bufOffset: int,
    adjustment: int) =
  case loc.relocation.kind
  of rkRelative, rkAbsolute:
    return
  of rkRelToAbs, rkAbsToRel:
    let (start, len) = loc.patchRange(bufOffset)
    var tmp: array[8, byte]
    for i in 0..<len:
      tmp[i] = buf[start + i]
    let cur = loc.relocation.readValue(tmp.toOpenArray(0, len - 1))
    let nv =
      if loc.relocation.kind == rkRelToAbs: cur - int64(adjustment)
      else: cur + int64(adjustment)
    if not loc.relocation.writeValue(tmp.toOpenArray(0, len - 1), nv):
      raise impossibleRelocation("managed adjust out of range")
    for i in 0..<len:
      buf[start + i] = tmp[i]

proc needsAdjustment*(loc: PatchLoc): bool =
  loc.relocation.kind == rkRelToAbs or loc.relocation.kind == rkAbsToRel

# --------------------------------------------------------------------------
# SimpleAssembler
# --------------------------------------------------------------------------

type
  SimpleAssembler* = object
    ops*: seq[byte]

proc initSimpleAssembler*(): SimpleAssembler = SimpleAssembler(ops: @[])

proc offset*(a: SimpleAssembler): AssemblyOffset =
  AssemblyOffset(a.ops.len)

proc push*(a: var SimpleAssembler, b: byte) = a.ops.add(b)
proc pushI8*(a: var SimpleAssembler, v: int8) = a.ops.add(cast[byte](v))
proc pushI16*(a: var SimpleAssembler, v: int16) =
  let u = cast[uint16](v)
  a.ops.add(byte(u and 0xFF)); a.ops.add(byte((u shr 8) and 0xFF))
proc pushI32*(a: var SimpleAssembler, v: int32) =
  let u = cast[uint32](v)
  a.ops.add(byte(u and 0xFF))
  a.ops.add(byte((u shr 8) and 0xFF))
  a.ops.add(byte((u shr 16) and 0xFF))
  a.ops.add(byte((u shr 24) and 0xFF))
proc pushI64*(a: var SimpleAssembler, v: int64) =
  let u = cast[uint64](v)
  a.ops.add(byte(u and 0xFF))
  a.ops.add(byte((u shr 8) and 0xFF))
  a.ops.add(byte((u shr 16) and 0xFF))
  a.ops.add(byte((u shr 24) and 0xFF))
  a.ops.add(byte((u shr 32) and 0xFF))
  a.ops.add(byte((u shr 40) and 0xFF))
  a.ops.add(byte((u shr 48) and 0xFF))
  a.ops.add(byte((u shr 56) and 0xFF))
proc pushU16*(a: var SimpleAssembler, v: uint16) =
  a.ops.add(byte(v and 0xFF)); a.ops.add(byte((v shr 8) and 0xFF))
proc pushU32*(a: var SimpleAssembler, v: uint32) =
  a.ops.add(byte(v and 0xFF))
  a.ops.add(byte((v shr 8) and 0xFF))
  a.ops.add(byte((v shr 16) and 0xFF))
  a.ops.add(byte((v shr 24) and 0xFF))
proc pushU64*(a: var SimpleAssembler, v: uint64) =
  a.ops.add(byte(v and 0xFF))
  a.ops.add(byte((v shr 8) and 0xFF))
  a.ops.add(byte((v shr 16) and 0xFF))
  a.ops.add(byte((v shr 24) and 0xFF))
  a.ops.add(byte((v shr 32) and 0xFF))
  a.ops.add(byte((v shr 40) and 0xFF))
  a.ops.add(byte((v shr 48) and 0xFF))
  a.ops.add(byte((v shr 56) and 0xFF))

proc align*(a: var SimpleAssembler, alignment: int, with: byte = 0x90) =
  if alignment <= 1: return
  let m = a.ops.len mod alignment
  if m != 0:
    for _ in m..<alignment: a.push(with)

proc extendBytes*(a: var SimpleAssembler, data: openArray[byte]) =
  a.ops.add(data)

proc finalize*(a: SimpleAssembler): seq[byte] = a.ops

# --------------------------------------------------------------------------
# VecAssembler
# --------------------------------------------------------------------------

type
  VecAssembler* = object
    ops*: seq[byte]
    baseAddr*: int
    labels*: LabelRegistry
    staticTargets*: seq[tuple[loc: PatchLoc, label: StaticLabel]]
    dynamicTargets*: seq[tuple[loc: PatchLoc, id: DynamicLabel]]
    error*: ref DynasmError

proc initVecAssembler*(baseAddr: int = 0): VecAssembler =
  VecAssembler(ops: @[], baseAddr: baseAddr,
    labels: initLabelRegistry(), staticTargets: @[], dynamicTargets: @[])

proc offset*(a: VecAssembler): AssemblyOffset =
  AssemblyOffset(a.ops.len)

proc push*(a: var VecAssembler, b: byte) = a.ops.add(b)
proc pushI8*(a: var VecAssembler, v: int8) = a.ops.add(cast[byte](v))
proc pushI16*(a: var VecAssembler, v: int16) =
  let u = cast[uint16](v)
  a.ops.add(byte(u and 0xFF)); a.ops.add(byte((u shr 8) and 0xFF))
proc pushI32*(a: var VecAssembler, v: int32) =
  let u = cast[uint32](v)
  a.ops.add(byte(u and 0xFF))
  a.ops.add(byte((u shr 8) and 0xFF))
  a.ops.add(byte((u shr 16) and 0xFF))
  a.ops.add(byte((u shr 24) and 0xFF))
proc pushI64*(a: var VecAssembler, v: int64) =
  let u = cast[uint64](v)
  a.ops.add(byte(u and 0xFF))
  a.ops.add(byte((u shr 8) and 0xFF))
  a.ops.add(byte((u shr 16) and 0xFF))
  a.ops.add(byte((u shr 24) and 0xFF))
  a.ops.add(byte((u shr 32) and 0xFF))
  a.ops.add(byte((u shr 40) and 0xFF))
  a.ops.add(byte((u shr 48) and 0xFF))
  a.ops.add(byte((u shr 56) and 0xFF))
proc pushU16*(a: var VecAssembler, v: uint16) =
  a.ops.add(byte(v and 0xFF)); a.ops.add(byte((v shr 8) and 0xFF))
proc pushU32*(a: var VecAssembler, v: uint32) =
  a.ops.add(byte(v and 0xFF))
  a.ops.add(byte((v shr 8) and 0xFF))
  a.ops.add(byte((v shr 16) and 0xFF))
  a.ops.add(byte((v shr 24) and 0xFF))
proc pushU64*(a: var VecAssembler, v: uint64) =
  a.ops.add(byte(v and 0xFF))
  a.ops.add(byte((v shr 8) and 0xFF))
  a.ops.add(byte((v shr 16) and 0xFF))
  a.ops.add(byte((v shr 24) and 0xFF))
  a.ops.add(byte((v shr 32) and 0xFF))
  a.ops.add(byte((v shr 40) and 0xFF))
  a.ops.add(byte((v shr 48) and 0xFF))
  a.ops.add(byte((v shr 56) and 0xFF))

proc align*(a: var VecAssembler, alignment: int, with: byte = 0x90) =
  if alignment <= 1: return
  let m = a.ops.len mod alignment
  if m != 0:
    for _ in m..<alignment: a.push(with)

proc extendBytes*(a: var VecAssembler, data: openArray[byte]) =
  a.ops.add(data)

proc newDynamicLabel*(a: var VecAssembler): DynamicLabel =
  a.labels.newDynamicLabel()

proc localLabel*(a: var VecAssembler, name: string) =
  a.labels.defineLocal(name, a.offset())

proc globalLabel*(a: var VecAssembler, name: string) =
  try:
    a.labels.defineGlobal(name, a.offset())
  except DynasmError as e:
    a.error = e

proc dynamicLabel*(a: var VecAssembler, id: DynamicLabel) =
  try:
    a.labels.defineDynamic(id, a.offset())
  except DynasmError as e:
    a.error = e

proc forwardReloc*(a: var VecAssembler, name: string, targetOffset: int,
    fieldOffset, refOffset: int, enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  let pl = a.labels.placeLocalReference(name)
  let lbl =
    if pl.found: pl.label.nextLocal()
    else: firstLocal(name)
  a.staticTargets.add((newPatchLoc(loc, targetOffset, fieldOffset,
    refOffset, r), lbl))

proc backwardReloc*(a: var VecAssembler, name: string, targetOffset: int,
    fieldOffset, refOffset: int, enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  let pl = a.labels.placeLocalReference(name)
  if not pl.found:
    a.error = unknownLabel(name, lkLocal)
    return
  a.staticTargets.add((newPatchLoc(loc, targetOffset, fieldOffset,
    refOffset, r), pl.label))

proc globalReloc*(a: var VecAssembler, name: string, targetOffset: int,
    fieldOffset, refOffset: int, enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  a.staticTargets.add((newPatchLoc(loc, targetOffset, fieldOffset,
    refOffset, r), globalLabel(name)))

proc dynamicReloc*(a: var VecAssembler, id: DynamicLabel, targetOffset: int,
    fieldOffset, refOffset: int, enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  a.dynamicTargets.add((newPatchLoc(loc, targetOffset, fieldOffset,
    refOffset, r), id))

proc valueReloc*(a: var VecAssembler, value: int, fieldOffset, refOffset: int,
    enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  let pl = newPatchLoc(loc, 0, fieldOffset, refOffset, r)
  try:
    pl.patchAt(a.ops, 0, a.baseAddr, value)
  except DynasmError as e:
    a.error = e

proc commit*(a: var VecAssembler) =
  if a.error != nil:
    let e = a.error
    a.error = nil
    raise e
  let statics = a.staticTargets
  a.staticTargets = @[]
  for (loc, lbl) in statics:
    let target = int(a.labels.resolveStatic(lbl))
    try:
      loc.patchAt(a.ops, 0, a.baseAddr, target)
    except DynasmError:
      raise impossibleRelocation("static " & lbl.name)
  let dyns = a.dynamicTargets
  a.dynamicTargets = @[]
  for (loc, id) in dyns:
    let target = int(a.labels.resolveDynamic(id))
    try:
      loc.patchAt(a.ops, 0, a.baseAddr, target)
    except DynasmError:
      raise impossibleRelocation("dynamic")

proc finalize*(a: var VecAssembler): seq[byte] =
  a.commit()
  a.ops

# --------------------------------------------------------------------------
# Assembler (full JIT, executable memory)
# --------------------------------------------------------------------------

type
  Assembler* = object
    staging*: seq[byte]
    committed*: seq[byte]
    labels*: LabelRegistry
    staticTargets*: seq[tuple[loc: PatchLoc, label: StaticLabel]]
    dynamicTargets*: seq[tuple[loc: PatchLoc, id: DynamicLabel]]
    managed*: Table[int, PatchLoc]
    error*: ref DynasmError
    execBuf*: ExecutableBuffer
    arch*: ArchKind

proc execAddr*(a: Assembler): int =
  if a.execBuf.mem == nil: 0 else: cast[int](a.execBuf.mem)

proc initAssembler*(arch: ArchKind = akX64,
    initialSize: int = DefaultPageSize): Assembler =
  result.staging = @[]
  result.committed = @[]
  result.labels = initLabelRegistry()
  result.staticTargets = @[]
  result.dynamicTargets = @[]
  result.managed = initTable[int, PatchLoc]()
  result.arch = arch
  result.execBuf = newExecutableBuffer(initialSize)

proc newAssembler*(arch: ArchKind = akX64): Assembler =
  initAssembler(arch)

proc offset*(a: Assembler): AssemblyOffset =
  AssemblyOffset(a.committed.len + a.staging.len)

proc push*(a: var Assembler, b: byte) = a.staging.add(b)
proc pushI8*(a: var Assembler, v: int8) = a.staging.add(cast[byte](v))
proc pushI16*(a: var Assembler, v: int16) =
  let u = cast[uint16](v)
  a.staging.add(byte(u and 0xFF)); a.staging.add(byte((u shr 8) and 0xFF))
proc pushI32*(a: var Assembler, v: int32) =
  let u = cast[uint32](v)
  a.staging.add(byte(u and 0xFF))
  a.staging.add(byte((u shr 8) and 0xFF))
  a.staging.add(byte((u shr 16) and 0xFF))
  a.staging.add(byte((u shr 24) and 0xFF))
proc pushI64*(a: var Assembler, v: int64) =
  let u = cast[uint64](v)
  a.staging.add(byte(u and 0xFF))
  a.staging.add(byte((u shr 8) and 0xFF))
  a.staging.add(byte((u shr 16) and 0xFF))
  a.staging.add(byte((u shr 24) and 0xFF))
  a.staging.add(byte((u shr 32) and 0xFF))
  a.staging.add(byte((u shr 40) and 0xFF))
  a.staging.add(byte((u shr 48) and 0xFF))
  a.staging.add(byte((u shr 56) and 0xFF))
proc pushU16*(a: var Assembler, v: uint16) =
  a.staging.add(byte(v and 0xFF)); a.staging.add(byte((v shr 8) and 0xFF))
proc pushU32*(a: var Assembler, v: uint32) =
  a.staging.add(byte(v and 0xFF))
  a.staging.add(byte((v shr 8) and 0xFF))
  a.staging.add(byte((v shr 16) and 0xFF))
  a.staging.add(byte((v shr 24) and 0xFF))
proc pushU64*(a: var Assembler, v: uint64) =
  a.staging.add(byte(v and 0xFF))
  a.staging.add(byte((v shr 8) and 0xFF))
  a.staging.add(byte((v shr 16) and 0xFF))
  a.staging.add(byte((v shr 24) and 0xFF))
  a.staging.add(byte((v shr 32) and 0xFF))
  a.staging.add(byte((v shr 40) and 0xFF))
  a.staging.add(byte((v shr 48) and 0xFF))
  a.staging.add(byte((v shr 56) and 0xFF))

proc align*(a: var Assembler, alignment: int, with: byte = 0x90) =
  if alignment <= 1: return
  var m = int(a.offset()) mod alignment
  while m != 0:
    a.push(with)
    m = int(a.offset()) mod alignment

proc extendBytes*(a: var Assembler, data: openArray[byte]) =
  a.staging.add(data)

proc newDynamicLabel*(a: var Assembler): DynamicLabel =
  a.labels.newDynamicLabel()

proc localLabel*(a: var Assembler, name: string) =
  a.labels.defineLocal(name, a.offset())

proc globalLabel*(a: var Assembler, name: string) =
  try:
    a.labels.defineGlobal(name, a.offset())
  except DynasmError as e:
    a.error = e

proc dynamicLabel*(a: var Assembler, id: DynamicLabel) =
  try:
    a.labels.defineDynamic(id, a.offset())
  except DynasmError as e:
    a.error = e

proc forwardReloc*(a: var Assembler, name: string, targetOffset: int,
    fieldOffset, refOffset: int, enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  let pl = a.labels.placeLocalReference(name)
  let lbl =
    if pl.found: pl.label.nextLocal()
    else: firstLocal(name)
  a.staticTargets.add((newPatchLoc(loc, targetOffset, fieldOffset,
    refOffset, r), lbl))

proc backwardReloc*(a: var Assembler, name: string, targetOffset: int,
    fieldOffset, refOffset: int, enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  let pl = a.labels.placeLocalReference(name)
  if not pl.found:
    a.error = unknownLabel(name, lkLocal)
    return
  a.staticTargets.add((newPatchLoc(loc, targetOffset, fieldOffset,
    refOffset, r), pl.label))

proc globalReloc*(a: var Assembler, name: string, targetOffset: int,
    fieldOffset, refOffset: int, enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  a.staticTargets.add((newPatchLoc(loc, targetOffset, fieldOffset,
    refOffset, r), globalLabel(name)))

proc dynamicReloc*(a: var Assembler, id: DynamicLabel, targetOffset: int,
    fieldOffset, refOffset: int, enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  a.dynamicTargets.add((newPatchLoc(loc, targetOffset, fieldOffset,
    refOffset, r), id))

proc valueReloc*(a: var Assembler, value: int, fieldOffset, refOffset: int,
    enc: uint8) =
  let r = fromEncoding(enc)
  let loc = int(a.offset())
  let pl = newPatchLoc(loc, 0, fieldOffset, refOffset, r)
  let bufOff = a.committed.len
  try:
    pl.patchAt(a.staging, bufOff, a.execAddr, value)
  except DynasmError as e:
    a.error = e
    return
  if pl.needsAdjustment:
    a.managed[loc - pl.fieldOffset] = pl

proc encodeRelocs*(a: var Assembler) =
  if a.error != nil:
    let e = a.error
    a.error = nil
    raise e
  let bufOff = a.committed.len
  let bufAddr = a.execAddr
  let statics = a.staticTargets
  a.staticTargets = @[]
  for (loc, lbl) in statics:
    let target = int(a.labels.resolveStatic(lbl))
    try:
      loc.patchAt(a.staging, bufOff, bufAddr, target)
    except DynasmError:
      raise impossibleRelocation("static " & lbl.name)
    if loc.needsAdjustment:
      a.managed[loc.location - loc.fieldOffset] = loc
  let dyns = a.dynamicTargets
  a.dynamicTargets = @[]
  for (loc, id) in dyns:
    let target = int(a.labels.resolveDynamic(id))
    try:
      loc.patchAt(a.staging, bufOff, bufAddr, target)
    except DynasmError:
      raise impossibleRelocation("dynamic")
    if loc.needsAdjustment:
      a.managed[loc.location - loc.fieldOffset] = loc

proc ensureExecCapacity*(a: var Assembler, need: int) =
  if need <= a.execBuf.mappedSize: return
  var newSize = max(a.execBuf.mappedSize, 4096)
  while newSize < need:
    newSize *= 2
  let oldAddr = a.execAddr
  let (nm, _) = allocWritable(newSize)
  # Open the JIT write gate before copying: a previous commit may
  # have left it closed (Apple Silicon; no-op elsewhere).
  makeWritable(nm, newSize)
  let newAddr = cast[int](nm)
  let delta = newAddr - oldAddr
  if delta != 0 and a.managed.len > 0 and a.committed.len > 0:
    # Adjust the committed copy once, then mirror it into the new
    # mapping: same result as adjusting both, with one pass and no
    # temporary seq allocation.
    for _, loc in a.managed.mpairs:
      loc.adjustAt(a.committed, 0, delta)
      # keep managed loc itself unchanged (location is offset-based)
  # copy committed bytes (already adjusted if needed)
  if a.committed.len > 0:
    copyMem(nm, unsafeAddr a.committed[0], a.committed.len)
  freeMapping(a.execBuf.mem, a.execBuf.mappedSize)
  makeExecutableNoFlush(nm, newSize)
  if a.committed.len > 0:
    # Copied committed bytes need invalidating on the fresh mapping;
    # scope it to their range instead of the whole (larger) mapping.
    flushCache(nm, a.committed.len)
  a.execBuf.mem = nm
  a.execBuf.mappedSize = newSize
  # length will be set on commit

proc commit*(a: var Assembler) =
  a.encodeRelocs()
  let newEnd = a.committed.len + a.staging.len
  a.ensureExecCapacity(max(newEnd, 1))
  # make writable, copy staging, make executable
  makeWritable(a.execBuf.mem, a.execBuf.mappedSize)
  if a.staging.len > 0:
    copyMem(cast[pointer](cast[int](a.execBuf.mem) + a.committed.len),
      unsafeAddr a.staging[0], a.staging.len)
  # On fresh realloc, committed bytes were already copied with adjustment.
  # On in-place grow, managed relocs do not need adjustment (same base).
  makeExecutableNoFlush(a.execBuf.mem, a.execBuf.mappedSize)
  if a.staging.len > 0:
    # Invalidate only the freshly written bytes (AArch64; no-op on
    # x86, which is coherent). Previously committed bytes were
    # flushed by their own commit (or by ensureExecCapacity above).
    flushCache(cast[pointer](cast[int](a.execBuf.mem) + a.committed.len),
      a.staging.len)
  if a.staging.len > 0:
    let oldLen = a.committed.len
    a.committed.setLen(oldLen + a.staging.len)
    copyMem(addr a.committed[oldLen], unsafeAddr a.staging[0],
      a.staging.len)
  a.staging.setLen(0)
  a.execBuf.length = a.committed.len
  if a.error != nil:
    let e = a.error
    a.error = nil
    raise e

proc finalize*(a: var Assembler): ExecutableBuffer =
  a.commit()
  # transfer ownership: copy struct, clear source to avoid double free
  result = a.execBuf
  a.execBuf = ExecutableBuffer(mem: nil, mappedSize: 0, length: 0)

proc readerPtr*(a: Assembler, off: AssemblyOffset): pointer =
  assert a.execBuf.mem != nil
  cast[pointer](cast[int](a.execBuf.mem) + int(off))

proc committedBytes*(a: Assembler): seq[byte] =
  a.committed & a.staging
