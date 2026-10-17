# histogram — byte-value histogram with `movzx` loads.
#
# Run with:
#   nim r examples/histogram.nim
#
# JIT signature (SysV AMD64): hist(data: ptr byte, n: int64,
# bins: ptr int64). Bins (256 int64 counters, zeroed by the caller)
# are bumped with a qword read-modify-write per input byte.
# See histogram_big.nim for the large-input sibling.

import dynasm
import benchutil

type HistFn = proc(data: pointer, n: int64, bins: pointer) {.cdecl.}

const N = 1_000_000
const Bins = 256

proc buildHist*(): ExecutableBuffer =
  when defined(arm64):
    var a = newAssembler(akAarch64)
    dynasm a:
      arch aarch64
      # Args: first slots (AAPCS64: X0, X1, X2). `ldrb` zero-extends
      # the input byte (like `movzx`); the counter bump is an
      # explicit ldr/add/str since memory cannot be an operand.
      alias data, x0
      alias n, x1
      alias bins, x2
      mov x9, xzr # i
      label loop
      cmp x9, n
      b.ge fwd("done")
      add x10, data, x9
      ldrb w10, [x10]
      lsl x10, x10, 3
      add x10, bins, x10 # &bins[byte]
      ldr x11, [x10]
      add x11, x11, 1
      str x11, [x10]
      add x9, x9, 1
      b bwd("loop")
      label done
      ret()
    a.finalize()
  else:
    var a = newAssembler(akX64)
    dynasm a:
      arch x64
      # Args: first slots (System V: RDI, RSI, RDX / Win64: RCX, RDX, R8).
      alias data, rdi, rcx
      alias n, rsi, rdx
      alias bins, rdx, r8
      `xor` r9d, r9d # i (r9: scratch on both ABIs)
      label loop
      cmp r9, n
      jge fwd("done")
      movzx eax, byte [data + r9*1]
      add qword [bins + rax*8], 1
      add r9, 1
      jmp bwd("loop")
      label done
      ret()
    a.finalize()

proc runHist(hist: HistFn, data: var seq[uint8], bins: var seq[int64]) =
  for b in bins.mitems: b = 0
  hist(cast[pointer](addr data[0]), int64(data.len),
    cast[pointer](addr bins[0]))

when isMainModule:
  var data = newSeq[uint8](N)
  for i in 0..<N: data[i] = uint8((i * 31 + 7) mod 256)
  var bins = newSeq[int64](Bins)
  var refBins = newSeq[int64](Bins)
  for b in data: refBins[int(b)] += 1
  let bt0 = getMonoTime()
  var buf = buildHist()
  echo "assembled ", buf.len, " bytes in ", shortDur(getMonoTime() - bt0)
  let hist = cast[HistFn](buf.ptrAt(AssemblyOffset(0)))
  runHist(hist, data, bins)
  assert bins == refBins, "mismatch"
  let iters = benchIters(30)
  let t0 = getMonoTime()
  let c0 = cpuTime()
  for _ in 0..<iters:
    runHist(hist, data, bins)
    assert bins == refBins
  let rep = benchReport(getMonoTime() - t0, cpuTime() - c0, iters)
  var total = 0'i64
  for b in bins: total += b
  echo "histogram(1M) total ", total, " x", iters, " iters: ", rep
  buf.destroy()
