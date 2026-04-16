# Import System + Dead Code Elimination

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken `using` header mechanism with a proper `import` native, then add dead code elimination so imported stdlib modules don't bloat Lua output.

**Architecture:** `import` is a native with `/using` refinement (interpreter) and a special form recognized during prescan + emission (compiler). DCE adds a `scanUsedSymbols` prescan pass that builds a usage set, then gates function emission on membership. Both features live primarily in `src/eval/natives_io.nim` and `src/emit/lua.nim`.

**Tech Stack:** Nim 2.0+, existing unittest module, nimble test runner, golden test infrastructure.

**Dependency:** Import must ship first. DCE builds on top (imports change how stdlib enters the AST).

---

## File Structure

### New files

- `tests/test_import.nim` - tests for the import native (interpreter + compiler)
- `tests/golden/dce_math.ktg` - DCE golden: imports math, calls only `clamp`
- `tests/golden/dce_math.lua` - golden output: only `clamp` definition, no dead stdlib
- `tests/golden/dce_collections.ktg` - DCE golden: imports collections, calls `flatten`
- `tests/golden/dce_collections.lua` - golden output: `flatten` + `flatten_deep`, nothing else

### Modified files

- `src/eval/natives_io.nim` - extend `import` native for lit-word stdlib resolution + `/using` refinement
- `src/eval/evaluator.nim` - no changes (preprocessor already handles meta-words; import is a native, not a meta-word)
- `src/kintsugi.nim` - remove `loadStdlib`, `applyUsing`, `parseHeader`; remove `applyUsingHeader` calls in compile paths
- `src/emit/lua.nim` - add import prescan/emission; remove `applyUsingHeader`/`extractUsingModules`; add DCE fields, prescan, and emission gate
- `src/kintsugi_js.nim` - remove `applyUsingHeader` call; JS stdlib resolution via staticRead in natives_io
- `tests/test_golden.nim` - remove `applyUsingHeader` call in `compileKtg`
- `tests/test_leanlua_metrics.nim` - remove `applyUsingHeader` call; add DCE metrics
- `tests/test_emitter_fixes.nim` - update using-header test suite to import syntax
- `tests/test_std.nim` - update stdlib accessibility tests

---

## Part 1: Import System

### Task 1: Write failing tests for import native

**Files:**
- Create: `tests/test_import.nim`

- [ ] **Step 1: Write the test file**

```nim
import std/[unittest, strutils]
import ../src/core/types
import ../src/parse/parser
import ../src/eval/[evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect,
                        attempt_dialect, parse_dialect]
import ../src/emit/lua

proc setupEval(): Evaluator =
  result = newEvaluator()
  result.registerNatives()
  result.registerDialect(newLoopDialect())
  result.registerMatch()
  result.registerObjectDialect()
  result.registerAttempt()
  result.registerParse()

proc run(source: string): string =
  let eval = setupEval()
  discard eval.evalString(source)
  eval.output.join("\n")

proc compile(source: string): string =
  let ast = parseSource(source)
  let eval = setupEval()
  let processed = eval.preprocess(ast, forCompilation = true)
  emitLua(processed, "")

suite "import native - interpreter":

  test "import 'math makes math/clamp accessible":
    let out = run("import 'math\nprint math/clamp 15 0 10")
    check out.strip == "10"

  test "import ['math 'collections] imports both":
    let out = run("import ['math 'collections]\nprint math/clamp 15 0 10")
    check out.strip == "10"

  test "import/using 'math [clamp] makes clamp bare":
    let out = run("import/using 'math [clamp]\nprint clamp 15 0 10")
    check out.strip == "10"

  test "import/using selective - unlisted names inaccessible":
    expect(KtgError):
      discard run("import/using 'math [clamp]\nprint lerp 0 10 0.5")

  test "unimported stdlib is inaccessible":
    expect(KtgError):
      discard run("print clamp 15 0 10")

  test "std/math backdoor is closed":
    expect(KtgError):
      discard run("print std/math/clamp 15 0 10")

  test "import unknown module raises error":
    expect(KtgError):
      discard run("import 'nonexistent")

suite "import native - compiler":

  test "import 'math compiles with namespaced access":
    let lua = compile("import 'math\nprint math/clamp 15 0 10")
    check "clamp" in lua
    check "print" in lua

  test "import/using 'math [clamp] compiles with bare access":
    let lua = compile("import/using 'math [clamp]\nprint clamp 15 0 10")
    check "function clamp" in lua
    check "print(clamp(15, 0, 10))" in lua

  test "import without using does not pollute top-level":
    let lua = compile("import 'math\nprint math/clamp 15 0 10")
    check "local math = " in lua or "math.clamp" in lua
```

