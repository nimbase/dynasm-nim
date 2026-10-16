## Label registry. Mirrors runtime/src/components.rs LabelRegistry.

import std/tables
import std/options
import ./types

type
  StaticLabel* = object
    name*: string
    version*: int  ## 0 = global, >=1 = local generation

proc isGlobal*(l: StaticLabel): bool = l.version == 0
proc isLocal*(l: StaticLabel): bool = l.version != 0

proc globalLabel*(name: string): StaticLabel =
  StaticLabel(name: name, version: 0)

proc localLabel*(name: string, version: int): StaticLabel =
  StaticLabel(name: name, version: version)

proc firstLocal*(name: string): StaticLabel =
  StaticLabel(name: name, version: 1)

proc nextLocal*(l: StaticLabel): StaticLabel =
  if l.version == 0: l
  else: StaticLabel(name: l.name, version: l.version + 1)

proc getName*(l: StaticLabel): string = l.name

type
  LabelRegistry* = object
    statics*: Table[(string, int), AssemblyOffset]
    dynamics*: seq[Option[AssemblyOffset]]
    localVersions*: Table[string, int]

proc initLabelRegistry*(): LabelRegistry =
  LabelRegistry(
    statics: initTable[(string, int), AssemblyOffset](),
    dynamics: @[],
    localVersions: initTable[string, int]()
  )

proc clear*(r: var LabelRegistry) =
  r.statics.clear()
  r.dynamics.setLen(0)
  r.localVersions.clear()

proc newDynamicLabel*(r: var LabelRegistry): DynamicLabel =
  let id = r.dynamics.len
  r.dynamics.add(none(AssemblyOffset))
  DynamicLabel(id)

proc defineDynamic*(r: var LabelRegistry, id: DynamicLabel,
    off: AssemblyOffset) =
  let i = int(id)
  if i < 0 or i >= r.dynamics.len:
    raise unknownLabel($i, lkDynamic, i)
  if r.dynamics[i].isSome:
    raise duplicateLabel($i, lkDynamic, i)
  r.dynamics[i] = some(off)

proc defineGlobal*(r: var LabelRegistry, name: string, off: AssemblyOffset) =
  let key = (name, 0)
  if key in r.statics:
    raise duplicateLabel(name, lkGlobal)
  r.statics[key] = off

proc defineLocal*(r: var LabelRegistry, name: string, off: AssemblyOffset) =
  var gen = 1
  if name in r.localVersions:
    gen = r.localVersions[name] + 1
  r.localVersions[name] = gen
  r.statics[(name, gen)] = off

proc placeLocalReference*(r: LabelRegistry, name: string): tuple[found: bool,
    label: StaticLabel] =
  if name in r.localVersions:
    let v = r.localVersions[name]
    (true, StaticLabel(name: name, version: v))
  else:
    (false, StaticLabel(name: name, version: 0))

proc resolveDynamic*(r: LabelRegistry, id: DynamicLabel): AssemblyOffset =
  let i = int(id)
  if i < 0 or i >= r.dynamics.len or r.dynamics[i].isNone:
    raise unknownLabel($i, lkDynamic, i)
  r.dynamics[i].get

proc resolveStatic*(r: LabelRegistry, label: StaticLabel): AssemblyOffset =
  let key = (label.name, label.version)
  if key notin r.statics:
    if label.isGlobal:
      raise unknownLabel(label.name, lkGlobal)
    else:
      raise unknownLabel(label.name, lkLocal)
  r.statics[key]
