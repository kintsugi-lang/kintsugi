# Lua Emitter Structural Rewrite

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `src/emit/lua.nim` so that any reasonable Kintsugi program (that doesn't use interpreter-only features) compiles to correct, runnable Lua.

**Architecture:** Keep string-concat output and KtgValue AST as input. Fix three structural problems: (1) replace the shallow arity prescan with a recursive binding tracker that knows function vs. value vs. unknown, (2) thread an emission context (statement/expression/return) through all emission paths, (3) unify the duplicated dispatch in emitExpr/emitBlock into a single dispatch function that branches on context. Also handle refinements in compiled output (positional booleans).

**Tech Stack:** Nim, Lua 5.1 output

**Key files:**
- Rewrite: `src/emit/lua.nim`
- Test: `tests/test_lua.nim`
- Validation: `examples/tic-tac-toe/graphical/main.ktg`, `examples/tic-tac-toe/terminal/main.ktg`

---

## Bug Catalog (What Must Be Fixed)

These are the specific bugs visible in compiled output today. Every task references which bugs it fixes.

**B1: Path-as-value treated as function call.** `pick board/cells 2` emits `board.cells(2)[nil]`. The emitter sees `board/cells` as an unknown path and heuristically consumes `2` as its argument. Should emit `board.cells[2]`.

**B2: Context field access emits `()`.** `board/cells` alone emits `board.cells()`. The emitter doesn't know `board` is a context (value), not a function. Should emit `board.cells`.

**B3: `state.full()` — bare value lookup emits call parens.** Same root cause as B2. Any value looked up via path in statement position gets spurious `()`.

**B4: Refinements in function specs emit invalid Lua.** `function [name /loud]` emits `function(name, /loud)`. `/loud` is not a valid Lua identifier.

**B5: Refinement calls emit as path access.** `greet/loud "world"` emits `greet.loud("world")`. Should emit `greet("world", true)`.

**B6: `prescanArities` only scans top-level.** Functions defined inside other functions, conditionals, or blocks don't get their arity tracked. Calls to them fall into the heuristic path.

**B7: `prescanArities` counts refinement names as params.** `/loud` in a spec block is counted as a regular parameter word, inflating the arity.

**B8: `emitFuncDef` emits refinement names as params.** Same as B7 but in the actual function header emission — refinement words become Lua params verbatim.

**B9: Duplicated dispatch.** `if`, `either`, `match`, `loop`, `print`, `return`, `break` all have separate handling in both `emitExpr` (expression context) and `emitBlock` (statement context). The two paths diverge in subtle ways.

**B10: `emitBlockReturn` statement-boundary scanning is fragile.** 90+ lines of "re-walk the AST to find where statements start" that silently misidentifies boundaries when constructs are nested or unfamiliar.

---

## Task 1: Binding Table — Recursive Prescan

**Fixes:** B1, B2, B3, B6, B7

**Files:**
- Modify: `src/emit/lua.nim` (the `prescanArities` proc and `LuaEmitter` type)
- Test: `tests/test_lua.nim`

The core of every other fix. Replace the flat arity scan with a recursive binding tracker.

- [ ] **Step 1: Write failing tests for path-as-value bugs**

Add to `tests/test_lua.nim`:

```nim
suite "binding tracking":
  test "path access is not a function call":
    let code = emitLua(parseSource("""
      obj: context [cells: [1 2 3]]
      print pick obj/cells 2
    """))
    check "obj.cells[2]" in code
    check "obj.cells(" notin code

  test "context field in loop is not a call":
    let code = emitLua(parseSource("""
      board: context [cells: [1 2 3]]
      loop [for [c] in board/cells [print c]]
    """))
    check "ipairs(board.cells)" in code
    check "board.cells()" notin code

  test "nested function arity is tracked":
    let code = emitLua(parseSource("""
      outer: function [] [
        inner: function [a b] [a + b]
        inner 3 4
      ]
    """))
    check "inner(3, 4)" in code

  test "typed params dont inflate arity":
    let code = emitLua(parseSource("""
      place: function [pos [integer!] mark [string!]] [pos]
      place 1 "x"
    """))
    check "place(1, \"x\")" in code

  test "refinement names dont inflate arity":
    let code = emitLua(parseSource("""
      greet: function [name /loud] [name]
      greet "world"
    """))
    check "greet(\"world\")" in code
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`
Expected: New tests fail (path emits `obj.cells(2)` not `obj.cells[2]`, etc.)

- [ ] **Step 3: Add BindingInfo type and recursive prescan**

Replace the current `prescanArities` with a recursive version. In `src/emit/lua.nim`, modify the `LuaEmitter` type and add the new prescan:

```nim
type
  BindingInfo = object
    arity: int          ## -1 = value (not callable), 0+ = function with N params
    maxArity: int       ## for variadic bindings
    isFunction: bool    ## true = definitely a function, false = definitely a value
    isUnknown: bool     ## true = couldn't determine (use heuristic)

  LuaEmitter = object
    indent: int
    output: string
    bindings: Table[string, BindingInfo]  ## replaces arities
    locals: HashSet[string]
    nameMap: Table[string, string]
    bindingKinds: Table[string, BindingKind]
```

The recursive prescan:

```nim
proc prescanBlock(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Recursively scan a block for function definitions and value bindings.
  var i = 0
  while i < vals.len:
    # bindings [...] dialect — delegate to prescanBindings
    if vals[i].kind == vkWord and vals[i].wordKind == wkWord and
       vals[i].wordName == "bindings":
      if i + 1 < vals.len and vals[i + 1].kind == vkBlock:
        e.prescanBindings(vals[i + 1].blockVals)
        i += 2
        continue

    # name: function [spec] [body]
    if vals[i].kind == vkWord and vals[i].wordKind == wkSetWord:
      let name = vals[i].wordName
      if i + 1 < vals.len and vals[i + 1].kind == vkWord and
         vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "function":
        if i + 2 < vals.len and vals[i + 2].kind == vkBlock:
          let spec = vals[i + 2].blockVals
          var paramCount = 0
          var j = 0
          while j < spec.len:
            let s = spec[j]
            # Skip refinements: /name tokens start with /
            if s.kind == vkWord and s.wordKind == wkWord and s.wordName.startsWith("/"):
              j += 1
              # Skip refinement params (words after /name until next /name or end)
              while j < spec.len:
                if spec[j].kind == vkWord and spec[j].wordKind == wkWord and
                   spec[j].wordName.startsWith("/"):
                  break  # next refinement
                if spec[j].kind == vkWord and spec[j].wordKind == wkSetWord:
                  break  # return:
                if spec[j].kind == vkBlock:
                  j += 1  # skip type block
                  continue
                j += 1  # skip refinement param word
              continue
            # Count regular params (words that aren't return:)
            if s.kind == vkWord and s.wordKind == wkWord:
              paramCount += 1
            elif s.kind == vkWord and s.wordKind == wkSetWord:
              # return: [type] — skip
              j += 1
              if j < spec.len and spec[j].kind == vkBlock: discard
            elif s.kind == vkBlock:
              discard  # type annotation
            j += 1
          e.bindings[name] = BindingInfo(arity: paramCount, maxArity: paramCount,
                                          isFunction: true, isUnknown: false)
          # Recurse into function body
          if i + 3 < vals.len and vals[i + 3].kind == vkBlock:
            e.prescanBlock(vals[i + 3].blockVals)
          i += 4
          continue
      else:
        # name: <non-function> — it's a value
        # Only record if not already known (don't overwrite function with value)
        if name notin e.bindings:
          e.bindings[name] = BindingInfo(arity: -1, maxArity: -1,
                                          isFunction: false, isUnknown: false)
    i += 1
```

Then update all call sites: replace `e.arity(name)` with lookups into `e.bindings`, and replace `e.arities` with `e.bindings` throughout.

The key behavioral change: when emitting a path like `board/cells`, the emitter checks if `board` is in `e.bindings` as a value. If so, `board/cells` is ALWAYS emitted as `board.cells` (field access) — never as a function call, never consuming args.

- [ ] **Step 4: Update path emission in emitExpr**

In the path handling section (around line 888), replace the heuristic with binding-aware logic:

```nim
elif name.contains('/'):
  let parts = name.split('/')
  let head = parts[0]
  let path = emitPath(name)

  # Check if head is a known value (context, object, etc.)
  if head in e.bindings and not e.bindings[head].isFunction:
    # Pure field access — no arg consumption
    result = path
  elif head in e.bindings and e.bindings[head].isFunction:
    # Function with refinement — handled in Task 4
    let info = e.bindings[head]
    var args: seq[string] = @[]
    for i in 0 ..< info.arity:
      args.add(e.emitExpr(vals, pos))
    result = e.resolvedName(head) & "(" & args.join(", ") & ")"
  elif name in e.bindings:
    # Whole path is a known binding (from bindings dialect)
    let info = e.bindings[name]
    if info.isFunction and info.arity > 0:
      var args: seq[string] = @[]
      for i in 0 ..< info.arity:
        args.add(e.emitExpr(vals, pos))
      result = path & "(" & args.join(", ") & ")"
    elif info.isFunction:
      result = path & "()"
    else:
      result = path
  else:
    # Unknown path — field access by default (safe: won't consume args)
    result = path
```

The critical change: **unknown paths default to field access, not function calls.** This is the opposite of the current heuristic. The old heuristic assumes "if there's a value after a path, it's probably an argument." The new rule: "a path is a field access unless the head is a known function."

- [ ] **Step 5: Update all `e.arity()` / `e.arities[]` call sites**

Replace `e.arity(name)` calls throughout the file with `e.bindings` lookups. The helper:

```nim
proc getBinding(e: LuaEmitter, name: string): BindingInfo =
  if name in e.bindings: e.bindings[name]
  else: BindingInfo(arity: -1, maxArity: -1, isFunction: false, isUnknown: true)
```

The `initNativeArities` table should populate `e.bindings` with `isFunction: true` for all natives.

- [ ] **Step 6: Run tests to verify they pass**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`
Expected: All new binding tracking tests pass. Existing tests still pass.

- [ ] **Step 7: Run full test suite**

Run: `nimble test 2>&1 | grep -c "\[OK\]"`
Expected: 855 (no regressions — emitter tests are separate from evaluator tests, but verify)

- [ ] **Step 8: Commit**

```bash
git add src/emit/lua.nim tests/test_lua.nim
git commit -m "emitter: recursive binding prescan, fix path-as-value bugs"
```

---

## Task 2: Emission Context — Statement vs Expression vs Return

**Fixes:** B9, B10

**Files:**
- Modify: `src/emit/lua.nim`
- Test: `tests/test_lua.nim`

Replace the duplicated emitExpr/emitBlock dispatch with a context-aware unified emitter.

- [ ] **Step 1: Write failing tests for implicit return edge cases**

```nim
suite "emission context":
  test "if in expression position wraps in IIFE":
    let code = emitLua(parseSource("""
      x: if true [42]
    """))
    check "function()" in code  # IIFE wrapper
    check "local x" in code

  test "if in statement position emits directly":
    let code = emitLua(parseSource("""
      if true [print 42]
    """))
    check "if true then" in code
    check "function()" notin code

  test "either as last expression in function gets implicit return":
    let code = emitLua(parseSource("""
      pick-side: function [x] [
        either x > 0 ["positive"] ["non-positive"]
      ]
    """))
    check "return" in code

  test "match as last expression in function gets implicit return":
    let code = emitLua(parseSource("""
      describe: function [x] [
        match x [
          [1] ["one"]
          [2] ["two"]
          default: ["other"]
        ]
      ]
    """))
    check "return" in code

  test "loop in statement position never returns":
    let code = emitLua(parseSource("""
      loop [for [i] from 1 to 3 [print i]]
    """))
    check "return" notin code
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`
Expected: At least the match implicit-return test fails.

- [ ] **Step 3: Add EmitContext enum and refactor dispatch**

```nim
type
  EmitContext = enum
    ecStatement   ## top-level or block body — emit as Lua statement
    ecExpression  ## RHS of assignment, function arg — emit as Lua expression string
    ecReturn      ## last position in function body — emit with `return` prefix
```

Create a new unified dispatch proc:

```nim
proc emitVal(e: var LuaEmitter, vals: seq[KtgValue], pos: var int, ctx: EmitContext): string =
  ## Unified emission. Returns a Lua expression string.
  ## For ecStatement, the expression is emitted as a line (side effect on e.output).
  ## For ecExpression, the string is returned for the caller to place.
  ## For ecReturn, the string is prefixed with "return ".
```

This proc contains a single `case val.kind` / `case val.wordName` dispatch. For constructs that differ between contexts:

- **`if`**: ecStatement → `if cond then ... end`, ecExpression → IIFE, ecReturn → `if cond then return ... end`
- **`either`**: ecStatement → `if/else`, ecExpression → ternary or IIFE, ecReturn → `if/else` with returns
- **`match`**: ecStatement → if-chain, ecExpression → IIFE, ecReturn → if-chain with returns
- **`loop`**: ecStatement → for loop, ecExpression → error (loops don't produce values), ecReturn → for loop (no return)
- **`print`**: always ecStatement (returns none)

Then rewrite `emitBlock` to call `emitVal(ecStatement)` for each value, and `emitBody(asReturn=true)` to call `emitVal(ecStatement)` for all but last, `emitVal(ecReturn)` for last.

- [ ] **Step 4: Replace emitBlockReturn with context-based last-expression handling**

Delete `emitBlockReturn` (the 90-line proc that re-scans statement boundaries). Replace with:

```nim
proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false) =
  if vals.len == 0: return
  var pos = 0
  while pos < vals.len:
    let isLast = (pos >= vals.len - 1) or
                 # peek: is this the last statement?
                 # (we need to check what emitVal would consume)
                 false  # conservative: only mark last if pos == vals.len - 1
    let ctx = if asReturn and isLast: ecReturn
              elif asReturn and isLastStatement(e, vals, pos): ecReturn
              else: ecStatement
    discard e.emitVal(vals, pos, ctx)