- [ ] **Step 2: Run to confirm tests fail**

Run: `nim c -r tests/test_import.nim`
Expected: FAIL (import does not handle lit-words yet)

- [ ] **Step 3: Commit**

```bash
git add tests/test_import.nim
git commit -m "test: add failing tests for import system"
```

---

### Task 2: Add stdlib module registry

**Files:**
- Modify: `src/eval/natives_io.nim`

- [ ] **Step 1: Read `natives_io.nim` to find the current import native**

The current import native handles `%file` paths. Find it and understand its structure.

- [ ] **Step 2: Add stdlib module registry constant**

Near the top of `natives_io.nim`, after imports, add:

```nim
const stdlibModules* = {
  "math": staticRead("../../lib/math.ktg"),
  "collections": staticRead("../../lib/collections.ktg"),
}.toTable
```

This embeds both modules at Nim compile time, works on all backends (native, JS).

- [ ] **Step 3: Add a proc to evaluate a stdlib module into an isolated context**

```nim
proc resolveStdlibModule(eval: Evaluator, moduleName: string): KtgContext =
  if moduleName notin stdlibModules:
    raise newKtgError("import", "unknown module: " & moduleName)
  let source = stdlibModules[moduleName]
  let moduleCtx = newContext(eval.global)
  moduleCtx.localOnly = true
  let ast = parseSource(source)
  discard eval.evalBlock(ast, moduleCtx)
  moduleCtx
```

- [ ] **Step 4: Commit**

```bash
git add src/eval/natives_io.nim
git commit -m "feat: add stdlib module registry with staticRead embedding"
```

---

### Task 3: Extend import native for lit-word stdlib resolution

**Files:**
- Modify: `src/eval/natives_io.nim`

- [ ] **Step 1: Read the existing import native to understand its dispatch**

Find the `import` native registration. It currently handles file-path arguments.

- [ ] **Step 2: Add lit-word branch to the import native's fn body**

Before the existing file-path handling, add:

```nim
# Stdlib import via lit-word: import 'math
if args[0].kind == vkWord and args[0].wordKind == wkLitWord:
  let moduleName = args[0].wordName
  let moduleCtx = resolveStdlibModule(eval, moduleName)
  let moduleVal = KtgValue(kind: vkContext, ctx: moduleCtx, line: 0)
  if "using" in eval.currentRefinements:
    # import/using 'math [clamp lerp] - selective flat import
    let symbolsBlock = args[1]
    if symbolsBlock.kind != vkBlock:
      raise newKtgError("import", "import/using requires a block of names")
    for sym in symbolsBlock.blockVals:
      if sym.kind == vkWord:
        let symName = sym.wordName
        if not moduleCtx.has(symName):
          raise newKtgError("import", moduleName & " has no export: " & symName)
        eval.currentCtx.set(symName, moduleCtx.get(symName))
  else:
    # import 'math - namespaced
    eval.currentCtx.set(moduleName, moduleVal)
  return ktgNone()

# Block of lit-words: import ['math 'collections]
if args[0].kind == vkBlock:
  for item in args[0].blockVals:
    if item.kind == vkWord and item.wordKind == wkLitWord:
      let moduleName = item.wordName
      let moduleCtx = resolveStdlibModule(eval, moduleName)
      let moduleVal = KtgValue(kind: vkContext, ctx: moduleCtx, line: 0)
      eval.currentCtx.set(moduleName, moduleVal)
    else:
      raise newKtgError("import", "block items must be lit-words, got: " & $item)
  return ktgNone()
```

- [ ] **Step 3: Add `/using` refinement spec to the import native**

Find the `RefinementSpec` list for import. Add:

```nim
RefinementSpec(name: "using", params: @[ParamSpec(name: "symbols")])
```

This makes `import/using 'math [clamp lerp]` consume the block argument as the refinement's parameter.

- [ ] **Step 4: Run interpreter tests**

Run: `nim c -r tests/test_import.nim`
Expected: interpreter suite passes, compiler suite still fails

