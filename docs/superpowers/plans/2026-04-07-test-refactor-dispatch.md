# Test Coverage, Quick Refactors, and Emitter Dispatch Tables

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shore up test coverage (especially cross-mode), extract three quick-win refactors (withCapture, compareValues, seriesAt), then break up `lua.nim` with dispatch tables.

**Architecture:** Three phases executed sequentially. Phase 1 builds the safety net (tests). Phase 2 does low-risk extractions that reduce code and improve clarity. Phase 3 is the large structural refactor of the emitter, done confidently because Phase 1's tests catch regressions.

**Tech Stack:** Nim 2.0+, `std/unittest`, `std/tables`, `std/sets`

---

## Phase 1: Test Coverage

### Task 1: Expand Lua Emitter Unit Tests

**Files:**
- Modify: `tests/test_lua.nim`

Currently 232 lines with 7 suites. We need coverage for: series operations, string operations, control flow edge cases, math, error handling, and the documented bugs (B1-B5) as known-failing regression markers.

- [ ] **Step 1: Add series operation emission tests**

Add a new suite at the end of `tests/test_lua.nim`:

```nim
suite "series operation emission":
  test "first emits indexing":
    let code = emitLua(parseSource("x: first [1 2 3]"))
    check "[1]" in code

  test "last emits length-based index":
    let code = emitLua(parseSource("x: last [1 2 3]"))
    check "[#" in code or "[3]" in code

  test "pick emits direct indexing":
    let code = emitLua(parseSource("x: pick [10 20 30] 2"))
    check "[2]" in code

  test "length emits #":
    let code = emitLua(parseSource("x: length? [1 2 3]"))
    check "#" in code

  test "empty? emits length check":
    let code = emitLua(parseSource("x: empty? [1 2 3]"))
    check "#" in code

  test "append emits table.insert":
    let code = emitLua(parseSource("""
      items: [1 2]
      append items 3
    """))
    check "table.insert" in code

  test "reverse emits helper or inline":
    let code = emitLua(parseSource("x: reverse [1 2 3]"))
    check "reverse" in code.toLowerAscii

  test "select on map emits key access":
    let code = emitLua(parseSource("""
      m: context [name: "alice"]
      x: select m "name"
    """))
    check "[\"name\"]" in code or ".name" in code
```

- [ ] **Step 2: Add string operation emission tests**

Append to `tests/test_lua.nim`:

```nim
suite "string operation emission":
  test "join emits table.concat":
    let code = emitLua(parseSource("""join ["a" "b" "c"] "-" """))
    check "table.concat" in code

  test "rejoin emits concatenation":
    let code = emitLua(parseSource("""x: rejoin ["hello" " " "world"]"""))
    check ".." in code or "concat" in code

  test "uppercase emits string.upper":
    let code = emitLua(parseSource("""x: uppercase "hello" """))
    check "string.upper" in code

  test "lowercase emits string.lower":
    let code = emitLua(parseSource("""x: lowercase "HELLO" """))
    check "string.lower" in code

  test "trim emits gsub pattern":
    let code = emitLua(parseSource("""x: trim "  hello  " """))
    check "gsub" in code

  test "split emits helper":
    let code = emitLua(parseSource("""x: split "a-b-c" "-" """))
    check "_split" in code or "gmatch" in code

  test "replace emits gsub":
    let code = emitLua(parseSource("""x: replace "hello" "l" "r" """))
    check "gsub" in code

  test "starts-with? emits sub or find":
    let code = emitLua(parseSource("""x: starts-with? "hello" "he" """))
    check "sub" in code or "find" in code

  test "substring emits string.sub":
    let code = emitLua(parseSource("""x: substring "hello" 2 3"""))
    check "string.sub" in code or "sub" in code
```

- [ ] **Step 3: Add math operation emission tests**

Append to `tests/test_lua.nim`:

