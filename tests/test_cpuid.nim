import unittest
import dynasm

# P3 detector mnemonics: cpuid (0F A2) and xgetbv (0F 01 D0) as real
# instructions. Zero operands; cpuid reads EAX/ECX, xgetbv reads ECX.
# AVX2 dispatch needs OSXSAVE+XCR0 via xgetbv, not cpuid alone.

template rejects(body: untyped) =
  static:
    assert not compiles(body), "expected a compile-time error"

template accepts(body: untyped) =
  static:
    assert compiles(body), "expected this to compile"

test "detector encodings":
  var v = initVecAssembler(0)
  dynasm v:
    arch x64
    cpuid()
    xgetbv()
  check v.finalize() == @[0x0F'u8, 0xA2'u8, 0x0F'u8, 0x01'u8, 0xD0'u8]

test "detector operand rules are enforced":
  var ops = initVecAssembler(0)
  accepts:
    dynasm ops:
      arch x64
      cpuid()
  accepts:
    dynasm ops:
      arch x64
      xgetbv()
  rejects:
    dynasm ops:
      arch x64
      cpuid eax
  rejects:
    dynasm ops:
      arch x64
      cpuid 0
  rejects:
    dynasm ops:
      arch x64
      xgetbv ecx
  rejects:
    dynasm ops:
      arch aarch64
      cpuid()
  rejects:
    dynasm ops:
      arch aarch64
      xgetbv()

when defined(amd64):
  proc jitCpuid(leaf, subleaf: uint32): array[4, uint32] =
    var a = newAssembler(akX64)
    let l = leaf
    let s = subleaf
    var o: array[16, uint8]
    dynasm a:
      arch x64
      alias outptr, rdi, rcx
      push rbx
      # Stash outptr BEFORE cpuid: cpuid overwrites EAX/EBX/ECX/EDX,
      # and on Windows outptr is RCX whose low half (ECX) is clobbered.
      mov r11, outptr
      mov eax, l
      mov ecx, s
      cpuid()
      mov [r11], eax
      mov [r11 + 4], ebx
      mov [r11 + 8], ecx
      mov [r11 + 12], edx
      pop rbx
      ret()
    var buf = a.finalize()
    type Fn = proc(a: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr o)
    buf.destroy()
    [uint32(o[0]) or (uint32(o[1]) shl 8) or (uint32(o[2]) shl 16) or
      (uint32(o[3]) shl 24),
     uint32(o[4]) or (uint32(o[5]) shl 8) or (uint32(o[6]) shl 16) or
      (uint32(o[7]) shl 24),
     uint32(o[8]) or (uint32(o[9]) shl 8) or (uint32(o[10]) shl 16) or
      (uint32(o[11]) shl 24),
     uint32(o[12]) or (uint32(o[13]) shl 8) or
      (uint32(o[14]) shl 16) or (uint32(o[15]) shl 24)]

  proc jitCpuidDb(leaf, subleaf: uint32): array[4, uint32] =
    ## Same query via the legacy db blob; must agree with the mnemonic.
    var a = newAssembler(akX64)
    let l = leaf
    let s = subleaf
    var o: array[16, uint8]
    dynasm a:
      arch x64
      alias outptr, rdi, rcx
      push rbx
      mov r11, outptr
      mov eax, l
      mov ecx, s
      db 0x0F, 0xA2
      mov [r11], eax
      mov [r11 + 4], ebx
      mov [r11 + 8], ecx
      mov [r11 + 12], edx
      pop rbx
      ret()
    var buf = a.finalize()
    type Fn = proc(a: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr o)
    buf.destroy()
    [uint32(o[0]) or (uint32(o[1]) shl 8) or (uint32(o[2]) shl 16) or
      (uint32(o[3]) shl 24),
     uint32(o[4]) or (uint32(o[5]) shl 8) or (uint32(o[6]) shl 16) or
      (uint32(o[7]) shl 24),
     uint32(o[8]) or (uint32(o[9]) shl 8) or (uint32(o[10]) shl 16) or
      (uint32(o[11]) shl 24),
     uint32(o[12]) or (uint32(o[13]) shl 8) or
      (uint32(o[14]) shl 16) or (uint32(o[15]) shl 24)]

  proc jitXgetbv(xcr: uint32): tuple[eax, edx: uint32] =
    var a = newAssembler(akX64)
    let c = xcr
    var o: array[8, uint8]
    dynasm a:
      arch x64
      alias outptr, rdi, rcx
      mov r11, outptr
      mov ecx, c
      xgetbv()
      mov [r11], eax
      mov [r11 + 4], edx
      ret()
    var buf = a.finalize()
    type Fn = proc(a: pointer) {.cdecl.}
    let f = cast[Fn](buf.ptrAt(AssemblyOffset(0)))
    f(addr o)
    buf.destroy()
    (uint32(o[0]) or (uint32(o[1]) shl 8) or (uint32(o[2]) shl 16) or
      (uint32(o[3]) shl 24),
     uint32(o[4]) or (uint32(o[5]) shl 8) or (uint32(o[6]) shl 16) or
      (uint32(o[7]) shl 24))

  test "cpuid mnemonic agrees with db blob":
    for (leaf, sub) in [(0'u32, 0'u32), (1'u32, 0'u32), (7'u32, 0'u32),
        (0x80000000'u32, 0'u32)]:
      check jitCpuid(leaf, sub) == jitCpuidDb(leaf, sub)

  test "cpuid leaf 0 is sane":
    let r = jitCpuid(0, 0)
    check r[0] >= 1 # max basic leaf
    check r[1] != 0 and r[3] != 0 # vendor EBX/EDX non-zero

  test "xgetbv xcr0 has x87 state":
    let (eax, edx) = jitXgetbv(0)
    check (eax and 1) == 1 # XCR0[0] x87 always set when xgetbv works
    discard edx