- [ ] **Step 5: Commit**

```bash
git add src/eval/natives_io.nim
git commit -m "feat: import native handles lit-word stdlib + /using refinement"
```

---

### Task 4: Remove loadStdlib and old using mechanism

**Files:**
- Modify: `src/kintsugi.nim`

- [ ] **Step 1: Read kintsugi.nim lines 42-116**

Identify `loadStdlib`, `applyUsing`, `parseHeader`, and where they are called.

- [ ] **Step 2: Remove `loadStdlib` proc (lines 42-68)**

Delete the entire proc. It unconditionally loaded stdlib into the global scope.

- [ ] **Step 3: Remove `applyUsing` proc (lines 70-81)**

Delete the entire proc. It was the old flattening mechanism.

- [ ] **Step 4: Remove `parseHeader` proc (lines 83-105)**

Delete the entire proc. The `Kintsugi [using [...]]` header is no longer recognized.

- [ ] **Step 5: Remove `loadStdlib()` call from `setupEval` (line 115)**

Remove the line `eval.loadStdlib()`. The evaluator starts clean; stdlib is only available via `import`.

- [ ] **Step 6: Remove `parseHeader`/`applyUsing` calls from file runner**

In the `runSingleFile` and `runDirectory` procs, find where `parseHeader` is called and `applyUsing` is invoked. Remove these calls. The `stripHeader` call stays (it strips `Kintsugi [name: ...]` for non-using purposes).

- [ ] **Step 7: Remove `applyUsingHeader` calls from compile paths**

In `compileOne` (around line 257) and `dryRunPath` (around lines 295, 308), remove `let source = applyUsingHeader(content)` and replace with `let source = content` (or just use content directly).

- [ ] **Step 8: Run tests to assess breakage**

Run: `nimble test`
Expected: some tests fail (tests that relied on `using` header or `std/math` backdoor). Note which ones.

- [ ] **Step 9: Commit**

```bash
git add src/kintsugi.nim
git commit -m "refactor: remove loadStdlib, applyUsing, parseHeader from CLI entry"
```

---

### Task 5: Update existing tests for new import syntax

**Files:**
- Modify: `tests/test_std.nim`
- Modify: `tests/test_golden.nim`
- Modify: `tests/test_leanlua_metrics.nim`
- Modify: `tests/test_emitter_fixes.nim`

- [ ] **Step 1: Read test_std.nim and identify tests that use `std/math` or `using`**

- [ ] **Step 2: Update test_std.nim to use `import` syntax**

Replace `Kintsugi [using [math]]` headers with `import 'math` or `import/using 'math [func-names]` statements. Replace `std/math/clamp` accesses with `math/clamp` (after `import 'math`).

- [ ] **Step 3: Update test_golden.nim to remove `applyUsingHeader` call**

In `compileKtg` proc, remove the `applyUsingHeader(content)` call. The source is passed directly to the parser; `import` statements in the source handle stdlib inclusion.

- [ ] **Step 4: Update test_leanlua_metrics.nim similarly**

Remove `applyUsingHeader` from the compile helper.

- [ ] **Step 5: Update test_emitter_fixes.nim**

Find the using-header test suite. Replace `Kintsugi [using [...]]` with `import` statements.

- [ ] **Step 6: Update golden .ktg files that use `Kintsugi [using [...]]`**

Check each golden source file for `using` headers and replace with `import` statements.

- [ ] **Step 7: Regenerate goldens**

Run: `nim c -r tests/test_golden.nim -- --update`

- [ ] **Step 8: Run full test suite**

Run: `nimble test`
Expected: ALL tests pass

- [ ] **Step 9: Commit**

```bash
git add tests/
git commit -m "test: update all tests for import system, remove applyUsingHeader"
```

---

### Task 6: Compiler prescan + emission for stdlib import

**Files:**
- Modify: `src/emit/lua.nim`

- [ ] **Step 1: Read how the emitter currently handles `import %path`**

Find in `prescanBlock` (around line 4103) and `emitBlock` where file imports are recognized. The stdlib import follows the same pattern but resolves against the embedded registry instead of the filesystem.

- [ ] **Step 2: Add stdlib import recognition to `prescanBlock`**