```nim
suite "math operation emission":
  test "abs emits math.abs":
    let code = emitLua(parseSource("x: abs -5"))
    check "math.abs" in code

  test "floor emits math.floor":
    let code = emitLua(parseSource("x: floor 3.7"))
    check "math.floor" in code

  test "ceil emits math.ceil":
    let code = emitLua(parseSource("x: ceil 3.2"))
    check "math.ceil" in code

  test "sqrt emits math.sqrt":
    let code = emitLua(parseSource("x: sqrt 9"))
    check "math.sqrt" in code

  test "sin emits math.sin":
    let code = emitLua(parseSource("x: sin 1.0"))
    check "math.sin" in code

  test "min emits math.min":
    let code = emitLua(parseSource("x: min 3 5"))
    check "math.min" in code

  test "max emits math.max":
    let code = emitLua(parseSource("x: max 3 5"))
    check "math.max" in code

  test "random emits math.random":
    let code = emitLua(parseSource("x: random 10"))
    check "math.random" in code
```

- [ ] **Step 4: Add control flow and error emission tests**

Append to `tests/test_lua.nim`:

```nim
suite "control flow emission":
  test "unless emits negated if":
    let code = emitLua(parseSource("unless false [print 1]"))
    check "if not" in code or "if false" notin code

  test "not emits not":
    let code = emitLua(parseSource("x: not true"))
    check "not" in code

  test "return emits return":
    let code = emitLua(parseSource("""
      f: function [] [return 42]
    """))
    check "return 42" in code

  test "break in loop emits break":
    let code = emitLua(parseSource("""
      loop [for [i] from 1 to 10 do [
        if i = 5 [break]
      ]]
    """))
    check "break" in code

  test "either in statement emits if/else":
    let code = emitLua(parseSource("""
      either true [print "yes"] [print "no"]
    """))
    check "else" in code

  test "attempt with source emits pcall":
    let code = emitLua(parseSource("""
      x: attempt [source [42] fallback [0]]
    """))
    check "pcall" in code

  test "try emits pcall":
    let code = emitLua(parseSource("""
      try [print 1]
    """))
    check "pcall" in code
```

- [ ] **Step 5: Run tests to verify all new tests pass**

Run: `nim c -r --outdir:bin/tests tests/test_lua.nim`

