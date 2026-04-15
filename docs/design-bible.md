# Kintsugi Design Bible

The authoritative record of what Kintsugi is, why it works the way it does, and what it will never become. This document governs all language decisions. When in doubt, refer here.

---

## Identity

Kintsugi is a homoiconic, dialect-driven programming language that compiles to clean Lua. It is for writing games.

**Influences:** REBOL, Red, Ren-C, Common Lisp, Lua, Raku.

**Targets:** LOVE2D (LuaJIT), Playdate (Lua 5.4), standalone Lua.

**Constraint:** Zero-dependency Lua output. No LuaRocks. No runtime library.

---

## Three Principles

Every design decision must serve at least one of these. If it serves none, it doesn't belong.

### 1. Simple

The language should be small enough to hold in your head. A new user should be able to read any Kintsugi program and understand the evaluation model within an hour. There is one evaluation rule (left-to-right), one data structure (blocks), one scoping mechanism (contexts), and one way to extend behavior (dialects).

### 2. Robust

Programs should fail loudly or not at all. Silent data corruption is the worst outcome. Money doesn't compare to integers. Type mismatches raise errors. Division by zero raises errors. If something can go wrong in a way the programmer didn't intend, it should stop and say so.

### 3. Explicit

Nothing happens behind the programmer's back. Assignment is by reference — if you want a copy, say `copy`. Evaluation is left-to-right — if you want different grouping, use parens. Type conversion requires `to`. Mutation requires set-path on a context. There are no implicit coercions, no operator precedence, no automatic copying, no silent type promotions.

---

## Evaluation Model

### Left-to-Right, No Precedence

`2 + 3 * 4` is `20`, not `14`. Operators are infix functions consumed left-to-right. Parens override grouping: `2 + (3 * 4)` is `14`.

**Why:** Precedence rules are a source of subtle bugs. Left-to-right is unambiguous. You never need to remember a precedence table.

### Fixed Arity

A function with N parameters always consumes exactly N values. No variadic functions. No optional parameters at the call site. Refinements handle optionality.

**Why:** When the evaluator sees a function name, it knows exactly how many arguments to consume. No lookahead, no ambiguity. Error messages are precise: "add expects 2 arguments, got 1."

### Infix Operators Are a Closed Set

`+`, `-`, `*`, `/`, `%`, `=`, `==`, `<>`, `<`, `>`, `<=`, `>=`, `and`, `or`, `->`. No user-defined infix.

**Why:** User-defined infix would require either a precedence system (which we rejected) or ad-hoc rules (which are confusing). The closed set is small enough that the language is completely learnable.

---

## Type System

### 28 Built-in Types

Beyond JSON's minimal set: money, pairs, tuples, dates, times, files, URLs, emails, sets, objects. Every value carries its type at runtime. Type names end with `!`.

**Why:** The language is for domain-specific work — games with coordinates, payments with money, dates/times, file paths. A pair isn't a 2-element array; it's inherently 2D coordinates. Rich types make code self-documenting.

### Money Is Cents

`money!` is stored as `int64` cents. `$19.99` is `1999`. No float drift. `$0.10 + $0.20` is exactly `$0.30`.

**Why:** Float arithmetic causes drift (`0.1 + 0.2 != 0.3`). Money requires exact arithmetic. Converting to float for display is explicit: `to float! $19.99` gives `19.99`.

### Money Is Its Own Domain

`$42.00 = 42` is `false`. Money and numbers don't compare.

**Why:** Dollars and unitless numbers are different things. Allowing comparison would make financial code accident-prone.

### Pairs Are 2D Coordinates

`pair!` has `px` and `py` (float64). Syntax: `100x200` or `1.5x-2.5`. Arithmetic works: `pos + 10x20`. Path access and set-path both work: `pos/x`, `pos/y`, `pos/x: 50`. Whole-valued pairs stringify as `100x200`, not `100.0x200.0`.

**Why:** Game development is coordinate-heavy. A dedicated type is faster and more readable than generic tuples.

