# zz_probe — TEMPORARY hardware probe for the tail_recursive ARM SIGBUS.
# Each variant isolates one mechanism; run via:
#   bash examples/bench.sh zz_probe
# (deleted once the root cause is found).

import dynasm
import benchutil

type F = proc(n, acc: int64): int64 {.cdecl.}

proc callIt(name: string, b: var ExecutableBuffer, n: int64): int64 =
  stderr.writeLine("probe: calling " & name)
  let f = cast[F](b.ptrAt(AssemblyOffset(0)))
  let r = f(n, 1)
  stderr.writeLine("probe: " & name & " returned " & $r)
  r

proc buildIter*(): ExecutableBuffer =
  # V_iter: iterative factorial, no bl, no stack.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    alias n, x0
    alias acc, x1
    mov x9, 1 # total starts at 1: this is a product loop
    mov x10, 1
    label loop
    cmp x10, n
    b.gt fwd("done")
    mul x9, x9, x10
    add x10, x10, 1
    b bwd("loop")
    label done
    mov x0, x9
    ret()
  a.finalize()

proc buildFwdCall*(): ExecutableBuffer =
  # V_fwdcall: stp/ldr frame + bl FORWARD to a helper, no recursion.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    alias n, x0
    alias acc, x1
    label entry
    cmp n, 1
    b.le fwd("base")
    stp n, x30, [sp, -16], pre
    mul acc, acc, n
    sub n, n, 1
    bl fwd("helper")
    ldr x30, [sp], 16
    ret()
    label helper
    mov x0, acc
    ret()
    label base
    mov x0, acc
    ret()
  a.finalize()

proc buildBwdCall*(): ExecutableBuffer =
  # V_bwdcall: stp/ldr frame + bl BACKWARD to a helper, no recursion.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    alias n, x0
    alias acc, x1
    label entry
    b fwd("real")
    label helper
    mov x0, acc
    ret()
    label real
    cmp n, 1
    b.le fwd("base")
    stp n, x30, [sp, -16], pre
    mul acc, acc, n
    sub n, n, 1
    bl bwd("helper")
    ldr x30, [sp], 16
    ret()
    label base
    mov x0, acc
    ret()
  a.finalize()

proc buildLdp*(): ExecutableBuffer =
  # V_ldp: genuine recursion, ldp (pair) restore instead of ldr.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    alias n, x0
    alias acc, x1
    label fact
    cmp n, 1
    b.le fwd("base")
    stp n, x30, [sp, -16], pre
    mul acc, acc, n
    sub n, n, 1
    bl bwd("fact")
    ldp x9, x30, [sp], 16
    ret()
    label base
    mov x0, acc
    ret()
  a.finalize()

proc buildV1*(): ExecutableBuffer =
  # V1: exact copy of the crashing tail_recursive kernel.
  var a = newAssembler(akAarch64)
  dynasm a:
    arch aarch64
    alias n, x0
    alias acc, x1
    label fact
    cmp n, 1
    b.le fwd("base")
    stp n, x30, [sp, -16], pre
    mul acc, acc, n
    sub n, n, 1
    bl bwd("fact")
    ldr x30, [sp], 16
    ret()
    label base
    mov x0, acc
    ret()
  a.finalize()

when isMainModule:
  # Assembly is host-independent (pure byte emission); execution is
  # ARM-only. x64 runners build this file and exit 0.
  when defined(arm64) or defined(aarch64):
    var b = buildIter()
    assert callIt("V_iter", b, 5) == 120
    b.destroy()
    b = buildFwdCall()
    assert callIt("V_fwdcall", b, 5) == 5
    b.destroy()
    b = buildBwdCall()
    assert callIt("V_bwdcall", b, 5) == 5
    b.destroy()
    b = buildLdp()
    assert callIt("V_ldp", b, 5) == 120
    b.destroy()
    b = buildV1()
    assert callIt("V1", b, 5) == 120
    b.destroy()
    stderr.writeLine("probe: all variants returned")
  else:
    echo "zz_probe: assembly ok (execution needs ARM)"
