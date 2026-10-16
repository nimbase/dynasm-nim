## Dynasm for Nim: dynamic assembler with macro DSL.
## Mirrors dynasm-rs runtime + plugin for x64/x86/aarch64.

import ./dynasm/types as typesMod
import ./dynasm/relocations as relocMod
import ./dynasm/labels as labelsMod
import ./dynasm/exec as execMod
import ./dynasm/assembler as asmMod
import ./dynasm/registers as regsMod
import ./dynasm/encoder as encMod
import ./dynasm/dispatch as dispMod
import ./dynasm/aarch64 as a64Mod
import ./dynasm/aarch64data as a64DataMod
import ./dynasm/aarch64match as a64MatchMod
import ./dynasm/macro_dsl as macroMod

export typesMod
export relocMod
export labelsMod
export execMod
export asmMod
export regsMod
export encMod
export dispMod
export a64Mod
export a64DataMod
export a64MatchMod
export macroMod