### Tuples Are Bounded Bytes

`tuple!` stores each element as `uint8` (0-255). Syntax: `1.2.3`. For versions, RGB colors, IP octets.

**Why:** These domains rarely exceed 255 per component. The constraint is a semantic statement, not a limitation.

### Numbers and Logic Are Different Domains

`to integer! true` is an error. `to logic! 0` is an error. Use comparisons: `either n > 0 [true] [false]`.

**Why:** "Is it nonzero?" is a question that should be explicit in the code, not an implicit coercion.

### Conversions Are Explicit

No implicit type conversions. `to target-type! value` for all conversions. Failed conversions raise `'type` errors.

**Why:** `"42" + 8` should not silently give `"428"` or `50`. The programmer decides.

---

## Equality Rules

1. **Cross-type numeric:** `42 = 42.0` is `true`. Integer and float compare by value.
2. **Money is isolated:** `$42.00 = 42` is `false`. Different domains.
3. **Structural blocks:** `[1 [2 3]] = [1 [2 3]]` is `true`. Deep recursive comparison.
4. **Structural maps:** Order-independent key-value comparison.
5. **Structural contexts:** Same fields, same values.
6. **Case-sensitive strings:** `"abc" = "ABC"` is `false`.
7. **Case-insensitive words:** `'hello = 'Hello` is `true`. Same subtype required.
8. **Functions by identity:** Two independently defined functions are never equal.
9. **Only false and none are falsy.** `0`, `""`, `[]` are all truthy.

---

## Block Semantics

### Blocks Are Inert Data

`[1 2 3]` returns itself unevaluated. `(1 + 2)` evaluates. This is homoiconicity — code and data are the same structure. When you pass a block to `loop` or `parse`, you're passing data. The dialect interprets it; the parent evaluator doesn't.

**Why:** This enables dialects. A dialect receives `[keyword1 arg1 keyword2 arg2]` as data and walks it with its own rules. Set-words inside a dialect block are interpreted by the dialect, not by the parent. No collision, no surprise mutations.

### Assignment Is By Reference

`a: b` binds `a` to the same object as `b` for compound types (blocks, maps, contexts). Use `copy` for independence, `copy/deep` for recursive independence.

**Why:** Matches Lua semantics (the compilation target). Tables are shared by reference. Explicit is better than magical.

### Blocks Are Mutable, Strings Are Immutable

`append block value` mutates in place. `append string value` is an error — use `rejoin` or `join` to build new strings. String operations (`uppercase`, `trim`, `split`, `replace`) return new strings.

**Why:** Lua strings are immutable. Since Kintsugi compiles to Lua, mutable strings in the interpreter would create a parity gap — code that works in dev would silently break in compiled output. Immutable strings keep the interpreter and emitter in agreement.

### Sequence Operations Work on Both

Blocks and strings are both sequential. Operations that make semantic sense on both work on both:

- **Access:** `first`, `second`, `last`, `pick`
- **Length:** `length`, `empty?`
- **Search:** `find`, `has?`
- **Transform:** `reverse`, `sort`, `subset`
- **Iterate:** `for/in` yields elements (block) or characters (string)
- **Build (immutable forms):** `insert`, `remove` return a new value when applied to strings

Mutation (`append`, in-place `insert`, in-place `remove`) only applies to blocks. For strings, `insert` and `remove` return a new string — matching the `replace`/`rejoin`/`uppercase` pattern.

**Why:** A sequential data structure should support sequential operations. Forcing users to convert strings to blocks just to iterate, slice, or sort is ceremony for no benefit. The mutable/immutable split remains: blocks mutate, strings rebuild.

---

## Scope and Binding

### Contexts Are Universal

Closures, objects, modules, scopes, instances — all contexts. A closure is a function whose `boundCtx` points to the enclosing context. A module is a context. An object instance is a context. `words` works on all of them.

**Why:** Eliminates special cases. One mechanism, many uses.