```

The `isLastStatement` helper: saves pos, does a dry-run of emitVal to see how many tokens it would consume, restores pos, checks if consumed-to == vals.len.

Actually, simpler approach: split into two passes just like the current code does, but cleaner:

```nim
proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false) =
  if vals.len == 0: return
  if not asReturn:
    var pos = 0
    while pos < vals.len:
      discard e.emitVal(vals, pos, ecStatement)
    return
  # Find where the last statement starts
  let lastStart = findLastStatementStart(e, vals)
  var pos = 0
  while pos < lastStart:
    discard e.emitVal(vals, pos, ecStatement)
  discard e.emitVal(vals, pos, ecReturn)
```

Where `findLastStatementStart` does the dry-run scan: walk through vals with a dummy emitter that tracks position but doesn't output, recording each statement's start position.

- [ ] **Step 5: Run tests**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`
Expected: All emission context tests pass.

- [ ] **Step 6: Run full test suite**

Run: `nimble test 2>&1 | grep -c "\[OK\]"`
Expected: 855 passing

- [ ] **Step 7: Commit**

```bash
git add src/emit/lua.nim tests/test_lua.nim
git commit -m "emitter: unified dispatch with emission context, kill emitBlockReturn"
```

---

## Task 3: Refinement Emission

**Fixes:** B4, B5, B8

