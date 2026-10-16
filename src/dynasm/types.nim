## Core types for dynasm Nim port.
## Mirrors runtime/src/lib.rs AssemblyOffset, DynamicLabel, errors.

type
  AssemblyOffset* = distinct int
    ## Offset into assembling buffer in bytes.

  DynamicLabel* = distinct int
    ## ID for a dynamic label.

  ArchKind* = enum
    akX64
    akX86
    akAarch64

  LabelKindDesc* = enum
    lkLocal
    lkGlobal
    lkDynamic

  DynasmErrorKind* = enum
    dekCheckFailed
    dekDuplicateLabel
    dekUnknownLabel
    dekImpossibleRelocation

  DynasmError* = object of CatchableError
    kind*: DynasmErrorKind
    labelName*: string
    labelKind*: LabelKindDesc
    dynId*: int

proc `==`*(a, b: AssemblyOffset): bool {.borrow.}
proc `==`*(a, b: DynamicLabel): bool {.borrow.}
proc `$`*(o: AssemblyOffset): string = $int(o)
proc `$`*(d: DynamicLabel): string = "dyn" & $int(d)

proc checkFailed*(): ref DynasmError =
  result = newException(DynasmError, "check failed")
  result.kind = dekCheckFailed

proc duplicateLabel*(name: string, k: LabelKindDesc, dynId = -1): ref DynasmError =
  result = newException(DynasmError, "duplicate label: " & name)
  result.kind = dekDuplicateLabel
  result.labelName = name
  result.labelKind = k
  result.dynId = dynId

proc unknownLabel*(name: string, k: LabelKindDesc, dynId = -1): ref DynasmError =
  result = newException(DynasmError, "unknown label: " & name)
  result.kind = dekUnknownLabel
  result.labelName = name
  result.labelKind = k
  result.dynId = dynId

proc impossibleRelocation*(msg: string): ref DynasmError =
  result = newException(DynasmError, "impossible relocation: " & msg)
  result.kind = dekImpossibleRelocation