When the prescan encounters `import 'math` (a word `import` followed by a lit-word), it should:
- Look up the module in `stdlibModules`
- Parse the stdlib source
- Prescan the stdlib AST to collect bindings
- Store bindings namespaced (e.g., `math/clamp`) or flat (for `/using`)

```nim
# In prescanBlock, after existing import handling:
if vals[i].kind == vkWord and vals[i].wordKind == wkWord and
   vals[i].wordName == "import":
  if i + 1 < vals.len and vals[i + 1].kind == vkWord and
     vals[i + 1].wordKind == wkLitWord:
    let moduleName = vals[i + 1].wordName
    if moduleName in stdlibModules:
      let modAst = parseSource(stdlibModules[moduleName])
      e.prescanBlock(modAst)
      # Register bindings under module namespace
      ...
```

- [ ] **Step 3: Add stdlib import emission to `emitBlock`**

When the emitter encounters `import 'math`:
- Emit the stdlib module's AST as a Lua table:
  ```lua
  local math = {}
  math.clamp = function(val, lo, hi) ... end
  ```
- OR: emit as a local scope then assign to table (simpler - emit all functions as locals, then build the table)

When the emitter encounters `import/using 'math [clamp lerp]`:
- Emit only the requested functions as top-level locals (like current applyUsingHeader but selective)
- For MVP: emit all module functions as locals (matching current behavior), let DCE handle elimination later

- [ ] **Step 4: Remove `applyUsingHeader` and `extractUsingModules` from lua.nim**

Delete lines 4230-4270 (both procs). Delete the `stripKtgHeader` proc if it's only used by these. Remove the `stdlibMathSrc` / `stdlibCollectionsSrc` constants (lines 4227-4228) - stdlib source is now in `stdlibModules` from `natives_io.nim`.

- [ ] **Step 5: Run compiler tests**

Run: `nim c -r tests/test_import.nim`
Expected: ALL tests pass (both interpreter and compiler suites)

- [ ] **Step 6: Run full suite**

Run: `nimble test`
Expected: ALL tests pass

- [ ] **Step 7: Commit**

```bash
git add src/emit/lua.nim
git commit -m "feat: compiler handles import 'module and import/using in prescan + emission"
```

---

### Task 7: Update kintsugi_js.nim for new import path

**Files:**
- Modify: `src/kintsugi_js.nim`

- [ ] **Step 1: Read current kintsugi_js.nim**

It currently calls `applyUsingHeader($source)` in both `kintsugiCompile` and `kintsugiRun`.

- [ ] **Step 2: Replace `applyUsingHeader` calls**

For `kintsugiCompile`: remove the `applyUsingHeader` call. The emitter now handles `import` statements in the AST.

```nim
proc kintsugiCompile*(source: cstring, target: cstring): cstring {.exportc.} =
  try:
    let ast = parseSource($source)
    let eval = setupEval()
    let processed = eval.preprocess(ast, forCompilation = true)
    cstring(emitLua(processed, $target))
  ...
```

For `kintsugiRun`: remove the `applyUsingHeader` call. The evaluator's `import` native handles stdlib loading when it encounters `import` statements.

```nim
proc kintsugiRun*(source: cstring): cstring {.exportc.} =
  try:
    let eval = setupEval()
    discard eval.evalString($source)
    ...
```

- [ ] **Step 3: Verify stdlib resolution works on JS backend**

The `stdlibModules` table in `natives_io.nim` uses `staticRead`, which works on both native and JS backends. The `resolveStdlibModule` proc evaluates the source at runtime. On JS, `parseSource` and `evalBlock` work the same way.

- [ ] **Step 4: Rebuild the JS bundle**

Run: `nim js -d:release --outdir:web src/kintsugi_js.nim`

- [ ] **Step 5: Test via Node**

```bash
node -e "
const fs = require('fs');
const vm = require('vm');
const b = fs.readFileSync('web/kintsugi_js.js', 'utf8');
const ctx = vm.createContext({console,setTimeout,setInterval,clearTimeout,clearInterval});
vm.runInContext(b, ctx);
console.log(vm.runInContext('kintsugiCompile(\"import/using \\'math [clamp]\\nprint clamp 15 0 10\", \"\")', ctx));
"
```

Expected: clean Lua output with `clamp` function definition and `print(clamp(15, 0, 10))`.

- [ ] **Step 6: Commit**

```bash
git add src/kintsugi_js.nim
git commit -m "feat: kintsugi_js uses new import system, remove applyUsingHeader"
```

