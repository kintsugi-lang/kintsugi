# Kintsugi Handoff Document

Last updated: 2026-04-04

---

## Project Status

**Version:** 0.4.0
**Language:** Nim (compiles to C)
**Source:** ~9,200 lines of Nim across 14 files in `src/`
**Tests:** 1112 passing across 29 test files
**Executable spec:** `examples/full-spec.ktg` (~1,800 lines, runs clean)
**Love2D:** Tic-tac-toe compiles and runs in Love2D

### What's Implemented

The core language is complete:

- **Lexer + parser** -- tokenizes 20+ datatypes, parses into AST
- **Evaluator** -- left-to-right, no precedence, greedy function consumption
- **Type system** -- runtime type checks, `is?`, `to`, function param constraints, custom types via `object`, `==` strict equality
- **Datatypes** -- integer, float, string, logic, none, pair, tuple, date, time, file, url, email, money, block, paren, map, set, context, object, function, native, op, type
- **Control flow** -- `if`, `either`, `unless`, `loop` (the only loop construct, `do` required before body)
- **Error handling** -- `error`, `try` (returns result context), `rethrow`, `attempt` dialect (pipelines with catch/retries/fallback)
- **Dialects** -- loop, parse, match, attempt, object, bindings
- **Objects** -- prototype-based with `field/required`, `field/optional`, `fields` bulk form, `make`, auto-generated types and constructors
- **Parse dialect** -- PEG-style with backtracking, string and block modes, captures, collect/keep, composable rules, `parse/ok?` refinement
- **Preprocessing** -- `#preprocess [...]` and `#[expr]` (block splicing), full language at preprocess time, runs before compilation
- **Modules** -- `import` (load/eval/freeze/cache), `import/fresh`, `exports`, `load`/`load/eval`/`load/eval/freeze`, recursive compilation with cycle detection
- **Lua emitter** -- compiles Kintsugi to Lua 5.1 via `-c` flag, recursive binding prescan, refinements as positional booleans, `= none` → `_is_none()`, prelude only on entrypoints
- **Functions** -- `function`, `does` (zero-arg shorthand), refinements (`/name`), closures
- **Chain operator** -- `->` for method-style calls
- **Scoping** -- set-word always shadows, `@global` for opt-in write-through, `@const` for constant annotation
- **Dynamic paths** -- `board/cells/:pos` for get/set with variable index
- **I/O** -- `read`/`read/dir`/`read/lines`/`read/stdin`, `write`, `print`/`print/no-newline`, `save`/`load` round-trip, `dir?`, `file?`, `exit`
- **Math** -- trig (sin/cos/tan/asin/acos/atan2), pow/exp/log/log10, floor/ceil, pi, random with /int /range /choice /seed refinements
- **Series** -- unified: `find`, `reverse`, `append`, `first`/`last`/`pick` work on both blocks and strings, `replace`/`replace/first` on both, `byte`/`char` for character codes
- **Compilation** -- `raw` for verbatim Lua output, `bindings` dialect with `'call`/`'const`/`'alias`/`'assign`/`'override` kinds, directory compilation, `--dry-run`
- **Emacs mode** -- syntax highlighting and indentation (separate repo: `kintsugi-mode/`)

### What's Solid

- Core evaluation model
- Type system and conversions
- All five dialects (loop, parse, match, attempt, object)
- Module system (import/exports/caching)
- Lua emitter for core constructs (functions, control flow, loops, match, contexts, paths)
- The executable spec (`full-spec.ktg`) as a living test
- Love2D compilation (tic-tac-toe verified running)

---

## What's Next: Two Changesets

### Changeset 1: Emitter Unified Dispatch

**Problem:** The emitter has three dispatch paths that duplicate logic:

1. `emitExpr` -- expression context (returns a Lua expression string)
2. `emitBlock` -- statement context (writes Lua statements to output)
3. `emitBlockReturn` / `findLastStmtStart` -- return context (last expression gets `return`)