**Files:**
- Modify: `src/emit/lua.nim`
- Test: `tests/test_lua.nim`

Emit user function refinements as positional boolean flags.

**Calling convention:** Refinements become extra boolean params appended after regular params. Refinement params follow their boolean flag. Example:

```
greet: function [name /loud /pad size] [...]
```
Emits as:
```lua
function greet(name, loud, pad, size)
```

Calls:
- `greet "world"` → `greet("world", false, false, nil)`
- `greet/loud "world"` → `greet("world", true, false, nil)`
- `greet/pad "world" 10` → `greet("world", false, true, 10)`

- [ ] **Step 1: Write failing tests**

```nim
suite "refinement emission":
  test "function with refinement emits boolean param":
    let code = emitLua(parseSource("""
      greet: function [name /loud] [
        if loud [uppercase name]
      ]
    """))
    check "function greet(name, loud)" in code
    check "/loud" notin code

  test "refinement call emits true":
    let code = emitLua(parseSource("""
      greet: function [name /loud] [name]
      greet/loud "world"
    """))
    check "greet(\"world\", true)" in code

  test "non-refinement call emits false":
    let code = emitLua(parseSource("""
      greet: function [name /loud] [name]
      greet "world"
    """))
    check "greet(\"world\", false)" in code

  test "refinement with param":
    let code = emitLua(parseSource("""
      fmt: function [val /pad size] [val]
      fmt/pad 42 10
    """))
    check "function fmt(val, pad, size)" in code
    check "fmt(42, true, 10)" in code

  test "multiple refinements":
    let code = emitLua(parseSource("""
      say: function [msg /loud /prefix tag] [msg]
      say/loud "hi"
    """))
    check "function say(msg, loud, prefix, tag)" in code
    check "say(\"hi\", true, false, nil)" in code
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`