### Set-Words Write Through

`x: value` writes to wherever `x` exists in the scope chain. If `x` doesn't exist anywhere, it creates a new local binding. Functions and loops can naturally update outer variables.

Context builders (`context [...]`, `make map! [...]`, `object [...]`, `scope [...]`) are isolated - set-words inside them always create local entries, never write through. This is because their purpose is to define a new set of bindings, not mutate the caller's scope.

**Why:** Matches Lua's scoping model (the compilation target). Simple scripts work naturally without ceremony. The isolation rule for context builders prevents `make map! [name: "Ray"]` from accidentally overwriting an outer `name` variable.

### Closures Capture By Reference

A closure holds a reference to the enclosing context, not a copy. It can read parent variables. It cannot rebind them (set-word creates locals).

**Why:** Matches Lua closure semantics.

---

## Dialects

### What They Are

A dialect is a block where words change meaning. `loop [for [x] in series do [body]]` — inside that block, `for`, `in`, `do` have loop-specific semantics. The parent evaluator hands the entire block to the dialect as data. The dialect walks it with its own rules.

**Why:** Dialects and templates are complementary. Templates (`@template`, `@compose`) generate code — they produce blocks that get spliced at the call site. Dialects interpret data — they receive blocks and walk them with custom rules. Dialects are not "more powerful" than templates; they solve a different problem. Use templates when you need code generation. Use dialects when you need a custom vocabulary for a domain.

### Six System Dialects

1. **Loop** — `for/in`, `from/to/by`, with `/collect`, `/fold`, `/partition` and `when` guards
2. **Match** — Pattern matching with type checks, captures, destructuring, guards
3. **Parse** — PEG-style parsing with backtracking (interpreter-only)
4. **Object** — Frozen objects with typed fields, auto-constructors, `make`
5. **Attempt** — Resilient pipelines with `source`, `then`, `when`, `catch`, `fallback`, `retries`
6. **Game** — Compile-time EC; user supplies S. Scenes, entities, components (via `@template`), collision, update/draw wiring, destroy/`alive?`. Compile-time only.

**Why:** These are the essential abstractions. Loops, pattern matching, parsing, objects, error handling, and games. Everything else is built from these.

### Dialects Return Values, Not Side Effects

`loop/collect` returns a block. `parse` returns a context. Dialects don't silently mutate the caller's scope. The caller assigns: `result: parse data [...]`.

**Why:** Explicit data flow. Visible, testable, composable.

### `@game` Is Compile-Time EC; You Supply the S

`@game` is the dialect for writing games. In ECS terms: **Entities and Components are handled by the dialect at compile time; Systems are ordinary user code that runs at runtime.**

The dialect knows about entities, expands components, and unrolls the update/draw loop into direct per-entity Lua. There is no runtime entity registry, no component dispatcher, no query system, no archetype table. The generated Lua reads `player.x = player.x + player.vx * dt` directly, not `for e in entities do ... end`. Systems are not a dialect concern: if you want a "movement system" you write `update [self/x: self/x + self/vx * dt]` inside a component or an entity body, and the composed update body *is* the system. The user is the scheduler.

This split is the axis of responsibility. The dialect owns plumbing - how entities declare, how components compose, how callbacks wrap into target-required shapes, how `self/<field>` substitution works, how collision enumerates pairs. The user owns logic - what happens when things update, what collisions mean, what draws look like. Neither side intrudes on the other.

**Consequence: no runtime entity registry is needed until something demands a dynamic entity count.** Traditional ECS needs a registry because systems iterate entities at runtime and must know which ones have which components. Kintsugi's registry is the compile pass - each entity already knows which update bodies apply to it because macro composition decided at parse time. The system runs as unrolled inline code per entity per frame. Zero lookup, zero dispatch, zero indirection. If you eventually want spawn / despawn / dynamic counts (bullet hell, runtime enemy pools), you pay for a registry and a runtime iteration loop, and the dialect will need a second output mode; until then, every game you write gets compile-time ECS composition with hand-written performance.

