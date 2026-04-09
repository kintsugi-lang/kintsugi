# Engineering Audit — Modular Architecture & Maintainability

Audited: 2026-03-22
Codebase: ~11,000 lines TypeScript, 499 tests across 27 files

Audited from the perspective of a principal engineer evaluating this codebase for long-term health, contributor onboarding, and scalability as the language grows.

---

## Current Architecture Map

```
src/
  types.ts           (62 lines)   — Token + AST type definitions
  lexer.ts           (278 lines)  — Generator-based tokenizer
  parser.ts          (54 lines)   — Stack-based AST builder
  helpers.ts         (10 lines)   — lex + parse pipeline
  interpreter.ts     (145 lines)  — CLI REPL + file runner
  compiler.ts        (72 lines)   — Compilation CLI

  evaluator/
    evaluator.ts     (666 lines)  — Core interpreter loop
    values.ts        (239 lines)  — Runtime value types + conversion
    context.ts       (48 lines)   — Scope/environment chain
    functions.ts     (93 lines)   — Spec parsing + function creation
    type-check.ts    (177 lines)  — Type matching & validation
    natives.ts       (1224 lines) — ALL built-in functions, operators, dialects, type registration
    dialect-loop.ts  (261 lines)  — Loop dialect
    dialect-object.ts(66 lines)   — Object field parsing
    parse.ts         (400+ lines) — Parse dialect (PEG engine)
    require.ts       (175 lines)  — Module system

  compiler/
    ir.ts            (339 lines)  — IR type definitions
    lower.ts         (1714 lines) — AST -> IR transformation
    emit-lua.ts      (819 lines)  — IR -> Lua codegen
    errors.ts        — Compiler error types
    compile.ts       (14 lines)   — Pipeline entry
```

---

## Issue 1: `natives.ts` is a 1224-line monolith that does everything

This single file registers:
- Output functions (print, probe)
- Control flow (if, either, unless, all, any, loop, break, return)
- Infix operators (and, or)
- Block/series operations (length?, empty?, first, last, pick, copy, append, insert, remove, select, has?, index?)
- Type operations (type, to, make, context, object)
- String operations (join, rejoin, trim, split, uppercase, lowercase, replace)
- Math utilities (min, max, abs, negate, round, odd?, even?, codepoint, from-codepoint)
- Code-as-data (do, reduce, compose, set, apply, function, does)
- Error handling (error, try)
- Binding/introspection (bind, words-of)
- Match dialect (match + tryMatchPattern + matchValuesEqual)
- Attempt dialect (attempt + parseAttemptDialect + executeAttempt + createAttemptFunction)
- @type definition
- Type name registration (all 31 type names)
- Type predicate generation
- Logic aliases (on, off, yes, no)
- Time context (time/now)
- Header handling (Kintsugi)
- Module loading (require)
- Parse dialect registration

This is the single biggest maintainability problem in the codebase. Every change to any native function requires touching this file. Every contributor working on any feature will conflict with every other contributor in this file.

**Recommendation:** Split into domain files that each export a registration function:

```
evaluator/
  natives/
    index.ts          — registerNatives() that calls all sub-registrations
    output.ts          — print, probe
    control-flow.ts    — if, either, unless, all, any, loop, break, return, not
    operators.ts       — and, or
    series.ts          — length?, empty?, first, last, pick, copy, append, etc.
    types.ts           — type, to, make, is?, type predicates, type names
    strings.ts         — join, rejoin, trim, split, uppercase, lowercase, replace
    math.ts            — min, max, abs, negate, round, odd?, even?, codepoint
    homoiconic.ts      — do, reduce, compose, set, apply, bind, words-of
    functions.ts       — function, does (merge with existing functions.ts)
    errors.ts          — error, try, attempt
    match.ts           — match dialect (extract from natives)
    io.ts              — require, future read/write
```

Each file exports a `register(ctx, evaluator)` function. The index calls them all. This also makes it trivial to create "profiles" — a minimal evaluator for embedded use could skip certain groups.

---

## Issue 2: Three nearly identical equality functions

The codebase has three separate implementations of value equality:

1. **`valuesEqual`** in `evaluator.ts:597` — used by the `=` and `<>` operators
2. **`valEq`** in `natives.ts:970` — used by `select`, `has?`, `index?`
3. **`matchValuesEqual`** in `natives.ts:1055` — used by pattern matching

They differ in subtle ways:
- `valuesEqual` compares words, lit-words, and meta-words. Does NOT compare dates, blocks, pairs, tuples.
- `valEq` compares all word types (via `wordName` helper). Does NOT compare dates, blocks, pairs, tuples.
- `matchValuesEqual` compares lit-words, words, meta-words, plus cross-type word matching (`lit-word! = word!`). Does NOT compare dates, blocks, pairs, tuples.

This is a maintenance trap. When someone adds block equality (per the design audit), they'll fix one function and miss the other two. Or they'll fix two and the third will behave differently.

