# Type erasure for Kintsugi custom types

> **STATUS: SUPERSEDED — 2026-04-17.** This proposal weighed Approach B
> (auto-desugar types into `@enter`/`@exit` contracts with debug/release
> Lua build modes). The shipped design diverged: Lua always erases, no
> build modes, `@type` declarations auto-synthesize predicate functions
> only when referenced by `is?` or `match`, and `@type/guard` is the
> opt-in compileability marker for user fns used in where-guards.
> See `docs/design-bible.md` section "Type Erasure" for the canonical
> description, and the implementation in `src/emit/lua.nim`,
> `src/eval/evaluator.nim`. This file is preserved for the design
> trade-offs it explored.

## Context



Kintsugi's custom types are inconsistently compiled. Today there are three

machineries that disagree the moment code crosses interpreter -> Lua:



1. **Function param annotations** are enforced in the interpreter

   (`src/eval/evaluator.nim:1195-1214`) but **erased without replacement** in

   Lua. Same source, silently different behavior.

2. **`@type/where` guards** run in the interpreter

   (`evaluator.nim:1054-1084`) and are dropped at `src/emit/lua.nim:2188` with

   all other meta-words emitting `nil`.

3. **`is?` works for `object!`-nominal types** (via `_type` tag injection at

   `lua.nim:938-940` and `scanTypeChecks` at `lua.nim:4243-4257`) but is

   silently `false` for `@type`-defined structural/union/enum types in Lua.

4. **`@enter` / `@exit`** (`evaluator.nim:904-963`) are block-scoped lifecycle

   hooks, interpreter-only, currently used for resource cleanup. They look

   exactly like design-by-contract primitives but aren't wired to function

   boundaries and don't compile.



"Broken" = the interpreter and Lua target disagree about which annotations

are load-bearing, with no principled erasure story. The design bible says

"types are a contract, not a proof" - the implementation actually says

"types are a contract in the interpreter and a lie in Lua."



The goal is TypeScript-style erasure: structural gradual typing that

disappears in release Lua, output indistinguishable from hand-written code.

The user explicitly asked to leverage `@enter`/`@exit` as the DbC mechanism.



## Design axes (decisions required)



- Where do checks run? (interpreter-only / debug compile / release compile / opt-in)

- Do `@type` annotations desugar into `@enter` contracts, or stay orthogonal?

- What does `is?` mean in compiled code for structural types?

- Do `@enter`/`@exit` stay block-scoped or get elevated to function-boundary?

- Do `object!` (nominal, tagged) and `@type` (structural) unify?

- Is interpreter/Lua parity a goal, or is divergence a documented feature?



## Approaches considered



### A. Pure TypeScript erasure

Types are pure documentation everywhere. Release Lua has zero validation.

`is?` compiles to a synthesized predicate only if textually referenced.

`@type/where` guards become decorative.

- Pros: minimal Lua, simplest impl (mostly deletion).

- Cons: divergence formalized, `where` guards lose teeth, interpreter becomes a lint.



### B. @enter/@exit as the contract primitive (RECOMMENDED)

Elevate `@enter`/`@exit` to function-boundary hooks. Param type annotations

desugar into synthesized `@enter` contracts. `@enter`/`@exit` compile to Lua

assertions in debug builds, fully erased in release builds.

- Release Lua: `local function square(x) return x * x end`

- Debug Lua: prepends `assert(_positive_p(x), "square: x expects positive!")`

- Pros: interpreter = debug-Lua (one contract mechanism, not two). Types

  become sugar; contracts are primary. Users gain invariants types can't

  express (cross-param, return-refers-to-`result`). Extends existing feature

  rather than inventing. Directly matches user's DbC hint.

- Cons: introduces build modes. Debug output bigger (intentionally).



### C. Explicit `@check` opt-in

Types always erased. User writes `@check x` inside body to opt into runtime

validation per-site.

- Pros: no hidden cost; minimal risk.

- Cons: burden on user; divergence only partially closed; feels like a workaround.



### D. Two-mode compiler + unified type model

Ship `--debug`/`--release` AND collapse `object!` into `@type`. Struct-shaped

`@type` becomes nominal-with-tag; other shapes are structural.

- Pros: cleanest conceptual endpoint.

- Cons: largest surface area; breaking migration of `object!`. Best as a

  follow-up to B, not a replacement.



## Recommendation: Approach B, shaped to admit D later