`@game` handles scenes, entities, state, collision, the update/draw/frame loop, and `self/<field>` substitution inside entity update bodies. It does not provide a cross-platform input API. It does not abstract target-specific graphics primitives beyond the auto-rect default for an entity.

**Target is a compile flag, not a source field.** `kintsugi -c pong.ktg --target=love2d`. The source contains `@game [...]` with no target declaration. A missing `--target` is a compile error; the REPL and interpret mode also error on `@game`, because `@game` is a compile-time-only dialect.

**Input is the concession.** LOVE accepts arbitrary keyboard keys as strings. Playdate has a fixed set of integer button bitmasks. These surfaces have no honest intersection, so the dialect does not try to unify them. Inside an `update` or `on-update` block, the dev writes target-native input directly: `if love/keyboard/isDown "w" [...]` on LOVE, `if playdate/buttonIsPressed playdate/kButtonUp [...]` on Playdate. The kButton constants are regular bindings on the Playdate backend; the dev references them like any other name. A file that mentions `playdate/kButtonUp` is implicitly a Playdate file, and compiling it with `--target=love2d` fails with an unbound-name error. Honest failure beats fake portability.

**Backends are data, mostly.** A `@game` backend is a record of `bindings` (a bindings block), `prelude` (top-of-file raw Lua), `framePrelude` (top-of-update raw Lua for things like `dt` and screen clear), `emitCallbacks` (how user update/draw bodies wrap into target-required callback shapes), `drawEntity` (target-optimal auto-rect emission for a standard entity), and `storesColor` (whether to extract `cr/cg/cb` fields at all — monochrome targets drop them). Adding a new target means writing a new backend record.

**Clean Lua out.** Generated Lua calls target SDK functions directly. No shim helpers, no dead state, no indirection. When the dev opens `pong.lua` to hand-extend it, they see `love.graphics.rectangle("fill", player.x, player.y, player.w, player.h)` or `playdate.graphics.fillRect(player.x, player.y, player.w, player.h)` — the same function they would have written by hand. `@game` gives you plumbing; what it outputs is yours.

**Components are templates.** An entity body is a linear sequence of component calls: `pos`, `rect`, `color`, `field`, `update`, `draw`, `tags`. The dialect recognizes these directly. To add a new component — `health`, `velocity`, `timeout`, `gravity`, whatever — you write an `@template` that expands into dialect vocabulary. When `parseEntity` encounters an unknown word inside an entity body, it asks the preprocessor whether the word is a registered template; if so, the template expands into the inline stream and parsing continues.

```
@template health: [amount [integer!]] [
  field hp (amount)
  field max-hp (amount)
]

entity player [pos 20 40  rect 12 12  health 25]
```

`@template` auto-wraps the body in `@compose`, so paren interpolation splices arguments directly. Refinements `/deep` and `/only` select `@compose/deep` and `@compose/only` respectively, for cases where nested interpolation or per-value splicing is required. For code generation that needs branching, iteration, or file I/O — anything beyond a declarative rewrite — use `@preprocess [emit [...]]` instead.

**Destroy is a skip marker, not a registry operation.** Every entity context carries an implicit `alive?: true` field. `destroy self` inside an update body, `destroy it` inside a collide body, and `destroy <name>` anywhere rewrite at dialect-expand time to `<target>/alive?: false`. Per-entity update and draw statements wrap in `if <entity>/alive? [...]`; collision pair tests include both sides' alive state in the guard condition. This is compile-time enough to model "entity is dead, stop processing it" without requiring a runtime entity registry or spawn/despawn machinery. Games that need dynamic entity counts — bullet hell, spawners, projectile pools — will eventually need a registry and the associated runtime loop; that's a bigger commitment and a separate dialect decision to make when a real game demands it.

