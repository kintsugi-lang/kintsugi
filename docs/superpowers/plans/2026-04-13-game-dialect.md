# @game Dialect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `@game` preprocess-time dialect that expands declarative `@game [...]` blocks into plain Kintsugi AST, producing clean LÖVE2D Lua (Step 5-8) and Playdate Lua (Step 9) output from the same source with only the `target:` field swapped.

**Architecture:** New file `src/dialects/game_dialect.nim` defines the `GameBackend` abstraction and `love2dBackend`. New file `src/dialects/game_playdate.nim` (Step 9) defines `playdateBackend`. The `expand(block) -> seq[KtgValue]` entry point is called from `src/eval/evaluator.nim`'s `preprocess` proc at a new `@game` branch alongside the existing `@inline`/`@preprocess`/`@macro` handlers. A new `prettyPrintBlock` helper in `src/core/pretty.nim` gives round-trippable `_expanded.ktg` golden output — necessary because `src/core/types.nim`'s `$` operator is broken for strings and unimplemented for map/set/context/object.

**Tech Stack:** Nim 2.x, std/unittest, existing `tests/golden/` test runner (already built by the lean-lua plan), `nim c` test driver, `nimble test` full suite. LÖVE2D and Playdate simulator for runtime verification at exit gates.

**Spec:** `docs/superpowers/specs/2026-04-13-lean-lua-and-game-dialect-design.md` Steps 5-9. This plan assumes the lean-lua plan (Steps 1-4) has shipped — specifically that `tests/golden/` exists with a runner that does LF-normalized byte comparison via `nim c -r tests/test_golden.nim`. If that runner isn't present, Task 1 of this plan extends it to handle the three-layer `.ktg` / `_expanded.ktg` / `.lua` convention.

---

## File Structure

### New files

- `src/core/pretty.nim` — round-trippable `prettyPrintBlock(vals: seq[KtgValue]): string` (~80 lines). Separate from `src/core/types.nim` because types.nim's `$` is for debug printing and we don't want to break existing `$` tests.
- `src/dialects/game_dialect.nim` — `GameBackend` type, `love2dBackend` instance, `backends` registry, `expand(block, backends): seq[KtgValue]` entry, walker helpers (`expandConstants`, `expandScene`, `expandEntity`, `expandDraw`, `substituteSelf`, `substituteIt`).
- `src/dialects/game_playdate.nim` (Step 9) — `playdateBackend` instance only; imports types from `game_dialect`.
- `tests/test_game_pretty.nim` — round-trip tests for `prettyPrintBlock`.
- `tests/test_game_dialect.nim` — three-layer golden runner that compiles each `.ktg` twice (once via `dryExpand` for `_expanded.ktg`, once normally for `.lua`).
- `tests/test_game_dialect_substitution.nim` — unit tests for `substituteSelf`/`substituteIt` (Step 7).
- `examples/game-pong-stub/main.ktg` — Step 5 exit artifact, runs in LÖVE2D showing 3 static entities.
- `tests/golden/game_pong_stub.ktg` + `game_pong_stub_expanded.ktg` + `game_pong_stub.lua` — Step 5 three-layer goldens.
- `tests/golden/game_pong_nocollide.ktg` + `_expanded.ktg` + `.lua` — Step 6 three-layer goldens.
- `tests/golden/game_pong.ktg` + `_expanded.ktg` + `.lua` — Step 8 three-layer goldens (full Pong).
- `tests/golden/game_pong_playdate.ktg` + `_expanded.ktg` + `.lua` — Step 9 three-layer goldens.

### Modified files

- `src/eval/evaluator.nim` — `preprocess` proc at line 1032: line 1045 extend `hasWork` scan to include `"game"`; after line 1131 add a new `@game` branch calling `game_dialect.expand`.
- `src/kintsugi.nim` — `compileOne` path (line ~263) does NOT change; `@game` expansion happens inside `preprocess` which is already called.

### Unchanged

- `src/eval/dialect.nim` — `@game` does NOT use the runtime `Dialect` base class. It's a preprocess-time syntactic rewrite; no `interpret` method, no vocabulary registration.
- `src/emit/lua.nim` — should not need changes. Expanded Kintsugi emits via existing paths. If the expansion exercises an emitter corner case, fix it as a separate lean-lua-style task, not as part of `@game`.

### Existing functions/utilities to reuse

- `ktgBlock`, `ktgWord`, `ktgString`, `ktgInteger`, `ktgFloat`, `ktgSetWord`, `ktgLitWord`, `ktgMetaWord`, `ktgPair`, `ktgNone` — constructors in `src/core/types.nim` for building expanded AST
- `parseSource` in `src/parse/parser.nim` — used by the round-trip test to verify `prettyPrintBlock` output
- `applyUsingHeader`, `preprocess`, `emitLua`, `emitLuaModule` — pipeline primitives already used by `tests/test_golden.nim`
- Meta-word handler pattern at `src/eval/evaluator.nim:1067-1131` — template for the new `@game` branch
- `evalBlock`, `evalNext`, `callCallable` — NOT needed; `@game` does not run user code at expand time
- `GameBackend.loadShell`/`updateShell`/`drawShell`/`keypressedShell` procs — the dialect core calls these to get backend-specific AST snippets without embedding LÖVE2D-specific names

### Pre-existing state (verified 2026-04-13)

- `src/eval/evaluator.nim` `proc preprocess*` at line 1032; `hasWork` scan at 1042-1047; meta-word handlers 1067-1131; fall-through at 1133-1135
- `src/core/types.nim` `$` proc (vkString outputs raw without quotes, vkMap/vkSet/vkContext/vkObject unimplemented) — **cannot be reused for pretty-print**
- `src/parse/parser.nim` / `src/parse/lexer.nim` — whitespace-lenient, indentation-agnostic
- `src/emit/lua.nim` line 2808, 3163-3175, 3864 — `@const` metaword emits as a Lua `local` constant; the emitter handles it correctly
- Lean-lua plan Steps 1-4 shipped; `tests/golden/` infrastructure exists (Task 1 of this plan extends rather than creates)

---

## Conventions

**TDD per task.** Each task: failing test → run to fail → minimal impl → run to pass → (regenerate goldens if applicable) → commit.

**Commits.** One semantic commit per task (~21 commits). Commit messages use imperative-mood semantic subjects, not the repo's `"Updates."` placeholder, matching the lean-lua plan's convention.

**Running a single test file:**
```bash
cd /home/raycat/Desktop/projects/kintsugi
nim c -r tests/test_game_dialect.nim
nim c -r tests/test_game_pretty.nim
nim c -r tests/test_game_dialect_substitution.nim
```

**Regenerating three-layer goldens:**
```bash
nim c -r tests/test_game_dialect.nim -- --update
```

**Full suite:**
```bash
nimble test
```

**Runtime sanity checks at exit gates:**
```bash
cd examples/game-pong-stub && love .                  # Step 5
cd examples/game-pong-nocollide && love .             # Step 6
cd examples/game-pong && love .                       # Step 8
cd examples/game-pong-playdate && ../path/to/pdc .    # Step 9
```

**Hand-off for git:** I cannot run git commands directly (permission-gated). Each task's commit step is a command the user runs; I produce the command and wait for confirmation.

---

## Step 5 — @game Phase 1: Minimal skeleton

**Session budget:** 1-2 sessions. Six tasks.

**Deliverable:** `@game` block with `target:`, `constants`, and a single `scene` containing entities with `pos`/`rect`/`color` renders 3 static rectangles in LÖVE2D. Three golden files pass. `_expanded.ktg` contains no bloat vs `docs/pong-generated.ktg`.

---

### Task 1: Write `prettyPrintBlock` and its round-trip tests

**Files:**
- Create: `src/core/pretty.nim`
- Create: `tests/test_game_pretty.nim`

**Context.** `src/core/types.nim`'s `$` is broken for round-trip: `ktgString("hi")` displays as `hi` (no quotes), and map/set/context/object are placeholders. We need a printer whose output re-parses to the same AST. Parser is whitespace-lenient, so indentation is not required — space-separated flat is fine.

- [ ] **Step 1: Write the failing round-trip test**

Write `tests/test_game_pretty.nim`:

```nim
import std/unittest
import ../src/core/[types, pretty]
import ../src/parse/parser

proc roundTrip(src: string) =
  let ast = parseSource(src)
  let pretty = prettyPrintBlock(ast)
  let ast2 = parseSource(pretty)
  check $ast == $ast2  ## uses $, but we compare printed forms as sanity
  check ast.len == ast2.len

suite "pretty print round trip":
  test "empty block": roundTrip("[]")
  test "integers and words": roundTrip("x: 42  y: 7  [x y]")
  test "nested blocks": roundTrip("foo: [bar [1 2 3] baz]")
  test "string with newline escape":
    let src = "msg: \"line one\\nline two\""
    let ast = parseSource(src)
    let pretty = prettyPrintBlock(ast)
    let ast2 = parseSource(pretty)
    check ast2[1].kind == vkString
    check ast2[1].strVal == "line one\nline two"
  test "set-word, lit-word, meta-word, get-word":
    roundTrip("name: value  'lit  @const  :getter")
  test "refinement word": roundTrip("loop/collect [for [x] in xs do [x]]")
  test "paren distinct from block": roundTrip("[a (b c) d]")
  test "pair and tuple": roundTrip("p: 100x200  v: 1.2.3")
```

- [ ] **Step 2: Run it to confirm failure**

```bash
nim c -r tests/test_game_pretty.nim
```

Expected: compile error, `pretty` module not found.

- [ ] **Step 3: Write the minimal `prettyPrintBlock`**

Write `src/core/pretty.nim`:

