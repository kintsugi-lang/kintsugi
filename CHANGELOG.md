# Changelog

## 0.5.2

### Fixed

- **`and` / `or` short-circuit in the interpreter.** The interpreter now skips evaluation of the right-hand side when the left-hand side already decides the result, matching the compiled Lua's native short-circuit. Previously both sides always evaluated, so `false and (1 / 0)` raised and RHS side effects (assignments, function calls) always fired. This closes a silent parity gap between interp and compiled output.

### Added

- **`'variadic` binding kind.** Declares a variadic FFI call whose single argument at the call site must be a block literal; contents splice into the emitted Lua call as positional arguments. Targets Lua APIs like `love.graphics.print`, `string.format`, and most SDK draw calls that today force one `'call N` binding per arity. Example: `bindings [rect "love.graphics.rectangle" 'variadic]` lets `rect ["fill" x y w h]` and `rect ["line" 0 0 10 10 3]` both work against the same binding.
- **`'variadic returns N`.** Declares Lua multi-return for a variadic binding. When the RHS of `set [a b c]` is a `'variadic returns > 1` call, the emitter produces `local a, b, c = lua.path(...)` directly — no temporary table, no indexing. Example: `bindings [rgb-bytes "love.math.colorFromBytes" 'variadic returns 3]` with `set [r g b] rgb-bytes [255 128 0]`. Interpreter placeholders return a block of N `none` values so destructuring stays consistent across targets.

## 0.5.1 — phase-2 type consolidation

### Changed

- **Objects dispatch nominally.** `is? :SomeObject v` and `is? some-object! v` now check that `v` was stamped by `make SomeObject [...]` (its `instanceOf` tag matches) instead of structurally comparing fields. Plain contexts that happen to share the field shape no longer match. Structural matching is still available via `@type ['name [t!] ...]`, which registers a `tkStruct` type distinct from the nominal object path.
- **`make` clones propagate nominal identity.** `make existing-instance [overrides]` now inherits `instanceOf` and field specs, so cloning preserves type.

### Removed

- **`typeEnv` legacy table.** Everything that read `Evaluator.typeEnv` now reads the unified `typeDefs` registry. One source of truth for `is?`, match, and the exhaustiveness analyzer.

## 0.5.0 — "No Ghosts"

### Language

- **Exhaustive match by default.** A `match` with no covering arm now raises `'match` instead of silently returning `none!`. Opt out with an explicit `default [none]` arm.
- **Static exhaustiveness pass.** Typed scrutinees (enum, builtin union, tagged union) are checked at compile time for missing variants, unreachable arms (after a catch-all or duplicate literal), and guard-only coverage. Guarded arms do not count toward coverage; coverage only by guard surfaces as a distinct error with a guard-specific message.
- **Tagged unions.** New syntax `@type [['circle float!] | ['rect float! float!]]` declares a nominal-by-tag union with positional field types. Match destructures by leading lit-word (`['rect w h]`) and the exhaustiveness pass treats each tag as a variant.
- **Coroutine stdlib.** `import/using 'coroutine [create resume yield status wrap]` exposes path-refined bindings that emit direct `coroutine.*` calls in compiled Lua. Interpreter raises; the module is Lua-target only.
- **Color stdlib.** `rgb`, `rgba`, `hex`, `hsl`, `lighten`, `darken`, `mix`, `apply` — 0..1 float blocks sized for LOVE2D's `setColor` and friends.
- **io stdlib.** (Landed from work alongside the 0.4 -> 0.5 cycle.) Multi-target filesystem bindings under `import/using 'io`.

### Removed

- **`freeze` / `frozen?`.** User-facing surface gone. Objects are still protected against direct template mutation; the error kind renamed from `'frozen` to `'mutation`. No semantic divergence between interpreter and Lua target anymore.

### Fixed

- **Stdlib module path routing.** `import 'math` followed by `math/clamp 15 0 10` used to silently route through Lua's `math.*` namespace (to a nonexistent `math.clamp`), because `math` shadows a Lua stdlib global. The emitter now resolves stdlib-module paths to the flattened spliced symbol and calls it directly. Every stdlib module that shares a name with a Lua global benefits.

### Under the hood

- **Unified type registry (phase 1).** Every `@type` and `object` registration mirrors into a single `Evaluator.typeDefs` table. `is?` and match dispatch route through it; legacy `CustomType` / `KtgObject` storage still backs each entry. Phase 2 (collapse the backings, flip object dispatch to nominal-by-tag) is deferred.
- **`analyze/` package.** New home for static analysis passes; exhaustiveness is the first tenant.