**Collision has an override seam.** The default collision test is an AABB between two entities' `pos` + `rect`. When that's not enough — circles, swept collisions, distance thresholds, per-pixel tests — use the `/using` refinement: `collide/using ball 'enemy circle-hit? [body]`. The dialect emits the user's predicate as the test in place of the AABB, with the same `it/<field>` substitution in the body. Default is what you want 80% of the time; the override is there for the 20% where it isn't.

**Why:** A game dialect that pretends to hide the target makes every game worse on every target. `@game` only hides what's the same across targets — structure — and leaves surface concerns alone. Most game code is structure, so most game code is portable. The parts that are not portable are where the dev would have made a platform-specific decision anyway. The dialect respects that by not lying. Components, destroy, and collision override all follow the same pattern: the common case is built in, the uncommon case gets an escape hatch, and neither the dialect nor the runtime grows machinery to hide the difference.

### `@game` Stops Where Runtime Begins

Two patterns that other game frameworks bake into their core — runtime entity spawn/despawn and scene transitions — are deliberately not in `@game`. They aren't "deferred features" waiting on implementation; they're **user-owned concerns** that don't need a dialect form because Kintsugi's primitives already express them cleanly.

**Runtime entity spawn/despawn = a list, a function, a loop.** Kintsugi has `[]` (block), `append` (push), `loop` (iteration), `function` (callable values), `context` (record values with field access). That is all the machinery a runtime entity system needs. The standard pattern is shipped as `lib/entities.ktg`:

```
spawn-entity: function [e] [append entities e  e]
run-updates:  function [dt] [loop [for [e] in entities do [if e/alive? [if has? e 'update [e/update e dt]]]]]
run-draws:    function [] [loop [for [e] in entities do [if e/alive? [if has? e 'draw [e/draw e]]]]]
cull-dead:    function [] [alive: copy []  loop [for [e] in entities do [if e/alive? [append alive e]]]  entities: alive]
```

Users write factory functions that return `context` values with `update`, `draw`, and `alive?` fields. `spawn-entity` adds them to the list. The `@game` `on-update` block calls `run-updates dt` and `cull-dead`; the `draw` block calls `run-draws`. The dialect contributes nothing - the runtime entity system is plain Kintsugi composing existing primitives.

The reason the dialect doesn't grow a `runtime` flag, an `@archetype` form, or a `spawn` keyword is that **any auto-generation locks in shape decisions** (free-list vs swap-and-pop vs pools? when does cull run? how is iteration ordered? how does collision interact?). Different games want different shapes - bullet hells want pools, RTS-style games want stable references, puzzle games want nothing at all. The dialect picking one shape forecloses the others. Plain functions don't.

The pattern also coexists with `@game`'s static entities. The `player`, `score-display`, and any other compile-time-known singleton stays unrolled and lean. Dynamic bullets and particles iterate the runtime list. Two categories of entity, one Lua output that mixes flat field access with table iteration. Both clean, neither pretending to be the other.

**Scene transitions = state plus alive flags.** Same answer. A `state [game-phase: 'menu]` declaration, an `on-update` block that watches the phase and toggles entities' `alive?` flags, and you have scene switching:

```
on-update [
  cursor/alive?: game-phase = 'menu
  player/alive?: game-phase = 'playing
  if all? [game-phase = 'menu  love/keyboard/isDown "space"] [game-phase: 'playing]
]
```

Per-entity update and draw guards already skip inactive entities. Multi-scene games are "which subset of entities is currently running." No dialect form, no `set-scene` function, no scene table. Same pattern works for pause overlays, boss intros, temporary invincibility, anything that gates entities by state.

**The principle:** `@game` provides compile-time E and C; everything that runs at runtime is user code. Scene management runs at runtime. Spawn/despawn runs at runtime. Pools, free-lists, broadphase collision, archetype dispatch, all runtime. The dialect doesn't grow to fit them. Kintsugi's existing primitives (block, function, context, loop, set-words, paths) are the building material; users assemble what their game needs.

