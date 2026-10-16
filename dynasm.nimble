# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "A dynamic assembler written in Nim for Nim"
license       = "MPL-2.0"
srcDir        = "src"


# Dependencies
#
# Note: intentionally dependency-free (pure Nim, no C libraries).
# Even the AArch64 execution tests use a scalar loop as oracle so
# that ARM CI needs no extra packages.

# Floor verified against the 2.2 series (CI installs `stable`).
requires "nim >= 2.2.0"
