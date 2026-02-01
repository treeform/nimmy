# Package

version       = "0.1.0"
author        = "Nimmy Contributors"
description   = "A small scripting language inspired by Nim and Lua"
license       = "MIT"
srcDir        = "src"
bin           = @["nimmy"]


# Dependencies

requires "nim >= 2.0.0"


# Tasks

task test, "Run the test suite":
  exec "nim c -r tests/tests.nim"

task build, "Build the nimmy interpreter":
  exec "nim c -d:release -o:nimmy src/nimmy.nim"