```nim
import std/[strutils, strformat]
import types

proc prettyPrintValue*(v: KtgValue): string
proc prettyPrintBlock*(vals: seq[KtgValue]): string

proc escapeString(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\r': result.add("\\r")
    else: result.add(c)
  result.add("\"")

proc prettyPrintValue*(v: KtgValue): string =
  case v.kind
  of vkInteger: $v.intVal
  of vkFloat: $v.floatVal
  of vkString: escapeString(v.strVal)
  of vkLogic: (if v.logicVal: "true" else: "false")
  of vkNone: "none"
  of vkMoney: "$" & $v.moneyVal.float / 100.0
  of vkPair: $v.pairX & "x" & $v.pairY
  of vkTuple:
    var parts: seq[string] = @[]
    for b in v.tupleVals: parts.add($b)
    parts.join(".")
  of vkDate: fmt"{v.dateYear:04}-{v.dateMonth:02}-{v.dateDay:02}"
  of vkTime: fmt"{v.timeHour:02}:{v.timeMinute:02}:{v.timeSecond:02}"
  of vkFile: "%" & v.fileVal
  of vkUrl: v.urlVal
  of vkEmail: v.emailVal
  of vkBlock: "[" & prettyPrintBlock(v.blockVals) & "]"
  of vkParen: "(" & prettyPrintBlock(v.parenVals) & ")"
  of vkWord:
    case v.wordKind
    of wkWord: v.wordName
    of wkSetWord: v.wordName & ":"
    of wkGetWord: ":" & v.wordName
    of wkLitWord: "'" & v.wordName
    of wkMetaWord: "@" & v.wordName
  of vkOp: v.opSymbol
  else: "<" & $v.kind & ">"  ## unreached for @game expansion

proc prettyPrintBlock*(vals: seq[KtgValue]): string =
  var parts: seq[string] = @[]
  for v in vals:
    parts.add(prettyPrintValue(v))
  parts.join(" ")
```

- [ ] **Step 4: Run and confirm pass**

```bash
nim c -r tests/test_game_pretty.nim
```

Expected: all round-trip tests pass.

- [ ] **Step 5: Run full suite**

```bash
nimble test
```

- [ ] **Step 6: Commit**

```bash
git add src/core/pretty.nim tests/test_game_pretty.nim
git commit -m "Add round-trippable prettyPrintBlock for Kintsugi AST."
```

---

### Task 2: Create `game_dialect.nim` with `GameBackend` type and `love2dBackend` stub

**Files:**
- Create: `src/dialects/game_dialect.nim`
- Create: `tests/test_game_dialect.nim` (initial skeleton)

- [ ] **Step 1: Write the failing test**

Write `tests/test_game_dialect.nim`:

```nim
import std/unittest, std/tables
import ../src/core/types
import ../src/dialects/game_dialect

suite "game dialect skeleton":
  test "love2d backend is registered":
    check backends.hasKey("love2d")
    check backends["love2d"].name == "love2d"

  test "unknown target raises compile error":
    let block = @[
      ktgSetWord("target"),
      ktgLitWord("playstation6"),
    ]
    expect(ValueError):
      discard expand(block)
```

- [ ] **Step 2: Run to confirm failure**

```bash
nim c -r tests/test_game_dialect.nim
```

Expected: compile error, game_dialect not found.

- [ ] **Step 3: Write the minimal `game_dialect.nim`**

```nim
## @game dialect — preprocess-time syntactic rewrite.
##
## Expands @game [...] blocks into plain Kintsugi AST. Called from
## src/eval/evaluator.nim's preprocess pass. NEVER evaluates user code
## at expand time: expansion is purely syntactic.

import std/tables
import ../core/types

type
  GameBackend* = object
    name*: string
    bindings*: seq[KtgValue]
      ## Bindings block spliced at the top of the expansion.
    loadShell*: proc(body: seq[KtgValue]): seq[KtgValue] {.nimcall.}
    updateShell*: proc(body: seq[KtgValue]): seq[KtgValue] {.nimcall.}
    drawShell*: proc(body: seq[KtgValue]): seq[KtgValue] {.nimcall.}
    keypressedShell*: proc(body: seq[KtgValue]): seq[KtgValue] {.nimcall.}
    setColorCall*: proc(r, g, b: KtgValue): seq[KtgValue] {.nimcall.}
    drawRectCall*: proc(x, y, w, h: KtgValue): seq[KtgValue] {.nimcall.}
    quitCall*: proc(): seq[KtgValue] {.nimcall.}
    isKeyDown*: proc(key: KtgValue): seq[KtgValue] {.nimcall.}

# --- love2d backend ---

proc love2dLoadShell(body: seq[KtgValue]): seq[KtgValue] =
  @[]  ## filled in Task 3

proc love2dUpdateShell(body: seq[KtgValue]): seq[KtgValue] = @[]
proc love2dDrawShell(body: seq[KtgValue]): seq[KtgValue] = @[]
proc love2dKeypressedShell(body: seq[KtgValue]): seq[KtgValue] = @[]
proc love2dSetColorCall(r, g, b: KtgValue): seq[KtgValue] = @[]
proc love2dDrawRectCall(x, y, w, h: KtgValue): seq[KtgValue] = @[]
proc love2dQuitCall(): seq[KtgValue] = @[]
proc love2dIsKeyDown(key: KtgValue): seq[KtgValue] = @[]

let love2dBackend* = GameBackend(
  name: "love2d",
  bindings: @[],
  loadShell: love2dLoadShell,
  updateShell: love2dUpdateShell,
  drawShell: love2dDrawShell,
  keypressedShell: love2dKeypressedShell,
  setColorCall: love2dSetColorCall,
  drawRectCall: love2dDrawRectCall,
  quitCall: love2dQuitCall,
  isKeyDown: love2dIsKeyDown,
)

var backends* = {"love2d": love2dBackend}.toTable

# --- expand entry ---

proc findTarget(blk: seq[KtgValue]): string =
  ## Locate `target: 'name` in block; raise on missing/unknown.
  var i = 0
  while i < blk.len - 1:
    if blk[i].kind == vkWord and blk[i].wordKind == wkSetWord and
       blk[i].wordName == "target" and blk[i+1].kind == vkWord and
       blk[i+1].wordKind == wkLitWord:
      return blk[i+1].wordName
    i += 1
  raise newException(ValueError, "@game: missing `target: 'name` field")

proc expand*(blk: seq[KtgValue]): seq[KtgValue] =
  let targetName = findTarget(blk)
  if not backends.hasKey(targetName):
    raise newException(ValueError, "@game: unknown target '" & targetName & "'")
  result = @[]  ## Tasks 3-6 fill this in
```

- [ ] **Step 4: Run and confirm pass**

```bash
nim c -r tests/test_game_dialect.nim
```

Expected: both tests pass.

- [ ] **Step 5: Run full suite**

```bash
nimble test
```

- [ ] **Step 6: Commit**

```bash
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Add game_dialect.nim skeleton with GameBackend type and love2d stub."
```

---

### Task 3: Wire `@game` into the preprocess pass

**Files:**
- Modify: `src/eval/evaluator.nim:1045` (extend hasWork scan)
- Modify: `src/eval/evaluator.nim:1131-1135` (add `@game` branch before the fall-through)
- Modify: `tests/test_game_dialect.nim` (add end-to-end expand test)

- [ ] **Step 1: Add the failing end-to-end test**

Append to `tests/test_game_dialect.nim`:

```nim
import ../src/parse/parser
import ../src/eval/[evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect,
                        attempt_dialect, parse_dialect]

proc setupEvaluator(): Evaluator =
  result = newEvaluator()
  result.registerNatives()
  result.registerDialect(newLoopDialect())
  result.registerMatch()
  result.registerObjectDialect()
  result.registerAttempt()
  result.registerParse()

suite "game dialect preprocess wiring":
  test "bare @game splices empty expansion":
    let src = "Kintsugi [name: 'test]\n@game [target: 'love2d]\nprint \"hi\"\n"
    let ast = parseSource(src)
    let eval = setupEvaluator()
    let processed = eval.preprocess(ast, forCompilation = true)
    ## The @game word + its block should be gone; `print "hi"` remains.
    var seen = false
    for v in processed:
      if v.kind == vkWord and v.wordKind == wkMetaWord and v.wordName == "game":
        seen = true
    check not seen
```

- [ ] **Step 2: Run to confirm failure**

```bash
nim c -r tests/test_game_dialect.nim
```

Expected: the new test fails because `@game` is not handled in preprocess, so the fall-through copies the meta-word into the output.

- [ ] **Step 3: Modify `src/eval/evaluator.nim:1045`**

Extend the `hasWork` scan to include `"game"`:

```nim
  for v in ast:
    if v.kind == vkWord and v.wordKind == wkMetaWord and
       v.wordName in ["preprocess", "inline", "macro", "game"]:
      hasWork = true
      break
```

- [ ] **Step 4: Add the `@game` branch**

Import at the top of `src/eval/evaluator.nim` (find the existing `import ../dialects/...` lines):

```nim
import ../dialects/game_dialect
```

Then, inside the `while i < ast.len` loop in `preprocess`, ABOVE the `else:` fall-through at line ~1133, insert:

```nim
    # @game [block] — preprocess-time dialect expansion
    elif ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       ast[i].wordName == "game" and i + 1 < ast.len and
       ast[i + 1].kind == vkBlock:
      try:
        let expanded = game_dialect.expand(ast[i + 1].blockVals)
        for v in expanded:
          result.add(v)
      except ValueError as e:
        raise newException(ValueError, "@game at line " & $ast[i].wordLine &
                           ": " & e.msg)
      i += 2
```

- [ ] **Step 5: Run to confirm pass**

```bash
nim c -r tests/test_game_dialect.nim
```

Expected: all tests pass including the new end-to-end test.

- [ ] **Step 6: Run full suite**

```bash
nimble test
```

Expected: green. If any existing test fails, the import change introduced a cycle — fix by moving the `game_dialect` import after other dialect imports and check for circular-import errors.

- [ ] **Step 7: Commit**

```bash
git add src/eval/evaluator.nim tests/test_game_dialect.nim
git commit -m "Wire @game metaword into preprocess pass."
```

---

### Task 4: Expand `target:` + `constants [...]` + `scene 'name [...]` skeleton

**Files:**
- Modify: `src/dialects/game_dialect.nim` (expand proc body)
- Modify: `tests/test_game_dialect.nim`

**Context.** The expand proc currently returns an empty block. This task adds real rewriting for three constructs: `target:` is consumed silently, `constants [...]` becomes `@const NAME: val` entries, `scene 'name [...]` is walked (entity handling is Task 5).

- [ ] **Step 1: Add failing tests**

Append:

```nim
suite "game dialect expansion":
  test "constants become @const entries":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("constants"),
      ktgBlock(@[
        ktgSetWord("SCREEN-W"), ktgInteger(800),
        ktgSetWord("SCREEN-H"), ktgInteger(600),
      ]),
    ]
    let out = expand(blk)
    ## Expect @const SCREEN-W: 800 @const SCREEN-H: 600
    check out.len == 6
    check out[0].kind == vkWord and out[0].wordKind == wkMetaWord and out[0].wordName == "const"
    check out[1].kind == vkWord and out[1].wordKind == wkSetWord and out[1].wordName == "SCREEN-W"
    check out[2].kind == vkInteger and out[2].intVal == 800
    check out[3].wordName == "const"
    check out[4].wordName == "SCREEN-H"
    check out[5].intVal == 600
```

- [ ] **Step 2: Run to confirm failure**

```bash
nim c -r tests/test_game_dialect.nim
```

Expected: fails (expand still returns empty).

- [ ] **Step 3: Implement constants expansion**

Replace the `expand` proc in `src/dialects/game_dialect.nim`:

```nim
proc expandConstants(constantsBlock: seq[KtgValue]): seq[KtgValue] =
  var i = 0
  while i < constantsBlock.len - 1:
    if constantsBlock[i].kind == vkWord and
       constantsBlock[i].wordKind == wkSetWord:
      result.add(ktgMetaWord("const"))
      result.add(constantsBlock[i])
      result.add(constantsBlock[i + 1])
      i += 2
    else:
      i += 1

proc expandScene(sceneName: string, sceneBody: seq[KtgValue],
                 backend: GameBackend): seq[KtgValue] =
  ## Fills in Task 5-6.
  @[]

proc expand*(blk: seq[KtgValue]): seq[KtgValue] =
  let targetName = findTarget(blk)
  if not backends.hasKey(targetName):
    raise newException(ValueError, "@game: unknown target '" & targetName & "'")
  let backend = backends[targetName]

  # Splice backend.bindings at the top.
  for v in backend.bindings:
    result.add(v)

  # Walk top-level forms.
  var i = 0
  while i < blk.len:
    let v = blk[i]
    if v.kind == vkWord and v.wordKind == wkSetWord and v.wordName == "target":
      i += 2  ## consume target: 'name
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "constants" and
         i + 1 < blk.len and blk[i + 1].kind == vkBlock:
      for c in expandConstants(blk[i + 1].blockVals):
        result.add(c)
      i += 2
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "scene" and
         i + 2 < blk.len and blk[i + 1].kind == vkWord and
         blk[i + 1].wordKind == wkLitWord and blk[i + 2].kind == vkBlock:
      for s in expandScene(blk[i + 1].wordName, blk[i + 2].blockVals, backend):
        result.add(s)
      i += 3
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "go":
      i += 2  ## consume go 'name — no-op in Phase 1 (single scene)
    else:
      i += 1  ## tolerate/skip unknown forms, errors come in later tasks
```

- [ ] **Step 4: Run to confirm pass**

```bash
nim c -r tests/test_game_dialect.nim
```

Expected: green.

- [ ] **Step 5: Run full suite**

```bash
nimble test
```

- [ ] **Step 6: Commit**

```bash
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Expand @game target + constants into AST."
```

---

### Task 5: Expand `entity name [pos rect color]` into set-word + context

**Files:**
- Modify: `src/dialects/game_dialect.nim` (expandScene, expandEntity)
- Modify: `tests/test_game_dialect.nim`

**Context.** The spec maps `entity player [pos 20 260  rect 12 80  color 0.9 0.9 1]` to:

```
player: context [
  x: 20  y: 260
  w: 12  h: 80
  cr: 0.9  cg: 0.9  cb: 1
]
```

`pos`, `rect`, `color` are the fixed Phase-1 vocabulary. Unknown component → skip for now (later phases add `field`, `tags`, `update`).

- [ ] **Step 1: Failing test**

```nim
  test "entity expands to set-word context":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("entity"), ktgWord("player"),
        ktgBlock(@[
          ktgWord("pos"), ktgInteger(20), ktgInteger(260),
          ktgWord("rect"), ktgInteger(12), ktgInteger(80),
          ktgWord("color"), ktgFloat(0.9), ktgFloat(0.9), ktgFloat(1.0),
        ]),
      ]),
    ]
    let out = expand(blk)
    ## Find player: context [...]
    var found = false
    for i in 0 ..< out.len - 1:
      if out[i].kind == vkWord and out[i].wordKind == wkSetWord and
         out[i].wordName == "player":
        check out[i + 1].kind == vkWord  ## `context`
        check out[i + 1].wordName == "context"
        check out[i + 2].kind == vkBlock
        let ctx = out[i + 2].blockVals
        ## Spot check: first set-word is x:, second is y:
        check ctx[0].wordName == "x"
        check ctx[1].intVal == 20
        check ctx[2].wordName == "y"
        check ctx[3].intVal == 260
        found = true
    check found
```

- [ ] **Step 2: Run to confirm failure**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 3: Implement `expandEntity` and flesh out `expandScene`**

In `src/dialects/game_dialect.nim`, replace the stub `expandScene` with:

```nim
proc expandEntityComponents(body: seq[KtgValue]): seq[KtgValue] =
  ## Walk entity body, turning pos/rect/color into set-word pairs.
  var i = 0
  while i < body.len:
    let head = body[i]
    if head.kind == vkWord and head.wordKind == wkWord:
      case head.wordName
      of "pos":
        if i + 2 < body.len:
          result.add(ktgSetWord("x")); result.add(body[i + 1])
          result.add(ktgSetWord("y")); result.add(body[i + 2])
          i += 3
          continue
      of "rect":
        if i + 2 < body.len:
          result.add(ktgSetWord("w")); result.add(body[i + 1])
          result.add(ktgSetWord("h")); result.add(body[i + 2])
          i += 3
          continue
      of "color":
        if i + 3 < body.len:
          result.add(ktgSetWord("cr")); result.add(body[i + 1])
          result.add(ktgSetWord("cg")); result.add(body[i + 2])
          result.add(ktgSetWord("cb")); result.add(body[i + 3])
          i += 4
          continue
      else:
        discard
    i += 1  ## skip unknown

type
  Entity = object
    name: string
    ctxBlock: seq[KtgValue]
    drawBody: seq[KtgValue]  ## Step 6 adds update/field; for Phase 1 unused
  SceneAccum = object
    entities: seq[Entity]
    drawBody: seq[KtgValue]

proc walkScene(sceneBody: seq[KtgValue]): SceneAccum =
  var i = 0
  while i < sceneBody.len:
    let head = sceneBody[i]
    if head.kind == vkWord and head.wordKind == wkWord and head.wordName == "entity" and
       i + 2 < sceneBody.len and sceneBody[i + 1].kind == vkWord and
       sceneBody[i + 1].wordKind == wkWord and sceneBody[i + 2].kind == vkBlock:
      let name = sceneBody[i + 1].wordName
      let components = expandEntityComponents(sceneBody[i + 2].blockVals)
      result.entities.add(Entity(name: name, ctxBlock: components))
      i += 3
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "draw" and
         i + 1 < sceneBody.len and sceneBody[i + 1].kind == vkBlock:
      result.drawBody = sceneBody[i + 1].blockVals
      i += 2
    else:
      i += 1

proc expandScene(sceneName: string, sceneBody: seq[KtgValue],
                 backend: GameBackend): seq[KtgValue] =
  let accum = walkScene(sceneBody)

  # Emit each entity as `name: context [fields]`
  for ent in accum.entities:
    result.add(ktgSetWord(ent.name))
    result.add(ktgWord("context"))
    result.add(ktgBlock(ent.ctxBlock))

  ## love/load, love/update, love/draw emitted in Task 6
```

You will need constructors `ktgSetWord`, `ktgWord`, `ktgBlock`, `ktgLitWord`, `ktgMetaWord`. If they don't exist in `src/core/types.nim`, grep for `proc ktgWord` and add the missing constructors in a sibling commit *before* this task. (Likely they exist; lean-lua and object dialect rely on them.)

- [ ] **Step 4: Run to confirm pass**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 5: Full suite**

```bash
nimble test
```

- [ ] **Step 6: Commit**

```bash
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Expand @game entities with pos/rect/color into set-word contexts."
```

---

### Task 6: Emit `love/load`, `love/update`, `love/draw` via backend shells

**Files:**
- Modify: `src/dialects/game_dialect.nim` (love2d backend shells + expandScene emission)
- Modify: `tests/test_game_dialect.nim`

**Context.** Phase 1 draws entities. No movement, no input. The backend shells wrap bodies in the target's callback names. For LÖVE2D that's `love/load`, `love/update`, `love/draw`, `love/keypressed`. Each is a `function [...]` set-word at the top level.

- [ ] **Step 1: Add test for love/draw shell**

```nim
  test "love/draw emits setColor + drawRect per entity":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("entity"), ktgWord("player"),
        ktgBlock(@[
          ktgWord("pos"), ktgInteger(20), ktgInteger(260),
          ktgWord("rect"), ktgInteger(12), ktgInteger(80),
          ktgWord("color"), ktgFloat(0.9), ktgFloat(0.9), ktgFloat(1.0),
        ]),
      ]),
    ]
    let out = expand(blk)
    ## There must be a `love/draw:` set-word somewhere in `out`.
    var sawDraw = false
    for v in out:
      if v.kind == vkWord and v.wordKind == wkSetWord and v.wordName == "love/draw":
        sawDraw = true
    check sawDraw
```

- [ ] **Step 2: Run to confirm failure**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 3: Implement the LÖVE2D shells**

Replace the `love2dLoadShell`/`love2dUpdateShell`/`love2dDrawShell` stubs and add per-entity draw emission:

```nim
proc love2dLoadShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgSetWord("love/load"),
    ktgWord("function"),
    ktgBlock(@[]),
    ktgBlock(body),
  ]

proc love2dUpdateShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgSetWord("love/update"),
    ktgWord("function"),
    ktgBlock(@[ktgWord("dt")]),
    ktgBlock(body),
  ]

proc love2dDrawShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgSetWord("love/draw"),
    ktgWord("function"),
    ktgBlock(@[]),
    ktgBlock(body),
  ]

proc love2dKeypressedShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgSetWord("love/keypressed"),
    ktgWord("function"),
    ktgBlock(@[ktgWord("key")]),
    ktgBlock(body),
  ]

proc love2dSetColorCall(r, g, b: KtgValue): seq[KtgValue] =
  @[ktgWord("love/graphics/setColor"), r, g, b]

proc love2dDrawRectCall(x, y, w, h: KtgValue): seq[KtgValue] =
  @[ktgWord("love/graphics/rectangle"), ktgLitWord("fill"), x, y, w, h]

proc love2dQuitCall(): seq[KtgValue] =
  @[ktgWord("love/event/quit")]

proc love2dIsKeyDown(key: KtgValue): seq[KtgValue] =
  @[ktgWord("love/keyboard/isDown"), key]
```