Expected: All new tests PASS (we're testing current behavior, not desired behavior).

If any fail, adjust the assertion to match what the emitter actually produces — these tests document current behavior. Add a comment `# TODO: fix — see B<N>` for any test that reveals a known bug.

- [ ] **Step 6: Commit**

```bash
git add tests/test_lua.nim
git commit -m "test: expand Lua emitter unit tests for series, strings, math, control flow"
```

---

### Task 2: Expand Cross-Mode Tests

**Files:**
- Modify: `tests/test_cross_mode.nim`

Cross-mode tests are the most valuable — they catch interpreter/emitter parity bugs automatically. Currently covers: arithmetic, control flow, series basics, strings, loops, match, try/error. Missing: more string ops, context/map access, nested functions, deeper series work, math.

**Note:** Cross-mode tests require `love` to be installed. If `love` isn't available in the execution environment, these tests will fail with a clear error. That's fine — they're designed to run in the full dev environment.

- [ ] **Step 1: Add string operation cross-mode tests**

Add a new suite at the end of `tests/test_cross_mode.nim`:

```nim
# ============================================================
# String operations
# ============================================================

suite "cross-mode: string operations":
  test "uppercase/lowercase":
    crossCheck("""print uppercase "hello" """)
    crossCheck("""print lowercase "HELLO" """)

  test "trim":
    crossCheck("""print trim "  hello  " """)

  test "starts-with?/ends-with?":
    crossCheck("""print starts-with? "hello" "he" """)
    crossCheck("""print ends-with? "hello" "lo" """)

  test "substring":
    crossCheck("""print substring "hello world" 1 5""")

  test "rejoin":
    crossCheck("""print rejoin ["a" "b" "c"]""")
```

- [ ] **Step 2: Add math cross-mode tests**

```nim
# ============================================================
# Math operations
# ============================================================

suite "cross-mode: math operations":
  test "abs":
    crossCheck("print abs -5")
    crossCheck("print abs 5")

  test "min/max":
    crossCheck("print min 3 7")
    crossCheck("print max 3 7")

  test "floor/ceil":
    crossCheck("print floor 3.9")
    crossCheck("print ceil 3.1")

  test "negate":
    crossCheck("print negate 5")
    crossCheck("print negate -3")

  test "odd?/even?":
    crossCheck("print odd? 3")
    crossCheck("print even? 4")
```

- [ ] **Step 3: Add context and nested function cross-mode tests**

```nim
# ============================================================
# Contexts and functions
# ============================================================

suite "cross-mode: contexts and functions":
  test "context field access":
    crossCheck("""
      obj: context [x: 42]
      print obj/x
    """)

  test "nested function calls":
    crossCheck("""
      add: function [a b] [a + b]
      double: function [x] [add x x]
      print double 5
    """)

  test "function as argument":
    crossCheck("""
      apply-fn: function [f x] [f x]
      double: function [n] [n * 2]
      print apply-fn :double 5
    """)

  test "closure captures outer variable":
    crossCheck("""
      make-adder: function [n] [
        function [x] [x + n]
      ]
      add5: make-adder 5
      print add5 10
    """)
```

- [ ] **Step 4: Add loop refinement cross-mode tests**

```nim
# ============================================================
# Loop refinements
# ============================================================

suite "cross-mode: loop refinements":
  test "loop/collect":
    crossCheck("""
      result: loop/collect [for [x] in [1 2 3] do [x * 2]]
      print first result
      print second result
      print last result
    """)

  test "loop/fold":
    crossCheck("""
      result: loop/fold [acc 0 for [x] in [1 2 3 4 5] do [acc + x]]
      print result
    """)

  test "loop with when guard":
    crossCheck("""
      result: loop/collect [for [x] in [1 2 3 4 5] when [x > 2] do [x]]
      print length? result
      print first result
    """)
```

- [ ] **Step 5: Run cross-mode tests**

Run: `nim c -r --outdir:bin/tests tests/test_cross_mode.nim`

Expected: Most tests PASS. Some may fail due to known emitter parity bugs (B1-B5). For any failures, either:
- Add a `# skip — known bug B<N>` comment and remove the failing assertion
- Or wrap in a `when false:` block with a comment

The goal is a green test suite that documents what works.

- [ ] **Step 6: Commit**

```bash
git add tests/test_cross_mode.nim
git commit -m "test: expand cross-mode tests for strings, math, contexts, loop refinements"
```

---

### Task 3: Add Evaluator Edge Case Tests

**Files:**
- Modify: `tests/test_evaluator.nim`

Add tests for the comparison operators and series operations we're about to refactor, so we have a safety net before changing them.

- [ ] **Step 1: Read the current test file to find where to add**

Run: `nim c -r --outdir:bin/tests tests/test_evaluator.nim`

Verify current tests pass first.

- [ ] **Step 2: Add comparison operator tests**

Add a new suite to `tests/test_evaluator.nim`:

```nim
suite "comparison operators":
  test "integer comparisons":
    let eval = makeEval()
    check $eval.evalString("1 < 2") == "true"
    check $eval.evalString("2 > 1") == "true"
    check $eval.evalString("1 <= 1") == "true"
    check $eval.evalString("2 >= 1") == "true"
    check $eval.evalString("2 < 1") == "false"

  test "float comparisons":
    let eval = makeEval()
    check $eval.evalString("1.5 < 2.5") == "true"
    check $eval.evalString("2.5 > 1.5") == "true"

  test "mixed int/float comparisons":
    let eval = makeEval()
    check $eval.evalString("1 < 2.5") == "true"
    check $eval.evalString("2.5 > 1") == "true"

  test "string comparisons":
    let eval = makeEval()
    check $eval.evalString(""""abc" < "def" """) == "true"
    check $eval.evalString(""""def" > "abc" """) == "true"
    check $eval.evalString(""""abc" <= "abc" """) == "true"

  test "money comparisons":
    let eval = makeEval()
    check $eval.evalString("$1.00 < $2.00") == "true"
    check $eval.evalString("$2.00 > $1.00") == "true"
    check $eval.evalString("$1.00 <= $1.00") == "true"

  test "date comparisons":
    let eval = makeEval()
    check $eval.evalString("2026-01-01 < 2026-12-31") == "true"
    check $eval.evalString("2026-12-31 > 2026-01-01") == "true"

  test "time comparisons":
    let eval = makeEval()
    check $eval.evalString("10:00:00 < 14:30:00") == "true"
    check $eval.evalString("14:30:00 > 10:00:00") == "true"

  test "type mismatch raises error":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""1 < "hello" """)
```

- [ ] **Step 3: Add series operation tests**

```nim
suite "series access safety":
  test "first/second/last on blocks":
    let eval = makeEval()
    check $eval.evalString("first [10 20 30]") == "10"
    check $eval.evalString("second [10 20 30]") == "20"
    check $eval.evalString("last [10 20 30]") == "30"

  test "first/second/last on strings":
    let eval = makeEval()
    check $eval.evalString("""first "abc" """) == "a"
    check $eval.evalString("""second "abc" """) == "b"
    check $eval.evalString("""last "abc" """) == "c"

  test "pick with valid index":
    let eval = makeEval()
    check $eval.evalString("pick [10 20 30] 2") == "20"
    check $eval.evalString("""pick "abc" 2""") == "b"

  test "first on empty block raises":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("first []")

  test "pick out of range raises":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("pick [1 2 3] 5")

  test "second on short block raises":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("second [1]")
```

- [ ] **Step 4: Run evaluator tests**

Run: `nim c -r --outdir:bin/tests tests/test_evaluator.nim`

Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/test_evaluator.nim
git commit -m "test: add comparison and series operation safety tests"
```

---

## Phase 2: Quick-Win Refactors

### Task 4: Extract `withCapture` Template

**Files:**
- Modify: `src/emit/lua.nim`

There are ~14 instances of the save/restore pattern. We'll add a `withCapture` template and convert all instances to use it. This is the lowest-risk, highest-clarity refactor.

- [ ] **Step 1: Run all tests to establish green baseline**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 2: Add the `withCapture` template**

In `src/emit/lua.nim`, after the `raw` proc (line 77), add:

```nim
template withCapture(e: var LuaEmitter, body: untyped): string =
  ## Capture emitter output in a temporary buffer.
  ## Returns the captured output string; restores e.output after.
  let wcSaved = e.output
  e.output = ""
  body
  let wcResult = e.output
  e.output = wcSaved
  wcResult
```

- [ ] **Step 3: Convert first instance — `findLastStmtStart` (line ~2026)**

Find the dry-run save/restore in `findLastStmtStart`:

```nim
# Before:
let saved = e.output
e.output = ""
# ... scanning code ...
e.output = saved
```

Replace with:
```nim
discard e.withCapture:
  # ... scanning code (unchanged) ...
```

- [ ] **Step 4: Run all tests**

Run: `nimble test`

Expected: All PASS. This validates the template works.

- [ ] **Step 5: Convert remaining instances one at a time**

Work through each of the ~14 save/restore instances. The general pattern:

**Before:**
```nim
let saved = e.output
e.output = ""
# emit code
let someVar = e.output
e.output = saved
```

**After:**
```nim
let someVar = e.withCapture:
  # emit code
```

Convert each instance, verify it compiles, and move to the next. The instances are at approximately these locations (line numbers will shift as you edit):
- `emitMatchExpr` match arm (~861)
- `emitMatchExpr` handler body (~911)
- `emitEitherExpr` true branch (~936)
- `emitTryExpr` source body (~1035)
- `try/handle` handler body (~1253)
- `try/handle` source body (~1259)
- `loop/collect,fold,partition` (~1283)
- `if` expression body (~1377)
- `function` expression (~1408)
- `does` expression (~1419)
- `capture` expression (~1444) — note: this also saves/restores `locals`, handle that separately
- `loop` in expression context (~1463)
- `attempt` result wrapper (~1830)

For the `capture` expression instance that also saves/restores `e.locals`:
```nim
let savedLocals = e.locals
let bodyStr = e.withCapture:
  # emit code
e.locals = savedLocals
```

- [ ] **Step 6: Run all tests**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 7: Commit**

```bash
git add src/emit/lua.nim
git commit -m "refactor: extract withCapture template, eliminate 14 save/restore patterns in emitter"
```

---

### Task 5: Extract `compareValues` in Evaluator

**Files:**
- Modify: `src/eval/evaluator.nim`

Lines 153-212 have four identical blocks for `<`, `>`, `<=`, `>=`. Extract to one `compareValues` function.

- [ ] **Step 1: Add the `compareValues` proc**

In `src/eval/evaluator.nim`, before the `applyOp` proc (before line 63), add:

```nim
proc compareValues*(left, right: KtgValue): int =
  ## Compare two values. Returns -1, 0, or 1.
  ## Raises KtgError if types are not comparable.
  if left.kind in {vkInteger, vkFloat} and right.kind in {vkInteger, vkFloat}:
    let lf = if left.kind == vkInteger: float64(left.intVal) else: left.floatVal
    let rf = if right.kind == vkInteger: float64(right.intVal) else: right.floatVal
    return cmp(lf, rf)
  if left.kind == vkString and right.kind == vkString:
    return cmp(left.strVal, right.strVal)
  if left.kind == vkMoney and right.kind == vkMoney:
    return cmp(left.cents, right.cents)
  if left.kind == vkDate and right.kind == vkDate:
    return cmp(
      (left.year, left.month, left.day),
      (right.year, right.month, right.day))
  if left.kind == vkTime and right.kind == vkTime:
    return cmp(
      (left.hour, left.minute, left.second),
      (right.hour, right.minute, right.second))
  raise KtgError(
    kind: "type",
    msg: "cannot compare " & typeName(left) & " and " & typeName(right),
    data: nil)
```

- [ ] **Step 2: Replace the four comparison operator blocks**

Replace lines 153-212 (the `<`, `>`, `<=`, `>=` branches) with:

```nim
  of "<":  return ktgLogic(compareValues(left, right) < 0)
  of ">":  return ktgLogic(compareValues(left, right) > 0)
  of "<=": return ktgLogic(compareValues(left, right) <= 0)
  of ">=": return ktgLogic(compareValues(left, right) >= 0)
```

- [ ] **Step 3: Run evaluator tests**

Run: `nim c -r --outdir:bin/tests tests/test_evaluator.nim`

Expected: All PASS — including the comparison tests from Task 3.

- [ ] **Step 4: Run all tests**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add src/eval/evaluator.nim
git commit -m "refactor: extract compareValues, replace 60 lines of duplicated comparison logic"
```

---

### Task 6: Extract `seriesAt` Helper in Natives

**Files:**
- Modify: `src/eval/natives.nim`

Lines 253-314 have four functions (`first`, `second`, `last`, `pick`) with repeated block/string access patterns.

- [ ] **Step 1: Add the `seriesAt` helper**

In `src/eval/natives.nim`, before the `registerNatives` proc, add:

```nim
proc seriesAt(val: KtgValue, idx: int, funcName: string): KtgValue =
  ## Access element at 0-based index from a block or string.
  ## Raises KtgError on type mismatch or out-of-range.
  case val.kind
  of vkBlock:
    if idx < 0 or idx >= val.blockVals.len:
      raise KtgError(kind: "range",
        msg: funcName & ": index out of range for block of length " & $val.blockVals.len,
        data: nil)
    return val.blockVals[idx]
  of vkString:
    if idx < 0 or idx >= val.strVal.len:
      raise KtgError(kind: "range",
        msg: funcName & ": index out of range for string of length " & $val.strVal.len,
        data: nil)
    return ktgString($val.strVal[idx])
  else:
    raise KtgError(kind: "type",
      msg: funcName & " expects series (block! or string!), got " & typeName(val),
      data: nil)
```

- [ ] **Step 2: Replace `first`, `second`, `last`**

Replace the bodies of `first`, `second`, `last` with calls to `seriesAt`:

```nim
  ctx.native("first", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    seriesAt(args[0], 0, "first")
  )

  ctx.native("second", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    seriesAt(args[0], 1, "second")
  )

  ctx.native("last", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let idx = case args[0].kind
      of vkBlock: args[0].blockVals.len - 1
      of vkString: args[0].strVal.len - 1
      else: -1  # seriesAt will raise
    seriesAt(args[0], idx, "last")
  )
```

- [ ] **Step 3: Replace `pick`**

Replace the `pick` body:

```nim
  ctx.native("pick", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[1].kind != vkInteger:
      raise KtgError(kind: "type", msg: "pick expects integer! as index", data: args[1])
    let idx = int(args[1].intVal) - 1  # 1-based to 0-based
    seriesAt(args[0], idx, "pick")
  )
```

- [ ] **Step 4: Run evaluator tests**

Run: `nim c -r --outdir:bin/tests tests/test_evaluator.nim`

Expected: All PASS — including series tests from Task 3.

- [ ] **Step 5: Run all tests**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add src/eval/natives.nim
git commit -m "refactor: extract seriesAt helper, replace duplicated first/second/last/pick logic"
```

---

## Phase 3: Emitter Dispatch Tables

### Task 7: Define the Emitter Registry Types

**Files:**
- Modify: `src/emit/lua.nim`

Before building the dispatch tables, define the types and the empty tables. This is a pure additive change — existing code isn't touched yet.

- [ ] **Step 1: Add the emitter handler types and tables**

In `src/emit/lua.nim`, after the `LuaEmitter` type definition (after line 57), add:

```nim
type
  ## An expression emitter: consume arguments starting at pos, return a Lua expression string.
  ExprHandler = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string

  ## A statement emitter: consume arguments starting at pos, emit Lua statements via e.ln().
  StmtHandler = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int)