---

### Task 8: Update playground examples

**Files:**
- Modify: `/home/raycat/Desktop/projects/kintsugi-lang/kintsugi-playground/src/examples.ts`

- [ ] **Step 1: Update combat example to use `import/using` if it needs stdlib**

Check if the combat excerpt uses any stdlib functions. If yes, add `import/using 'math [clamp]` at the top. If no (it defines its own `clamp`), no change needed.

- [ ] **Step 2: Sync the playground bundle**

```bash
cd ../kintsugi-playground && ./sync-bundle.sh
```

- [ ] **Step 3: Commit**

```bash
git add ../kintsugi-playground/src/examples.ts
git commit -m "chore: update playground examples for import syntax"
```

---

## Part 2: Dead Code Elimination

### Task 9: Add DCE data structures

**Files:**
- Modify: `src/emit/lua.nim`

- [ ] **Step 1: Add new fields to `LuaEmitter`**

After the existing `usedHelpers` field (line 63), add:

```nim
    usedSymbols: HashSet[string]
    topLevelFuncDefs: HashSet[string]
    funcBodies: Table[string, seq[KtgValue]]
```

- [ ] **Step 2: Commit**

```bash
git add src/emit/lua.nim
git commit -m "refactor: add DCE data structures to LuaEmitter"
```

---

### Task 10: Write failing DCE tests

**Files:**
- Modify: `tests/test_leanlua_metrics.nim`
- Create: `tests/golden/dce_math.ktg`
- Create: `tests/golden/dce_collections.ktg`

- [ ] **Step 1: Add DCE metric tests**

```nim
  test "import/using with single call emits only needed functions":
    let src = "import/using 'math [clamp]\nprint clamp 15 0 10\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check "function clamp" in lua
    check "function lerp" notin lua
    check "function smoothstep" notin lua

  test "transitive deps are kept":
    let src = "import/using 'collections [flatten]\nprint flatten [[1 2] [3 4]]\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check "function flatten" in lua
    check "function flatten_deep" in lua
    check "function zip" notin lua

  test "get-word reference preserves function":
    let src = "import/using 'math [clamp]\nf: :clamp\nprint f 15 0 10\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check "function clamp" in lua
```

- [ ] **Step 2: Create DCE golden source files**

Write `tests/golden/dce_math.ktg`:
```
import/using 'math [clamp]
print clamp 15 0 10
```

Write `tests/golden/dce_collections.ktg`:
```
import/using 'collections [flatten]
print flatten [[1 2] [3 4]]
```

- [ ] **Step 3: Run tests to confirm failure**

Run: `nim c -r tests/test_leanlua_metrics.nim`
Expected: DCE tests FAIL (all functions still emitted)

- [ ] **Step 4: Commit**

```bash
git add tests/test_leanlua_metrics.nim tests/golden/dce_math.ktg tests/golden/dce_collections.ktg
git commit -m "test: add failing DCE tests and golden sources"
```

---

### Task 11: Implement `collectTopLevelFuncDefs`

**Files:**
- Modify: `src/emit/lua.nim`

- [ ] **Step 1: Add proc near `collectModuleNames` (around line 4272)**

```nim
proc collectTopLevelFuncDefs(e: var LuaEmitter, vals: seq[KtgValue]) =
  var i = 0
  while i < vals.len:
    if vals[i].kind == vkWord and vals[i].wordKind == wkSetWord:
      let name = luaName(vals[i].wordName)
      if i + 1 < vals.len and vals[i + 1].kind == vkWord and
         vals[i + 1].wordKind == wkWord:
        if vals[i + 1].wordName == "function" and i + 3 < vals.len and
           vals[i + 2].kind == vkBlock and vals[i + 3].kind == vkBlock:
          e.topLevelFuncDefs.incl(name)
          e.funcBodies[name] = vals[i + 3].blockVals
          i += 4
          continue
        elif vals[i + 1].wordName == "does" and i + 2 < vals.len and
             vals[i + 2].kind == vkBlock:
          e.topLevelFuncDefs.incl(name)
          e.funcBodies[name] = vals[i + 2].blockVals
          i += 3
          continue
    i += 1
```

- [ ] **Step 2: Commit**

```bash
git add src/emit/lua.nim
git commit -m "feat: collectTopLevelFuncDefs identifies DCE candidates"
```

