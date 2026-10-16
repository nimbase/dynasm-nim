# mandel — integer Mandelbrot escape count with `imul`.
#
# Run with:
#   nim r examples/mandel.nim
#
# JIT signature (SysV AMD64): mandel(cx, cy: int64): int64.
# Inputs are fixed-point with scale 256 (so cx=-512 means -2.0).
# Uses `imul` for x*x / y*y / x*y plus `shr` to rescale, and
# returns the iteration count (max 64).

import dynasm
import benchutil

const
  Scale = 256'i64
  MaxIter = 64'i64
  Escape = 4 * Scale # (x*x + y*y stay scaled by Scale)

type MandelFn = proc(cx, cy: int64): int64 {.cdecl.}

proc buildMandel(): ExecutableBuffer =
  var a = newAssembler(akX64)
  dynasm a:
    arch x64
    # SysV: args arrive in RDI, RSI (use RCX, RDX on Windows x64).
    alias a1, rdi
    alias a2, rsi
    # r8 = cx, r9 = cy, r10 = x, r11 = y, rcx = iter
    mov r8, a1
    mov r9, a2
    `xor` r10, r10
    `xor` r11, r11
    `xor` ecx, ecx
    label loop
    cmp rcx, 64
    jge fwd("done")
    # x2 = (x*x) >> 8, y2 = (y*y) >> 8
    mov rax, r10
    imul rax, r10
    `shr` rax, 8
    mov rdx, r11
    imul rdx, r11
    `shr` rdx, 8
    # if x2 + y2 > 4*Scale, escape
    mov rsi, rax
    add rsi, rdx
    cmp rsi, 1024
    jg fwd("done")
    # y = ((x*y) >> 7) + cy   (2*x*y scaled)
    mov rsi, r10
    imul rsi, r11
    `shr` rsi, 7
    add rsi, r9
    # x = x2 - y2 + cx
    sub rax, rdx
    add rax, r8
    mov r10, rax
    mov r11, rsi
    add rcx, 1
    jmp bwd("loop")
    label done
    mov rax, rcx
    ret()
  a.finalize()

proc mandelRef(cx, cy: int64): int64 =
  var x = 0'i64
  var y = 0'i64
  var i = 0'i64
  while i < MaxIter:
    let x2 = (x * x) shr 8
    let y2 = (y * y) shr 8
    if x2 + y2 > Escape: break
    let xy = (x * y) shr 7
    x = x2 - y2 + cx
    y = xy + cy
    inc i
  i

when isMainModule:
  var buf = buildMandel()
  let mandel = cast[MandelFn](buf.ptrAt(AssemblyOffset(0)))
  for (cx, cy) in [(-512'i64, 0'i64), (0, 0), (256, 0), (-128, 256)]:
    assert mandel(cx, cy) == mandelRef(cx, cy),
      "mismatch at " & $cx & "," & $cy
  # tiny ascii render of the set
  for py in 0..<12:
    var line = ""
    for px in 0..<32:
      let cx = -512 + px * 32
      let cy = -256 + py * 42
      line.add(if mandel(cx, cy) == MaxIter: '#' else: '.')
    echo line
  let iters = benchIters(200_000)
  var acc = 0'i64
  for _ in 0..<iters:
    acc += mandel(0, 0)
  assert acc == mandelRef(0, 0) * iters
  buf.destroy()
