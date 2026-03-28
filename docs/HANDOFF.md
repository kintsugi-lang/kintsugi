# Kintsugi Handoff Document

Last updated: 2026-03-26

---

## Project Status

**Version:** 0.3.0 (nimble), header says 0.4.0
**Language:** Nim (compiles to C)
**Source:** ~7,200 lines of Nim across 13 files in `src/`
**Tests:** 855 passing across 20 test files (~7,400 lines)
**Executable spec:** `examples/full-spec.ktg` (~1,700 lines, runs clean)

### What's Implemented

The core language is complete and usable:

- **Lexer + parser** -- tokenizes all 20+ datatypes, parses into AST
- **Evaluator** -- left-to-right, no precedence, greedy function consumption
- **Type system** -- runtime type checks, `is?`, `to`, function param constraints, custom types via `object`
- **Datatypes** -- integer, float, string, logic, none, pair, tuple, date, time, file, url, email, money, block, paren, map, set, context, object, function, native, op, type
- **Control flow** -- `if`, `either`, `unless`, `loop` (the only loop construct)
- **Error handling** -- `error`, `try` (returns result context), `rethrow`
- **Dialects** -- loop, parse, match, attempt, object, bindings, header
- **Objects** -- prototype-based with `field/required`, `field/optional`, `fields` bulk form, `make`, auto-generated types and constructors
- **Parse dialect** -- PEG-style with backtracking, string and block modes, captures, collect/keep
- **Preprocessing** -- `#preprocess [...]` and `#[expr]` inline form, full language at preprocess time
- **Modules** -- `load`, `load/eval`, `load/header`, `load/fresh`, `require`, `require/fresh`, `exports`, caching
- **Lua emitter** -- compiles Kintsugi to Lua 5.1 source via -c flag
- **Chain operator** -- `->` for method-style calls
- **Natives** -- 80+ built-in functions including string ops, file I/O, date/time, freeze/copy with /deep refinements
- **Emacs mode** -- syntax highlighting, indentation

### What's Solid

- Core evaluation model
- Type system and conversions
- Loop dialect (collect, fold, partition, filter)
- Object dialect (field declarations, make, auto-generation)
- Parse dialect (backtracking, captures, collect/keep)
- Error handling (try/rethrow)
- Module loading and caching
- The executable spec (`full-spec.ktg`) as a living test

### What Needs Work

- Lua emitter uses recursive binding tracking and context-aware dispatch; foreign API calls need `bindings` dialect to declare arities
- No LSP, debugger, or formatter

---

## Architecture

### File Layout

```
src/
  kintsugi.nim              -- entry point (REPL, file runner, compiler CLI)  171 lines
  core/
    types.nim               -- all value types (KtgValue variant object)      339 lines
    equality.nim            -- structural equality                             99 lines
  parse/
    lexer.nim               -- tokenizer for all datatypes                   392 lines
    parser.nim              -- token stream -> AST                            65 lines
  eval/
    evaluator.nim           -- the main eval loop                            977 lines
    natives.nim             -- all built-in functions                        1582 lines
    dialect.nim             -- dialect dispatch interface                      35 lines
  dialects/
    loop_dialect.nim        -- for/in/from/to/by/when/collect/fold/partition  204 lines
    parse_dialect.nim       -- PEG parser with backtracking                  698 lines
    match_dialect.nim       -- pattern matching with destructuring           213 lines
    attempt_dialect.nim     -- resilient pipelines                           284 lines
    object_dialect.nim      -- prototype objects with typed fields           278 lines
  emit/
    lua.nim                 -- Kintsugi AST -> Lua 5.1 source               2066 lines
```

### How the Evaluator Works

The evaluator (`eval/evaluator.nim`) walks a flat list of values left-to-right:

1. Encounter a value -- if it's a literal type (integer, string, etc.), return it
2. If it's a `word!`, look it up in the context chain. If the result is callable, consume N arguments from the stream and call it
3. After evaluating a value, check if the next value is an `op!` (infix operator). If so, consume the right operand and apply the operator
4. `set-word!` evaluates the RHS (including any infix), then binds the result in the **current** scope (always shadows, never writes through)
5. `paren!` evaluates its contents recursively
6. `block!` returns itself unevaluated (blocks are data until someone calls `do`)

Context chain: each scope has a parent pointer. Lookup walks up the chain. Set-word always creates in the current scope.

### How Dialects Work

Dialects are scoped vocabularies. When the evaluator encounters a dialect word (`loop`, `parse`, `match`, `attempt`, `object`), it hands the argument block to the dialect handler in `dialects/`. The dialect interprets the block's contents with its own rules -- keywords like `for`, `in`, `from`, `some`, `keep` only have special meaning inside their dialect.

The dispatch is in `eval/dialect.nim`. Each dialect module exports a proc that takes the block and the evaluator pointer and returns a `KtgValue`.

