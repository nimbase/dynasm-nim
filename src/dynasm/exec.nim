## Executable memory buffer (mmap / VirtualAlloc).
## Mirrors runtime/src/mmap.rs.

when defined(windows):
  import std/winlean
else:
  import std/posix

import ./types

when defined(windows):
  # std/winlean is a lean subset: it has DWORD and the PAGE_* flags
  # but none of the virtual-memory API, so declare what we use.
  # (kernel32; stdcall is the 32-bit ABI, unified on 64-bit.)
  type SIZE_T = csize_t
  const
    MEM_COMMIT = 0x1000.DWORD
    MEM_RESERVE = 0x2000.DWORD
    MEM_RELEASE = 0x8000.DWORD
  proc VirtualAlloc(lpAddress: pointer, dwSize: SIZE_T,
    flAllocationType, flProtect: DWORD): pointer {.importc,
    header: "<windows.h>", stdcall.}
  proc VirtualProtect(lpAddress: pointer, dwSize: SIZE_T,
    flNewProtect: DWORD,
    lpflOldProtect: ptr DWORD): WINBOOL {.importc,
    header: "<windows.h>", stdcall.}
  proc VirtualFree(lpAddress: pointer, dwSize: SIZE_T,
    dwFreeType: DWORD): WINBOOL {.importc,
    header: "<windows.h>", stdcall.}

const DefaultPageSize* = 4096

when defined(macosx) and defined(arm64):
  # Apple Silicon forbids W+X pages outright. JIT memory must be
  # mapped with MAP_JIT, and stores into it are gated per-thread by
  # pthread_jit_write_protect_np (see the JIT cookbook used by
  # LuaJIT/wasmtime). Plain mprotect RW->RX does not work there.
  const MAP_JIT {.used.} = 0x0800
  proc pthread_jit_write_protect_np(enabled: cint) {.importc,
    header: "<pthread.h>".}

  proc jitAllowWrites*(allow: bool) =
    ## Thread-level JIT write gate. allow=true permits stores into
    ## MAP_JIT pages; allow=false re-arms protection before executing.
    pthread_jit_write_protect_np(cint(if allow: 0 else: 1))
else:
  proc jitAllowWrites*(allow: bool) {.inline.} =
    discard

when defined(arm64) or defined(aarch64):
  when defined(macosx):
    # Real API (not a compiler builtin), so it compiles on both
    # Intel and Apple Silicon Macs; on Intel it is never called
    # with executable mappings in practice.
    proc sys_icache_invalidate(s: pointer,
      len: csize_t) {.importc, header: "<libkern/OSCacheControl.h>".}
  proc flushCache(s: pointer, len: int) =
    ## Invalidate the instruction cache over freshly written code.
    ## x86 is coherent and needs nothing; ARM does not speculate
    ## for us.
    if s == nil or len <= 0: return
    when defined(macosx):
      sys_icache_invalidate(s, csize_t(len))
    else:
      # __clear_cache is a GCC/Clang builtin, declared only when
      # targeting ARM, so this branch compiles on Linux AArch64.
      {.emit: "__clear_cache(`s`, (char*)(`s`) + `len`);".}
else:
  proc flushCache(s: pointer, len: int) {.inline.} =
    discard

proc pageSize*(): int =
  when defined(windows):
    # Windows uses 4 KiB pages on every supported architecture
    # (x86, x64, ARM64); no GetSystemInfo call needed, which also
    # keeps this working on winlean-only toolchains.
    DefaultPageSize
  else:
    int(sysconf(SC_PAGESIZE))

type
  ExecutableBuffer* = object
    ## Owns RX memory. Derefs to bytes for reading.
    mem*: pointer
    mappedSize*: int
    length*: int

  MutableBuffer* = object
    mem*: pointer
    mappedSize*: int
    length*: int

proc isEmpty*(b: ExecutableBuffer): bool = b.mem == nil or b.length == 0
proc size*(b: ExecutableBuffer): int = b.mappedSize
proc len*(b: ExecutableBuffer): int = b.length

proc `[]`*(b: ExecutableBuffer, i: int): byte =
  assert i >= 0 and i < b.length
  cast[ptr UncheckedArray[byte]](b.mem)[i]

proc toSeq*(b: ExecutableBuffer): seq[byte] =
  result = newSeq[byte](b.length)
  if b.length > 0:
    copyMem(addr result[0], b.mem, b.length)

proc ptrAt*(b: ExecutableBuffer, off: AssemblyOffset): pointer =
  assert int(off) <= b.length
  cast[pointer](cast[int](b.mem) + int(off))

