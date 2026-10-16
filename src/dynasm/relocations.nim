## Relocation model for x64/x86 (SimpleRelocation only).
## Mirrors runtime/src/relocations.rs.

type
  RelocationKind* = enum
    rkRelative = 0      ## PC-relative, no adjust on move
    rkAbsToRel = 1      ## absolute -> relative, needs adjust
    rkRelToAbs = 2      ## relative -> absolute, needs adjust
    rkAbsolute = 3      ## absolute, no adjust

  RelocationSize* = enum
    rsByte = 1
    rsWord = 2
    rsDWord = 4
    rsQWord = 8

  SimpleRelocation* = object
    kind*: RelocationKind
    size*: RelocationSize
    arch*: int8
      ## -1 for plain x64/x86 relocations, else an AArch64 arch-specific
      ## encoding id (mirrors dynasm-rs Aarch64RelocationEncoding):
      ## 0=B, 1=BCOND, 2=ADR, 3=ADRP, 4=TBZ.

const
  AarchB* = 0
    ## b, bl: 26 bits, dword aligned
  AarchBCond* = 1
    ## b.cond, cbz, cbnz, ldr literal: 19 bits, dword aligned
  AarchAdr* = 2
    ## adr: split 21 bit, byte aligned
  AarchAdrp* = 3
    ## adrp: split 21 bit, 4096-byte aligned
  AarchTbz* = 4
    ## tbz, tbnz: 14 bits, dword aligned

proc encodeAarchReloc*(id: int): uint8 =
  ## Pack an AArch64 arch-specific relocation for macro emission.
  ## Plain x64/x86 codes always have low 6 bits 0..3, so ids live
  ## at 4..8 with zero kind bits (mirrors how rs keeps arch codes
  ## disjoint from the simple ones). Addition, not OR: 0x04|4 would
  ## collapse back to 0x04 and mistarget TBZ as B.
  0x04'u8 + uint8(id)

const
  EncByte* = 0
  EncWord* = 1
  EncDWord* = 2
  EncQWord* = 3

proc relSize*(s: RelocationSize): int = ord(s)

proc decodeKind*(code: uint8): RelocationKind =
  case code shr 6
  of 0: rkRelative
  of 1: rkAbsToRel
  of 2: rkRelToAbs
  else: rkAbsolute