**The cost of this principle:** dynamic features are more verbose than they would be in a dialect that bakes them in. Spawning a bullet is `spawn-entity make-bullet self/x self/y 500.0` instead of `spawn 'bullet [...]`. Scene switching is explicit state assignment instead of `go 'menu`. Reuse via factory functions instead of archetype declarations. The user is doing work the dialect could do for them.

**The benefit of this principle:** the dialect stays small and the user stays in control. There is no version where `@game`'s opinions about runtime entity management collide with what a particular game wants. The dialect can never lock you out of a shape you need, because it has no runtime-shape opinions to lock you out with. When a game wants something different - a pool, a registry, a per-tag spatial hash - the user writes it as plain Kintsugi and it composes with everything else. The dialect doesn't need a feature flag, an opt-in directive, or a backend change.

**`scene` and `go` in source today.** Both are parsed as no-ops for backward compatibility with prior pong sources. `scene 'main [...]` strips its wrapper and processes contents as if they were at `@game` top level; `go 'name` consumes its two tokens and emits nothing. Consider them deprecated syntax; new code shouldn't use them.

---

## Object Protocol

### Objects Are Frozen Templates, Instances Are Mutable Copies

`object [...]` creates an `object!` — a frozen template with field specs, defaults, and methods. `make Object [overrides]` stamps a mutable `context!` from that template. The object is immutable; the instance is mutable. The instance has no link back to the object.

`freeze` converts a `context!` to an `object!` (one-way). `freeze/deep` does so recursively. `frozen?` returns true for `object!` values.

**Why:** No prototype chains, no delegation, no method resolution order. `make` copies fields into a new context — the result is a complete, independent value. Objects are frozen because they define structure, not state. If you need runtime customization, write a constructor function that calls `make`, modifies the instance, and returns it.

### `make` Is a Stamp, Not Delegation

Shallow-copies fields, applies overrides, validates required fields, binds `self`. The result is a complete, independent context.

**Why:** Simple mental model. Instances own all their fields and methods. No "where does this method live?" question.

### `merge` Is Mixin Composition

`merge a b` returns a new `context!` with entries from both (b wins on conflicts). `merge/freeze a b` returns an `object!`. Both arguments can be `context!` or `object!`.

```
dragon: merge (make Base [hp: 500]) Flying
```

No prototype chains. No diamond problem. Just data flowing into a new context.

---

## Boolean Combinators

`all? [cond1 cond2 ...]` returns `true` if every expression is truthy (short-circuits on first falsy). `any? [cond1 cond2 ...]` returns `true` if at least one is truthy (short-circuits on first truthy). Both return `logic!`, never the intermediate values.

**Why:** Replaces deeply nested `if` chains. `if all? [x > 0  x < 100  is? integer! x] [...]` reads as a single condition. Returning `logic!` rather than values keeps the semantics explicit - these are predicates, not value selectors.

---

## Error Handling

### Errors Are Values

`try [expr]` returns a context with `ok`, `value`, `kind`, `message`, `data`. Not a special "result" type — a normal context you can pass around, pattern-match, serialize.

### Standard Error Kinds

`'type`, `'arity`, `'undefined`, `'math`, `'range`, `'syntax`, `'parse`, `'loop`, `'attempt`, `'load`, `'frozen`, `'make`, `'self`, `'object`, `'match`, `'dialect`, `'io`, `'stack`, `'user`. Users can raise custom kinds.

### Attempt Pipelines

`attempt [source [...] then [...] catch ['kind [...]] fallback [...] retries N]` — declarative error handling for sequences of operations that might fail.

**Steps:**
- `source [expr]` — initial value. Required for compiled use. Inside the pipeline body, `it` is bound to the current value.
- `then [expr]` — transform step. `it` is the previous result.
- `when [expr]` — guard. If falsy, the whole pipeline short-circuits to `none`.
- `catch 'kind [expr]` — handler for a specific error kind. Inside, `error` is bound to the error message string.
- `fallback [expr]` — last-resort handler for any unhandled error. `error` is bound the same way.
- `retries N` — re-run the source up to N times on error before running handlers.