Then, at the end of `expandScene`, add draw emission:

```nim
  # Build per-entity draw body:
  #   love/graphics/setColor ent/cr ent/cg ent/cb
  #   love/graphics/rectangle 'fill ent/x ent/y ent/w ent/h
  var drawStatements: seq[KtgValue] = @[]
  for ent in accum.entities:
    let cr = ktgWord(ent.name & "/cr")
    let cg = ktgWord(ent.name & "/cg")
    let cb = ktgWord(ent.name & "/cb")
    for v in backend.setColorCall(cr, cg, cb):
      drawStatements.add(v)
    let x = ktgWord(ent.name & "/x")
    let y = ktgWord(ent.name & "/y")
    let w = ktgWord(ent.name & "/w")
    let h = ktgWord(ent.name & "/h")
    for v in backend.drawRectCall(x, y, w, h):
      drawStatements.add(v)
  # Append user draw block (verbatim).
  for v in accum.drawBody:
    drawStatements.add(v)

  for v in backend.loadShell(@[]):
    result.add(v)
  for v in backend.updateShell(@[]):
    result.add(v)
  for v in backend.drawShell(drawStatements):
    result.add(v)
  for v in backend.keypressedShell(@[]):
    result.add(v)
```

- [ ] **Step 4: Run to confirm pass**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 5: Commit**

```bash
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Emit love/load, love/update, love/draw, love/keypressed shells."
```

---

### Task 7: Three-layer golden runner + `game_pong_stub` exit gate

**Files:**
- Modify: `tests/test_game_dialect.nim` (add three-layer golden suite)
- Create: `examples/game-pong-stub/main.ktg`
- Create: `tests/golden/game_pong_stub.ktg` (copy of the example)
- Create: `tests/golden/game_pong_stub_expanded.ktg` (post-dialect expansion)
- Create: `tests/golden/game_pong_stub.lua` (post-compile)

**Context.** The three-layer convention:
- `.ktg` → `_expanded.ktg`: dialect output. If this changes, the dialect changed.
- `_expanded.ktg` → `.lua`: emitter output.
- `.ktg` → `.lua`: end-to-end.

The runner compiles each `.ktg` twice: once with `dryExpand` (preprocess only, no emission) and once normally.

- [ ] **Step 1: Extend `tests/test_game_dialect.nim` with a golden suite**

```nim
import std/[os, strutils]
import ../src/core/pretty
import ../src/emit/lua

proc dryExpand(src: string): string =
  ## Parse + preprocess; return pretty-printed expanded AST.
  let sourceWithHeader = applyUsingHeader(src)
  let ast = parseSource(sourceWithHeader)
  let eval = setupEvaluator()
  let expanded = eval.preprocess(ast, forCompilation = true)
  prettyPrintBlock(expanded)

proc compileKtg(src, sourceDir: string): string =
  let sourceWithHeader = applyUsingHeader(src)
  let ast = parseSource(sourceWithHeader)
  let eval = setupEvaluator()
  let processed = eval.preprocess(ast, forCompilation = true)
  emitLua(processed, sourceDir)

proc normalizeLF(s: string): string =
  s.replace("\r\n", "\n").replace("\r", "\n")

proc goldenDir(): string =
  currentSourcePath().parentDir / "golden"

let update = commandLineParams().contains("--update")

suite "game dialect goldens (three layer)":
  for name in ["game_pong_stub"]:
    test name:
      let ktgPath = goldenDir() / (name & ".ktg")
      let expPath = goldenDir() / (name & "_expanded.ktg")
      let luaPath = goldenDir() / (name & ".lua")

      let src = readFile(ktgPath)
      let actualExpanded = normalizeLF(dryExpand(src)) & "\n"
      let actualLua = normalizeLF(compileKtg(src, goldenDir()))

      if update:
        writeFile(expPath, actualExpanded)
        writeFile(luaPath, actualLua)
        check true
      else:
        check fileExists(expPath) and fileExists(luaPath)
        check normalizeLF(readFile(expPath)) == actualExpanded
        check normalizeLF(readFile(luaPath)) == actualLua
```

- [ ] **Step 2: Write `examples/game-pong-stub/main.ktg`**

```
Kintsugi [name: 'pong-stub]

@game [
  target: 'love2d
  constants [
    SCREEN-W: 800
    SCREEN-H: 600
  ]
  scene 'main [
    entity player [pos 20 260  rect 12 80  color 0.9 0.9 1]
    entity cpu    [pos 768 260 rect 12 80  color 0.9 0.9 1]
    entity ball   [pos 396 296 rect 8 8    color 1 0.8 0.2]
  ]
  go 'main
]
```

- [ ] **Step 3: Mirror into the golden directory**

```bash
cp examples/game-pong-stub/main.ktg tests/golden/game_pong_stub.ktg
```

- [ ] **Step 4: Run with `--update` to capture baseline goldens**

```bash
nim c -r tests/test_game_dialect.nim -- --update
```

Expected: `tests/golden/game_pong_stub_expanded.ktg` and `tests/golden/game_pong_stub.lua` are written.

- [ ] **Step 5: Inspect `_expanded.ktg` by eye vs `docs/pong-generated.ktg`**

Open `tests/golden/game_pong_stub_expanded.ktg`. It should contain: `@const SCREEN-W: 800`, `@const SCREEN-H: 600`, three `player: context [...]` / `cpu: context [...]` / `ball: context [...]` set-words, a `love/load: function [] []`, a `love/update: function [dt] []`, a `love/draw: function [] [...]` that calls setColor + rectangle for each entity, a `love/keypressed: function [key] []`. **Exit gate (per spec):** no unnecessary wrapper blocks, no dead helpers, nothing that doesn't match `docs/pong-generated.ktg`'s shape. If there's bloat, stop and rework before Step 6.

- [ ] **Step 6: Run without `--update` to confirm the goldens match**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 7: Manual runtime sanity**

```bash
cd examples/game-pong-stub && love .
```

Expected: LÖVE2D window showing two paddles (left/right edges) and a ball in the middle. Static — no movement, no input.

- [ ] **Step 8: Commit**

```bash
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim examples/game-pong-stub/main.ktg tests/golden/game_pong_stub.ktg tests/golden/game_pong_stub_expanded.ktg tests/golden/game_pong_stub.lua
git commit -m "@game Phase 1 skeleton: 3 static entities in LOVE2D via dialect."
```

---

## Step 6 — @game Phase 2: Handlers, state, baseline `self` substitution

**Session budget:** 2 sessions. Five tasks.

**Deliverable:** Pong without collision. Paddles move, CPU tracks ball, score renders, space pauses, escape quits. Three-layer golden `game_pong_nocollide` passes.

---

### Task 8: Expand `state [...]` to top-level set-words

**Files:**
- Modify: `src/dialects/game_dialect.nim` (walkScene accepts `state`)
- Modify: `tests/test_game_dialect.nim`

- [ ] **Step 1: Failing test**

```nim
  test "state lifts to top-level set-words":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("state"),
        ktgBlock(@[
          ktgSetWord("paused?"), ktgLogic(true),
          ktgSetWord("score"), ktgInteger(0),
        ]),
      ]),
    ]
    let out = expand(blk)
    var saw = 0
    for i in 0 ..< out.len - 1:
      if out[i].kind == vkWord and out[i].wordKind == wkSetWord:
        if out[i].wordName == "paused?" and out[i + 1].kind == vkLogic and out[i + 1].logicVal == true:
          saw += 1
        if out[i].wordName == "score" and out[i + 1].kind == vkInteger and out[i + 1].intVal == 0:
          saw += 1
    check saw == 2
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Extend `walkScene`**

Add a `state: seq[KtgValue]` field to `SceneAccum` and a branch in `walkScene`:

```nim
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "state" and
         i + 1 < sceneBody.len and sceneBody[i + 1].kind == vkBlock:
      for v in sceneBody[i + 1].blockVals:
        result.state.add(v)
      i += 2
```

And in `expandScene`, emit state BEFORE entities:

```nim
  for v in accum.state:
    result.add(v)
```

- [ ] **Step 4-5: Run / full suite**

- [ ] **Step 6: Commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Lift scene state [...] block to top-level set-words."
```

---

### Task 9: `field name default` inside entity

**Files:**
- Modify: `src/dialects/game_dialect.nim`
- Modify: `tests/test_game_dialect.nim`

**Context.** `field score 0` inside an entity adds `score: 0` to the entity's context block.

- [ ] **Step 1: Failing test**

```nim
  test "field inside entity adds to context":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("entity"), ktgWord("player"),
        ktgBlock(@[
          ktgWord("pos"), ktgInteger(0), ktgInteger(0),
          ktgWord("rect"), ktgInteger(10), ktgInteger(10),
          ktgWord("color"), ktgInteger(1), ktgInteger(1), ktgInteger(1),
          ktgWord("field"), ktgWord("score"), ktgInteger(0),
        ]),
      ]),
    ]
    let out = expand(blk)
    ## Find player's context block and check for `score: 0`.
    var found = false
    for i in 0 ..< out.len - 2:
      if out[i].kind == vkWord and out[i].wordKind == wkSetWord and out[i].wordName == "player":
        let ctx = out[i + 2].blockVals
        for j in 0 ..< ctx.len - 1:
          if ctx[j].kind == vkWord and ctx[j].wordKind == wkSetWord and ctx[j].wordName == "score":
            check ctx[j + 1].intVal == 0
            found = true
    check found
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Extend `expandEntityComponents`**

Add a `field` branch:

```nim
      of "field":
        if i + 2 < body.len and body[i + 1].kind == vkWord:
          let fieldName = body[i + 1].wordName
          result.add(ktgSetWord(fieldName))
          result.add(body[i + 2])
          i += 3
          continue
```

- [ ] **Step 4-5: Run / full suite**

- [ ] **Step 6: Commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Expand `field name default` inside entity into context set-word."
```

---