**Recommendation:** One canonical `valuesEqual(a, b): boolean` in `values.ts`, exported and used everywhere. Match-specific semantics (cross-type word matching) should be in the match dialect as a wrapper that calls the base function with a flag or handles the extra case.

---

## Issue 3: Runtime `require()` calls to break circular dependencies

Eight places in the evaluator use Node's `require()` at call time instead of top-level imports:

```
type-check.ts:113    -> require('./parse')
dialect-loop.ts:186  -> require('./values')     -- isTruthy
dialect-loop.ts:203  -> require('./values')     -- isTruthy
natives.ts:64        -> require('./dialect-loop')
natives.ts:463       -> require('./dialect-object')
natives.ts:673       -> require('./functions')
natives.ts:828       -> require('./require')
natives.ts:854       -> require('./parse')
```

This pattern exists because of circular dependencies:
```
natives.ts -> evaluator.ts (via Evaluator type)
evaluator.ts -> natives.ts (via registerNatives)
```

The runtime `require()` calls make the dependency graph opaque, bypass TypeScript's type checking, and are fragile — if module initialization order changes, things break silently.

**Recommendation:** Break the cycle by extracting the registration interface:

1. Define a `NativeRegistry` interface that `Evaluator` implements (or a thin adapter)
2. `natives.ts` depends on the interface, not the concrete `Evaluator` class
3. All dialect files import directly from `values.ts` and `context.ts` — no runtime requires
4. `dialect-loop.ts` importing `isTruthy` from `values.ts` via runtime require is especially egregious — `isTruthy` has no circular dependency, this is just a copy-paste artifact. Import it normally.

---

## Issue 4: 96 `as any` casts across the codebase

The most common pattern:
```typescript
(val as any).name      // on word-type values
(val as any).values    // on block-type values
(val as any).symbol    // on op-type values
```

This happens because functions receive `KtgValue` (the full union type) and then branch on `val.type` but TypeScript doesn't narrow the union inside the branch deeply enough — or the code doesn't use the narrowed binding.

**Recommendation:** Add type guard helpers in `values.ts`:

```typescript
export function isWord(v: KtgValue): v is KtgWord { return v.type === 'word!'; }
export function isBlock(v: KtgValue): v is KtgBlock { return v.type === 'block!'; }
export function isSetWord(v: KtgValue): v is KtgSetWord { return v.type === 'set-word!'; }
// etc.
```

Then use them in conditionals:
```typescript
// Before
if (v.type === 'word!' && (v as any).name === 'for') { ... }

// After
if (isWord(v) && v.name === 'for') { ... }
```

This is not about being pedantic — `as any` suppresses real type errors. If a `KtgValue` field is ever renamed, `as any` casts won't catch it. Type guards will.

---

## Issue 5: Duplicate spec parsing — interpreter vs compiler

Two separate implementations parse function specs:

- **`parseSpec()`** in `evaluator/functions.ts:7` — produces `FuncSpec { params: ParamSpec[], refinements, returnType }`
- **`parseSpecBlock()`** in `compiler/lower.ts:621` — produces `{ params: IRParam[], refinements, returnType: IRType }`

They parse the same syntax with the same logic but produce different output types. When one gets a bug fix or feature (like the `opt` keyword support, or element types), the other needs the same fix applied manually. The compiler's version is already missing features the interpreter's has (`opt`, element types).

**Recommendation:** Single spec parser in a shared location (e.g., `src/spec.ts` or `evaluator/functions.ts`) that produces a neutral intermediate representation. The compiler can then map `ParamSpec -> IRParam` in a trivial transform. This also guarantees that the interpreter and compiler agree on what a valid spec looks like.

---

## Issue 6: Module-level mutable state in the compiler

`emit-lua.ts:25-26`:
```typescript
let neededRuntime: Set<RuntimeChunk>;
let emitWarnings: string[];
```

These are module-scoped variables mutated during compilation. If `emitLua()` is ever called concurrently (e.g., compiling multiple modules in parallel), they'll corrupt each other. Even without concurrency, this makes the function non-reentrant — calling `emitLua` while processing a `require`'d module would break.

Similarly, `require.ts` has:
```typescript
const globalCache: ModuleCache = { ... };
const loading: Set<string> = new Set();
```

This is shared across all `Evaluator` instances in the process.

**Recommendation:**
- For `emit-lua.ts`: Pass an `EmitContext` object through all emit functions, or make `emitLua` create one locally and thread it through.
- For `require.ts`: Move the cache and loading set into the `Evaluator` instance (or a `Runtime` object that the evaluator owns). `resetRequireCache()` already exists for tests, which is a sign that the global state is causing problems.

---

## Issue 7: `lower.ts` is 1714 lines with hardcoded keyword dispatch

