# Kintsugi Nim Rewrite — Build Plan

This document is a handoff for implementation. Read `docs/language-spec-questions.md` first — it contains 34 design decisions that are load-bearing.

## Host Language

**Nim.** Compiles to C (Playdate embedding), gives JS output for free (`nim js` for browser playground), GC handles interpreter lifetimes, fast compilation.

## Project Structure

```
kintsugi-nim/
├── src/
│   ├── kintsugi.nim              # CLI entry point (REPL + file runner + compiler)
│   ├── core/
│   │   ├── types.nim             # KtgValue variant type, WordKind, all 27+ types
│   │   ├── context.nim           # Context (mutable scope), Object (frozen), scope chains
│   │   ├── errors.nim            # KtgError with kind, message, data, stack frames
│   │   └── equality.nim          # ONE equality function, all 10 rules from spec section 5
│   ├── parse/
│   │   ├── lexer.nim             # Generator/iterator-based tokenizer
│   │   └── parser.nim            # Stack-based AST builder (blocks + parens)
│   ├── eval/
│   │   ├── evaluator.nim         # Core eval loop: evalBlock, evalNext, applyInfix
│   │   ├── dialect.nim           # Dialect protocol: vocabulary, interpret, return
│   │   ├── natives.nim           # Built-in function registration
│   │   └── preprocess.nim        # #preprocess and #[expr] handling
│   ├── dialects/
│   │   ├── loop.nim              # Loop dialect (for/in, from/to, collect, fold, partition)
│   │   ├── parse_dialect.nim     # Parse dialect (PEG-like, string + block modes)
│   │   ├── match_dialect.nim     # Match dialect (pattern matching with guards)
│   │   ├── object_dialect.nim    # Object dialect (prototypes, field specs, auto-gen)
│   │   └── attempt_dialect.nim   # Attempt dialect (resilient pipelines)
│   └── emit/
│       └── lua.nim               # Lua emitter (AST → Lua source string)
├── lib/
│   ├── math.ktg                  # Standard library (port from existing)
│   ├── string.ktg
│   └── collections.ktg
├── tests/
│   ├── test_lexer.nim
│   ├── test_parser.nim
│   ├── test_evaluator.nim
│   ├── test_dialects.nim
│   ├── test_equality.nim
│   ├── test_types.nim
│   └── test_emit_lua.nim
├── examples/
│   ├── hello.ktg
│   ├── script-spec.ktg           # Port the spec — this is the test suite
│   └── game-demo.ktg
├── kintsugi.nimble               # Nim package file
└── README.md
```

## Value Type

The core data structure. Every design decision flows through this.

```nim
type
  WordKind* = enum
    wkWord, wkSetWord, wkGetWord, wkLitWord, wkMetaWord

  ValueKind* = enum
    vkInteger, vkFloat, vkString, vkLogic, vkNone,
    vkMoney, vkPair, vkTuple, vkDate, vkTime,
    vkFile, vkUrl, vkEmail,
    vkBlock, vkParen, vkMap, vkSet,
    vkContext, vkObject,
    vkFunction, vkNative, vkOp, vkType,
    vkWord  # all word subtypes share this variant

  KtgValue* = ref object
    case kind*: ValueKind
    of vkInteger: intVal*: int64
    of vkFloat: floatVal*: float64
    of vkString: strVal*: string
    of vkLogic: boolVal*: bool
    of vkNone: discard
    of vkMoney: cents*: int64
    of vkPair: px*, py*: int32
    of vkTuple: tupleVals*: seq[uint8]
    of vkDate: year*: int16; month*, day*: uint8
    of vkTime: hour*, minute*, second*: uint8
    of vkFile, vkUrl, vkEmail: resVal*: string
    of vkBlock, vkParen: values*: seq[KtgValue]
    of vkMap: mapEntries*: OrderedTable[string, KtgValue]
    of vkSet: setMembers*: HashSet[string]  # simplified; optimize later
    of vkContext: ctx*: KtgContext
    of vkObject: obj*: KtgObject
    of vkFunction: fn*: KtgFunc
    of vkNative: nativeFn*: NativeFunc
    of vkOp: opFn*: NativeFunc; opSymbol*: string
    of vkType: typeName*: string
    of vkWord: wordName*: string; wordKind*: WordKind
    line*: int  # source line for error reporting (all variants)

  KtgContext* = ref object
    entries*: OrderedTable[string, KtgValue]
    parent*: KtgContext

  KtgObject* = ref object
    ## Immutable. No RefCell equivalent needed — just don't mutate.
    entries*: OrderedTable[string, KtgValue]
    fieldSpecs*: seq[FieldSpec]  # for make validation
    name*: string                # prototype name for auto-gen

  KtgFunc* = ref object
    params*: seq[ParamSpec]
    refinements*: seq[RefinementSpec]
    returnType*: string          # "" = untyped
    body*: seq[KtgValue]
    closure*: KtgContext         # captured scope
```

