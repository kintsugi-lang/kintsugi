# Kintsugi: Bug Analysis

Comprehensive bug report combining the 15 documented bugs (B1-B15 from `bugs-and-gaps.md`) with newly discovered issues (N1-N5). Ordered by severity.

---

## Previously Documented Bugs (B1-B15)

These are tracked in `docs/bugs-and-gaps.md`. Summary for reference:

| ID | Severity | File | Issue |
|----|----------|------|-------|
| B1 | **HIGH** | lua.nim:1658 | `has?` emitter uses table key lookup, not linear scan |
| B2 | **HIGH** | lua.nim:1662 | `find` emitter uses Lua `==`, not deep equality |
| B3 | **HIGH** | lua.nim:1598 | `replace` emitter doesn't escape Lua pattern metacharacters |
| B4 | MEDIUM | lua.nim:917 | `either` ternary fails when true branch is `false`/`nil` |
| B5 | MEDIUM | lua.nim:1653 | `select` emitter only works for maps, not flat blocks |
| B6 | MEDIUM | lua.nim (meta) | `@parse` has no emitter — emits `nil` with compile error |
| B7 | MEDIUM | lua.nim:1017 | `attempt` without `source` emits `nil` silently |
| B8 | MEDIUM | lua.nim (missing) | `prototype` has no dedicated emitter branch |
| B9 | MEDIUM | natives.nim:11 | `deepCopyValue` incomplete for maps/sets/prototypes |
| B10 | LOW | natives.nim:214 | `size?` and `length?` are 100% duplicated code |
| B11 | MEDIUM | lua.nim:1638 | `copy` emitter only works for array-like tables |
| B12 | LOW | lua.nim:1833 | `apply` emitter may lack `unpack` definition in Lua 5.4 |
| B13 | LOW | evaluator.nim:153 | Comparison operators have implicit fallthrough control flow |
| B14 | LOW | lua.nim:765 | Match emitter doesn't support multi-element destructuring |
| B15 | LOW | evaluator.nim:748 | `@macro` untested and has no emitter support |

---

## Newly Discovered Bugs

### N1. Time literal parsing accepts invalid values (no bounds checking)

**File:** `src/parse/lexer.nim:163-166`
**Severity:** Medium — silently accepts invalid times

The date parser validates month (1-12) and day (1-31) at lines 182-185, but the time parser applies **no bounds checking** before casting to `uint8`:

```nim
let h = if parts.len > 0 and parts[0].len > 0: uint8(parseInt(parts[0])) else: 0'u8
let m = if parts.len > 1 and parts[1].len > 0: uint8(parseInt(parts[1])) else: 0'u8
let s = if parts.len > 2 and parts[2].len > 0: uint8(parseInt(parts[2])) else: 0'u8
```

Input `25:61:99` silently creates a time with hour=25, minute=61, second=99. Since `uint8` holds 0-255, there's no overflow — just semantically invalid data that propagates silently.

**Fix:** Add the same style of bounds checking that dates already have:
```nim
let hVal = parseInt(parts[0])
if hVal < 0 or hVal > 23:
  raise KtgError(kind: "syntax", msg: "hour out of range (0-23): " & parts[0], data: nil)
let h = uint8(hVal)
# same for minutes (0-59) and seconds (0-59)
```

---

### N2. `substring` doesn't handle negative length

**File:** `src/eval/natives.nim:620-626`
**Severity:** Low — returns empty string instead of erroring

```nim
let start = int(args[1].intVal) - 1  # 1-based
let length = int(args[2].intVal)
let s = args[0].strVal
if start < 0 or start >= s.len:
  raise KtgError(kind: "range", msg: "substring start out of range", data: args[1])
let endIdx = min(start + length, s.len)
ktgString(s[start ..< endIdx])
```

If `length` is negative, `endIdx` becomes `start + (negative) < start`. Nim's `s[5 ..< 3]` returns `""` rather than crashing, but silently returning empty for `substring "hello" 2 -1` is misleading. Other languages either error or have defined semantics (e.g., "from end").

**Fix:** Add early check: `if length < 0: raise KtgError(kind: "range", msg: "substring length must be non-negative", data: args[2])`

---

### N3. No recursion depth limit in evaluator

**File:** `src/eval/evaluator.nim` — `evalBlock` / `evalNext` / `callCallable`
**Severity:** Medium — stack overflow on deep recursion

The parser has `MaxNestingDepth = 256` (parser.nim:10), but the evaluator has no equivalent guard. Recursive user code can overflow the Nim call stack:

```
; This will crash the interpreter with a stack overflow
inf: function [] [inf]
inf
```

The evaluator tracks `callStack` (line ~881) for error reporting, but never checks its depth.

**Fix:** Check `callStack.len` at function entry and raise a KtgError when exceeding a limit (e.g., 512):
```nim
if eval.callStack.len > MaxCallDepth:
  raise KtgError(kind: "stack", msg: "stack overflow: recursion depth exceeded " & $MaxCallDepth, data: nil)
```

---

### N4. Interpreter/emitter parity gaps beyond documented bugs

**Severity:** Various — these are semantic mismatches between interpret and compile modes

Beyond B1-B8/B11-B14, there are additional parity gaps found by tracing through the emitter:

1. **`sort/by` refinement** — The interpreter supports `sort/by [block] [key-fn]` (natives.nim:957-998), but the emitter's handling of `sort` (lua.nim) doesn't account for the `/by` refinement. Compiled `sort/by` would likely emit incorrect or broken Lua.

2. **`set` destructuring with `@rest`** — The interpreter handles `set [a b @rest] [1 2 3 4 5]` (natives.nim:895-931) with rest-collection. The emitter would need to generate multiple local assignments plus a table slice, which may not be implemented.

3. **Custom type predicates** — `@type` generates runtime predicates (e.g., `person?`) in the interpreter. The emitter erases types, so these predicates don't exist in compiled output. Code relying on runtime type checking via custom types silently breaks.

---

### N5. `scope` native silently returns `none` on non-block input after error

**File:** `src/eval/natives.nim:631-636`
**Severity:** Low — error handling is correct but worth noting

The `scope` native raises on non-block input (line 634), which is correct. But if the block evaluates to no result (empty block), the return value is whatever `evalBlock` returns for an empty sequence — which is `ktgNone()`. This is consistent behavior, just undocumented.

Not a bug per se, but worth noting that `scope []` returns `none` and this should be the documented contract.

---

## Bug Severity Summary

**Critical path bugs (will produce wrong compiled output):**
- B1, B2, B3 — series operations in emitter have semantic mismatches
- B4 — `either` ternary fails on falsy true-branches
- B8 — `prototype` has no emitter branch at all

**Silent failures (code compiles but doesn't work correctly):**
- B5, B7, B11 — various emitter features produce wrong/incomplete Lua
- N4 — additional parity gaps (sort/by, set/@rest, custom type predicates)

**Input validation (malformed data accepted):**
- N1 — time literals accept invalid hours/minutes/seconds
- N2 — substring with negative length silently returns empty

**Robustness (interpreter can crash):**
- N3 — no recursion depth limit → stack overflow

**Code quality (correct but confusing):**
- B9, B10, B13, B15 — incomplete implementations, duplication, unclear control flow