**Error model:** `error 'kind "msg" data` raises an error carrying all three fields. Inside `catch` and `fallback` blocks, `error` is bound to the message string (not the error object). Catch handlers dispatch on kind by exact match — `'parse` catches only `'parse`.

**Why:** Game code has many fallible operations (file I/O, network, parsing). Pipeline-style error handling is more readable than nested try/catch. Binding `error` to the message string is the common case — if a handler needs the kind or data, `try [expr]` returns a richer value context instead.

---

## Compilation Model

### Type Erasure

The interpreter enforces types at runtime. In compiled Lua, `@type` definitions are erased. Built-in type checks (`integer?`, `string?`, `is? integer! x`) emit Lua `type()` checks. Custom type checks (`is? person! x`) emit `_type` tag checks — `make` stamps instances with a `_type` string field.

**Why:** Trust the programmer for what Lua can't verify. Let Lua verify what it can.

### Zero-Dependency Lua Output

Emitted Lua has no external requires. Prelude helpers are tree-shaken — only helpers you actually use appear in the output.

**Why:** Game runtimes (Playdate, LOVE2D) have constrained environments. No package manager, no external dependencies. The compiled output must be self-contained.

### Interpreter-Only Features

`@parse` raises a compile error in the emitter — PEG parsing requires runtime evaluation that can't be statically compiled. All other features compile.

### Type Checking in Compiled Output

Built-in type checks (`is? integer! x`, `integer?`, `string?`, etc.) emit Lua `type()` checks — Lua can verify these natively. Custom type checks (`is? person! x`, `person?`) emit `_type` tag checks — `make` stamps instances with a `_type` string field, and `is?` checks it. `@type` definitions are erased (they define interpreter-only custom types), but `object`-based type tags work at both levels. `freeze` is a no-op in compiled output (returns its argument unchanged). `frozen?` always returns `false` in compiled output (Lua tables are always mutable).

### AST Is the IR

No intermediate representation. Both the interpreter and emitter walk the same `seq[KtgValue]`. The pipeline is: parse, prescan, infer, emit — all operating on the same data structure.

**Why:** Homoiconic design. Code-as-data macros (`@compose`) work naturally. No IR translation bugs. One representation to understand, not two.

---

## What Kintsugi Is Not

### Not a systems language
No manual memory management, no pointers, no inline assembly.

### Not a functional language
Side effects are allowed and common. Blocks are mutable. No persistent data structures. Use mutation where it's natural; use `copy` where you need isolation.

### Not a gradually typed language
Types exist for documentation and runtime checking in the interpreter. They are erased in compiled output. There is no type inference pass that affects semantics. Types are a contract, not a proof.

### Not extensible at the syntax level
No user-defined operators. No reader macros. No custom syntax. The grammar is fixed. Extensions happen through dialects (semantic, not syntactic) and `@compose` (code generation, not parsing).

### Not backwards-compatible with REBOL or Red
Influenced by, not compatible with. Key divergences:
- No operator precedence (Red has it)
- No `opt` in function specs (refinements replace it)
- No variadic functions
- No `make` delegation chains (stamp, not chain)
- Money is cents-based (Red uses decimal)
- `set-word` writes through (REBOL shadows by default)
- `==` is strict type equality (both sides must be same scalar type)

---

## Decision Checklist

When adding a feature, ask:

1. **Does it serve Simple, Robust, or Explicit?** If not, don't add it.
2. **Can it be a dialect instead of a language change?** Prefer dialects.
3. **Does it compile to clean Lua?** If it can't be statically compiled, it's interpreter-only and must raise a compile error.
4. **Does it add a new concept?** The language has enough concepts. Prefer composing existing ones.
5. **Would a REBOL programmer recognize it?** Good. But Kintsugi is not REBOL — diverge when the principle demands it.
6. **Would a game developer reach for it?** The language is for writing games. Features that don't help games are lower priority.