var exprHandlers: Table[string, ExprHandler]
var stmtHandlers: Table[string, StmtHandler]
```

- [ ] **Step 2: Verify it compiles**

Run: `nim c --outdir:bin/tests tests/test_lua.nim`

Expected: Compiles without error (unused variable warnings are OK).

- [ ] **Step 3: Commit**

```bash
git add src/emit/lua.nim
git commit -m "refactor: add ExprHandler/StmtHandler types and dispatch tables to emitter"
```

---

### Task 8: Extract Math Native Handlers to Dispatch Table

**Files:**
- Modify: `src/emit/lua.nim`

Start with the simplest group: math natives. These are 1-argument `math.X(arg)` calls, plus a few 2-argument variants. Extract them from the `emitExpr` elif chain into `exprHandlers`.

- [ ] **Step 1: Register math expression handlers**

After the `exprHandlers`/`stmtHandlers` declarations, add a block of handler registrations. These must go at module level (not inside a proc):

```nim
# --- Math native expression handlers ---

proc mathUnary(luaFn: string): ExprHandler =
  ## Factory for math.X(arg) patterns.
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
    luaFn & "(" & e.emitExpr(vals, pos) & ")"

proc mathBinary(luaFn: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
    let a = e.emitExpr(vals, pos)
    let b = e.emitExpr(vals, pos)
    luaFn & "(" & a & ", " & b & ")"

exprHandlers["abs"] = mathUnary("math.abs")
exprHandlers["sqrt"] = mathUnary("math.sqrt")
exprHandlers["sin"] = mathUnary("math.sin")
exprHandlers["cos"] = mathUnary("math.cos")
exprHandlers["tan"] = mathUnary("math.tan")
exprHandlers["asin"] = mathUnary("math.asin")
exprHandlers["acos"] = mathUnary("math.acos")
exprHandlers["exp"] = mathUnary("math.exp")
exprHandlers["log"] = mathUnary("math.log")
exprHandlers["log10"] = mathUnary("math.log10")
exprHandlers["floor"] = mathUnary("math.floor")
exprHandlers["ceil"] = mathUnary("math.ceil")
exprHandlers["negate"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "-(" & e.emitExpr(vals, pos) & ")"
exprHandlers["min"] = mathBinary("math.min")
exprHandlers["max"] = mathBinary("math.max")
exprHandlers["pow"] = mathBinary("math.pow")
exprHandlers["atan2"] = mathBinary("math.atan2")
exprHandlers["to-degrees"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "math.deg(" & e.emitExpr(vals, pos) & ")"
exprHandlers["to-radians"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "math.rad(" & e.emitExpr(vals, pos) & ")"
```

- [ ] **Step 2: Add dispatch lookup in `emitExpr`**

Find the top of the word-name elif chain in `emitExpr` (around line 1213). Before the first `elif name == ...` branch, add:

```nim
        # --- Dispatch table lookup ---
        if name in exprHandlers:
          result = exprHandlers[name](e, vals, pos)
        elif name == "raw":
```

This means: if a handler exists in the table, use it. Otherwise fall through to the existing elif chain.

- [ ] **Step 3: Remove the math branches from the elif chain**

Find and delete the individual `elif name == "abs"`, `elif name == "sqrt"`, etc. branches from `emitExpr`. These are the branches that now duplicate the dispatch table handlers.

Search for each of these names in the elif chain and remove their blocks:
- `abs`, `negate`, `min`, `max`, `sqrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan2`, `pow`, `exp`, `log`, `log10`, `floor`, `ceil`, `to-degrees`, `to-radians`

- [ ] **Step 4: Run math emission tests**

Run: `nim c -r --outdir:bin/tests tests/test_lua.nim`

Expected: All PASS — including the math suite from Task 1.

- [ ] **Step 5: Run all tests**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add src/emit/lua.nim
git commit -m "refactor: move math native emitters to dispatch table"
```

---

### Task 9: Extract String Native Handlers to Dispatch Table

**Files:**
- Modify: `src/emit/lua.nim`

Same pattern as Task 8 but for string operations.

- [ ] **Step 1: Register string expression handlers**

Add after the math handlers:

```nim
# --- String native expression handlers ---

exprHandlers["uppercase"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "string.upper(" & e.emitExpr(vals, pos) & ")"

exprHandlers["lowercase"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "string.lower(" & e.emitExpr(vals, pos) & ")"

exprHandlers["trim"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let s = e.emitExpr(vals, pos)
  s & ":match('^%s*(.-)%s*$')"

exprHandlers["length?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "#" & e.emitExpr(vals, pos)

exprHandlers["size?"] = exprHandlers["length?"]

exprHandlers["empty?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "#" & e.emitExpr(vals, pos) & " == 0"
```

Note: Only extract the straightforward string handlers. Some string operations (like `split`, `replace`, `join`) may have more complex logic involving helpers or multiple arguments — look at the existing elif branches carefully before extracting. If the branch is >5 lines with conditional logic, leave it in the elif chain for now and extract it in a later task.

- [ ] **Step 2: Remove the corresponding elif branches from `emitExpr`**

Remove the `elif name == "uppercase"`, `elif name == "lowercase"`, `elif name == "trim"`, `elif name == "length?"`, `elif name == "size?"`, `elif name == "empty?"` branches.

- [ ] **Step 3: Run string emission tests**

Run: `nim c -r --outdir:bin/tests tests/test_lua.nim`

Expected: All PASS.

- [ ] **Step 4: Run all tests**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add src/emit/lua.nim
git commit -m "refactor: move string native emitters to dispatch table"
```

---

### Task 10: Extract Type Predicate Handlers to Dispatch Table

**Files:**
- Modify: `src/emit/lua.nim`

The type predicates (`integer?`, `string?`, `float?`, etc.) are a large block of elif branches with a regular pattern. Extract them with a factory.

- [ ] **Step 1: Register type predicate handlers**

```nim
# --- Type predicate expression handlers ---

proc typePredHandler(luaType: string): ExprHandler =
  ## Factory for type?(val) → type(val) == "luaType" patterns.
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
    "type(" & e.emitExpr(vals, pos) & ") == \"" & luaType & "\""

exprHandlers["integer?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "type(" & arg & ") == \"number\" and " & arg & " % 1 == 0"

exprHandlers["float?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "type(" & arg & ") == \"number\" and " & arg & " % 1 ~= 0"

exprHandlers["string?"] = typePredHandler("string")
exprHandlers["logic?"] = typePredHandler("boolean")
exprHandlers["function?"] = typePredHandler("function")
exprHandlers["block?"] = typePredHandler("table")

exprHandlers["none?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  e.useHelper("_is_none")
  "_is_none(" & e.emitExpr(vals, pos) & ")"
```

**Important:** Read the existing elif branches for each predicate before extracting. The exact Lua emission may differ from the patterns above — match what the current code does, not what seems logical. Adjust the handlers to match the existing output exactly.

- [ ] **Step 2: Remove the corresponding elif branches from `emitExpr`**

Find and remove the `integer?`, `float?`, `string?`, `logic?`, `function?`, `block?`, `none?` branches.

- [ ] **Step 3: Run all tests**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 4: Commit**

```bash
git add src/emit/lua.nim
git commit -m "refactor: move type predicate emitters to dispatch table"
```

---

### Task 11: Extract Simple 1-2 Argument Natives to Dispatch Table

**Files:**
- Modify: `src/emit/lua.nim`

Now extract the remaining simple native handlers: series access (`first`, `last`, `pick`), `not`, `type`, `odd?`/`even?`, `print`, and any other 1-2 line elif branches.

- [ ] **Step 1: Read each remaining elif branch in `emitExpr`**

Before extracting, read the exact code for each branch you plan to move. Only extract branches that are self-contained (no complex conditional logic, no interaction with `e.indent` or other state beyond `e.output`).

Good candidates for extraction:
- `not` — simple `not (expr)` wrapper
- `type` — `type(expr)`
- `odd?`/`even?` — modulo check
- `first` — `expr[1]`
- `last` — `expr[#expr]`
- `print` — `print(expr)`
- `probe` — `print(expr); return expr` pattern
- Any other branch that is ≤5 lines and purely computes a string

- [ ] **Step 2: Register handlers for each candidate**

Example patterns (adjust to match actual emitter output):

```nim
exprHandlers["not"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "not " & e.emitExpr(vals, pos)

exprHandlers["type"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "type(" & e.emitExpr(vals, pos) & ")"

exprHandlers["odd?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  e.emitExpr(vals, pos) & " % 2 ~= 0"

exprHandlers["even?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  e.emitExpr(vals, pos) & " % 2 == 0"

exprHandlers["first"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  e.emitExpr(vals, pos) & "[1]"

exprHandlers["last"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let s = e.emitExpr(vals, pos)
  s & "[#" & s & "]"
```

**Important:** For each one, read the existing branch first and match its exact behavior. Don't guess — copy the logic.

- [ ] **Step 3: Remove the corresponding elif branches**

- [ ] **Step 4: Run all tests**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add src/emit/lua.nim
git commit -m "refactor: move simple native emitters to dispatch table"
```

---

### Task 12: Add Statement-Level Dispatch Table

**Files:**
- Modify: `src/emit/lua.nim`

The `emitBlock` proc (lines ~2227-2700) has its own set of word-name checks for statement-level emission. Many statement handlers just call the expression handler and discard the result, but some (like `if`, `loop`, `match`) have genuinely different statement vs expression behavior.

- [ ] **Step 1: Add dispatch lookup in `emitBlock`**

Find the statement word-name dispatch in `emitBlock` (the `if val.wordName == "X"` chain). Before the first branch, add:

```nim
        if name in stmtHandlers:
          stmtHandlers[name](e, vals, pos)
        elif name == "raw":
```

- [ ] **Step 2: Register statement handlers that differ from expression handlers**

Only extract statement handlers where the behavior is genuinely different from the expression handler (i.e., emits statements via `e.ln()` rather than returning a string).

For natives where statement behavior is just "emit the expression as a statement", add a helper:

```nim
proc stmtFromExpr(name: string) =
  ## Auto-create a statement handler that calls the expression handler.
  if name in exprHandlers:
    stmtHandlers[name] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
      e.ln(exprHandlers[name](e, vals, pos))

# Apply to all expression-only natives
for name in ["abs", "sqrt", "sin", "cos", "tan", "asin", "acos",
             "atan2", "pow", "exp", "log", "log10", "floor", "ceil",
             "negate", "min", "max", "to-degrees", "to-radians",
             "uppercase", "lowercase", "trim"]:
  stmtFromExpr(name)
```

For `print` specifically (which is very common as a statement):

```nim
stmtHandlers["print"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  e.ln("print(" & e.emitExpr(vals, pos) & ")")
```

- [ ] **Step 3: Remove the corresponding branches from `emitBlock`**

Only remove branches that are now covered by the dispatch table. Leave complex statement handlers (like `if`, `loop`, `match`, `either`) in the elif chain for now.

- [ ] **Step 4: Run all tests**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add src/emit/lua.nim
git commit -m "refactor: add statement dispatch table, auto-generate statement wrappers for expr handlers"
```

---

### Task 13: Final Verification and Line Count

**Files:**
- No modifications — verification only.

- [ ] **Step 1: Run the full test suite**

Run: `nimble test`

Expected: All PASS.

- [ ] **Step 2: Check line counts**

Run: `wc -l src/emit/lua.nim src/eval/evaluator.nim src/eval/natives.nim`

Compare to the starting counts:
- `lua.nim`: was 3,083 — should be ~2,400-2,600 (15-25% reduction)
- `evaluator.nim`: was 1,206 — should be ~1,150 (~5% reduction)
- `natives.nim`: was 1,046 — should be ~1,010 (~3% reduction)

- [ ] **Step 3: Run cross-mode tests specifically**

Run: `nim c -r --outdir:bin/tests tests/test_cross_mode.nim`

Expected: All PASS (same as before the refactor).

- [ ] **Step 4: Commit any cleanup**

If any dead imports or unused variables were left behind, clean them up:

```bash
git add -u
git commit -m "chore: clean up unused imports after dispatch table refactor"
```