## Dialect Protocol

The architecture's keystone. Every dialect implements this.

```nim
type
  Dialect* = ref object of RootObj
    vocabulary*: seq[string]

method interpret*(d: Dialect,
                  block: seq[KtgValue],
                  eval: Evaluator): KtgValue {.base.} =
  raise newException(KtgError, "dialect not implemented")
```

Key rules:
- The dialect receives the block as inert data (not evaluated)
- The dialect interprets the block according to its vocabulary
- Results return via the return value, never by mutating the caller's scope
- Set-words inside the block are the dialect's to interpret (not parent set-word assignment)

## Build Order

### Phase 1: Core (prove the dialect protocol)
**Goal:** Lexer + parser + evaluator + dialect protocol + loop dialect. ~500-800 lines.

1. `core/types.nim` — KtgValue, KtgContext, KtgObject, KtgError
2. `core/context.nim` — scope chains, get/set, child(), freeze()
3. `core/errors.nim` — KtgError, stack frames, formatted output
4. `core/equality.nim` — one function, 10 rules from spec section 5
5. `parse/lexer.nim` — tokenize to KtgValues (generator-based)
6. `parse/parser.nim` — stack-based block/paren nesting
7. `eval/evaluator.nim` — evalBlock, evalNext, applyInfix, word dispatch
8. `eval/dialect.nim` — Dialect base type, registration
9. `dialects/loop.nim` — first dialect: for/in, from/to, collect, fold, partition
10. `eval/natives.nim` — minimal built-ins: print, if, either, arithmetic, append, first, last, size?

**Test:** Can you run this?
```
loop [for [x] from 1 to 10 [print x]]
squares: loop/collect [for [n] from 1 to 5 [n * n]]
print squares
```

If yes, the dialect protocol works. Everything else is filling in.

### Phase 2: Language completeness
**Goal:** All dialects, full type system, error handling.

11. `dialects/parse_dialect.nim` — PEG-like parse with set-word capture, collect/keep
12. `dialects/match_dialect.nim` — pattern matching with guards
13. `dialects/object_dialect.nim` — prototypes, make, self, auto-generation
14. `dialects/attempt_dialect.nim` — resilient pipelines
15. `eval/preprocess.nim` — #preprocess, #[expr], platform
16. Expand `eval/natives.nim` — full native function set (strings, math, series, types, to, is?, set, etc.)
17. `core/types.nim` — add set! type, complete to conversion matrix

**Test:** Port `examples/script-spec.ktg` and run it. Every example should produce the expected output.

### Phase 3: Lua emitter
**Goal:** Compile Kintsugi/Lua files to clean, zero-dependency Lua.

18. `emit/lua.nim` — AST walking emitter. Match on value kinds, emit Lua strings.
19. Specialize dialect output: loop → for/ipairs, match → if-chain, object → table+constructor
20. Type erasure: use type info for optimization, don't emit runtime checks
21. Compile-time error for interpreter-only features (do, bind, compose on dynamic blocks)

**Test:** Compile a game script to Lua. Run it in LÖVE2D. It works.

### Phase 4: Game dialects + Chronodistort
**Goal:** Build the game. Let the game tell you what dialects to build.

