# Kintsugi Architectural Breakdown

A junior-engineer-friendly guide to the entire codebase. Every file, every major function, what it does, and where to make changes.

## Overview

Kintsugi is a REBOL/Red-inspired programming language that operates in two modes:
1. **Interpreter**: Lex → Parse → Evaluate (tree-walking)
2. **Compiler**: Lex → Parse → Preprocess → Emit Lua source code

The AST (`seq[KtgValue]`) is the only IR. Both the evaluator and emitter walk the same data structure — this is the homoiconic design.

**Total: ~9,230 lines of Nim across 17 source files.**

---

## Layer 1: Core Types (`src/core/` — 447 lines)

### `types.nim` (348 lines)
The foundation of everything. Defines the entire value system.

| Construct                                    | Purpose                                                                                                                                                                                     | Lines   |
|----------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------|
| `WordKind` enum                              | 5 word subtypes: `wkWord`, `wkSetWord`, `wkGetWord`, `wkLitWord`, `wkMetaWord`                                                                                                              | 4-9     |
| `ValueKind` enum                             | 23 value types (integer, float, string, block, context, function, etc.)                                                                                                                     | 11-35   |
| `KtgValue`                                   | **The central data structure.** Variant object — every value in the language is one of these. Has `line` for error reporting, `boundCtx` for closures, `customType` for user-defined types. | 43-78   |
| `KtgContext`                                 | Scope/environment — an ordered table of name→value with a parent pointer for lexical scoping.                                                                                               | 80-82   |
| `FieldSpec` / `ParamSpec` / `RefinementSpec` | Metadata for prototype fields and function parameters.                                                                                                                                      | 84-103  |
| `KtgFunc`                                    | User-defined function: params, refinements, return type, body (as `seq[KtgValue]`), and closure context.                                                                                    | 105-110 |
| `KtgNative`                                  | Built-in function: name, arity, proc pointer, refinements.                                                                                                                                  | 114-118 |
| `KtgError`                                   | Error type with kind (string), message, data payload, and stack trace.                                                                                                                      | 125-128 |
| Value constructors                           | `ktgInt`, `ktgFloat`, `ktgString`, `ktgBlock`, `ktgWord`, etc. — convenience factories.                                                                                                     | 133-173 |
| Context operations                           | `newContext`, `get` (walks parent chain), `set` (current scope), `setThrough` (write-through to parent), `has`, `child`.                                                                    | 178-218 |
| `isTruthy`                                   | Only `false` and `none` are falsy.                                                                                                                                                          | 244-249 |
| `typeName`                                   | Returns the type name string (e.g., `"integer!"`) for any value.                                                                                                                            | 254-285 |
| `$` (display)                                | String representation for all value types.                                                                                                                                                  | 290-349 |

**To make changes here:** Adding a new value type requires updating `ValueKind`, adding a branch to `KtgValue`, adding a constructor, updating `typeName`, `$`, and `valuesEqual`. Then update the lexer, evaluator, emitter, and `natives_convert.nim` for `to` conversions.

### `equality.nim` (99 lines)
Single function `valuesEqual` implementing 10 equality rules from the spec. Cross-type numeric comparison (int/float), structural deep comparison for blocks/maps/contexts, case-sensitive strings, case-insensitive words, identity comparison for functions.

---

## Layer 2: Parsing (`src/parse/` — 502 lines)

### `lexer.nim` (431 lines)
Hand-written character-by-character lexer. No regular expressions.

| Function                                             | Purpose                                                                                                                                                                                                                                                         |
|------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `newLexer` / `atEnd` / `peek` / `peekAt` / `advance` | Cursor management                                                                                                                                                                                                                                               |
| `skipWhitespace`                                     | Handles `;` comments and whitespace                                                                                                                                                                                                                             |
| `readString` / `readBraceString`                     | `"..."` with escape sequences, `{...}` with nesting                                                                                                                                                                                                             |
| `readNumber`                                         | Integers, floats, pairs (`100x200`), tuples (`1.2.3`), dates (`2026-03-15`), times (`14:30:00`) — all from one entry point based on lookahead                                                                                                                   |
| `readWord`                                           | Word characters + path segments (`obj/field/sub`, `obj/:dynamic`, `obj/1`)                                                                                                                                                                                      |
| `readFilePath`                                       | `%path/to/file` or `%"path with spaces"`                                                                                                                                                                                                                        |
| `readMoney`                                          | `$12.50` → cents-based integer                                                                                                                                                                                                                                  |
| `nextToken`                                          | **The main dispatch.** 15+ branches based on first character: strings, blocks `[]`, parens `()`, money `$`, files `%`, numbers, operators, get-words `:word`, lit-words `'word`, meta-words `@word`, set-words `word:`, URLs `word://...`, emails `word@domain` |
| `tokenize`                                           | Loop calling `nextToken` until nil                                                                                                                                                                                                                              |

