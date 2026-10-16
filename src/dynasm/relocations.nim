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
  ## Decode packed byte emitted by macro: kind<<6 | size-code.
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
  SimpleRelocation(kind: k, size: s)

proc fromSize*(kind: RelocationKind, size: RelocationSize): SimpleRelocation =
  SimpleRelocation(kind: kind, size: size)

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

proc writeValue*(r: SimpleRelocation, buf: var openArray[byte],
    value: int64): bool =
  ## Returns false on overflow (caller maps to ImpossibleRelocation).
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
