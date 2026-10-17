# strings — strlen/strcmp/strcpy/strhash kernels in one JIT buffer.
#
# Run with:
#   nim r examples/strings.nim
#
# Four functions are assembled back to back into a single
# ExecutableBuffer; each entry offset is captured with `offset()`
# before its `global` label. Idioms: terminator scanning, pairwise
# compare returning a signed difference (via 64-bit `movzx`, since a
# 32-bit `sub` would zero-extend), copying, and FNV-1a hashing
# (`xor` + `imul` per byte with a 64-bit prime).

import dynasm
import benchutil

type
  StrlenFn = proc(s: pointer): int64 {.cdecl.}
  StrcmpFn = proc(a, b: pointer): int64 {.cdecl.}
  StrcpyFn = proc(dst, src: pointer): int64 {.cdecl.}
  StrhashFn = proc(s: pointer, n: int64): int64 {.cdecl.}

const N = 65_536

proc buildStrings(): tuple[buf: ExecutableBuffer, strlen, strcmp,
    strcpy, strhash: AssemblyOffset] =
  var a = newAssembler(akX64)
  let oStrlen = a.offset()
  dynasm a:
    arch x64
    global strlenFn
    # Args: first slot (System V: RDI / Win64: RCX).
    alias s, rdi, rcx
    `xor` eax, eax
    label slen
    cmp byte [s + rax*1], 0
    je fwd("slend")
    add rax, 1
    jmp bwd("slen")
    label slend
    ret()
  let oStrcmp = a.offset()
  dynasm a:
    arch x64
    global strcmpFn
    # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
    alias sa, rdi, rcx
    alias sb, rsi, rdx
    `xor` r10d, r10d # i (r10: scratch on both ABIs)
    label scmp
    movzx rax, byte [sa + r10*1]
    movzx r8, byte [sb + r10*1]
    sub rax, r8
    jne fwd("scmpd")
    cmp r8b, 0 # equal so far: terminator?
    je fwd("scmpeq")
    add r10, 1
    jmp bwd("scmp")
    label scmpeq
    `xor` eax, eax
    ret()
    label scmpd
    ret()
  let oStrcpy = a.offset()
  dynasm a:
    arch x64
    global strcpyFn
    # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
    alias dd, rdi, rcx
    alias ss, rsi, rdx
    `xor` r10d, r10d # i (r10: scratch on both ABIs)
    label scpy
    movzx eax, byte [ss + r10*1]
    mov byte [dd + r10*1], al
    add r10, 1
    cmp eax, 0
    jne bwd("scpy")
    mov rax, r10
    ret()
  let oStrhash = a.offset()
  dynasm a:
    arch x64
    global strhashFn
    # Args: first slots (System V: RDI, RSI / Win64: RCX, RDX).
    alias hs, rdi, rcx
    alias hn, rsi, rdx
    # FNV-1a offset basis as signed int64 (same bit pattern)
    mov rax, -3750763034362895579
    mov r11, 1099511628211
    `xor` r10d, r10d # i (r10: scratch on both ABIs)
    label shash
    cmp r10, hn
    jge fwd("shashd")
    movzx r8d, byte [hs + r10*1]
    `xor` rax, r8
    imul rax, r11
    add r10, 1
    jmp bwd("shash")
    label shashd
    ret()
  let buf = a.finalize()
  (buf, oStrlen, oStrcmp, oStrcpy, oStrhash)

proc strlenRef(s: openArray[uint8]): int =
  var i = 0
  while s[i] != 0: inc i
  i

proc strcmpRef(a, b: openArray[uint8]): int64 =
  var i = 0
  while true:
    let d = int64(a[i]) - int64(b[i])
    if d != 0 or a[i] == 0: return d
    inc i

proc strhashRef(s: openArray[uint8]): uint64 =
  var h = 14695981039346656037'u64
  for c in s:
    h = h xor uint64(c)
    h = h * 1099511628211'u64
  h

when isMainModule:
  var text = newSeq[uint8](N + 1)
  for i in 0..<N: text[i] = uint8(33 + (i * 37) mod 94)
  text[N] = 0
  var text2 = newSeq[uint8](N + 1)
  for i in 0..N: text2[i] = text[i]
  text2[N - 1] = text[N - 1] + 1 # differ in last byte
  var copy = newSeq[uint8](N + 1)
  let bt0 = getMonoTime()
  var parts = buildStrings()
  var buf = parts.buf
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let strlen = cast[StrlenFn](buf.ptrAt(parts.strlen))
  let strcmp = cast[StrcmpFn](buf.ptrAt(parts.strcmp))
  let strcpy = cast[StrcpyFn](buf.ptrAt(parts.strcpy))
  let strhash = cast[StrhashFn](buf.ptrAt(parts.strhash))
  assert strlen(cast[pointer](addr text[0])) ==
    int64(strlenRef(text))
  assert strcmp(cast[pointer](addr text[0]),
    cast[pointer](addr text[0])) == 0
  assert strcmp(cast[pointer](addr text[0]),
    cast[pointer](addr text2[0])) == strcmpRef(text, text2)
  assert strcpy(cast[pointer](addr copy[0]),
    cast[pointer](addr text[0])) == int64(N + 1)
  assert copy == text, "strcpy mismatch"
  assert cast[uint64](strhash(cast[pointer](addr text[0]), int64(N))) ==
    strhashRef(text.toOpenArray(0, N - 1))
  # NOTE: wrapping arithmetic — the 64-bit hash alone can exceed
  # int64 range once accumulated, and modular sums agree regardless
  # of association order.
  let iters = benchIters(300)
  var acc = 0'i64
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    acc = acc +% strlen(cast[pointer](addr text[0]))
    acc = acc +% strcmp(cast[pointer](addr text[0]),
      cast[pointer](addr text2[0]))
    acc = acc +% strcpy(cast[pointer](addr copy[0]),
      cast[pointer](addr text[0]))
    acc = acc +% strhash(cast[pointer](addr text[0]), int64(N))
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  let one = int64(strlenRef(text)) +% strcmpRef(text, text2) +%
    int64(N + 1) +% cast[int64](strhashRef(text.toOpenArray(0, N - 1)))
  assert acc == one *% iters
  echo "strings(64k) ok x", iters, " iters: ", rep
  buf.destroy()