- [ ] **Step 3: Update emitFuncDef to handle refinements**

In `emitFuncDef`, parse the spec block properly:

```nim
proc emitFuncDef(e: var LuaEmitter, specBlock, bodyBlock: seq[KtgValue]): string =
  var params: seq[string] = @[]
  var refinements: seq[tuple[name: string, params: seq[string]]] = @[]
  var i = 0
  var currentRef = ""
  while i < specBlock.len:
    let s = specBlock[i]
    # Refinement: /name token
    if s.kind == vkWord and s.wordKind == wkWord and s.wordName.startsWith("/"):
      currentRef = s.wordName[1..^1]
      refinements.add((name: currentRef, params: @[]))
      i += 1
      continue
    if s.kind == vkWord and s.wordKind == wkWord:
      if currentRef.len > 0:
        # Refinement param
        refinements[^1].params.add(luaName(s.wordName))
      else:
        # Regular param
        params.add(luaName(s.wordName))
    elif s.kind == vkBlock:
      discard  # type annotation
    elif s.kind == vkWord and s.wordKind == wkSetWord:
      i += 1  # skip return: [type]
      if i < specBlock.len and specBlock[i].kind == vkBlock: discard
    i += 1

  # Build full param list: regular + refinement flags + refinement params
  var allParams = params
  for ref in refinements:
    allParams.add(luaName(ref.name))  # boolean flag
    for rp in ref.params:
      allParams.add(rp)

  # ... rest of function emission with allParams
```

