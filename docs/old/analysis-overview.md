# Kintsugi: Codebase Overview

Updated 2026-04-08.

---

## What It Is

Kintsugi is a **homoiconic, dialect-driven programming language** that compiles to clean, zero-dependency Lua. It draws from REBOL/Red, Common Lisp, Lua, and Raku.

**Target:** Game development runtimes (LOVE2D, Playdate via Lua 5.4/LuaJIT), general-purpose scripting.

**Core thesis:** Blocks of data become programs. Code and data share the same representation — there is no separate AST; `seq[KtgValue]` is the universal IR.

---

## Vital Stats

| Metric | Value |
|--------|-------|
| Language | Nim |
| Source lines | ~9,280 |
| Source files | 17 |
| Test lines | ~9,960 |
| Test suites | ~80+ |
| Pipeline | Lexer → Parser → Evaluator (interpret) or Lua Emitter (compile) |
| Largest file | `src/emit/lua.nim` at 3,074 lines (33% of codebase) |

---

## Syntax in 60 Seconds

The entire grammar fits 6 categories — no keywords, no operator precedence:

```
word      — look up, maybe call:      print "hello"
word:     — bind a value:             x: 42
'word     — lit-word (symbol):        'north
:word     — get-word (raw lookup):    :some-var
@word     — meta-word (directive):    @type, @macro, @parse
[block]   — inert data:              [1 2 3]
(paren)   — evaluate immediately:    (1 + 2)
/refine   — modify behavior:         loop/collect, print/no-newline
```

Evaluation is **strict left-to-right** with no operator precedence. `2 + 3 * 4` is `(2 + 3) * 4 = 20`, not 14.

---

## 27 Value Types

Beyond JSON: money (`$12.50`), pairs (`100x200`), tuples (`1.2.3`), dates (`2026-03-15`), times (`14:30:00`), files (`%path/to/file`), URLs (`https://...`), emails (`user@host`), sets, prototypes.

---

## The Pipeline

### Layer 1: Lexer (`src/parse/lexer.nim`, 440 lines)

Hand-written, character-by-character. No regex. Discriminates between integers, floats, pairs, tuples, dates, times, money based on character patterns. Validates date ranges and time bounds. Outputs a flat `seq[KtgValue]`.

### Layer 2: Parser (`src/parse/parser.nim`, 71 lines)

Stack-based bracket nesting. Pushes containers on `[`/`(`, pops on `]`/`)`. Single-pass, no backtracking. Trivially small because the lexer does most of the work.

### Layer 3a: Interpreter (`src/eval/evaluator.nim`, 1,179 lines)

Tree-walking evaluator. Core loop: for each value, dispatch on type → lookup words → consume infix operators left-to-right → handle meta-words. Closures capture lexical scope via `KtgContext` parent chains. Recursion depth limited to 512.

### Layer 3b: Lua Emitter (`src/emit/lua.nim`, 3,074 lines)

Two-phase: **prescan** (discover function arities, bindings, exports) then **emit** (walk AST, produce Lua strings). Uses dispatch tables: 81 expression handlers + 6 statement handlers for native emission, with ~16 remaining elif branches for complex constructs (dialects, IIFE wrapping, pcall chains). Runtime helpers are tree-shaken — only used helpers appear in output.

---

## Five System Dialects

1. **Loop** (`loop_dialect.nim`, 211 lines) — `for/in`, `from/to/by`, with `/collect`, `/fold`, `/partition` refinements and `when` guards
2. **Match** (`match_dialect.nim`, 213 lines) — Pattern matching with type checks, lit-words, captures, destructuring, guards
3. **Parse** (`parse_dialect.nim`, 688 lines) — PEG-style parsing with backtracking. **Interpreter-only** — raises compile error in emitter
4. **Object/Prototype** (`object_dialect.nim`, 278 lines) — Prototype-based objects with typed fields, required/optional, auto-generated constructors and predicates
5. **Attempt** (`attempt_dialect.nim`, 286 lines) — Error-handling pipelines with `source`, `then`, `when`, `catch`, `fallback`, `retries`

---

## Module Structure

```
src/
  core/
    types.nim          (348 lines)   KtgValue variant, KtgContext, KtgFunc, KtgNative
    equality.nim       (99 lines)    10-rule deep equality

  parse/
    lexer.nim          (440 lines)   Character-by-character tokenizer
    parser.nim         (71 lines)    Stack-based bracket nesting

  eval/
    dialect.nim        (38 lines)    Dialect base type, Evaluator forward decl
    evaluator.nim      (1,179 lines) Tree-walking interpreter
    natives.nim        (1,029 lines) Built-in functions
    natives_math.nim   (215 lines)   Math functions
    natives_io.nim     (576 lines)   File I/O, modules, imports, system
    natives_convert.nim (188 lines)  Type conversions

  dialects/
    loop_dialect.nim   (211 lines)   Loop dialect
    match_dialect.nim  (213 lines)   Pattern matching
    parse_dialect.nim  (688 lines)   PEG parsing (interpreter-only)
    object_dialect.nim (278 lines)   Prototypes and objects
    attempt_dialect.nim (286 lines)  Error pipelines

  emit/
    lua.nim            (3,074 lines) AST → Lua transpiler (dispatch tables + 16 complex elif branches)

  kintsugi.nim         (346 lines)   CLI entry point, REPL, stdlib loading
```

---

## Key Architectural Decisions

1. **Homoiconic AST as IR.** No intermediate representation — both evaluator and emitter walk the same `seq[KtgValue]`. Enables `@compose` (code-as-data macros) naturally.

2. **No operator precedence.** Strict left-to-right. Parens for grouping. Simpler evaluator, simpler mental model, zero ambiguity.

3. **Dialects as natives, not syntax.** `loop`, `match`, `either`, `if` are functions hosting DSLs, not language constructs. Keeps the evaluator core lean.

4. **Type erasure in compilation.** Rich static types exist (`@type`, `is?`, guard clauses) but compiled Lua strips them. `@type` raises a compile error. Design choice: trust the programmer, smaller output.

5. **Zero-dependency Lua output.** Emitted code has no external requires. Prelude helpers are tree-shaken.

6. **Dispatch table emission.** Native emitters registered in tables, looked up by name. Adding a new native is one handler registration, not two 500-line proc edits.
