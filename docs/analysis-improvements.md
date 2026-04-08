# Kintsugi: Improvement Analysis

Updated 2026-04-08. Reflects work done on dispatch tables, test coverage, bug fixes, and refactoring.

---

## 1. Architecture

### 1.1 Emitter Dispatch Tables (DONE)

`src/emit/lua.nim` (3,074 lines) now uses dispatch tables for native emission:
- 81 expression handlers in `exprHandlers`
- 6 statement handlers in `stmtHandlers`
- Expression handlers auto-wrap as statements via `e.ln()` fallback
- Remaining elif chain: ~16 complex branches (dialects, IIFE wrapping, pcall chains)

Adding a new simple native now means registering one handler instead of touching two 500+ line procs.

### 1.2 Duplicated Parsers (OPEN)

Three independent implementations of the function spec parser still exist. Similarly, the loop spec grammar is parsed twice (interpreter + emitter). These are sync bugs waiting to happen. See S2 and S7 in `docs/simplification.md`.

### 1.3 Arity Table (OPEN)

The ~120-line hardcoded arity table in `lua.nim` must be manually kept in sync with `natives.nim`. See S5 in `docs/simplification.md`.

### 1.4 What's Good

- Clean layering: core → parse → eval → dialects → emit. No circular dependencies.
- Homoiconic design: same `seq[KtgValue]` for interpreter and emitter.
- Dialect isolation: modular and independently testable.
- Module system: cycle detection, caching, export tracking.
- Dispatch tables: adding new natives is now straightforward.

---

## 2. Code Quality

### 2.1 Completed Refactors

- **`compareValues`** — 4 one-liners replace 60 lines of duplicated comparison logic
- **`seriesAt`** — `first`/`second`/`last`/`pick` are thin wrappers over shared helper
- **`withCapture`** — 18 save/restore sites use clean template

### 2.2 Remaining Opportunities

See `docs/simplification.md` for S6 (match pattern compiler), S8 (IO accessor factory), S11 (merge context/prototype), S12 (shared path resolution).

---

## 3. Testing

### 3.1 Current Coverage

| File | Lines | Suites | Notes |
|------|-------|--------|-------|
| `test_lua.nim` | 387 | 11 | Series, strings, math, control flow, binding tracking, refinements, imports |
| `test_cross_mode.nim` | 502 | 15 | Runs via luajit. 70 tests covering arithmetic, control flow, series, strings, math, contexts, loops, match, try |
| `test_evaluator.nim` | 283 | 8 | Arithmetic, variables, strings, functions, comparisons, series safety, @macro, recursion limit |
| Other test files | ~8,900 | ~50+ | Ported tests, dialects, custom types, stdlib, parse dialect, objects, etc. |
| **Total** | ~9,962 | ~80+ | |

### 3.2 Remaining Gaps

- **Error path coverage** — Division by zero, type mismatches, circular imports, malformed lexer input are lightly tested
- **Untested features** — `bindings` (FFI stub), `@preprocess`, lifecycle hooks (`@enter`/`@exit`)
- **Cross-mode skipped tests** — 3 tests skipped for real parity bugs: closure return calls, get-word function args, loop/fold accumulator

---

## 4. Robustness

### 4.1 Completed

- **Recursion depth limit** — `callStack.len > 512` check at both native and function call sites
- **Time validation** — Hours 0-23, minutes 0-59, seconds 0-59
- **Substring validation** — Negative length rejected
- **Emitter error handling** — `compileError` raises `EmitError` for interpreter-only features (`@parse`, `@type`, sourceless `attempt`, `prototype`)

### 4.2 Open

- **Parser error recovery** — One error stops the whole file. Skip-to-next-bracket recovery would let the REPL report multiple errors at once. Nice-to-have for game dev iteration speed.

---

## 5. Feature Completeness

### 5.1 Interpreter-Only Features (by design)

These raise `compileError` in the emitter:
- `@parse` dialect (688 lines of interpreter code)
- `@type` custom type definitions
- `prototype` definitions
- `attempt` without `source`

### 5.2 Emitter Handles Core Language Well

- Function definitions and closures
- Loop dialect (all three modes + collect/fold/partition)
- Match dialect (type checks, literals, captures, destructuring)
- `either`/`if`/`unless` control flow (IIFE for expression context)
- Series operations with deep equality helpers
- String operations with literal pattern matching
- Math operations
- Module imports and exports
- `sort/by`, `set`/`@rest` destructuring

### 5.3 Known Cross-Mode Parity Gaps

- Returned closures not called correctly in some cases
- Get-word function argument passing
- `loop/fold` accumulator handling

---

## 6. Recommended Next Steps

1. **S2 + S5 + S7** — Eliminate sync points between interpreter and emitter (spec parser, arity table, loop parser). Highest value remaining refactors.
2. **S6 + S8 + S12** — Medium-value deduplication (match compiler, IO accessors, path resolution).
3. **Error path tests** — Fill gaps in edge case coverage.
4. **S11** — Merge context/prototype. High-risk, do last or skip.