- [ ] **Step 4: Update refinement call emission**

Store refinement info in `BindingInfo`:

```nim
type
  RefinementInfo = object
    name: string
    paramCount: int

  BindingInfo = object
    arity: int
    maxArity: int
    isFunction: bool
    isUnknown: bool
    refinements: seq[RefinementInfo]  ## NEW
```

When emitting a path like `greet/loud`:

```nim
# In the path emission section:
let parts = name.split('/')
let head = parts[0]
let refNames = parts[1..^1]

if head in e.bindings and e.bindings[head].isFunction and
   e.bindings[head].refinements.len > 0:
  let info = e.bindings[head]
  # Consume regular args
  var args: seq[string] = @[]
  for i in 0 ..< info.arity:
    args.add(e.emitExpr(vals, pos))  # TODO: update to emitVal after Task 2
  # Emit refinement flags and params
  for ref in info.refinements:
    let active = ref.name in refNames
    args.add(if active: "true" else: "false")
    if active:
      for j in 0 ..< ref.paramCount:
        args.add(e.emitExpr(vals, pos))
    else:
      for j in 0 ..< ref.paramCount:
        args.add("nil")
  result = e.resolvedName(head) & "(" & args.join(", ") & ")"
```

- [ ] **Step 5: Update prescanBlock to store refinement info**