Ship B. Its architecture is forward-compatible with D (once types desugar

into contracts, unifying `object!` with `@type` reduces to "does the

desugaring add a `_type` tag"). Doing both at once risks churn.



### Why B beats the alternatives

- **Parity**: interpreter runs the same contract machinery that debug-Lua

  emits. Release-Lua's divergence is documented and opt-in, not accidental.

- **Aesthetic**: release output is literally hand-written Lua; debug output

  is idiomatic Lua assertions.

- **DbC**: `@enter`/`@exit` become first-class and central rather than niche.

- **Cost**: extends existing machinery; no new surface concepts beyond

  function-boundary `@enter` (intuitive).



### Example: before / after Lua



Source:

```

@type positive! [integer! | float! | where it > 0]

@type/where non-empty! [string!] [(length? it) > 0]



square: function [x [positive!]] [ x * x ]

greet: function [name [non-empty!]] [ print ["hi" name] ]

```



Release Lua (default):

```lua

local function square(x) return x * x end

local function greet(name) print("hi " .. name) end

```



Debug Lua:

```lua

local function _positive_p(v) return type(v) == "number" and v > 0 end

local function _non_empty_p(v) return type(v) == "string" and #v > 0 end

local function square(x)

  assert(_positive_p(x), "square: x expects positive!")

  return x * x

end

local function greet(name)

  assert(_non_empty_p(name), "greet: name expects non-empty!")

  print("hi " .. name)

end

```



Explicit `@exit` contracts get a return-capturing wrapper in debug, erased

in release:

```

divide: function [a b] [

  @enter [ assert b <> 0 ]

  @exit  [ assert (is? number! result) ]

  a / b

]

```



## Breaking changes



1. Programs silently running buggy code in compiled Lua will `assert` under

   `--debug`. This is a fix, but a behavior change.

2. `@enter`/`@exit` at function-body scope now attach at function boundary.

   In practice the body block *is* the function block, so semantics are

   preserved for existing uses - but audit them.

3. `@type/where` guards gain teeth in debug; subtly wrong guards start firing.

4. `is? @type-x` now returns truthful results in Lua where it used to be

   silently `false`.



Migration: default to `--release` at introduction (pure extension, no

existing output changes). Flip to `--debug` default after one release cycle.



## Critical files



- `src/core/types.nim` - `CustomType` (37-42), `ParamSpec` (99-112),

  `parseFuncSpec` (386). Optional `contract: seq[KtgValue]` on `KtgFunc`.

- `src/eval/evaluator.nim` - `@enter`/`@exit` handling (904-963) extended to

  function boundaries; `callCallable` (1140+) wraps body so desugared

  contracts execute. Param-type checks (1195-1214) move from hard-coded

  path into synthesized `@enter`.

- `src/emit/lua.nim` - add `emitMode: {release, debug}` on `LuaEmitter`.

  Replace meta-word fall-through at line 2188 with a dispatch (compile

  `@enter`/`@exit` in debug, erase in release). Extend `scanTypeChecks`

  (4243-4257) to register `@type` definitions needing synthesized

  predicates. Emit one predicate per referenced `@type` in the prelude

  alongside `_make`.

- `src/eval/natives.nim` - `is?` (177-252); reuse same match logic when

  synthesizing predicates.

- CLI: add `--debug`/`--release` flags plumbed to `emitLua` /

  `emitLuaModule`.

- Tests: golden pairs under `tests/golden/` are release-mode; add a

  parallel `tests/golden/debug/` set. Add `tests/test_custom_types.nim`

  coverage for debug-Lua contract execution.

- `docs/design-bible.md` - update "Type System" / "Type Erasure" to

  formalize debug vs release.



## Open questions



1. **Default build mode.** Release at introduction (my recommendation) vs

   debug from day one.

2. **Function-scope vs block-scope `@enter`.** Both? Only top-of-body

   contracts attach at function boundary, deeper ones stay block-scoped?

3. **`is?` against structural `@type` in release.** Synthesize predicate

   (truthful, small cost), emit `false` with warning, or compile error.

4. **`@type/where` guards in debug.** Full evaluation (emit the `it`-bound

   block as a Lua function) vs restrict to a pure-expression subset.

5. **`object!` unification (D extension).** Defer (my recommendation) vs

   bundle with B.

6. **Return-type contracts.** `KtgFunc.returnType` is parsed but unused.

   Wire into synthesized `@exit [ assert is? ret result ]`?

7. **Error shape on contract failure.** Raw `assert` vs a small

   Kintsugi-style error helper in the prelude (line/name/expected).



## Verification



- Unit tests: `tests/test_custom_types.nim` - add cases where source has

  `@type/where` + param annotations; assert interpreter behavior unchanged.

- Emitter golden tests: extend `tests/golden/` with a matched release vs

  debug pair for at least `combat.ktg` and a new `contracts.ktg`.

- Emitter unit tests: `tests/test_emitter_fixes.nim` - new cases for

  (a) param desugaring emits `assert` in debug, nothing in release,

  (b) `is?` on structural `@type` emits predicate in both modes,

  (c) `@enter`/`@exit` at function body compile correctly in debug.

- End-to-end: compile a program that uses `@type/where`, run under `lua`,

  expect `assert` in debug and clean execution in release.

- Interpreter parity: pick 3-5 existing `.ktg` examples, confirm

  interpreter behavior matches `--debug` Lua output under same inputs

  (including failure cases raising equivalent errors).