proc allocWritable*(size: int): tuple[mem: pointer, mapped: int] =
  if size == 0:
    return (nil, 0)
  when defined(windows):
    let m = VirtualAlloc(nil, SIZE_T(size), MEM_COMMIT or MEM_RESERVE,
      PAGE_READWRITE)
    if m == nil:
      raise newException(IOError, "VirtualAlloc failed")
    (m, size)
  else:
    var flags = MAP_PRIVATE or MAP_ANONYMOUS
    when defined(macosx) and defined(arm64):
      flags = flags or MAP_JIT.cint
    let m = mmap(nil, size, PROT_READ or PROT_WRITE, flags, -1, 0)
    if m == MAP_FAILED:
      raise newException(IOError, "mmap failed")
    (m, size)

proc makeExecutable*(mem: pointer, mapped, length: int) =
  if mem == nil: return
  when defined(windows):
    var oldProtect: DWORD
    if VirtualProtect(mem, SIZE_T(mapped), PAGE_EXECUTE_READ,
        addr oldProtect) == 0:
      raise newException(IOError, "VirtualProtect RX failed")
  elif defined(macosx) and defined(arm64):
    # MAP_JIT pages need all three: gate closed, RX transition
    # (executing a RW page raises SIGBUS on Apple Silicon), flush.
    jitAllowWrites(false)
    if mprotect(mem, mapped, PROT_READ or PROT_EXEC) != 0:
      raise newException(IOError, "mprotect RX failed")
  else:
    if mprotect(mem, mapped, PROT_READ or PROT_EXEC) != 0:
      raise newException(IOError, "mprotect RX failed")
  if length > 0:
    flushCache(mem, length)
  else:
    # Assembler.commit passes length 0 after copying fresh code;
    # flush the whole mapping (page-granular, tiny in practice).
    flushCache(mem, mapped)

proc makeWritable*(mem: pointer, mapped: int) =
  if mem == nil: return
  when defined(windows):
    var oldProtect: DWORD
    if VirtualProtect(mem, SIZE_T(mapped), PAGE_READWRITE,
        addr oldProtect) == 0:
      raise newException(IOError, "VirtualProtect RW failed")
  elif defined(macosx) and defined(arm64):
    # RX->RW must also go through mprotect: after the first commit
    # the mapping is RX, and the open gate alone does not restore
    # writability.
    if mprotect(mem, mapped, PROT_READ or PROT_WRITE) != 0:
      raise newException(IOError, "mprotect RW failed")
    jitAllowWrites(true)
  else:
    if mprotect(mem, mapped, PROT_READ or PROT_WRITE) != 0:
      raise newException(IOError, "mprotect RW failed")

proc freeMapping*(mem: pointer, mapped: int) =
  if mem == nil: return
  when defined(windows):
    discard VirtualFree(mem, 0, MEM_RELEASE)
  else:
    discard munmap(mem, mapped)

proc newExecutableBuffer*(size: int): ExecutableBuffer =
  if size == 0:
    return ExecutableBuffer(mem: nil, mappedSize: 0, length: 0)
  let (m, mapped) = allocWritable(size)
  makeExecutable(m, mapped, 0)
  ExecutableBuffer(mem: m, mappedSize: mapped, length: 0)

proc newMutableBuffer*(size: int): MutableBuffer =
  if size == 0:
    return MutableBuffer(mem: nil, mappedSize: 0, length: 0)
  let (m, mapped) = allocWritable(size)
  MutableBuffer(mem: m, mappedSize: mapped, length: 0)

proc destroy*(b: var ExecutableBuffer) =
  freeMapping(b.mem, b.mappedSize)
  b.mem = nil
  b.mappedSize = 0
  b.length = 0

proc destroy*(b: var MutableBuffer) =
  freeMapping(b.mem, b.mappedSize)
  b.mem = nil
  b.mappedSize = 0
  b.length = 0

proc writeBytes*(b: var MutableBuffer, data: openArray[byte]) =
  assert b.length + data.len <= b.mappedSize
  if data.len > 0:
    copyMem(cast[pointer](cast[int](b.mem) + b.length), unsafeAddr data[0],
      data.len)
    b.length += data.len

proc toExecutable*(b: MutableBuffer): ExecutableBuffer =
  makeExecutable(b.mem, b.mappedSize, b.length)
  ExecutableBuffer(mem: b.mem, mappedSize: b.mappedSize, length: b.length)

proc toMutable*(b: ExecutableBuffer): MutableBuffer =
  makeWritable(b.mem, b.mappedSize)
  MutableBuffer(mem: b.mem, mappedSize: b.mappedSize, length: b.length)