---

### Task 12: Implement `scanUsedSymbols` and transitive closure

**Files:**
- Modify: `src/emit/lua.nim`

- [ ] **Step 1: Add `scanUsedInBody` helper**

Recursive AST walker that marks all word references as used:

```nim
proc scanUsedInBody(e: var LuaEmitter, vals: seq[KtgValue]) =
  for v in vals:
    case v.kind
    of vkBlock: e.scanUsedInBody(v.blockVals)
    of vkParen: e.scanUsedInBody(v.parenVals)
    of vkWord:
      case v.wordKind
      of wkWord:
        let name = luaName(v.wordName)
        if name notin ["function", "does", "object", "if", "either",
                        "unless", "loop", "match", "return", "break",
                        "set", "context", "import", "true", "false", "none",
                        "Kintsugi", "exports", "bindings", "attempt",
                        "error", "while", "repeat", "and", "or", "not",
                        "make", "copy", "print", "rejoin", "append",
                        "remove", "insert", "pick", "first", "second",
                        "last", "length", "empty?", "reduce", "sort",
                        "join", "split", "find", "has?", "type",
                        "negate", "modulo", "random"]:
          e.usedSymbols.incl(name)
          if '/' in v.wordName:
            e.usedSymbols.incl(luaName(v.wordName.split('/')[0]))
      of wkGetWord, wkLitWord:
        e.usedSymbols.incl(luaName(v.wordName))
      else: discard
    else: discard
```

Wait - this approach of excluding builtins is fragile. Better approach: mark everything as used, then only GATE emission for names in `topLevelFuncDefs`. Builtins are not in `topLevelFuncDefs` so they are never eliminated.

Revised:

```nim
proc scanUsedInBody(e: var LuaEmitter, vals: seq[KtgValue]) =
  for v in vals:
    case v.kind
    of vkBlock: e.scanUsedInBody(v.blockVals)
    of vkParen: e.scanUsedInBody(v.parenVals)
    of vkWord:
      let name = luaName(v.wordName)
      case v.wordKind
      of wkWord:
        if v.wordName notin ["function", "does", "object"]:
          e.usedSymbols.incl(name)
      of wkGetWord, wkLitWord:
        e.usedSymbols.incl(name)
      of wkSetWord:
        discard
      else: discard
    else: discard
```

- [ ] **Step 2: Add `scanTopLevelUsage` - Phase 1 of DCE scan**

Scans only non-function-def top-level code to find the root set:

```nim
proc scanTopLevelUsage(e: var LuaEmitter, vals: seq[KtgValue]) =
  var i = 0
  while i < vals.len:
    if vals[i].kind == vkWord and vals[i].wordKind == wkSetWord:
      let name = luaName(vals[i].wordName)
      i += 1
      if name in e.topLevelFuncDefs:
        # Skip function/does definition - don't scan body yet
        if i < vals.len and vals[i].kind == vkWord and
           vals[i].wordName == "function":
          i += 1
          if i < vals.len and vals[i].kind == vkBlock: i += 1
          if i < vals.len and vals[i].kind == vkBlock: i += 1
          continue
        elif i < vals.len and vals[i].kind == vkWord and
             vals[i].wordName == "does":
          i += 1
          if i < vals.len and vals[i].kind == vkBlock: i += 1
          continue
      # Non-function def or non-top-level-func: scan RHS
      continue
    # Non-set-word: scan for usage
    case vals[i].kind
    of vkWord:
      let name = luaName(vals[i].wordName)
      if vals[i].wordKind in {wkWord, wkGetWord, wkLitWord}:
        e.usedSymbols.incl(name)
    of vkBlock: e.scanUsedInBody(vals[i].blockVals)
    of vkParen: e.scanUsedInBody(vals[i].parenVals)
    else: discard
    i += 1
```

- [ ] **Step 3: Add `resolveTransitiveDeps` - Phase 2 of DCE scan**

```nim
proc resolveTransitiveDeps(e: var LuaEmitter) =
  var changed = true
  while changed:
    changed = false
    for name, body in e.funcBodies:
      if name in e.usedSymbols:
        let prevSize = e.usedSymbols.len
        e.scanUsedInBody(body)
        if e.usedSymbols.len > prevSize:
          changed = true
```

- [ ] **Step 4: Commit**