### How the Emitter Works

`emit/lua.nim` walks the AST and generates Lua 5.1 source. It handles:
- Variable declarations (`local`)
- Function definitions
- Object/make patterns
- Bindings (foreign API declarations)
- `->` chain operator (emits Lua `:` method calls)
- `@const` (emits `<const>` in Lua 5.4)
- Control flow, loops, match

The emitter is heuristic-based -- it pattern-matches on AST shapes rather than having a formal IR. This means some complex patterns (implicit returns in certain contexts, deeply nested expressions) may not emit correctly.

### How to Add a New Native Function

In `src/eval/natives.nim`:

```nim
ctx.native("my-func", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
  # args[0] and args[1] are the two arguments
  # ep is the evaluator pointer (cast to Evaluator if needed)
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

### How to Add a New Dialect

1. Create `src/dialects/my_dialect.nim`
2. Export a proc: `proc evalMyDialect*(body: seq[KtgValue], ep: pointer): KtgValue`
3. Register in `src/eval/dialect.nim`
4. Register the dialect word as a native in `natives.nim` that calls your dialect proc

---

## Key Design Decisions

The living spec is `docs/language-spec-questions.md` (34+ decisions documented). The most important ones:

1. **Contexts are universal** -- closures, objects, modules, scopes are all contexts. `context!` is mutable, `object!` is frozen.
2. **Set-word always shadows** -- `x: 5` inside a function creates a new local binding, never writes to the parent scope. Mutate shared state through context paths: `state/counter: state/counter + 1`.
3. **Dialects are scoped vocabularies** -- `for`, `in`, `some`, `keep` are only keywords inside their respective dialects. Outside, they're just words.
4. **No operator precedence** -- `2 + 3 * 4` evaluates to 20, not 14. Use parens.
5. **Only false and none are falsy** -- 0, "", and [] are truthy.
6. **Strings are immutable** -- no mutable string operations. Use `join`/`rejoin`.
7. **Try returns a result context** -- not the error itself. Access via path: `result/ok`, `result/message`.
8. **Objects use stamp model** -- `make` copies fields, no prototype chains, no delegation.
9. **Exports are body-level** -- `exports [...]` in the module body, not the header.
10. **Parse captures go into the result context** -- not the caller's scope.

---

## Known Limitations

- **Lua emitter** -- uses recursive binding tracking to distinguish functions from values. Foreign API calls (Love2D, Playdate) need `bindings` dialect to declare arities. Unknown paths default to field access.
- **`some`/`any` backtracking** -- greedy with backtracking like REBOL. Has exponential worst-case potential on pathological inputs (e.g., deeply nested alternatives with overlapping prefixes).
- **No LSP, no debugger, no formatter** -- editor support is Emacs syntax highlighting only.

---

## Next Steps

1. **Build Chronodistort** -- the autobattler game is the whole point of the language. Building a real game drives every future decision.
2. **Game dialects emerge from building the game** -- entity, scene, input, tween dialects should be discovered through actual game code, not designed in a vacuum.
3. **Lua emitter needs architectural rewrite** -- replace heuristic pattern-matching with a proper IR or at least a more systematic AST walk. This is the biggest technical debt.
4. **Self-hosting roadmap** -- lexer + parser + emitter in Kintsugi itself, estimated ~1000 lines. The parse dialect is already powerful enough for the lexer.
5. **Nim compiles to C** -- Playdate native embedding is possible (Playdate SDK is C-based). This is a real deployment target.
6. **`nim js` gives browser playground for free** -- Nim's JavaScript backend means a web REPL is achievable with minimal effort.

---

## How to Build and Test

```bash
nimble build    # release binary in bin/
nimble test     # run all tests (855 passing)
bin/kintsugi                          # REPL
bin/kintsugi file.ktg                 # run a file
bin/kintsugi -c file.ktg              # compile to Lua
bin/kintsugi -c file.ktg -o out.lua   # compile to specific output
bin/kintsugi -c file.ktg --stdout     # compile to stdout
```

---

## Key Files

| File | Purpose |
|------|---------|
| `docs/language-spec-questions.md` | The living spec (34+ decisions) |
| `examples/full-spec.ktg` | Executable spec (THE test -- 1,700 lines) |
| `lib/playdate.ktg` | Playdate SDK bindings |
| `lib/love2d.ktg` | LOVE2D bindings |
| `editors/emacs/kintsugi.el` | Emacs major mode |
| `examples/tic-tac-toe/` | Working game example (terminal + LOVE2D) |
| `examples/playdate-hello/` | Playdate SDK example |
| `docs/TODO.md` | Outstanding tasks |
| `docs/engineering-audit.md` | Code quality audit |
| `docs/language-design-audit.md` | Language design audit |