In the prescan (Task 1's `prescanBlock`), when parsing a function spec, also collect refinement info:

```nim
var refInfos: seq[RefinementInfo] = @[]
# ... during spec parsing, when encountering /name:
refInfos.add(RefinementInfo(name: refName, paramCount: refParamCount))
# ... after parsing:
e.bindings[name] = BindingInfo(arity: paramCount, maxArity: paramCount,
                                isFunction: true, isUnknown: false,
                                refinements: refInfos)
```

- [ ] **Step 6: Run tests**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`
Expected: All refinement tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/emit/lua.nim tests/test_lua.nim
git commit -m "emitter: refinements as positional booleans"
```

---

## Task 4: Statement-Level Function Spec Parsing

**Fixes:** B8 (the emitBlock path for `name: function [spec] [body]`)

**Files:**
- Modify: `src/emit/lua.nim`
- Test: `tests/test_lua.nim`

The `emitBlock` path (around line 1484-1522) has its own function spec parser that doesn't skip refinements or type blocks correctly. It must match the logic from Task 3's `emitFuncDef`.

- [ ] **Step 1: Write failing test**

```nim
suite "statement-level function definition":
  test "typed params with refinement at statement level":
    let code = emitLua(parseSource("""
      place: function [pos [integer!] mark [string!] /force] [pos]
    """))
    check "function place(pos, mark, force)" in code
    check "integer" notin code
    check "/force" notin code
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep "typed params with refinement"`

- [ ] **Step 3: Refactor to share spec parsing**

Extract the spec-parsing logic from `emitFuncDef` (Task 3) into a shared helper:

```nim
type ParsedSpec = object
  params: seq[string]
  refinements: seq[tuple[name: string, params: seq[string]]]
  returnType: string

proc parseSpec(specBlock: seq[KtgValue]): ParsedSpec =
  ## Parse a function spec block into params, refinements, and return type.
  ## Handles type annotations, /refinements, and return: [type].
  var params: seq[string] = @[]
  var refinements: seq[tuple[name: string, params: seq[string]]] = @[]
  var returnType = ""
  var i = 0
  var inRefinement = false
  while i < specBlock.len:
    let s = specBlock[i]
    if s.kind == vkWord and s.wordKind == wkWord and s.wordName.startsWith("/"):
      let refName = s.wordName[1..^1]
      refinements.add((name: refName, params: @[]))
      inRefinement = true
      i += 1
      continue
    if s.kind == vkWord and s.wordKind == wkWord:
      if inRefinement:
        refinements[^1].params.add(luaName(s.wordName))
      else:
        params.add(luaName(s.wordName))
    elif s.kind == vkBlock:
      discard  # type annotation
    elif s.kind == vkWord and s.wordKind == wkSetWord and s.wordName == "return":
      i += 1
      if i < specBlock.len and specBlock[i].kind == vkBlock:
        let typeBlock = specBlock[i].blockVals
        if typeBlock.len > 0:
          returnType = $typeBlock[0]
    i += 1
  ParsedSpec(params: params, refinements: refinements, returnType: returnType)

proc allParams(spec: ParsedSpec): seq[string] =
  ## Full Lua param list: regular params + refinement flags + refinement params.
  result = spec.params
  for ref in spec.refinements:
    result.add(luaName(ref.name))
    for rp in ref.params:
      result.add(rp)
```

Use `parseSpec` in both `emitFuncDef` and the `emitBlock` statement-level function path.

- [ ] **Step 4: Run tests**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/emit/lua.nim tests/test_lua.nim
git commit -m "emitter: shared spec parser, fix statement-level function emission"
```

---

## Task 5: Native Refinement Calls

**Files:**
- Modify: `src/emit/lua.nim`
- Test: `tests/test_lua.nim`

Handle calls to native functions with refinements: `copy/deep`, `sort/by`, `round/down`, `round/up`.

- [ ] **Step 1: Write failing tests**

```nim
suite "native refinement calls":
  test "copy/deep emits deep copy helper":
    let code = emitLua(parseSource("""
      items: [[1 2] [3 4]]
      result: copy/deep items
    """))
    check "copy" notin code or "_deep_copy" in code  # should use a helper, not bare copy

  test "sort/by emits table.sort with comparator":
    let code = emitLua(parseSource("""
      items: [3 1 2]
      sort/by items :first
    """))
    check "table.sort" in code

  test "round/down emits math.floor":
    let code = emitLua(parseSource("""
      x: round/down 3.7
    """))
    check "math.floor(3.7)" in code

  test "round/up emits math.ceil":
    let code = emitLua(parseSource("""
      x: round/up 3.2
    """))
    check "math.ceil(3.2)" in code
```

- [ ] **Step 2: Run tests — round/down and round/up should already pass (they're special-cased). Identify which fail.**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`

- [ ] **Step 3: Add native refinement mappings**

In the bindings initialization, register native refinements that need special emission:

```nim
# In initNativeBindings or equivalent:
# These are handled as special cases in emitVal, not through the generic refinement system
# round/down and round/up already work via hardcoded checks (line 880-885)
# copy/deep needs a runtime helper
# sort/by needs table.sort with comparator
```

For `copy/deep`, add a prelude helper:

```nim
const LuaPrelude = """-- Kintsugi runtime support
local unpack = unpack or table.unpack
local _NONE = setmetatable({}, {__tostring = function() return "none" end})
local function _is_none(v) return v == nil or v == _NONE end
local function _deep_copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = _deep_copy(v) end
  return r
end
"""
```

Then in the path handler, when encountering `copy/deep`:
```nim
if head == "copy" and "deep" in refNames:
  let arg = e.emitExpr(vals, pos)
  result = "_deep_copy(" & arg & ")"
```

- [ ] **Step 4: Run tests**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep -E "FAIL|OK"`

- [ ] **Step 5: Commit**

```bash
git add src/emit/lua.nim tests/test_lua.nim
git commit -m "emitter: native refinement calls (copy/deep, sort/by)"
```

---

## Task 6: Integration Validation — Tic-Tac-Toe

**Files:**
- Test: `tests/test_lua.nim`
- Validate: `examples/tic-tac-toe/graphical/main.ktg`, `examples/tic-tac-toe/terminal/main.ktg`

End-to-end validation that real programs compile correctly.

- [ ] **Step 1: Write integration tests**

```nim
suite "tic-tac-toe compilation":
  test "graphical main compiles without errors":
    let source = readFile("examples/tic-tac-toe/graphical/main.ktg")
    let code = emitLua(parseSource(source))
    # Should not contain known bug patterns
    check "board.cells()" notin code
    check "state.full()" notin code
    check "state.choice()" notin code
    # Should contain correct patterns
    check "board.cells" in code
    check "ipairs(board.cells)" in code
    check "function cell_at(pos)" in code
    check "board.cells[pos]" in code

  test "terminal main compiles without errors":
    let source = readFile("examples/tic-tac-toe/terminal/main.ktg")
    let code = emitLua(parseSource(source))
    check "board.cells()" notin code
    check "board.cells" in code
```

- [ ] **Step 2: Run tests — they should fail with the current emitter, pass after Tasks 1-5**

Run: `nim c -r tests/test_lua.nim 2>&1 | grep "tic-tac-toe"`

- [ ] **Step 3: Fix any remaining issues found by integration tests**

Examine the compiled output, identify any bugs not covered by Tasks 1-5, fix them.

- [ ] **Step 4: Manually inspect compiled output**

Run: `bin/kintsugi -c examples/tic-tac-toe/graphical/main.ktg --stdout`

Read through the output line by line. Check:
- No `()` on value access
- `pick` calls have correct arity
- `copy`/`remove`/`insert` sequences are sequential statements
- `either` produces correct ternary or if/else
- Loop constructs are correct for/ipairs

- [ ] **Step 5: Run full test suite**

Run: `nimble test 2>&1 | grep -c "\[OK\]"`
Expected: 855+ passing (new tests add to the count)

- [ ] **Step 6: Commit**

```bash
git add src/emit/lua.nim tests/test_lua.nim
git commit -m "emitter: integration validation, tic-tac-toe compiles correctly"
```

---

## Task 7: Cleanup and Documentation

**Files:**
- Modify: `docs/HANDOFF.md`
- Modify: `docs/TODO.md`

- [ ] **Step 1: Update HANDOFF.md**

Remove "Lua emitter is heuristic-based and fragile" from the "What Needs Work" section. Replace with current state: "Lua emitter uses recursive binding tracking and context-aware dispatch. Known limitation: unknown paths default to field access (may need bindings dialect for foreign APIs)."

- [ ] **Step 2: Update TODO.md**

Remove or update entries that reference the old emitter limitations.

- [ ] **Step 3: Remove dead code**

Search for any procs that are no longer called after the refactor (the old `emitBlockReturn`, old `prescanArities`, old `arity()` helper). Delete them.

- [ ] **Step 4: Run full test suite one final time**

Run: `nimble test 2>&1 | grep -c "\[OK\]"`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add docs/HANDOFF.md docs/TODO.md src/emit/lua.nim
git commit -m "emitter: cleanup dead code, update docs"
```