```bash
git add src/emit/lua.nim
git commit -m "feat: scanUsedSymbols + transitive closure for DCE"
```

---

### Task 13: Wire DCE into emitLua and gate emission

**Files:**
- Modify: `src/emit/lua.nim`

- [ ] **Step 1: Wire scans into `emitLua` (around line 4341)**

After `scanNoneUsage(ast)` and before `emitBlock(ast)`, add:

```nim
e.collectTopLevelFuncDefs(ast)
e.scanTopLevelUsage(ast)
e.resolveTransitiveDeps()
```

Do the same in `emitLuaModule` (around line 4282), with the addition of seeding exports:

```nim
e.collectTopLevelFuncDefs(ast)
# Exports are always used
for v in ast:
  if v.kind == vkWord and v.wordKind == wkWord and v.wordName == "exports":
    # next value is the exports block
    ...
e.scanTopLevelUsage(ast)
e.resolveTransitiveDeps()
```

- [ ] **Step 2: Add emission gate in `emitBlock`**

Before the function definition emission (around line 3233), after the set-word name is resolved but before the RHS check:

```nim
# DCE: skip unused top-level function definitions
if rawName in e.topLevelFuncDefs and rawName notin e.usedSymbols:
  if pos < vals.len and vals[pos].kind == vkWord and
     vals[pos].wordName == "function":
    pos += 1  # skip "function"
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1  # skip spec
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1  # skip body
    continue
  elif pos < vals.len and vals[pos].kind == vkWord and
       vals[pos].wordName == "does":
    pos += 1  # skip "does"
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1  # skip body
    continue
```

- [ ] **Step 3: Run DCE tests**

Run: `nim c -r tests/test_leanlua_metrics.nim`
Expected: DCE tests PASS

- [ ] **Step 4: Run full test suite**

Run: `nimble test`
Expected: ALL tests pass

- [ ] **Step 5: Generate DCE goldens**

Run: `nim c -r tests/test_golden.nim -- --update`
Verify `tests/golden/dce_math.lua` contains only `clamp` and `print`, no other math functions.

- [ ] **Step 6: Commit**

```bash
git add src/emit/lua.nim tests/golden/dce_math.lua tests/golden/dce_collections.lua
git commit -m "feat: dead code elimination for unused top-level function definitions"
```

---

### Task 14: End-to-end verification

**Files:** (none modified)

- [ ] **Step 1: Run the full test suite**

Run: `nimble test`
Expected: ALL tests pass (1350+ with new tests)

- [ ] **Step 2: Rebuild JS bundle and test playground**

```bash
cd /home/raycat/Desktop/projects/kintsugi-lang/kintsugi
nim js -d:release --outdir:web src/kintsugi_js.nim
cd ../kintsugi-playground
./sync-bundle.sh
npm run dev
```

Verify in browser:
- Hello example compiles to minimal Lua (no stdlib bloat)
- Combat example compiles cleanly
- Pong example compiles with love2d target

- [ ] **Step 3: Verify DCE output quality**

Compile a program that imports math and uses only clamp:
```bash
echo 'import/using '\''math [clamp]
print clamp 15 0 10' > /tmp/test_dce.ktg
bin/kintsugi -c /tmp/test_dce.ktg --dry-run
```

Expected output: ~10 lines (clamp definition + print call), NOT ~200 lines.

- [ ] **Step 4: Commit any final golden updates**

```bash
git add -A tests/golden/
git commit -m "chore: regenerate goldens after import + DCE"
```

---

## Verification Checklist

- [ ] `nimble test` passes (all 1350+ tests)
- [ ] `import 'math` namespaces correctly in interpreter
- [ ] `import/using 'math [clamp]` flattens selectively in interpreter
- [ ] Unimported stdlib is inaccessible (no `std/math` backdoor)
- [ ] `import 'math` compiles to namespaced Lua table
- [ ] `import/using 'math [clamp]` compiles to flat local function
- [ ] DCE eliminates unused stdlib functions from Lua output
- [ ] DCE preserves transitively-referenced functions
- [ ] DCE preserves get-word referenced functions
- [ ] JS bundle works (kintsugiCompile, kintsugiRun with import syntax)
- [ ] Playground compiles examples correctly
- [ ] Golden tests match expected output
- [ ] No `applyUsingHeader` calls remain in codebase
- [ ] No `loadStdlib` calls remain in codebase
