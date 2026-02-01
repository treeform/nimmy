# Nimmy

A small scripting language inspired by Nim and Lua.

## Overview

Nimmy is designed to be a lightweight config and scripting language for games and other applications. It combines:

- **Nim-like syntax** — Clean, readable, indentation-based syntax
- **Lua-like simplicity** — A small, simple core that's easy to understand and embed

The entire implementation is just a couple of files, making it easy to integrate into your projects.

## Features

- **Sandboxed execution** — Safe to run untrusted scripts
- **Embeddable** — Designed to be embedded in host applications
- **Minimal footprint** — Small codebase, easy to audit and maintain
- **Familiar syntax** — If you know Nim or Python, you'll feel at home

## Syntax Example

```nim
# Variables
let name = "Nimmy"
var count = 0

# Functions
proc greet(who) =
  echo "Hello, " & who & "!"

# Control flow
if count == 0:
  greet(name)
else:
  echo "Already greeted"

# Loops
for i in 0 ..< 5:
  count = count + 1

# Types
type Person = object
  name
  age

let person = Person(name: "John", age: 30)
```

## Use Cases

- **Game scripting** — Let players or modders extend your game
- **Configuration files** — More powerful than JSON/YAML, safer than full languages
- **Plugin systems** — Allow third-party extensions in a sandboxed environment
- **Automation** — Simple scripts for repetitive tasks

## Embedding

Nimmy is designed to be embedded in host applications written in Nim or other languages via FFI.

```nim
import nimmy

let vm = newNimmyVM()
vm.run("""
  let x = 10
  echo x * 2
""")

vm.addProc "add", proc(a, b) =
  return a + b

vm.run "echo add(1, 2)"
# Output: 3
```

## Debugger and inspection support

You can add breakpoints and execute the script step by step. You can also ask the VM to print the local variables, nested structures, and the stack traces.

## Design

There are only a few files:
- src/nimmy.nim
- src/nimmy_vm.nim
- src/nimmy_parser.nim
- src/nimmy_lexer.nim
- src/nimmy_types.nim
- src/nimmy_utils.nim
- src/nimmy_debug.nim

The main file is src/nimmy.nim. It contains the main entry point and the API for the VM.

## Testing

Nimmy uses "gold master" testing. There are scripts to run and their output is compared to the expected output.

## Status

Nimmy is currently in early development.

## License

MIT