**To make changes here:** Adding a new literal type means adding a branch in `nextToken` and possibly a new `read*` proc. The lexer is pure — no side effects, no state beyond position/line.

### `parser.nim` (71 lines)
Stack-based nesting of tokens into blocks and parens. Extremely simple:
- `[` pushes a new container onto the stack
- `]` pops and wraps as `vkBlock`
- `(` / `)` same for `vkParen`
- Everything else is appended to the current container
- `parseSource` = `tokenize` then `parse` — the only function most code calls

---

## Layer 3: Evaluation (`src/eval/` — 2,283 lines)

### `dialect.nim` (38 lines)
Base class for dialects. Defines the `Evaluator` type (the central interpreter state) and the `Dialect` base object with a virtual `interpret` method. Also defines `isCallable` and `isInfix` helpers.

Key `Evaluator` fields:
- `global` / `currentCtx` — scope chain
- `currentRefinements` — active refinements for current call
- `output` — captured print output (for testing)
- `callStack` — for error traces
- `dialects` — registered dialect interpreters
- `moduleCache` / `moduleLoading` — import cycle detection
- `globals` / `macros` — sets of words with special behavior
- `parseFn` — function pointer to the parse dialect (avoids circular imports)

### `evaluator.nim` (1,206 lines)
**The heart of the interpreter.** Tree-walking evaluator.

| Function                                                   | Purpose                                                                                                                                                                                                                                                                                                                                                     | Lines     |
|------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------|
| `applyOp`                                                  | All infix operators: `+`, `-`, `*`, `/`, `%`, `=`, `==`, `<>`, `<`, `>`, `<=`, `>=` for numbers, money, pairs, strings, dates, times.                                                                                                                                                                                                                       | 63-219    |
| `applyInfix`                                               | Left-to-right infix consumption loop. Also handles `->` method chains and `and`/`or` short-circuit.                                                                                                                                                                                                                                                         | 222-269   |
| `navigatePath` / `parsePath`                               | Path navigation: `obj/field/sub`, dynamic segments `obj/:var`, tuple/pair indexing.                                                                                                                                                                                                                                                                         | 274-345   |
| `evalNext`                                                 | **The core dispatch.** Evaluates one expression from the value stream. Handles: scalars (return self), blocks (copy), parens (evaluate), words (lookup + call), set-words (assignment with path support, prototype auto-generation), get-words (raw lookup), lit-words (symbol), meta-words (`@type`, `@const`, `@global`, `@macro`, `@compose`, `@parse`). | 350-796   |
| `evalBlock`                                                | Evaluates a sequence of values. Handles `@enter`/`@exit` lifecycle hooks. The main loop: `evalNext` + `applyInfix` until end.                                                                                                                                                                                                                               | 798-848   |
| `matchesCustomType` / `typeMatches` / `typeMatchesBuiltin` | Custom type checking: enum types, structural types, union types, guard clauses.                                                                                                                                                                                                                                                                             | 853-1005  |
| `callCallable`                                             | Calls a function or native: collects args (with infix), type-checks params, creates scope, binds refinements, handles return signals.                                                                                                                                                                                                                       | 1007-1128 |
| `preprocess`                                               | Walks AST for `@preprocess` and `@inline` blocks — compile-time code generation.                                                                                                                                                                                                                                                                            | 1131-1192 |
| `evalString`                                               | Convenience: parse + preprocess + evalBlock.                                                                                                                                                                                                                                                                                                                | 1197-1200 |

**To make changes here:** This is where language semantics live. Adding a new control flow construct means adding a branch in `evalNext`. Adding a new meta-word means a branch in the `wkMetaWord` section (~lines 658-796). The evaluator is the most complex file and the most likely to need changes.

### `natives.nim` (1,045 lines)
All built-in functions registered on the global context.