### Task 10: `update [body]` inside entity with baseline `substituteSelf`

**Files:**
- Modify: `src/dialects/game_dialect.nim`
- Modify: `tests/test_game_dialect.nim`

**Context.** `update [self/y: self/y + 10]` inside `entity player [...]` should splice into `love/update`'s body as `player/y: player/y + 10`. The `substituteSelf` pass walks the body recursively, replacing every `self/<field>` word with `<entityName>/<field>`. Phase 2's shape handles straight path access, path set-words, and walks into `if`, `match`, `loop`, `either` bodies — the shapes Pong needs. Harder shapes are Step 7.

- [ ] **Step 1: Failing test**

```nim
  test "update body self substitution":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("entity"), ktgWord("player"),
        ktgBlock(@[
          ktgWord("pos"), ktgInteger(0), ktgInteger(0),
          ktgWord("rect"), ktgInteger(10), ktgInteger(10),
          ktgWord("color"), ktgInteger(1), ktgInteger(1), ktgInteger(1),
          ktgWord("update"),
          ktgBlock(@[
            ktgSetWord("self/y"), ktgWord("self/y"),
            ktgOp("+"), ktgInteger(10),
          ]),
        ]),
      ]),
    ]
    let out = expand(blk)
    ## Find love/update and check that `player/y:` appears in its body.
    var found = false
    for i in 0 ..< out.len - 3:
      if out[i].kind == vkWord and out[i].wordKind == wkSetWord and out[i].wordName == "love/update":
        let body = out[i + 3].blockVals
        for v in body:
          if v.kind == vkWord and v.wordKind == wkSetWord and v.wordName == "player/y":
            found = true
    check found
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Implement `substituteSelf` and update-body collection**

```nim
proc substituteSelf*(vals: seq[KtgValue], entityName: string): seq[KtgValue] =
  ## Replace self/<field> with <entityName>/<field>, both in word and
  ## set-word forms. Recurses into blocks and parens.
  result = newSeq[KtgValue](vals.len)
  for idx, v in vals:
    case v.kind
    of vkWord:
      if v.wordName.startsWith("self/"):
        let suffix = v.wordName["self/".len .. ^1]
        let newName = entityName & "/" & suffix
        case v.wordKind
        of wkWord: result[idx] = ktgWord(newName)
        of wkSetWord: result[idx] = ktgSetWord(newName)
        of wkGetWord: result[idx] = ktgGetWord(newName)
        of wkLitWord: result[idx] = ktgLitWord(newName)
        of wkMetaWord: result[idx] = ktgMetaWord(newName)
      else:
        result[idx] = v
    of vkBlock:
      result[idx] = ktgBlock(substituteSelf(v.blockVals, entityName))
    of vkParen:
      result[idx] = ktgParen(substituteSelf(v.parenVals, entityName))
    else:
      result[idx] = v
```

Extend the `Entity` type with an `updateBody: seq[KtgValue]` field. In `expandEntityComponents`, detect `update [body]` and collect. Since `expandEntityComponents` currently returns just the context entries, split it into two phases: one that builds the context block, one that returns the update body. Or pass an accumulator:

Refactor `walkScene` to handle entities differently — split entity parsing out of the current inline code. New proc:

```nim
proc parseEntity(name: string, body: seq[KtgValue]): Entity =
  result.name = name
  var i = 0
  while i < body.len:
    let head = body[i]
    if head.kind == vkWord and head.wordKind == wkWord:
      case head.wordName
      of "pos":
        if i + 2 < body.len:
          result.ctxBlock.add(ktgSetWord("x")); result.ctxBlock.add(body[i + 1])
          result.ctxBlock.add(ktgSetWord("y")); result.ctxBlock.add(body[i + 2])
          i += 3; continue
      of "rect":
        if i + 2 < body.len:
          result.ctxBlock.add(ktgSetWord("w")); result.ctxBlock.add(body[i + 1])
          result.ctxBlock.add(ktgSetWord("h")); result.ctxBlock.add(body[i + 2])
          i += 3; continue
      of "color":
        if i + 3 < body.len:
          result.ctxBlock.add(ktgSetWord("cr")); result.ctxBlock.add(body[i + 1])
          result.ctxBlock.add(ktgSetWord("cg")); result.ctxBlock.add(body[i + 2])
          result.ctxBlock.add(ktgSetWord("cb")); result.ctxBlock.add(body[i + 3])
          i += 4; continue
      of "field":
        if i + 2 < body.len and body[i + 1].kind == vkWord:
          result.ctxBlock.add(ktgSetWord(body[i + 1].wordName))
          result.ctxBlock.add(body[i + 2])
          i += 3; continue
      of "update":
        if i + 1 < body.len and body[i + 1].kind == vkBlock:
          for v in substituteSelf(body[i + 1].blockVals, name):
            result.updateBody.add(v)
          i += 2; continue
      else: discard
    i += 1

# Delete `expandEntityComponents` — `parseEntity` replaces it.
```

Then in `walkScene`, replace the inline entity handling:

```nim
    if head.kind == vkWord and head.wordKind == wkWord and head.wordName == "entity" and
       i + 2 < sceneBody.len and sceneBody[i + 1].kind == vkWord and
       sceneBody[i + 1].wordKind == wkWord and sceneBody[i + 2].kind == vkBlock:
      let ent = parseEntity(sceneBody[i + 1].wordName, sceneBody[i + 2].blockVals)
      result.entities.add(ent)
      i += 3
```

Finally, in `expandScene`, build the update body from each entity's updateBody, splice into `love/update`:

```nim
  var updateStatements: seq[KtgValue] = @[]
  for ent in accum.entities:
    for v in ent.updateBody:
      updateStatements.add(v)
  # replace the earlier `backend.updateShell(@[])` with:
  for v in backend.updateShell(updateStatements):
    result.add(v)
```

- [ ] **Step 4: Run to fail initially, then pass**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 5: Full suite**

- [ ] **Step 6: Commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Add baseline substituteSelf and entity update bodies."
```

---

### Task 11: `on-key "key" [body]` handlers → `love/keypressed` match

**Files:**
- Modify: `src/dialects/game_dialect.nim`
- Modify: `tests/test_game_dialect.nim`

**Context.** `on-key "space" [paused?: not paused?]` at scene level becomes a `match key [["space" [paused?: not paused?]] default [] ]` inside `love/keypressed`'s body.

- [ ] **Step 1: Failing test**

```nim
  test "on-key lifts to match in love/keypressed":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("on-key"), ktgString("space"),
        ktgBlock(@[ktgSetWord("paused?"), ktgWord("not"), ktgWord("paused?")]),
      ]),
    ]
    let out = expand(blk)
    ## love/keypressed body should contain `match key [...]`.
    var found = false
    for i in 0 ..< out.len - 3:
      if out[i].kind == vkWord and out[i].wordKind == wkSetWord and out[i].wordName == "love/keypressed":
        let body = out[i + 3].blockVals
        for v in body:
          if v.kind == vkWord and v.wordKind == wkWord and v.wordName == "match":
            found = true
    check found
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Implement on-key handling**

Add `onKeys: seq[(KtgValue, seq[KtgValue])]` to `SceneAccum`. In `walkScene`:

```nim
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "on-key" and
         i + 2 < sceneBody.len and sceneBody[i + 1].kind == vkString and
         sceneBody[i + 2].kind == vkBlock:
      result.onKeys.add((sceneBody[i + 1], sceneBody[i + 2].blockVals))
      i += 3
```

In `expandScene`, build a match block if onKeys is non-empty:

```nim
  var keyBody: seq[KtgValue] = @[]
  if accum.onKeys.len > 0:
    var matchArms: seq[KtgValue] = @[]
    for (keyStr, armBody) in accum.onKeys:
      matchArms.add(ktgBlock(@[keyStr]))
      matchArms.add(ktgBlock(armBody))
    matchArms.add(ktgWord("default"))
    matchArms.add(ktgBlock(@[]))
    keyBody.add(ktgWord("match"))
    keyBody.add(ktgWord("key"))
    keyBody.add(ktgBlock(matchArms))
  # replace backend.keypressedShell(@[]) with:
  for v in backend.keypressedShell(keyBody):
    result.add(v)
```

- [ ] **Step 4-5: Run / full suite**

- [ ] **Step 6: Commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Lift on-key handlers into love/keypressed match block."
```

---

### Task 12: `quit` primitive + `game_pong_nocollide` golden

**Files:**
- Modify: `src/dialects/game_dialect.nim` (quit walker)
- Create: `examples/game-pong-nocollide/main.ktg`
- Create: `tests/golden/game_pong_nocollide.{ktg,_expanded.ktg,lua}`
- Modify: `tests/test_game_dialect.nim` (add to golden suite)

**Context.** The token `quit` inside any handler body should be replaced with `backend.quitCall()`. For LÖVE2D that's `love/event/quit`. Walk handler bodies (update, keypressed) recursively and splice.

- [ ] **Step 1: Write `examples/game-pong-nocollide/main.ktg`**

```
Kintsugi [name: 'pong-nocollide]

@game [
  target: 'love2d
  constants [
    SCREEN-W: 800
    SCREEN-H: 600
    PADDLE-SPEED: 420
    BALL-SPEED: 350
  ]
  scene 'main [
    state [
      paused?: false
      player-score: 0
      cpu-score: 0
    ]
    entity player [
      pos 20 260  rect 12 80  color 0.9 0.9 1
      update [
        if love/keyboard/isDown "w" [self/y: self/y - (PADDLE-SPEED * dt)]
        if love/keyboard/isDown "s" [self/y: self/y + (PADDLE-SPEED * dt)]
      ]
    ]
    entity cpu [
      pos 768 260 rect 12 80  color 0.9 0.9 1
      update [
        self/y: ball/y - 40
      ]
    ]
    entity ball [
      pos 396 296 rect 8 8  color 1 0.8 0.2
      update [
        self/x: self/x + (BALL-SPEED * dt)
      ]
    ]
    on-key "space"  [paused?: not paused?]
    on-key "escape" [quit]
  ]
  go 'main
]
```

- [ ] **Step 2: Implement `quit` substitution**

Add after `substituteSelf` in `game_dialect.nim`:

```nim
proc substituteQuit*(vals: seq[KtgValue], backend: GameBackend): seq[KtgValue] =
  for v in vals:
    case v.kind
    of vkWord:
      if v.wordKind == wkWord and v.wordName == "quit":
        for q in backend.quitCall():
          result.add(q)
      else:
        result.add(v)
    of vkBlock:
      result.add(ktgBlock(substituteQuit(v.blockVals, backend)))
    of vkParen:
      result.add(ktgParen(substituteQuit(v.parenVals, backend)))
    else:
      result.add(v)
```

Apply `substituteQuit` to each on-key arm body in `expandScene`:

```nim
    for (keyStr, armBody) in accum.onKeys:
      matchArms.add(ktgBlock(@[keyStr]))
      matchArms.add(ktgBlock(substituteQuit(armBody, backend)))
```

And to each entity's updateBody (in parseEntity, after substituteSelf).

- [ ] **Step 3: Add `game_pong_nocollide` to the golden suite**

In the golden suite loop, change:

```nim
for name in ["game_pong_stub"]:
```

to:

```nim
for name in ["game_pong_stub", "game_pong_nocollide"]:
```

Mirror the example file into `tests/golden/`:

```bash
cp examples/game-pong-nocollide/main.ktg tests/golden/game_pong_nocollide.ktg
```

- [ ] **Step 4: Capture the new goldens**

```bash
nim c -r tests/test_game_dialect.nim -- --update
```

- [ ] **Step 5: Inspect `_expanded.ktg`** — should be procedural-Kintsugi shape matching `docs/pong-generated.ktg`, minus collision handling.

- [ ] **Step 6: Runtime check**

```bash
cd examples/game-pong-nocollide && love .
```

Expected: paddles move via W/S, CPU tracks ball, ball slides off the right edge (no bouncing yet), space pauses, escape quits.

- [ ] **Step 7: Confirm goldens match**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 8: Commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim examples/game-pong-nocollide/main.ktg tests/golden/game_pong_nocollide.*
git commit -m "@game Phase 2: handlers, state, quit, pong without collision."
```

---

## Step 7 — @game Phase 3: Substitution pass hardening

**Session budget:** 1 session. Four tasks.

**Deliverable:** `substituteSelf` handles every shape the spec describes + explicit error cases, all pinned by unit tests. `substituteIt` (for collide blocks) ships alongside with symmetric error handling.

---

### Task 13: Compile-error cases for bare `self` and misplaced `self/field`

**Files:**
- Modify: `src/dialects/game_dialect.nim`
- Create: `tests/test_game_dialect_substitution.nim`

- [ ] **Step 1: Write failing tests**

```nim
import std/unittest
import ../src/core/types
import ../src/dialects/game_dialect

suite "substituteSelf error cases":
  test "bare self raises":
    let body = @[ktgWord("self")]
    expect(ValueError):
      discard substituteSelf(body, "player")

  test "self in scene draw block raises (reported by scene walker)":
    ## The walker collects draw into accum.drawBody; substituteSelf isn't
    ## applied there. Step 7 lifts the error by walking draw separately.
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("draw"),
        ktgBlock(@[ktgWord("self/x")]),
      ]),
    ]
    expect(ValueError):
      discard expand(blk)
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Implement errors**

In `substituteSelf`, raise on bare `self`:

```nim
    of vkWord:
      if v.wordName == "self":
        raise newException(ValueError, "bare `self` is not valid; use `self/<field>`")
      elif v.wordName.startsWith("self/"):
        ...
```

In `expandScene`, scan draw body for any `self/` reference before emission:

```nim
proc assertNoSelf*(vals: seq[KtgValue], contextLabel: string) =
  for v in vals:
    case v.kind
    of vkWord:
      if v.wordName == "self" or v.wordName.startsWith("self/"):
        raise newException(ValueError,
          "`self` has no binding inside " & contextLabel)
    of vkBlock: assertNoSelf(v.blockVals, contextLabel)
    of vkParen: assertNoSelf(v.parenVals, contextLabel)
    else: discard
```

Call `assertNoSelf(accum.drawBody, "scene draw block")` at the start of `expandScene`'s draw-statement build. Call `assertNoSelf(armBody, "on-key handler")` per on-key arm.

- [ ] **Step 4-5: Run / full suite**

- [ ] **Step 6: Commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect_substitution.nim
git commit -m "@game: compile error on bare self and self outside entity scope."
```

---

### Task 14: Nested shape coverage for `substituteSelf`

**Files:**
- Modify: `tests/test_game_dialect_substitution.nim`
- Modify: `src/dialects/game_dialect.nim` if a shape breaks the existing recursion

**Context.** The Step 6 `substituteSelf` recurses into `vkBlock` and `vkParen`. That covers `if body`, `match arms`, `loop body`, `either branches`, and `attempt` handlers automatically because those are all just nested blocks. This task ADDS unit tests for each shape to pin the behavior; no code change unless a test reveals a gap.

- [ ] **Step 1: Write unit tests per nested shape**

```nim
suite "substituteSelf nested shapes":
  test "if body": 
    let body = @[ktgWord("if"), ktgWord("cond"),
                 ktgBlock(@[ktgSetWord("self/x"), ktgInteger(1)])]
    let out = substituteSelf(body, "player")
    let inner = out[2].blockVals
    check inner[0].wordName == "player/x"

  test "match arm body":
    let body = @[ktgWord("match"), ktgWord("v"),
                 ktgBlock(@[
                   ktgBlock(@[ktgInteger(1)]),
                   ktgBlock(@[ktgSetWord("self/y"), ktgInteger(2)]),
                 ])]
    let out = substituteSelf(body, "ball")
    let arms = out[2].blockVals
    let armBody = arms[1].blockVals
    check armBody[0].wordName == "ball/y"

  test "loop body":
    let body = @[ktgWord("loop"),
                 ktgBlock(@[ktgWord("for"), ktgBlock(@[ktgWord("i")]),
                            ktgWord("in"), ktgBlock(@[]),
                            ktgWord("do"),
                            ktgBlock(@[ktgSetWord("self/count"),
                                       ktgWord("self/count"), ktgOp("+"), ktgWord("i")])])]
    let out = substituteSelf(body, "emitter")
    ## drill to the innermost block
    let loopBlk = out[1].blockVals
    let doBlk = loopBlk[loopBlk.len - 1].blockVals
    check doBlk[0].wordName == "emitter/count"

  test "either branches":
    let body = @[ktgWord("either"), ktgWord("cond"),
                 ktgBlock(@[ktgSetWord("self/a"), ktgInteger(1)]),
                 ktgBlock(@[ktgSetWord("self/a"), ktgInteger(2)])]
    let out = substituteSelf(body, "p")
    check out[2].blockVals[0].wordName == "p/a"
    check out[3].blockVals[0].wordName == "p/a"

  test "attempt handlers":
    let body = @[ktgWord("attempt"),
                 ktgBlock(@[ktgWord("source"),
                            ktgBlock(@[ktgSetWord("self/x"), ktgInteger(0)]),
                            ktgWord("catch"),
                            ktgBlock(@[ktgSetWord("self/err"), ktgWord("e")])])]
    let out = substituteSelf(body, "obj")
    let attempted = out[1].blockVals
    check attempted[1].blockVals[0].wordName == "obj/x"
    check attempted[3].blockVals[0].wordName == "obj/err"

  test "non-mutating: input unchanged":
    let orig = @[ktgSetWord("self/x"), ktgInteger(1)]
    let origCopy = orig
    discard substituteSelf(orig, "player")
    check orig[0].wordName == origCopy[0].wordName  ## not mutated
```

- [ ] **Step 2: Run**

```bash
nim c -r tests/test_game_dialect_substitution.nim
```

Expected: all should pass on the existing Step 6 implementation because it already recurses into vkBlock/vkParen. If any fail, the test exposed a gap — fix the gap, rerun.

- [ ] **Step 3: Commit**

```
git add tests/test_game_dialect_substitution.nim
git commit -m "Pin substituteSelf behavior across nested block shapes."
```

---

### Task 15: Implement `substituteIt` with the same shape + error cases

**Files:**
- Modify: `src/dialects/game_dialect.nim`
- Modify: `tests/test_game_dialect_substitution.nim`

**Context.** Phase 4's `collide` blocks bind a second variable `it` for the other entity in the pair. `substituteIt` has the same structure as `substituteSelf` — replace `it/<field>` with `<otherName>/<field>` — plus the same error cases (bare `it` outside a collide block).

- [ ] **Step 1: Failing tests**

```nim
suite "substituteIt":
  test "simple it/field":
    let body = @[ktgWord("it/x")]
    let out = substituteIt(body, "ball")
    check out[0].wordName == "ball/x"
  test "bare it raises":
    expect(ValueError):
      discard substituteIt(@[ktgWord("it")], "ball")
  test "it in scene draw raises (via assertNoIt)":
    ## same pattern as assertNoSelf in Task 13
    discard  ## pinned by Task 18 when collide ships
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Implement**

Copy the `substituteSelf` proc to `substituteIt`, replacing `self` with `it`. Also add `assertNoIt` parallel to `assertNoSelf`.

- [ ] **Step 4-5-6: Run / suite / commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect_substitution.nim
git commit -m "Add substituteIt for collide blocks with symmetric errors."
```

---

### Task 16: Confirm non-mutating via explicit deepcopy test

**Files:**
- Modify: `tests/test_game_dialect_substitution.nim`

- [ ] **Step 1: Add a test that mutates the returned seq and checks input**

```nim
  test "returned seq is independent of input":
    let orig = @[ktgBlock(@[ktgSetWord("self/x"), ktgInteger(1)])]
    let out = substituteSelf(orig, "p")
    ## Mutating out should not affect orig.
    var mut = out
    mut[0] = ktgInteger(999)
    check orig[0].kind == vkBlock
    check orig[0].blockVals[0].wordName == "self/x"  ## still self, not p
