## Executable memory buffer (mmap / VirtualAlloc).
## Mirrors runtime/src/mmap.rs.

when defined(windows):
  import std/winlean
else:
  import std/posix

import ./types

const DefaultPageSize* = 4096

proc pageSize*(): int =
  when defined(windows):
    var si: SYSTEM_INFO
    GetSystemInfo(addr si)
    int(si.dwPageSize)
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
    let m = mmap(nil, size, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
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
  else:
    when defined(macosx) and defined(arm64):
      # Apple Silicon requires JIT writes to be fenced; x64 path uses mprotect.
      discard
    if mprotect(mem, mapped, PROT_READ or PROT_EXEC) != 0:
      raise newException(IOError, "mprotect RX failed")
  # Flush instruction cache where required (x86/x64 are coherent; keep hook).
  when defined(macosx) or defined(arm64) or defined(aarch64):
    discard # __clear_cache via compiler builtin if ARM targets are added later

proc makeWritable*(mem: pointer, mapped: int) =
  if mem == nil: return
  when defined(windows):
    var oldProtect: DWORD
    if VirtualProtect(mem, SIZE_T(mapped), PAGE_READWRITE,
        addr oldProtect) == 0:
      raise newException(IOError, "VirtualProtect RW failed")
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