| Section              | Functions                                                                                                                                  | Lines     |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------|-----------|
| Output               | `print`, `probe`                                                                                                                           | 41-65     |
| Control flow         | `if`, `either`, `unless`, `not`, `return`, `break`                                                                                         | 69-107    |
| Type introspection   | `type`, all `?` predicates, `is?` (unified type check)                                                                                     | 110-210   |
| Series operations    | `size?`, `length?`, `empty?`, `first`, `second`, `last`, `pick`, `append`, `copy`, `insert`, `remove`, `select`, `has?`, `find`, `reverse` | 212-485   |
| String operations    | `join`, `rejoin`, `trim`, `uppercase`, `lowercase`, `starts-with?`, `ends-with?`, `pad`, `split`, `replace`, `substring`                   | 487-626   |
| Block evaluation     | `scope`, `reduce`, `all`, `any`, `words-of`                                                                                                | 628-691   |
| Context manipulation | `merge`, `context`                                                                                                                         | 693-731   |
| Function creation    | `function` (spec parser + closure capture), `does`                                                                                         | 736-810   |
| Error handling       | `error`, `try` (with `/handle` refinement), `rethrow`                                                                                      | 812-893   |
| Destructuring        | `set` (with `@rest` support)                                                                                                               | 895-931   |
| Apply / Sort         | `apply`, `sort` (with `/by` key function)                                                                                                  | 934-998   |
| Make / Sets          | Delegated to `object_dialect.nim`, plus `charset`, `union`, `intersect`                                                                    | 1005-1035 |

### `natives_math.nim` (215 lines)
Math natives: `abs`, `negate`, `min`, `max`, `round` (with `/down`, `/up`), `odd?`, `even?`, `sqrt`, trig (`sin`, `cos`, `tan`, `asin`, `acos`, `atan2`), `pow`, `exp`, `log`, `log10`, `to-degrees`, `to-radians`, `floor`, `ceil`, `pi`, `random` (with `/int`, `/range`, `/choice`, `/seed`).

### `natives_io.nim` (576 lines)
I/O and system natives:
- `byte` / `char` — character code conversion
- `read` (with `/dir`, `/lines`, `/stdin`) / `write` — file I/O
- `dir?` / `file?` — filesystem predicates
- `exit` — process exit
- `now`, `time/*`, `date/*` — temporal operations
- `load` (with `/eval`, `/header`) / `save` — data serialization
- `import` (with `/fresh`, module caching, cycle detection) / `exports`
- `bindings` — compile-time FFI declarations (interpreter stubs)
- `system` — platform/env context
- `capture` — declarative keyword extraction from blocks

### `natives_convert.nim` (188 lines)
The `to` function for type conversions between all 17+ types. Handles `integer!`, `float!`, `string!`, `block!`, `money!`, `pair!`, `word!`, `set-word!`, `lit-word!`, `get-word!`, `meta-word!`, `logic!`, `time!`, `date!`, `tuple!`, `file!`, `url!`, `email!`.

---

## Layer 4: Dialects (`src/dialects/` — 1,676 lines)

### `loop_dialect.nim` (211 lines)
Loop dialect registered as "loop". Three modes:
- **Infinite**: `loop [body]` — `while true`
- **For-in**: `loop [for [v] in series do [body]]` — iteration over blocks
- **From-to**: `loop [for [i] from N to M by S do [body]]` — numeric range

Refinements: `/collect` (map), `/fold` (reduce), `/partition` (split by predicate). Supports `when` guards and `break`.

### `match_dialect.nim` (213 lines)
Pattern matching registered as native `match`. Rules block contains `[pattern] [handler]` pairs with optional `when [guard]` and `default:` fallback. Pattern elements: literals (exact match), bare words (capture), `type!` (type match), `'word` (symbol match), `_` (wildcard), `(expr)` (computed match), nested blocks (destructuring).

### `object_dialect.nim` (278 lines)
Prototype-based object system. Three key pieces:
- `prototype` native: parses field declarations (`field/required`, `field/optional`, `fields` bulk), evaluates method body, returns frozen `KtgPrototype`
- `make` native: stamps instances from prototypes/contexts, applies overrides with type checking, validates required fields, binds `self` in all methods
- Also handles `make map! [...]` and `make set! [...]`

Auto-generation on assignment: `Person: prototype [...]` auto-creates `person!` type, `person?` predicate, `make-person` constructor.

### `attempt_dialect.nim` (286 lines)
Resilient pipeline dialect. Keywords: `source`, `then`, `when`, `catch`, `fallback`, `retries`. Two modes: immediate (with `source`) or returns a reusable pipeline function (without `source`). Error handlers match by kind string.

### `parse_dialect.nim` (688 lines)
PEG-style parsing dialect with backtracking. Two modes: string parsing (character-level) and block parsing (value-level). Combinators: `some` (1+), `any` (0+), `opt`, `not`, `ahead`, `to`, `thru`, `keep`, `collect`, `into`, `quote`, `skip`, `end`, `break`, `fail`. Set-words capture matched content. Alternation with `|`. Returns context with `ok` field and captures.