proc fromEncoding*(code: uint8): SimpleRelocation =
  ## Decode packed byte emitted by macro: kind<<6 | size-code, or
  ## 0x04|id for AArch64 arch-specific relocations.
  if (code shr 6) == 0 and (code and 0x3F'u8) >= 0x04'u8:
    let id = int(code) - 4
    if id < 0 or id > 4:
      raise newException(ValueError,
        "invalid aarch64 relocation code: " & $id)
    return SimpleRelocation(kind: rkRelative, size: rsDWord,
      arch: int8(id))
  let k = decodeKind(code)
  let e = code and 0x3F'u8
  let s =
    case e
    of 0: rsByte
    of 1: rsWord
    of 2: rsDWord
    of 3: rsQWord
    else:
      raise newException(ValueError,
        "invalid complex relocation code for x64/x86: " & $e)
  SimpleRelocation(kind: k, size: s, arch: -1)

proc fromSize*(kind: RelocationKind, size: RelocationSize): SimpleRelocation =
  SimpleRelocation(kind: kind, size: size, arch: -1)

proc encodeKind*(kind: RelocationKind, size: RelocationSize): uint8 =
  ## Pack for macro emission, matches common.rs RelocationEncoding::encode.
  let base =
    case size
    of rsByte: 0'u8
    of rsWord: 1'u8
    of rsDWord: 2'u8
    of rsQWord: 3'u8
  (uint8(ord(kind)) shl 6) or base

proc fitsSigned*(value: int64, bits: int): bool =
  if bits >= 64: return true
  let half = 1'i64 shl (bits - 1)
  value < half and value >= -half

proc relSize*(r: SimpleRelocation): int =
  if r.arch >= 0: 4
  else: relSize(r.size)

proc aarchMask(id: int): uint32 =
  case id
  of AarchB: 0xFC000000'u32
  of AarchBCond: 0xFF00001F'u32
  of AarchAdr, AarchAdrp: 0x9F00001F'u32
  else: 0xFFF8001F'u32 # AarchTbz

proc readU32(buf: openArray[byte]): uint32 =
  uint32(buf[0]) or (uint32(buf[1]) shl 8) or
    (uint32(buf[2]) shl 16) or (uint32(buf[3]) shl 24)

proc writeU32(buf: var openArray[byte], v: uint32) =
  buf[0] = uint8(v and 0xFF)
  buf[1] = uint8((v shr 8) and 0xFF)
  buf[2] = uint8((v shr 16) and 0xFF)
  buf[3] = uint8((v shr 24) and 0xFF)

proc writeAarchValue*(id: int, buf: var openArray[byte],
    value: int64): bool =
  ## Masked read-modify-write of one LE u32, mirroring
  ## Aarch64RelocationEncoding::encode in dynasm-rs.
  let mask = aarchMask(id)
  let tmpl = readU32(buf) and mask
  var packed = 0'u32
  case id
  of AarchB:
    if (value and 3) != 0 or not fitsSigned(value shr 2, 26):
      return false
    packed = uint32((value shr 2) and 0x3FFFFFF)
  of AarchBCond:
    if (value and 3) != 0 or not fitsSigned(value shr 2, 19):
      return false
    packed = (uint32((value shr 2) and 0x7FFFF)) shl 5
  of AarchAdr:
    if not fitsSigned(value, 21): return false
    packed = ((uint32((value shr 2) and 0x7FFFF)) shl 5) or
      ((uint32(value and 3)) shl 29)
  of AarchAdrp:
    let v = value + 0xFFF
    if not fitsSigned(v shr 12, 21): return false
    packed = ((uint32((v shr 14) and 0x7FFFF)) shl 5) or
      ((uint32((v shr 12) and 3)) shl 29)
  else: # AarchTbz
    if (value and 3) != 0 or not fitsSigned(value shr 2, 14):
      return false
    packed = (uint32((value shr 2) and 0x3FFF)) shl 5
  writeU32(buf, tmpl or packed)
  true

proc readAarchValue*(id: int, buf: openArray[byte]): int64 =
  ## Inverse of writeAarchValue, with sign extension.
  let value = readU32(buf)
  let mask = not aarchMask(id)
  var unpacked = 0'u64
  var bits = 0
  case id
  of AarchB:
    unpacked = uint64(value and mask) shl 2
    bits = 26
  of AarchBCond:
    unpacked = uint64((value and mask) shr 5) shl 2
    bits = 19
  of AarchAdr:
    unpacked = uint64((((value shr 5) and 0x7FFFF) shl 2) or
      ((value shr 29) and 3))
    bits = 21
  of AarchAdrp:
    unpacked = uint64((((value shr 5) and 0x7FFFF) shl 2) or
      ((value shr 29) and 3)) shl 12
    bits = 33
  else: # AarchTbz
    unpacked = uint64((value and mask) shr 5) shl 2
    bits = 14
  let offset = 1'u64 shl (bits - 1)
  cast[int64]((unpacked xor offset) - offset)

proc writeValue*(r: SimpleRelocation, buf: var openArray[byte],
    value: int64): bool =
  ## Returns false on overflow (caller maps to ImpossibleRelocation).
  if r.arch >= 0:
    return writeAarchValue(int(r.arch), buf, value)
  case r.size
  of rsByte:
    if value < -128 or value > 127: return false
    buf[0] = cast[uint8](cast[int8](value))
  of rsWord:
    if value < -32768 or value > 32767: return false
    let v = cast[uint16](cast[int16](value))
    buf[0] = uint8(v and 0xFF)
    buf[1] = uint8((v shr 8) and 0xFF)
  of rsDWord:
    if value < low(int32) or value > high(int32): return false
    let v = cast[uint32](cast[int32](value))
    buf[0] = uint8(v and 0xFF)
    buf[1] = uint8((v shr 8) and 0xFF)
    buf[2] = uint8((v shr 16) and 0xFF)
    buf[3] = uint8((v shr 24) and 0xFF)
  of rsQWord:
    let v = cast[uint64](value)
    for i in 0..<8:
      buf[i] = uint8((v shr (i*8)) and 0xFF)
  true

proc readValue*(r: SimpleRelocation, buf: openArray[byte]): int64 =
  if r.arch >= 0:
    return readAarchValue(int(r.arch), buf)
  case r.size
  of rsByte:
    int64(cast[int8](buf[0]))
  of rsWord:
    let v = uint16(buf[0]) or (uint16(buf[1]) shl 8)
    int64(cast[int16](v))
  of rsDWord:
    let v = uint32(buf[0]) or (uint32(buf[1]) shl 8) or
            (uint32(buf[2]) shl 16) or (uint32(buf[3]) shl 24)
    int64(cast[int32](v))
  of rsQWord:
    var v = 0'u64
    for i in 0..<8:
      v = v or (uint64(buf[i]) shl (i*8))
    cast[int64](v)