The lowering pass has:
- A `BUILTINS` arity table (40+ entries) that must stay in sync with `natives.ts`
- Inline keyword checks in `lowerNext()` for `if`, `either`, `unless`, `loop`, `break`, `return`, `match`, `error`, `try`, `attempt`, `do`, `bind`
- Inline keyword checks in `lowerAtom()` for `if`, `either`, `unless`, `function`, `context`, `compose`, `reduce`, `do`, `bind`, `words-of`, `all`, `any`, `apply`, `set`
- A separate `lowerLoop`, `lowerMatch`, `lowerIf`, `lowerEither`, `lowerUnless`, `lowerTry`, `lowerAttempt`, `lowerAll`, `lowerAny`, `lowerApply`, `lowerSet`, `lowerCompose`, `lowerReduce`, `lowerBind`, `lowerWordsOf` — each a standalone function

This is the compiler equivalent of the natives.ts problem. Adding a new native that requires special lowering means touching the arity table, adding a keyword check in lowerNext and/or lowerAtom, and writing a lowerXxx function — all in one file.

**Recommendation:** Split lowering into:
```
compiler/
  lower/
    index.ts           — lowerBlock, lowerNext, lowerExpr, lowerAtom (the skeleton)
    control-flow.ts    — lowerIf, lowerEither, lowerUnless, lowerLoop, lowerMatch
    functions.ts       — lowerFunctionExpr, lowerContextExpr, lowerCallable
    homoiconic.ts      — lowerCompose, lowerReduce, lowerBind, lowerWordsOf
    errors.ts          — lowerError, lowerTry, lowerTryHandle, lowerAttempt
    builtins.ts        — BUILTINS arity table + type predicate registration
```

Each file exports a `Map<string, LowerFn>` or similar dispatch table. The main lowerer looks up the keyword in the table instead of an if-chain. Adding a new keyword becomes: add to the table in the relevant file. No conflicts.

---

## Issue 8: The lexer silently drops unrecognized characters

`lexer.ts:274`:
```typescript
// Fallback for anything we didn't catch
advance();
```

If the lexer encounters a character it doesn't understand (say `~` in certain positions, or Unicode beyond ASCII), it silently skips it. No error, no warning, no `STUB` token. The user's code just silently changes meaning.

**Recommendation:** Emit a `STUB` token with the offending character, or throw a `LexError`. For a scripting language targeting non-experts, "your code was silently mangled" is worse than "syntax error at character X".

---

## Issue 9: No shared test helpers — test files re-implement setup patterns

Looking across the 27 test files, most of them repeat this pattern:
```typescript
const evaluator = new Evaluator();
evaluator.evalString(code);
// ... check evaluator.output or returned value
```

There's no shared test harness that provides a standard way to run code and check results.

Each test file sets up its own evaluator and does its own assertions. This isn't a critical problem, but it increases the friction of writing new tests and leads to inconsistent error-checking patterns across test files.

**Recommendation:** A `tests/helpers.ts` with shared utilities for running Kintsugi code, checking output, and asserting on errors.

---

## Issue 10: The `Evaluator.output` Proxy pattern is fragile

`interpreter.ts:19-31` uses a `Proxy` on the `output` array to intercept `push` calls and log to console:

```typescript
evaluator.output = new Proxy(evaluator.output, {
  get(target, prop) {
    if (prop === 'push') {
      return (...items: string[]) => {
        for (const item of items) console.log(item);
        return originalPush(...items);
      };
    }
    return (target as any)[prop];
  },
});
```

This is clever but it:
- Breaks if any code accesses `output` via a method other than `push` (e.g., `splice`, `unshift`, direct index assignment)
- Doesn't intercept the output accumulation — only adds console logging as a side effect
- Makes the evaluator's output mechanism invisible to anyone reading `evaluator.ts`

**Recommendation:** Replace with a simple callback or event:
```typescript
class Evaluator {
  public onOutput?: (line: string) => void;

  print(value: string): void {
    this.output.push(value);
    this.onOutput?.(value);
  }
}
```

Then in the interpreter: `evaluator.onOutput = console.log;`

This is explicit, discoverable, and doesn't rely on Proxy behavior.

---

## Summary: Structural Priorities

| Priority | Issue | Effort | Impact |
|----------|-------|--------|--------|
| 1 | Split `natives.ts` into domain files | Medium | High — every contributor touches this file |
| 2 | Unify the three equality functions | Small | Medium — prevents future inconsistency |
| 3 | Replace runtime `require()` with proper imports | Medium | Medium — makes dependency graph explicit |
| 4 | Add type guards to replace `as any` | Medium | Medium — catches real bugs at compile time |
| 5 | Split `lower.ts` into domain files | Medium | Medium — same problem as natives.ts |
| 6 | Move mutable state into instance objects | Small | Medium — enables embedding and testing |
| 7 | Unify spec parsing | Small | Small — but prevents interpreter/compiler drift |
| 8 | Fix lexer silent drop | Small | Small — but prevents user confusion |
| 9 | Shared test helpers | Small | Small — reduces test friction |
| 10 | Replace Proxy with callback | Small | Small — but improves readability |

The codebase is in good shape for its size and maturity. The architecture (lexer -> parser -> AST -> evaluator with dialects, or AST -> IR -> emitter) is sound and well-separated at the phase level. The issues above are about internal modularity within those phases — making the code match the conceptual boundaries that already exist in your head.
