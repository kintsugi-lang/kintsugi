# The `bindings` Dialect

`bindings [...]` is the escape hatch that teaches Kintsugi about foreign (Lua-side) names. It is the *only* supported way to reference Lua globals, target SDK APIs, or module-level constants from Kintsugi source without a strict-globals compile error.

## When To Reach For It

- Binding a target SDK: `love.graphics.print`, `playdate.graphics.drawCircle`, `coroutine.yield`.
- Exposing a Lua stdlib you will compile against: `math.pi`, `string.format`.
- Declaring callback assignment slots: `love.update`, `playdate.update`.
- Wrapping a small native Lua runtime helper that Kintsugi doesn't provide.

If you find yourself writing the same bindings block at the top of every file, hoist the block into `lib/<thing>.ktg` and `import %<thing>`. See `lib/coroutine.ktg` for the canonical example.

## Shape

```
bindings [
  <universal-entries>

  <target-word> [
    <entries-for-that-target>
  ]

  <another-target-word> [
    <entries-for-that-target>
  ]
]
```

The outer entries apply to every compile target *and* to the interpreter. Target sub-blocks group entries that should only fire for a specific target — `'love2d`, `'playdate`, `'lua`. The target word is bare, not quoted, and is followed immediately by a block.

**One bindings block per module.** You can collect multiple target sub-blocks inside a single `bindings [...]`; there is no need to repeat the outer keyword. In practice, modules that target multiple runtimes (e.g. a filesystem helper that maps to `love.filesystem`, `playdate.file`, or `io` depending on target) belong in one bindings block with three sub-blocks.

## Entry Forms

Every outer or sub-block entry is a tuple: `name "lua.path" 'kind [extra]`.

| Kind | Shape | What it does |
|------|-------|--------------|
| `'call` | `name "lua.path" 'call N` | Declare a function of arity `N`. At Kintsugi call sites, `name a b ...` consumes exactly `N` args and emits `lua.path(a, b, ...)`. |
| `'const` | `name "lua.path" 'const` | Declare an immutable value. Emits as a bare reference to `lua.path`. Path access (`name/field`) works normally. |
| `'alias` | `name "lua.path" 'alias` | Same as `const` but additionally emits a `local name = lua.path` declaration at module top. On `playdate`, the local is marked `<const>` for runtime savings. Use when you reference the name often and want Lua-side inlining. |
| `'assign` | `name "lua.path" 'assign` | Declare an assignment target. `name: value` emits as `lua.path = value`. Use for callback slots (`love/update: function [...] [...]`). |
| `'override` | `name "lua.path" 'override` | Reserved / internal; do not rely on it for user code today. |
| `'method` | `name "lua.path" 'method N` | Declare a method of arity `N`. At Kintsugi call sites, `name receiver a b ...` emits `receiver:path(a, b, ...)` (colon-call). Use when the Lua API expects method-call syntax. |
| `'variadic` | `name "lua.path" 'variadic [returns N]` | Declare a variadic call. At the call site, the one argument **must** be a block literal; its contents splice into the Lua call as positional arguments. Optional `returns N` declares Lua multi-return; combined with `set [a b c] name [...]`, the emitter produces `local a, b, c = lua.path(...)` directly. |

The `name` is a plain word. The `lua.path` is a string — dotted paths are supported (`"love.graphics.print"`). The `'kind` is a lit-word.

### Variadic bindings

Fixed-arity bindings (`'call N`, `'method N`) force you to pre-commit to a specific arg count per binding name. For variadic Lua APIs (`love.graphics.print`, `string.format`, most SDK draw calls) declare `'variadic`:

```
bindings [
  lg/rectangle "love.graphics.rectangle" 'variadic
  lg/print    "love.graphics.print"      'variadic
]

lg/rectangle ["fill" x y w h]       ; -> love.graphics.rectangle("fill", x, y, w, h)
lg/rectangle ["line" 0 0 10 10 3]   ; -> love.graphics.rectangle("line", 0, 0, 10, 10, 3)
```

The block argument is spliced at compile time, so each element becomes an independent Lua expression:

- Literals and word references pass through as-is.
- Paren-wrapped sub-expressions evaluate normally (`(x + 1)`).
- Nested variadic calls compose: `outer ["a" (inner [1 2]) "b"]` → `outer("a", inner(1, 2), "b")`.
- An empty block emits a zero-arg call: `quit []` → `os.exit()`.

**Block literal required at the call site.** Runtime splicing (passing a variable that holds a block) is *not* supported — the emitter rewrites calls at compile time, and would need `table.unpack` plus a runtime helper to dynamically spread. Hand-construct the call, or generate it via `@preprocess` / `@template` for code-gen.

