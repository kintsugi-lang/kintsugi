# Kintsugi

A homoiconic programming language. Blocks of data interpreted by dialects, targeting clean Lua output for game dev on constrained devices.

> [!CAUTION]
> This language is in active development. Things will break and explode.

```rebol
Enemy: object [
  field [hp [integer!] 100]
  field [speed [float!] 40.0]
  field [pos [pair!] 0x0]

  damage: function [amount [integer!]] [
    self/hp: self/hp - amount
  ]

  update: function [dt [float!] target [pair!]] [
    dir: target - self/pos
    self/pos: self/pos + dir * self/speed * dt
  ]
]

goblin: make Enemy [pos: 80x60]
goblin/damage 10
print goblin/hp                        ; 90
```

## Features

- **27+ built-in types** including `money!` (exact cents), `pair!`, `date!`, `time!`, `url!`, `email!`, `set!`
- **Gradual typing** with `[type!]` annotations, custom `@type`, `@type/where` guards, `@type/enum`, structural types, typed blocks
- **Five dialects** -- loop, parse, match, object, attempt -- each a scoped vocabulary that changes what words mean inside its block
- **Object dialect** with `field` declarations, prototypes (`object!` -- immutable), instances (`context!` -- mutable), auto-generated constructors and type predicates
- **Parse dialect** for PEG-like pattern matching on strings and blocks, with set-word captures returned as a context
- **Loop dialect** with `for/in`, `from/to`, guards, `collect`, `fold`, `partition`
- **Match dialect** for pattern matching with destructuring, guards, wildcards, type matching
- **Attempt dialect** for resilient pipelines with `catch`, `fallback`, `retries`
- **No operator precedence** -- left-to-right evaluation, parens for grouping
- **Homoiconic** -- code is data, data is code. `compose`, `bind`, `do`, `reduce`
- **Preprocessing** -- `#preprocess` runs the full language at compile time for code generation
- **Modules** -- `require` loads and caches modules as frozen objects. `exports` controls visibility
- **Custom type system** -- `@type` unions, `@type/where` with guards, `@type/enum` (case-sensitive), structural context validation
- **Lua compiler** targeting Lua 5.1 (LOVE2D, Playdate, Defold)

## Quick Start

Requires [Nim](https://nim-lang.org/) 2.0+.

```bash
# Run tests
nimble test

# Build the interpreter
nimble build

# REPL
bin/kintsugi

# Run a file
bin/kintsugi examples/full-spec.ktg

# Compile to Lua
bin/kintsugi -c examples/hello.ktg
```

## Learn Kintsugi

The language spec is a single executable file that doubles as the documentation:

**[`examples/full-spec.ktg`](examples/full-spec.ktg)**

It covers everything: types, functions, control flow, dialects, objects, error handling, the module system, preprocessing, and gotchas for developers coming from C-style or REBOL-style languages. Because it's `.ktg`, it's tested -- if the docs are wrong, the tests fail.

## Design Decisions

The full spec with 30+ design decisions is at [`docs/language-spec-questions.md`](docs/language-spec-questions.md). Key principles:

- **Dialects are scoped vocabularies.** A dialect changes what words mean inside its block. The compiler is a dialect.
- **`context!` is mutable, `object!` is immutable.** The type determines mutability, not annotations.
- **Set-word always shadows.** Mutate shared state via context + set-path.
- **Only `false` and `none` are falsy.** 0, "", and [] are truthy.
- **Explicit primitives, compositional magic.** Small explicit functions at the base.
- **Rich compile-time, lean runtime.** Dialects resolve at compile time. The Playdate shouldn't know Kintsugi exists.

## Architecture

```
Source text
  -> Lexer (tokens)
  -> Parser (AST: seq[KtgValue])
  -> #preprocess pass (AST -> AST)
  -> Evaluator (runs it) OR Lua Emitter (emits .lua)
```

Written in Nim. Compiles to C. 6,000 lines of source, 771 tests.

## Lineage

Influenced by REBOL, Red, Common Lisp, Lua, and Raku.
