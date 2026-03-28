# Kintsugi

A homoiconic programming language. Blocks of data interpreted by dialects, targeting clean Lua output for game dev on constrained devices. Influenced by REBOL, Red, Common Lisp, Lua, and Raku.
 
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

## Learn

The language spec is a single executable file that doubles as the documentation:

**[`examples/full-spec.ktg`](examples/full-spec.ktg)**

It covers everything: types, functions, control flow, dialects, objects, error handling, the module system, preprocessing, and gotchas for developers coming from C-style or REBOL-style languages. Because it's `.ktg`, it's tested -- if the docs are wrong, the tests fail.