---

## Layer 5: Lua Emitter (`src/emit/lua.nim` — 2,991 lines)

**The largest file by far (32% of the codebase).** A direct AST-to-Lua-string transpiler.

| Section              | Purpose                                                                                                              | Lines     |
|----------------------|----------------------------------------------------------------------------------------------------------------------|-----------|
| Helpers              | `sanitize` (name conversion), `luaEscape`, `pad`, `luaName`, `resolvedName`                                          | 60-268    |
| Native arity table   | `initNativeBindings` — hardcoded arity for every built-in so the emitter knows how many args to consume              | 122-243   |
| Literal emission     | `emitLiteral`, `emitBlockLiteral`, `emitContextBlock`                                                                | 319-383   |
| Function spec parser | `parseSpec`, `allLuaParams`, `emitFuncDef` — shared between expression and statement contexts                        | 389-469   |
| Loop emission        | `emitLoop`, `emitLoopBody` — translates loop dialect to Lua `for`/`while`                                            | 475-677   |
| Match emission       | `emitMatchStmt` (if-chain), `emitMatchExpr` (IIFE)                                                                   | 682-911   |
| Either emission      | `emitEitherExpr` — ternary or IIFE                                                                                   | 917-952   |
| Attempt emission     | `emitAttemptExpr` — pcall-based pipeline                                                                             | 958-1096  |
| Type predicates      | `isTypePredicate`, `emitTypePredicateCall` — inline Lua type checks                                                  | 1115-1153 |
| **`emitExpr`**       | **The core expression emitter.** 750+ lines of `elif` chains handling every word/native as a special case.           | 1159-1964 |
| `emitExprWithChain`  | Extends `emitExpr` with `->` method chain support                                                                    | 1966-1991 |
| `findLastStmtStart`  | Dry-run to find where the last statement starts (for implicit return)                                                | 1997-2107 |
| `emitLastWithReturn` | Emit the last statement with `return`                                                                                | 2109-2201 |
| `emitBlock`          | **The statement emitter.** Another 400+ lines of special cases for statement-level constructs.                       | 2203-2677 |
| Prelude              | Runtime helpers: `_NONE`/`_is_none`, `_deep_copy`, `_capture`, `_append`, `_split`                                   | 2686-2763 |
| Prescan              | `prescanBindings`, `prescanBlock` — walks AST before emission to discover function arities, bindings, module exports | 2780-2938 |
| Public API           | `emitLua` (entrypoint), `emitLuaModule` (module with exports)                                                        | 2953-2991 |

**To make changes here:** Adding support for a new native in the compiler means: (1) add to `initNativeBindings` arity table, (2) add an `elif` branch in `emitExpr`, (3) possibly add a statement-level branch in `emitBlock`. Adding a helper means adding a `const Prelude*` and updating `buildPrelude`.

---

## Layer 6: CLI Entry Point (`src/kintsugi.nim` — 346 lines)

| Function                                    | Purpose                                                                 |
|---------------------------------------------|-------------------------------------------------------------------------|
| `hasHeader` / `stripHeader` / `parseHeader` | Parse `Kintsugi [...]` file headers with `using` blocks                 |
| `loadStdlib`                                | Loads `lib/math.ktg` and `lib/collections.ktg` into `std` context       |
| `applyUsing`                                | Unwraps stdlib modules into global scope                                |
| `setupEval`                                 | Creates evaluator, registers all natives and dialects                   |
| `repl`                                      | Interactive REPL loop                                                   |
| `runFile` / `runSingleFile`                 | Interpret `.ktg` files (single or directory)                            |
| `compileOne` / `compilePath` / `dryRunPath` | Compile to Lua                                                          |
| `main`                                      | CLI arg parser: `-e` (eval), `-c` (compile), `-o` (output), `--dry-run` |

---

## Data Flow Summary

```
Source text
    → Lexer (lexer.nim) → seq[KtgValue] (flat token stream)
    → Parser (parser.nim) → seq[KtgValue] (nested blocks/parens)
    ├─ Interpreter path:
    │   → Preprocessor (evaluator.nim:preprocess) → seq[KtgValue]
    │   → Evaluator (evaluator.nim:evalBlock) → KtgValue result
    └─ Compiler path:
        → Preprocessor (evaluator.nim:preprocess) → seq[KtgValue]
        → Prescan (lua.nim:prescanBlock) → populates arity/binding tables
        → Emitter (lua.nim:emitBlock) → Lua source string
```