```

- [ ] **Step 2-3: Run / commit**

```
git add tests/test_game_dialect_substitution.nim
git commit -m "Pin substituteSelf non-mutating behavior."
```

---

## Step 8 — @game Phase 4: Tag-based collision enumeration

**Session budget:** 1-2 sessions. Three tasks.

**Deliverable:** Full Pong with working collision. Ball bounces off paddles, speed ramps, scoring works. Emitted Kintsugi contains ZERO runtime tag lookups — collision code is a flat sequence of `if all? [...]` blocks.

---

### Task 17: `tags [name ...]` on entities populates tag map

**Files:**
- Modify: `src/dialects/game_dialect.nim` (parseEntity + walkScene + SceneAccum)
- Modify: `tests/test_game_dialect.nim`

- [ ] **Step 1: Failing test**

```nim
  test "tags collected per entity":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("entity"), ktgWord("player"),
        ktgBlock(@[
          ktgWord("pos"), ktgInteger(0), ktgInteger(0),
          ktgWord("rect"), ktgInteger(10), ktgInteger(10),
          ktgWord("color"), ktgInteger(1), ktgInteger(1), ktgInteger(1),
          ktgWord("tags"), ktgBlock(@[ktgWord("paddle")]),
        ]),
      ]),
    ]
    ## Direct API check: expand+internal test helper listing tag map.
    ## Use a new proc `collectTagMap` that walks scene body for the test.
    let tagMap = collectTagMap(blk)
    check "paddle" in tagMap
    check "player" in tagMap["paddle"]
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Implement**

Add `tags: seq[string]` to `Entity`. In `parseEntity`:

```nim
      of "tags":
        if i + 1 < body.len and body[i + 1].kind == vkBlock:
          for t in body[i + 1].blockVals:
            if t.kind == vkWord: result.tags.add(t.wordName)
          i += 2; continue
```

Add a helper for the tag map:

```nim
proc collectTagMap*(gameBlock: seq[KtgValue]): Table[string, seq[string]] =
  ## Walks @game block (top level) and returns tag->entities map.
  result = initTable[string, seq[string]]()
  var i = 0
  while i < gameBlock.len:
    let v = gameBlock[i]
    if v.kind == vkWord and v.wordKind == wkWord and v.wordName == "scene" and
       i + 2 < gameBlock.len and gameBlock[i + 2].kind == vkBlock:
      let sceneBody = gameBlock[i + 2].blockVals
      var j = 0
      while j < sceneBody.len:
        let h = sceneBody[j]
        if h.kind == vkWord and h.wordKind == wkWord and h.wordName == "entity" and
           j + 2 < sceneBody.len and sceneBody[j + 1].kind == vkWord and
           sceneBody[j + 2].kind == vkBlock:
          let ent = parseEntity(sceneBody[j + 1].wordName, sceneBody[j + 2].blockVals)
          for tag in ent.tags:
            if not result.hasKey(tag):
              result[tag] = @[]
            result[tag].add(ent.name)
          j += 3
        else:
          j += 1
      break
    i += 1
```

- [ ] **Step 4-5-6: Run / suite / commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Collect entity tags into a tag->entities map."
```

---

### Task 18: `collide <self-entity> '<tag-or-entity> [body]` enumerates flat AABB checks

**Files:**
- Modify: `src/dialects/game_dialect.nim`
- Modify: `tests/test_game_dialect.nim`

**Context.** The spec's template:

```
collide ball 'paddle [
  ball/dx: negate ball/dx
  ball/speed: ball/speed + 20
]
```

expands to (per the spec):

```
if all? [
  <self>/x < (<other>/x + <other>/w)
  <other>/x < (<self>/x + <self>/w)
  <self>/y < (<other>/y + <other>/h)
  <other>/y < (<self>/y + <self>/h)
] [ <substituteIt(body, other)> ]
```

One `if all?` block PER (self, other) pair. Flat unroll.

- [ ] **Step 1: Failing test**

```nim
  test "collide enumerates per-tag with flat if all?":
    let blk = @[
      ktgSetWord("target"), ktgLitWord("love2d"),
      ktgWord("scene"), ktgLitWord("main"),
      ktgBlock(@[
        ktgWord("entity"), ktgWord("player"),
        ktgBlock(@[ktgWord("pos"), ktgInteger(0), ktgInteger(0),
                   ktgWord("rect"), ktgInteger(10), ktgInteger(10),
                   ktgWord("color"), ktgInteger(1), ktgInteger(1), ktgInteger(1),
                   ktgWord("tags"), ktgBlock(@[ktgWord("paddle")])]),
        ktgWord("entity"), ktgWord("cpu"),
        ktgBlock(@[ktgWord("pos"), ktgInteger(0), ktgInteger(0),
                   ktgWord("rect"), ktgInteger(10), ktgInteger(10),
                   ktgWord("color"), ktgInteger(1), ktgInteger(1), ktgInteger(1),
                   ktgWord("tags"), ktgBlock(@[ktgWord("paddle")])]),
        ktgWord("entity"), ktgWord("ball"),
        ktgBlock(@[ktgWord("pos"), ktgInteger(0), ktgInteger(0),
                   ktgWord("rect"), ktgInteger(10), ktgInteger(10),
                   ktgWord("color"), ktgInteger(1), ktgInteger(1), ktgInteger(1)]),
        ktgWord("collide"), ktgWord("ball"), ktgLitWord("paddle"),
        ktgBlock(@[ktgSetWord("ball/speed"), ktgInteger(42)]),
      ]),
    ]
    let out = expand(blk)
    ## Count `all?` occurrences in love/update body. Should be 2 (one per paddle).
    var allCount = 0
    for i in 0 ..< out.len - 3:
      if out[i].kind == vkWord and out[i].wordKind == wkSetWord and out[i].wordName == "love/update":
        let body = out[i + 3].blockVals
        for v in body:
          if v.kind == vkWord and v.wordName == "all?": allCount += 1
          if v.kind == vkBlock:
            for vv in v.blockVals:
              if vv.kind == vkWord and vv.wordName == "all?": allCount += 1
    check allCount == 2
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Implement `expandCollide`**

In `walkScene`, collect collide forms. Extend `SceneAccum` with `collides: seq[CollideForm]`:

```nim
type CollideForm = object
  selfEntity: string
  tagOrEntity: string
  isTag: bool  ## true if lit-word (tag), false if word (entity)
  body: seq[KtgValue]
```

In `walkScene`:

```nim
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "collide" and
         i + 3 < sceneBody.len and sceneBody[i + 1].kind == vkWord and
         sceneBody[i + 3].kind == vkBlock:
      let selfEnt = sceneBody[i + 1].wordName
      let target = sceneBody[i + 2]
      let body = sceneBody[i + 3].blockVals
      result.collides.add(CollideForm(
        selfEntity: selfEnt,
        tagOrEntity: target.wordName,
        isTag: target.wordKind == wkLitWord,
        body: body,
      ))
      i += 4
```

In `expandScene`, after building the tag map, enumerate each collide form:

```nim
  # Build tag map from entities.
  var tagMap: Table[string, seq[string]] = initTable[string, seq[string]]()
  for ent in accum.entities:
    for tag in ent.tags:
      if not tagMap.hasKey(tag): tagMap[tag] = @[]
      tagMap[tag].add(ent.name)

  var collideStatements: seq[KtgValue] = @[]
  for coll in accum.collides:
    let others =
      if coll.isTag:
        if tagMap.hasKey(coll.tagOrEntity): tagMap[coll.tagOrEntity] else: @[]
      else:
        @[coll.tagOrEntity]
    for other in others:
      if other == coll.selfEntity: continue
      let s = coll.selfEntity
      let o = other
      let aabbBlock = ktgBlock(@[
        ktgWord(s & "/x"), ktgOp("<"),
        ktgParen(@[ktgWord(o & "/x"), ktgOp("+"), ktgWord(o & "/w")]),
        ktgWord(o & "/x"), ktgOp("<"),
        ktgParen(@[ktgWord(s & "/x"), ktgOp("+"), ktgWord(s & "/w")]),
        ktgWord(s & "/y"), ktgOp("<"),
        ktgParen(@[ktgWord(o & "/y"), ktgOp("+"), ktgWord(o & "/h")]),
        ktgWord(o & "/y"), ktgOp("<"),
        ktgParen(@[ktgWord(s & "/y"), ktgOp("+"), ktgWord(s & "/h")]),
      ])
      collideStatements.add(ktgWord("if"))
      collideStatements.add(ktgWord("all?"))
      collideStatements.add(aabbBlock)
      collideStatements.add(ktgBlock(substituteIt(coll.body, o)))
  # Append collideStatements to the updateStatements that feed love/update.
  for v in collideStatements:
    updateStatements.add(v)
```

(Collide statements go AFTER entity updateBody in love/update.)

- [ ] **Step 4-5: Run / full suite**

- [ ] **Step 6: Commit**

```
git add src/dialects/game_dialect.nim tests/test_game_dialect.nim
git commit -m "Expand collide with flat per-pair AABB if all? blocks."
```

---

### Task 19: Full pong example + golden, Phase 4 exit gate

**Files:**
- Create: `examples/game-pong/main.ktg`
- Create: `tests/golden/game_pong.{ktg,_expanded.ktg,lua}`
- Modify: `tests/test_game_dialect.nim` (add to golden list)

- [ ] **Step 1: Write `examples/game-pong/main.ktg`**

Full pong: copy Step 6's nocollide file and add `tags [paddle]` to player/cpu, `collide ball 'paddle [...]` at scene level with the ball-bounce body, ball reset logic on scoring, score display in the `draw` block.