Each construct (`if`, `either`, `match`, `loop`, `print`, etc.) is handled separately in each path. Adding a new construct means touching 2-3 places.

**Solution:** Collapse into one `emitVal(vals, pos, ctx: EmitContext)` where `EmitContext = ecStatement | ecExpression | ecReturn`. Each construct branches on context:

- `if`: ecStatement → `if/then/end`, ecExpression → IIFE, ecReturn → `if/then return/end`
- `match`: ecStatement → if-chain, ecExpression → IIFE, ecReturn → if-chain with returns
- `loop`: ecStatement → for loop, ecReturn → for loop (no return)

Kill `emitBlockReturn` and `findLastStmtStart`. Replace with `emitBody(vals, asReturn)` that calls `emitVal(ecStatement)` for all but last, `emitVal(ecReturn)` for last.

**Files:** `src/emit/lua.nim` (~2,477 lines, the only file changed)

**Risk:** High -- touches every emission path. Must verify all 977 tests pass + full-spec + all compiled examples.

**Benefit:** Every subsequent emitter addition (Changeset 2) is 1 implementation instead of 2-3.

### Changeset 2: Complete Dialect Emission

**Problem:** These constructs work in the interpreter but don't compile:

| Construct | Status | Effort |
|-----------|--------|--------|
| `loop/collect` | Not emitted | ~40 lines (for loop building result table) |
| `loop/fold` | Not emitted | ~30 lines (for loop with accumulator) |
| `loop/partition` | Not emitted | ~40 lines (for loop splitting into two tables) |
| `attempt` dialect | Not emitted | ~50 lines (pcall chains with retry/catch/fallback) |
| `parse` dialect | Not emitted | ~150+ lines (PEG engine in Lua, or compile error) |
| `@global` | Not emitted | ~10 lines (emit as global variable, no `local`) |
| `does` | Partially emitted | ~5 lines (statement-level path done, expression done) |
| `find` | Not emitted | ~15 lines (helper function or inline) |
| `reverse` | Not emitted | ~15 lines (helper function) |
| `byte`/`char` | Not emitted | ~5 lines each (string.byte/string.char) |
| `getenv` | Not implemented | ~5 lines (os.getenv) |

**Decision needed for `parse`:** The parse dialect is a ~700-line PEG engine. Options:
1. Compile error: "parse is interpreter-only, use #preprocess"
2. Emit a Lua PEG runtime (~200 lines of Lua helpers + rule compilation)
3. Defer

**Files:** `src/emit/lua.nim` primarily, possibly `src/eval/natives.nim` for `getenv`

**Order:** Do Changeset 1 first. Then Changeset 2 is easy — each dialect's emission is one `case ctx` block in the unified dispatch.

---

## Architecture

### File Layout

```
src/
  kintsugi.nim              -- entry point (REPL, file runner, compiler CLI)  278 lines
  core/
    types.nim               -- all value types (KtgValue, KtgContext, etc.)   351 lines
    equality.nim            -- structural equality                             99 lines
  parse/
    lexer.nim               -- tokenizer for all datatypes                   410 lines
    parser.nim              -- token stream -> AST                            65 lines
  eval/
    evaluator.nim           -- the main eval loop                           1112 lines
    natives.nim             -- all built-in functions (~100 natives)         1884 lines
    dialect.nim             -- dialect dispatch interface + Evaluator type     36 lines
  dialects/
    loop_dialect.nim        -- for/in/from/to/by/when/do/collect/fold/part  208 lines
    parse_dialect.nim       -- PEG parser with backtracking                  698 lines
    match_dialect.nim       -- pattern matching with destructuring           213 lines
    attempt_dialect.nim     -- resilient pipelines                           284 lines
    object_dialect.nim      -- prototype objects with typed fields           278 lines
  emit/
    lua.nim                 -- Kintsugi AST -> Lua 5.1 source              2477 lines
```

### How the Evaluator Works

The evaluator (`eval/evaluator.nim`) walks a flat list of values left-to-right:

