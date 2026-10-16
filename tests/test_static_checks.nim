import unittest
import dynasm

# Compile-time safety net: every case below must be rejected while the
# block expands (via error()), i.e. `compiles` is false. The `ops`
# variable lives in the caller's scope so the checked code resolves it.
template rejects(body: untyped) =
  static:
    assert not compiles(body), "expected a compile-time error"

template accepts(body: untyped) =
  static:
    assert compiles(body), "expected this to compile"

proc touchemasm(ops: var VecAssembler) {.used.} =
  # Only referenced inside rejects() blocks (which never reach sem),
  # proving all-lowercase unknown calls are macro errors, not Nim calls.
  ops.push(0x90'u8)

proc touchAsm(ops: var VecAssembler) =
  ops.push(0x90'u8)

proc TouchAsm(ops: var VecAssembler) =
  ops.push(0x90'u8)

test "unknown mnemonics are rejected with hints":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      move rax, rbx
  rejects:
    dynasm ops:
      arch x64
      noppp()
  rejects:
    dynasm ops:
      arch x64
      frobnicate ops

test "arities are enforced":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      mov rax
  rejects:
    dynasm ops:
      arch x64
      mov rax, rbx, rcx
  rejects:
    dynasm ops:
      arch x64
      ret 1
  rejects:
    dynasm ops:
      arch x64
      add rax
  rejects:
    dynasm ops:
      arch x64
      jmp
  rejects:
    dynasm ops:
      arch x64
      u8
  rejects:
    dynasm ops:
      arch x64
      db
  rejects:
    dynasm ops:
      arch x64
      rel32 rax
  rejects:
    dynasm ops:
      arch x64
      cqo rax

test "mov shapes are validated":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      mov 5, rax
  rejects:
    dynasm ops:
      arch x64
      mov [rax], [rbx]
  rejects:
    dynasm ops:
      arch x64
      mov al, 256
  rejects:
    dynasm ops:
      arch x64
      movabs rax, rbx
  rejects:
    dynasm ops:
      arch x64
      movabs [rax], 5

test "lea shapes are validated":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      lea rax, rbx
  rejects:
    dynasm ops:
      arch x64
      lea [rax], rbx
  rejects:
    dynasm ops:
      arch x64
      lea rax, glob("x")

test "alu/test/incdec/push/pop shapes are validated":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      add [rax], [rbx]
  rejects:
    dynasm ops:
      arch x64
      test rax, [rbx]
  rejects:
    dynasm ops:
      arch x64
      push [rax]
  rejects:
    dynasm ops:
      arch x64
      pop [rax]
  rejects:
    dynasm ops:
      arch x64
      push 0x1FFFFFFFF
  rejects:
    dynasm ops:
      arch x64
      add rax, 0x100000000
  rejects:
    dynasm ops:
      arch x64
      mov al, byte(300)
  rejects:
    dynasm ops:
      arch x64
      `shr` rax, byte(99)

test "jump and call targets are validated":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      jmp 123
  rejects:
    dynasm ops:
      arch x64
      jz rax
  rejects:
    dynasm ops:
      arch x64
      call 0x1000
  rejects:
    dynasm ops:
      arch x64
      jmp extAddr(4096)

test "shifts, imul and div shapes are validated":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      `shr` rax, rdx
  rejects:
    dynasm ops:
      arch x64
      `shl` rax, 99
  rejects:
    dynasm ops:
      arch x64
      imul rax, 5
  rejects:
    dynasm ops:
      arch x64
      imul rax, rbx, rdx
  rejects:
    dynasm ops:
      arch x64
      imul rax, rbx, 0x100000000
  rejects:
    dynasm ops:
      arch x64
      `div` rax, rbx
  rejects:
    dynasm ops:
      arch x64
      movzx al, bl
  rejects:
    dynasm ops:
      arch x64
      movzx eax, ecx

test "labels, aliases and arch are validated":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      global foo
      global foo
  rejects:
    dynasm ops:
      arch sparc
  rejects:
    dynasm ops:
      arch x64
      alias rax, rbx
  rejects:
    dynasm ops:
      arch x64
      label mov
  rejects:
    dynasm ops:
      arch x86
      mov rax, rbx
  rejects:
    dynasm ops:
      arch x86
      push r8

test "all-lowercase helper calls are rejected, not silently passed":
  var ops = initVecAssembler(0)
  rejects:
    dynasm ops:
      arch x64
      touchemasm(ops)

test "genuine Nim still passes through":
  var ops = initVecAssembler(0)
  accepts:
    dynasm ops:
      arch x64
      let tmp = 1
      mov rax, tmp
  accepts:
    dynasm ops:
      arch x64
      echo "assembling"
      mov rax, rbx
  accepts:
    dynasm ops:
      arch x64
      mov rax, rbx
      if true:
        discard
  accepts:
    dynasm ops:
      arch x64
      TouchAsm(ops)
  accepts:
    dynasm ops:
      arch x64
      touchAsm(ops)
  accepts:
    dynasm ops:
      arch x64
      mov rax, glob("hello")