(Exact content is ~60 lines of declarative Kintsugi; the engineer writes it following the spec's Phase 4 example block exactly.)

- [ ] **Step 2: Mirror into goldens + capture**

```bash
cp examples/game-pong/main.ktg tests/golden/game_pong.ktg
nim c -r tests/test_game_dialect.nim -- --update
```

- [ ] **Step 3: Inspect `game_pong_expanded.ktg`**

**Exit gate (spec, hard):** No `for tag in paddles`, no dispatch table, no runtime tag lookup anywhere. The collision block must be a flat sequence of `if all? [...]` forms, one per (ball, paddle-entity) pair. If a loop appears, rewind and fix `expandCollide`.

- [ ] **Step 4: Runtime check**

```bash
cd examples/game-pong && love .
```

Expected: full pong game. Player moves via W/S, CPU tracks ball, ball bounces off paddles, ramps speed, scores increment, space pauses, escape quits.

- [ ] **Step 5: Run test**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 6: Commit**

```
git add examples/game-pong/main.ktg tests/golden/game_pong.* tests/test_game_dialect.nim
git commit -m "@game Phase 4: full Pong with tag-based collision."
```

---

## Step 9 — @game Phase 5: Playdate backend

**Session budget:** 2 sessions. Three tasks.

**Deliverable:** `playdateBackend` ships in a new file and is registered next to `love2dBackend`. Swapping `target: 'love2d` to `target: 'playdate` in `game-pong/main.ktg` produces Playdate-ready Lua. `GameBackend` field count grew by at most 2 from Phase 1.

---

### Task 20: `playdateBackend` in `game_playdate.nim`

**Files:**
- Create: `src/dialects/game_playdate.nim`
- Modify: `src/dialects/game_dialect.nim` (import playdate + add to registry)
- Modify: `tests/test_game_dialect.nim`

**Context.** Playdate uses `playdate.graphics`, `playdate.buttonIsPressed`, Lua 5.4. No `setColor` (monochrome). `setColorCall` is a no-op on Playdate (emit nothing). `drawRectCall` emits `playdate/graphics/fillRect`. `isKeyDown` emits `playdate/buttonIsPressed`. `quitCall` is `playdate/system/exit` (or whatever Playdate's equivalent is — check the Playdate SDK).

- [ ] **Step 1: Failing test**

```nim
  test "playdate backend is registered":
    check backends.hasKey("playdate")
    check backends["playdate"].name == "playdate"
```

- [ ] **Step 2: Run to fail**

- [ ] **Step 3: Write `src/dialects/game_playdate.nim`**

```nim
import std/tables
import ../core/types
import game_dialect

proc playdateLoadShell(body: seq[KtgValue]): seq[KtgValue] =
  ## Playdate has no love.load; use playdate.graphics.setBackgroundColor, etc.
  ## For Phase 1 we wrap in a one-shot init block at the top of the script.
  body

proc playdateUpdateShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgSetWord("playdate/update"),
    ktgWord("function"),
    ktgBlock(@[]),  ## playdate.update takes no args
    ktgBlock(body),
  ]

proc playdateDrawShell(body: seq[KtgValue]): seq[KtgValue] =
  ## Playdate doesn't separate draw from update — fold into update.
  body

proc playdateKeypressedShell(body: seq[KtgValue]): seq[KtgValue] =
  ## Playdate polls buttons each frame; wrap as a runtime check block.
  body

proc playdateSetColorCall(r, g, b: KtgValue): seq[KtgValue] =
  @[]  ## no-op on Playdate

proc playdateDrawRectCall(x, y, w, h: KtgValue): seq[KtgValue] =
  @[ktgWord("playdate/graphics/fillRect"), x, y, w, h]

proc playdateQuitCall(): seq[KtgValue] =
  @[ktgWord("playdate/system/exit")]

proc playdateIsKeyDown(key: KtgValue): seq[KtgValue] =
  @[ktgWord("playdate/buttonIsPressed"), key]

let playdateBackend* = GameBackend(
  name: "playdate",
  bindings: @[],
  loadShell: playdateLoadShell,
  updateShell: playdateUpdateShell,
  drawShell: playdateDrawShell,
  keypressedShell: playdateKeypressedShell,
  setColorCall: playdateSetColorCall,
  drawRectCall: playdateDrawRectCall,
  quitCall: playdateQuitCall,
  isKeyDown: playdateIsKeyDown,
)
```

- [ ] **Step 4: Register in `game_dialect.nim`**

At the bottom of `game_dialect.nim`, replace:

```nim
var backends* = {"love2d": love2dBackend}.toTable
```

with:

```nim
import game_playdate
var backends* = {
  "love2d": love2dBackend,
  "playdate": playdateBackend,
}.toTable
```

Note: the import has to be AFTER the `love2dBackend` definition because `game_playdate` imports from `game_dialect` (the `GameBackend` type). If Nim complains about circular imports, move `GameBackend` type definition to a new small file `src/dialects/game_backend.nim`, import that from both.

- [ ] **Step 5-6-7: Run / full suite / commit**

```
git add src/dialects/game_dialect.nim src/dialects/game_playdate.nim tests/test_game_dialect.nim
git commit -m "Add playdate backend and register in dialect table."
```

---

### Task 21: `game_pong_playdate` golden + exit gate

**Files:**
- Create: `examples/game-pong-playdate/main.ktg`
- Create: `tests/golden/game_pong_playdate.{ktg,_expanded.ktg,lua}`
- Modify: `tests/test_game_dialect.nim`

- [ ] **Step 1: Copy pong example with target swap**

```bash
mkdir -p examples/game-pong-playdate
cp examples/game-pong/main.ktg examples/game-pong-playdate/main.ktg
```

Then edit `examples/game-pong-playdate/main.ktg` and change exactly ONE line:

```
-  target: 'love2d
+  target: 'playdate
```

**Nothing else in the file may change.** This is the spec's exit gate (Step 9): "A user takes the Phase 4 Pong source, changes only `target: 'love2d` to `target: 'playdate`, compiles, and the result runs on the Playdate simulator with the same gameplay. If ANY other source line has to change, the abstraction leaks and Phase 5 is wrong."

- [ ] **Step 2: Mirror into goldens + capture**

```bash
cp examples/game-pong-playdate/main.ktg tests/golden/game_pong_playdate.ktg
nim c -r tests/test_game_dialect.nim -- --update
```

- [ ] **Step 3: Verify `_expanded.ktg`**

Diff against `game_pong_expanded.ktg` — the only differences should be:
- `love/load` → `playdate/load`-equivalent or absent
- `love/update` → `playdate/update`
- `love/draw` calls → folded into update
- `love/keypressed` → polled button checks
- `love/graphics/*` → `playdate/graphics/*`
- `love/event/quit` → `playdate/system/exit`
- Setcolor calls absent (Playdate is monochrome)

- [ ] **Step 4: Runtime check (Playdate simulator)**

```bash
cd examples/game-pong-playdate
## Convert to Playdate project: one-time scaffold with pdxinfo + main.pdz
## After scaffold, run via Playdate Simulator.
```

**Note:** Full Playdate packaging is out of scope for this task. A minimal sanity check: the compiled `main.lua` should parse without syntax errors in the Playdate simulator's Lua 5.4 environment. If the Playdate SDK is not installed, the exit gate falls back to eye-diffing `game_pong_playdate.lua` against the expected shape.

- [ ] **Step 5: Confirm goldens match**

```bash
nim c -r tests/test_game_dialect.nim
```

- [ ] **Step 6: Commit**

```
git add examples/game-pong-playdate/main.ktg tests/golden/game_pong_playdate.*
git commit -m "@game Phase 5: Pong compiles for Playdate via target swap only."
```

---

### Task 22: Measure `GameBackend` field count growth + spec appendix

**Files:**
- Modify: `docs/superpowers/specs/2026-04-13-lean-lua-and-game-dialect-design.md`

**Context.** The spec says `GameBackend`'s field count at the end of Step 9 should exceed Phase 1's count by at most 2. Count, document, adjust.

- [ ] **Step 1: Count fields in current `GameBackend`**

Read `src/dialects/game_dialect.nim`'s `GameBackend` object. Expected fields (Phase 1): `name`, `bindings`, `loadShell`, `updateShell`, `drawShell`, `keypressedShell`, `setColorCall`, `drawRectCall`, `quitCall`, `isKeyDown` = **10 fields**. If Step 9 shipped any new fields, count them.

- [ ] **Step 2: Append an appendix to the spec**

At the bottom of `docs/superpowers/specs/2026-04-13-lean-lua-and-game-dialect-design.md`, append:

```markdown

---

## Appendix: GameBackend field count measurement (Step 9 exit gate)

**Phase 1 field count (Step 5):** 10 fields — `name`, `bindings`, `loadShell`, `updateShell`, `drawShell`, `keypressedShell`, `setColorCall`, `drawRectCall`, `quitCall`, `isKeyDown`.

**Phase 5 field count (Step 9):** [fill in actual count]

**Growth:** [diff]

**Verdict:** [within +2 budget / exceeded +2 budget]

[If exceeded: list the new fields and the reason for each. Document why Phase 1's abstraction was too narrow and what design lesson that yields.]
```

- [ ] **Step 3: Commit**

```
git add docs/superpowers/specs/2026-04-13-lean-lua-and-game-dialect-design.md
git commit -m "Document Step 9 GameBackend field-count measurement."
```

---

## Completion check

- `git log --oneline` shows ~22 commits from this plan, linear, no merges.
- `tests/golden/game_pong_stub.*`, `game_pong_nocollide.*`, `game_pong.*`, `game_pong_playdate.*` all exist and are byte-identical to emitter output.
- `nimble test` runs green with original test count + 4 new golden suites + ~20 new substitution/expansion unit tests.
- `examples/game-pong/main.ktg` runs in LÖVE2D with working paddles, ball bouncing, scoring, pause, quit.
- `examples/game-pong-playdate/main.ktg` differs from `examples/game-pong/main.ktg` by exactly ONE line (target swap) and compiles to runnable Playdate Lua.
- `_expanded.ktg` files contain ZERO runtime tag lookups, ZERO `self/` references, ZERO dialect-named runtime helpers.
- `GameBackend` field count stayed within +2 of the Phase 1 baseline.

## Named abort conditions (from spec)

Stop and reassess if any trigger:

1. **`_expanded.ktg` has bloat after Step 5.** Unnecessary wrapper blocks, dead helpers, anything that doesn't appear in `docs/pong-generated.ktg`. Stop and rework Phase 1 component grammar.
2. **Dialect core ends up with LÖVE2D-specific strings anywhere.** Any literal like `"love.graphics"` appearing in `game_dialect.nim` outside the `love2dBackend` instance. Fix before Step 6.
3. **Any phase's golden file contains a runtime helper named after the dialect** (`_game_*`, `_collide_*`, etc.). Zero runtime presence is non-negotiable.
4. **Collide expansion contains a runtime loop** (`for tag in paddles`). Per-pair enumeration is required.
5. **Step 9 needs more than 2 new `GameBackend` fields.** Document the miss and add the fields, but note the cost.
6. **No running LÖVE2D Pong after Step 5+6.** The confidence roadmap's 3-sessions-without-visible-output rule.

## What this plan is NOT

- Not a lean-lua plan. It builds on the lean-lua goldens and assumes the emitter is already clean.
- Not a new language feature blitz. `@game` is the only feature addition; it erases itself at compile time.
- Not a Breakout plan. `@game` Phase 6 (per the original roadmap) is explicitly out of scope.
- Not a performance project. Compile-time speed isn't on the radar.