22. Start building Chronodistort in Kintsugi targeting LÖVE2D
23. Build game dialects as needed: unit, ability, synergy, pattern, scene, input, tween
24. Each dialect is a Nim file implementing the Dialect protocol — same as built-ins
25. Iterate: ugly game code → extract dialect → clean game code → repeat

### Phase 5: Polish + Playground
26. REPL improvements
27. Error message quality pass
28. `nim js` build for browser playground
29. Playdate target testing (compile to Lua, test on device/simulator)

### Phase 6: Native compute kernels (only if Playdate perf demands it)
30. C emitter for `native` functions — reads typed AST, emits C struct + function
31. Lua bridge generation — emits the `register_natives` boilerplate for Playdate SDK
32. Build script integration — one `native` keyword, two artifacts (`.c` + `.lua`), build handles the split
33. Constraints enforced at compile time: no allocation, no dynamic dispatch, no strings — math on typed struct arrays only
See `docs/language-spec-questions.md` section 14.5 for full details.

## Key Constraints

- **ONE equality function.** `core/equality.nim` implements all 10 rules. No duplicates.
- **Set-word always shadows.** No write-through. No persist. No global. Mutate shared state via set-path on contexts.
- **Contexts are mutable, objects are frozen.** This is enforced at the type level — KtgContext has mutable entries, KtgObject does not expose mutation.
- **`size?` not `length?`.** Canonical name for element count.
- **`load` is the primitive, `require` is sugar.** `require` = load/eval/freeze/cache.
- **`exports` is body-level.** Not in the header. The header is just `Kintsugi []` or `Kintsugi/Lua []`.
- **Parse returns a context.** Set-word captures build fields on the result. `parse/ok` for boolean-only.
- **Dialect blocks are inert data.** The evaluator hands the block to the dialect. The parent scope never evaluates it.
- **No prototype chains.** `make` is a stamp. Shallow copy. No delegation.
- **Circular deps are always errors.** Loading stack detection.

## What NOT to Build

- No JS/WASM backends
- No bytecode VM
- No advice system
- No prototype chains or inheritance
- No `persist`/`global` for write-through
- No implicit function serialization
- No operator precedence
- No DWIM polymorphic built-ins (explicit primitives, users compose)

## Reference

- `docs/language-spec-questions.md` — the full spec with 34 decisions
- `examples/script-spec.ktg` — executable spec from the TypeScript era (behavior reference, syntax may need updating)
- `src/` (TypeScript) — the legacy implementation. Useful for understanding intent, not for porting directly.
- `src/tests/*.test.ts` — 825+ test cases across 30 files (4740 lines). These are the behavioral spec.

## Test Suite Porting

The TypeScript test suite (`src/tests/`) contains 825+ behavioral test cases that should be ported to Nim. The approach:

1. **Read each `.test.ts` file.** Extract the Kintsugi source strings and expected outputs from each `test()` call.
2. **Generate Nim equivalents.** Each `ev.evalString("...")` + `expect(...)` becomes a Nim test calling the evaluator and checking the result.
3. **Skip obsolete tests:**
   - `lower.test.ts` — IR lowering is gone (AST is the IR)
   - `emit-lua.test.ts` — will be rewritten for the new emitter
   - Any test for JS/WASM backends
4. **Flag tests that conflict with new spec decisions:**
   - `try` now returns `context!` with path access, not a block with `select`
   - `parse` now returns `context!` with captures, not `logic!`
   - `and`/`or` short-circuit behavior — spec says they DON'T, tests may assume they do
   - Block equality now works (`[1 2 3] = [1 2 3]` is true)
   - Loop variables are now scoped (spec says they don't leak)
   - `append` on strings is now an ERROR
   - `length?` renamed to `size?`
   - `require` is now sugar for `load/eval/freeze/cache`
   - Word equality is now same-subtype only (`'hello = first [hello]` is false)
   - `to integer! true` and `to logic! 0` are now errors
5. **Port the rest as-is.** ~80% of test cases (lexer, parser, arithmetic, functions, closures, control flow, type predicates, string ops, math ops, series ops) are valid unchanged.

Priority order for porting: lexer → parser → evaluator → natives → loop → match → parse → object → errors → stdlib.