1. Encounter a value -- if it's a literal type (integer, string, etc.), return it
2. If it's a `word!`, look it up in the context chain. If callable, consume N arguments and call it
3. After evaluating a value, check for infix ops. If so, consume the right operand and apply
4. `set-word!` evaluates the RHS (including infix), then:
   - If the word is `@global`, writes to `eval.global`
   - Otherwise, creates in the current scope (shadows)
5. `paren!` evaluates its contents recursively
6. `block!` returns itself unevaluated (data until `do`)

Context chain: each scope has a parent pointer. Lookup (`get`) walks up the chain. Set-word creates in current scope unless `@global`.

### How the Emitter Works

`emit/lua.nim` walks the same AST the evaluator walks and generates Lua 5.1 source.

**Prescan phase:** Recursive `prescanBlock` walks the entire AST before emission. Builds a `bindings: Table[string, BindingInfo]` that tracks:
- Is this name a function or a value?
- What's its arity?
- What refinements does it have?
- What are its exported symbols? (for `import`)

**Emission phase:** Walks the AST with `emitBlock` (statements) and `emitExpr` (expressions). Key behaviors:
- Paths: known-value paths (`board/cells`) → field access, known-function paths (`greet/loud`) → function call with refinement flags
- Unknown paths default to field access (safe: won't consume args)
- `= none` / `<> none` → `_is_none()` calls (handles `_NONE` sentinel)
- Refinements → positional booleans: `greet/loud "world"` → `greet("world", true)`
- `import` → recursive compilation of dependency, `require("module")` in output
- `exports` → `return {name = name, ...}` at end of module
- Prelude (`_NONE`, `_is_none`, `_deep_copy`, `pi`) only on entrypoints (files with `Kintsugi [...]` header)

**Bindings dialect:** Declares foreign API arities for compilation.
- `'call N` -- function with fixed arity N
- `'const` -- bare value reference
- `'alias` -- local variable declaration
- `'assign` -- callback assignment (`lua.path = function(...)`)
- `'override` -- function definition form (`function lua.path(...)`)

### How to Add a New Native Function

In `src/eval/natives.nim`:

```nim
ctx.native("my-func", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
  ktgInt(args[0].intVal + args[1].intVal)
)
```

For refinements:

```nim
let myNative = KtgNative(
  name: "my-func",
  arity: 1,
  refinements: @[RefinementSpec(name: "deep", params: @[])],
  fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if "deep" in eval.currentRefinements:
      # handle /deep refinement
    ...
)
ctx.set("my-func", KtgValue(kind: vkNative, nativeFn: myNative, line: 0))
```

Then add to emitter's `initNativeBindings()` and add emission special-case if needed.

---

## Key Design Decisions

1. **Contexts are universal** -- closures, objects, modules, scopes are all contexts. `context!` is mutable, `object!` is frozen.
2. **Set-word shadows by default** -- `x: 5` inside a function creates a new local. Use `@global` for write-through to global scope. Use context + set-path (`state/counter:`) for shared mutable state.
3. **Dialects are scoped vocabularies** -- `for`, `in`, `some`, `keep` are only keywords inside their respective dialects.
4. **No operator precedence** -- `2 + 3 * 4` = 20. Use parens.
5. **Only false and none are falsy** -- 0, "", and [] are truthy.
6. **Strings are mutable** -- `append` works on both blocks and strings.
7. **Try returns a result context** -- `result/ok`, `result/message`, `result/kind`.
8. **Objects use stamp model** -- `make` copies fields, no prototype chains.
9. **Exports are body-level** -- `exports [...]` in the module body.
10. **Parse captures go into result context** -- not the caller's scope.
11. **Loop requires `do`** -- `loop [for [i] from 1 to 5 do [body]]`. Infinite loops don't need `do`.
12. **`=` is loose, `==` is strict** -- `1 = 1.0` is true, `1 == 1.0` is false. `==` errors on non-scalars.
13. **Dynamic paths** -- `items/:i` evaluates `i` as index. Matches Rebol behavior.
14. **Fixed-arity bindings** -- no variadic. Use parens for extra args: `(set-color r g b a)`.
15. **Refinements are one token** -- `/loud` not `/ loud`.
16. **`import` not `require`** -- `import %module.ktg`. Frozen, cached.
17. **`raw` for verbatim Lua** -- `raw "import \"CoreLibs/graphics\""`. No-op in interpreter.
18. **Header = entrypoint** -- `Kintsugi [...]` marks entrypoint (gets prelude). No header = module.

---

## Recent: Codebase Audit (2026-04-04)

A full audit identified and fixed 17 bugs + 1 stdlib bug, added 39 new tests:

**Crash fixes:**
- Modulo by zero in evaluator
- Lexer crashes on malformed pair, tuple, time, date, money literals (now validated)
- `insert` with out-of-bounds index
- `substring` off-by-one at string boundary
- `copy []` on empty blocks
- `step 0` infinite loop in loop dialect
- Negative retries crash in attempt dialect
- Parser depth limit added (256 max nesting)

**Logic fixes:**
- Nested path `self` binding (was binding to root, now binds to parent)
- `self` rebinding check scope (was walking parent chain, now checks current scope only)
- Odd-length block-to-context silent data drop (now errors)
- Money multiplication overflow detection
- `float?` / `integer?` type predicates in emitter (were wrong for Lua)
- `split` emission (was generating broken Lua gmatch, now uses proper helper)
- `last` double-evaluation in emitter (now uses IIFE with local)
- `tally` stdlib bug (`has?` was receiving lit-word instead of variable)

**New test files:**
- `test_stdlib_gaps.nim` -- 24 tests (smoothstep, fraction, magnitude, normalize, wrap, remap, deadzone, tally, etc.)
- `test_emitter_fixes.nim` -- 7 tests (type predicates, split, last, @const)
- `test_cli.nim` -- 8 tests (-e, -c, --dry-run, file execution)

---

## Known Limitations

- **Emitter dispatch is split** -- three paths (emitExpr/emitBlock/emitBlockReturn) duplicate logic. Unified dispatch is Changeset 1.
- **Dialect emission incomplete** -- loop/collect, loop/fold, loop/partition, attempt, parse don't compile. Changeset 2.
- **`some`/`any` backtracking** -- greedy, exponential worst-case on pathological inputs.
- **No LSP, no debugger, no formatter** -- Emacs syntax highlighting only.

---

## How to Build and Test

```bash
nimble build                              # release binary in bin/
nimble test                               # run all tests (1112 passing)
bin/kintsugi                              # REPL
bin/kintsugi file.ktg                     # run a file
bin/kintsugi dir/                         # run all .ktg in directory
bin/kintsugi -e 'print 1 + 2'            # evaluate expression
bin/kintsugi -c file.ktg                  # compile to Lua
bin/kintsugi -c file.ktg -o out.lua       # compile to specific output
bin/kintsugi -c dir/                      # compile all .ktg in directory
bin/kintsugi -c file.ktg --dry-run        # print compiled Lua to stdout
```

---

## Key Files

| File | Purpose |
|------|---------|
| `docs/language-spec-questions.md` | The living spec (34+ decisions) |
| `examples/full-spec.ktg` | Executable spec (~1,800 lines) |
| `lib/playdate.ktg` | Playdate SDK bindings |
| `lib/love2d.ktg` | LOVE2D bindings |
| `lib/math.ktg` | Math stdlib (clamp, lerp, smoothstep, etc.) |
| `lib/string.ktg` | String stdlib (pad, repeat, etc.) |
| `lib/collections.ktg` | Collections stdlib (flatten, zip, unique, etc.) |
| `examples/tic-tac-toe/` | Working game example (terminal + LOVE2D) |
| `examples/playdate-hello/` | Playdate SDK example |
| `examples/love2d/` | Minimal LOVE2D example |
| `docs/HANDOFF.md` | This document |