**Caution: Lua multi-return truncation.** When a call that returns multiple values is used in a non-tail position of another call's argument list, Lua truncates its return to one value. This rule is Lua's, not Kintsugi's; the emitter preserves the call shape 1:1. Destructure explicitly at the boundary with `set [...]` if the extra values matter.

### Variadic with `returns N` (multi-return)

Declare the return arity when a Lua call returns multiple values:

```
bindings [
  rgb-bytes "love.math.colorFromBytes" 'variadic returns 3
]

set [r g b] rgb-bytes [255 128 0]
; -> local r, g, b = love.math.colorFromBytes(255, 128, 0)
```

The emitter specializes the `set [...]` destructure into a direct Lua multi-assign when the RHS is a `'variadic returns > 1` binding call. No `_set_tmp` table, no indexing — Lua's own multi-return mechanism carries the values. `returns 1` is the default and behaves like a normal single-value call.

In the interpreter, `'variadic returns N` placeholders return a block of N `none` values so `set [...]` destructures without diverging from the compiled shape. The interpreter never executes the foreign call — bindings are compile-time escape hatches.

## Runtime vs Compile Behavior

**Interpreter.** `bindings [...]` is a regular native (see `src/eval/natives_io.nim`). Outer entries get installed as placeholder natives in the current context: `'call` and `'assign` install no-op natives that return `none`; `'const` and `'alias` install `none`. **Every** target sub-block is then walked and applied in source order — later declarations overwrite earlier ones, but since the placeholders are target-agnostic, the runtime behavior is identical regardless of which sub-block wins. The interpreter does not execute the foreign calls; it lets dialects like `attempt` and `loop` compose around them for structural tests, and defers real semantics to compilation.

**Compiler.** The emitter reads the `Kintsugi [target: 'foo]` header to pick a target. Outer entries always apply. Entries inside a target sub-block apply only when the sub-block's leading word matches the compile target. Unknown target words are skipped silently — the emitter cannot verify target names, so the developer is trusted.

## Name Resolution and Strict Globals

The emitter runs a strict-globals pass that rejects any name that was not:
1. Declared locally (`x: ...`),
2. Registered as a user function during prescan,
3. Declared in a `bindings [...]` block,
4. Part of the Lua stdlib allowlist (`math`, `string`, `table`, `io`, `os`, `coroutine`, etc. — see `src/emit/globals.nim`).

This is the mechanism that turns typos into compile errors. If a reference fails, the error text hints: "if it should be a Lua global or target-native, add a `bindings [...]` entry."

## Example: Multi-Target Bindings

```
Kintsugi [target: 'love2d]

bindings [
  ; Universal. Applies to love2d, playdate, lua, and the interpreter.
  print            "print"            'call 1

  love2d [
    graphics/print "love.graphics.print" 'call 3
    update         "love.update"         'assign
  ]

  playdate [
    graphics/print "playdate.graphics.drawText" 'call 3
    update         "playdate.update"            'assign
  ]

  lua [
    graphics/print "io.write"           'call 1
  ]
]

update: function [dt] [
  graphics/print "hello" 10 20
]
```

On `target: 'love2d`, `graphics/print` binds to `love.graphics.print` and `update` becomes an assignment to `love.update`. On `target: 'playdate`, both rebind to the Playdate SDK. On `target: 'lua`, the graphics call falls back to `io.write`.

## Mirror Between Interpreter and Emitter

The two sides must agree on the set of names registered. The interpreter's `bindings` native in `src/eval/natives_io.nim:449` walks entries and installs placeholders. The emitter's `applyBindingEntries` in `src/emit/lua.nim:4321` does the same walk and populates `nameMap` / `bindingKinds` / `bindings`. If a new binding kind is added, both paths must learn it — otherwise a name that parses in the interpreter will fail the strict-globals check (or vice versa).

## Limitations

- Binding paths are strings, not Kintsugi expressions. There is no way to conditionally build the Lua path — the target sub-block mechanism is the only conditionalization.
- Arity is a static integer. Variadic Lua functions need to be wrapped (either with a Kintsugi function that forwards to `call`, or by declaring multiple arities under different names).
- `'override` and a couple of less-common kinds exist in the implementation but are not considered stable user surface.
- There is no runtime way to query the declared bindings; they are installed into the context like any other name and are indistinguishable from user definitions at introspection time.

## Where To Look

- Interpreter implementation: `src/eval/natives_io.nim:447-532`.
- Emitter implementation (prescan + apply): `src/emit/lua.nim:4321-4489`.
- Alias local emission (with playdate `<const>`): `src/emit/lua.nim:3734-3780`.
- Strict-globals check: `src/emit/lua.nim:415-440`.
- Real-world module: `lib/coroutine.ktg`.
