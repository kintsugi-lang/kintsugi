# Design: Lean Lua Output + `@game` Dialect (Combined Plan)

**Date:** 2026-04-13
**Status:** Approved for planning
**Scope:** Full `roadmap-lean-lua.md` Phases 1-3, then `roadmap-game-dialect.md` Phases 1-5. Breakout (game-dialect Phase 6) is explicitly out of scope.

---

## Purpose

Kintsugi's compiled Lua output should be indistinguishable from hand-written code. A compile-time `@game` dialect should let a user write a Pong-shaped game in ~100 declarative lines and produce clean, retargetable Lua for LÖVE2D and Playdate. This plan does both, in that order, over ~13-17 sessions.

This is a calibration move. It directly services the confidence roadmap's strategy: "ship a small game, feature-freeze the language, keep a compile-pipeline notebook." Lean-lua cleanup is cleanup, not feature work, and is exempt from the freeze. `@game` is the one feature addition; its justification is that it's a compile-time dialect that erases itself from the output, so it adds zero runtime surface area.

## Strategy

**Lean-lua leads. `@game` follows.** The rationale is "solid and correct before building more things on top." Every byte of `@game`'s output flows through the emitter, so a cleaner emitter means cleaner dialect output without additional work inside the dialect. Going `@game`-first would make us re-evaluate every Phase-1-4 deliverable after lean-lua lands.

**Linear, not parallel.** Each step's output is visible in the golden files from the previous step. Parallel branches would collide on `src/emit/lua.nim` and `tests/golden/` constantly. Sequential commits with co-committed golden regenerations give us a clean bisect history.

## Step 0 — Pre-work commit (shipped)

The pre-work described in `docs/roadmap-game-dialect.md` (emitter bug fixes A-D, test additions in `tests/test_emitter_fixes.nim`, the `docs/pong-generated.ktg` paper sketch, and the game-dialect roadmap doc itself) was shipped as one commit before this plan started. No further action.

## Step 1 — Test infrastructure

**Deliverable:** a `tests/golden/` directory, a runner that byte-compares compiled output against committed goldens, a metric-test harness, and initial goldens captured from the current emitter.

**Layout:**

```
tests/
  golden/
    hello.ktg            ; committed source
    hello.lua            ; committed expected output (LF-normalized)
    pong.ktg             ; = copy of examples/pong/main.ktg
    pong.lua
    combat.ktg
    combat.lua
    playdate.ktg         ; = copy of examples/playdate-hello/main.ktg
    playdate.lua
    leanlua_stress.ktg   ; new: exercises every IIFE-prone construct
    leanlua_stress.lua
  test_golden.nim        ; new: runner — diffs fresh compile against .lua sibling
  test_leanlua_metrics.nim ; new: targeted invariants
```

**Runner semantics (`test_golden.nim`):**

- One unit test per `.ktg` file in `tests/golden/`.
- Each test reads the `.ktg`, compiles via `emitLua` or `emitLuaModule` (based on `Kintsugi [...]` header presence), compares against the sibling `.lua` file.
- **Comparison is LF-normalized byte-identical.** Line endings normalized to LF before compare. No other normalization — no blank-line collapsing, no trailing-whitespace stripping. Blank-line placement and trailing whitespace are considered part of output quality and must match exactly.
- Failure produces a unified diff in the test output.
- `nim c -r tests/test_golden.nim --update` rewrites the goldens in place. The flag is required for updates so every golden change is an explicit author decision.

**Initial golden capture:** Run the runner once with `--update` against the current emitter. The resulting goldens are "where we are today, including the warts." Commit them as the baseline. Every subsequent lean-lua commit's golden diffs are the receipt for the improvement.

**Metric tests (`test_leanlua_metrics.nim`):** small, specific per-program invariants. Example shape:

```nim
test "pong emits zero _add calls":
  check compileAndCount(pongKtg, "_add(") == 0
test "hello has no prelude":
  check preludeLength(helloKtg) == 0
test "simple match emits clean if/elseif":
  check compileAndCount(matchKtg, "(function()") == 0
```

Metrics are added **as each lean-lua step lands**, not all upfront. Each metric is the step's definition of done.

**`leanlua_stress.ktg`:** a new synthetic file that hits every IIFE-prone construct in one program: `either` on rhs of set-word, nested `loop/partition`, `match` as expression, `if` as expression, `rejoin` with mixed types. Initial golden will be bloated. At the end of Step 4, its golden should be lean.

**Non-goal:** modifying `examples/*/main.lua`. Those are documentation and example code; keeping them identical to goldens is nice but not load-bearing. The goldens are a separate, purpose-built test corpus.

**Session budget:** 1 session.

---

## Step 2 — Lean-lua Phase 1: Defensive wrapping removal

**Three sub-deliverables, all in `src/emit/lua.nim`:**

### 2.1 Defensive `tostring()` in `rejoin`

Extend the concat-safety check to consult `funcReturnTypes` and expression inference, not just `objectFields` via `isFieldSafeForConcat`. When a rejoin arg is provably `integer!`/`float!`/`string!`/`money!`, emit `..` without `tostring`. Default stays `tostring` only when the type is genuinely unknown.

### 2.2 IIFE elimination

Four patterns to kill:

- **`either` on rhs of set-word.** Hoist to if/else statement writing the set-word directly.
- **`if` as expression.** Same treatment, or `cond and x or nil` when `x` is never false/nil.
- **`loop/partition` inner predicate.** Currently wraps `[x < pivot]` in `(function() return x < pivot end)()`. Inline the expression.
- **`match` as expression.** Hoist via `local _m_tmp = value; if ... end` then use `_m_tmp`.

### 2.3 `_add` helper elimination

Only emit `_add(a, b)` when at least one operand is inferable as `money!` or `float!`. Integer math emits `(a + b)` directly. The type inference already has the information; the emitter needs to consult it at `+`/`-` call sites.

**Definition of done:**

- Golden `hello.lua` has zero `(function()` occurrences.
- Golden `pong.lua` and `combat.lua` have zero `_add(` occurrences.
- Golden `leanlua_stress.lua` demonstrates clean lowering of every IIFE-prone construct.
- Metric tests pinning each of these.
- `nimble test` green (1344+ passing, zero regressions).

**Session budget:** 2 sessions.

---

## Step 3 — Lean-lua Phase 2: Idiomatic Lua patterns

### 3.1 `ipairs` vs `pairs` discrimination

`loop [for [x] in vals]` currently emits `ipairs(vals)` unconditionally. Consult `varTypes` (for contexts) and `varSeqTypes` (for blocks). Contexts → `pairs`, blocks/strings → `ipairs`. Unknown type defaults to `ipairs` (today's behavior, preserved as a fallback).

### 3.2 `match` tightening

Three specific cleanups:

- Literal-only match arms emit `x == "hello"`, not `x == "hello" and true`.
- Single-element patterns don't emit a trailing `and` chain.
- Type predicates emit `type(x) == "number"`, not a helper function.

### 3.3 String ops audit

Roadmap Phase 2.4 is vague ("could leverage Lua string patterns where applicable"). Scope this as: audit each of `_split`, `_replace`, `_subset`, `_insert`, `_remove`, `_sort` against native `string.*` methods. Where the Lua string method is a one-liner that matches our semantics, inline it and drop the helper. Where semantics differ (e.g., `_split` with empty delimiter splits into chars), keep the helper. Document the decision per helper in a spec appendix at the end of this step rather than leaving a "vague roadmap item."

### Explicitly out of scope

**`@method` for user object definitions.** Binding-side `'method` already works (confirmed in `examples/playdate-hello/main.lua`). Object-side `@method` adds language surface for something no in-scope program uses. Adding it would be speculative feature work and is deferred to a separate spec.

**Definition of done:**

- A context-iterating test program emits `pairs`; a block-iterating one emits `ipairs`. Both have golden files.
- `match` goldens have no `and true` tail and no helper calls for type checks.
- Each string helper is either kept (with justification in the appendix) or dropped (with a golden confirming the direct `string.*` call).
- `nimble test` green.

**Session budget:** 1-2 sessions.

---

## Step 4 — Lean-lua Phase 3: Erase Kintsugi

### 4.1 `none` as `nil`

Default emission for `none` is `nil`. The `_NONE` sentinel is only emitted when the program uses `none?` **and** could legitimately have a nil value from external sources (e.g., a table field that might be absent). Detection via an AST scan for `none?` usage — conservative: when in doubt, keep the sentinel. Emitted code is correct either way; an unnecessary sentinel is acceptable, an incorrect nil collapse is not.

### 4.2 Inline `make` unless `is?` is used

Already partially done (pong's output shows inlined defaults). Finish it: when `usedTypeChecks` does not include a type, `make Type [...]` emits a direct table constructor with all defaults + overrides resolved, with no `_type` tag and no `_make` helper call. When `is?` IS used for that type, keep the `_type` tag but still inline the constructor — `_make` helper goes away entirely.

### 4.3 Prelude erasure for simple programs

`buildPrelude` already returns empty string when `usedHelpers.len == 0`, but the prelude header (`-- Kintsugi runtime support`), `math.randomseed(os.time())`, and `PreludeUnpack` are always emitted when ANY helper is used. Split these: only emit `math.randomseed` when the program uses `random`; only emit `unpack` compat when the program uses variadic unpack; only emit the comment header when there's content under it.

**Definition of done:**

- `hello.lua` golden has zero prelude lines (no `-- Kintsugi runtime support`, no `math.randomseed`, no `_NONE`).
- `pong.lua` golden has zero prelude lines.
- `combat.lua` golden may still emit a small prelude for genuinely needed helpers (e.g., `_equals`, `_copy` for non-trivial type work) — acceptable. Metric asserts `preludeLength ≤ 10`, and the test body enumerates each helper present along with a single-sentence justification for why it stays. A prelude longer than 10 lines fails the metric and forces either a real helper removal or a spec update that argues for a higher bound.
- Metric test: `preludeLength(helloKtg) == 0`.
- Metric test: `compileAndCount(pongKtg, "_make(") == 0`.
- `leanlua_stress.lua` golden is smaller than at the end of Step 2.
- `nimble test` green.

**Explicit non-fix:** the `hello.ktg` artifact compiles via `emitLuaModule` because it has no `Kintsugi [...]` header, and modules don't emit a prelude — so `hello.ktg` compiled as a module references unresolved helpers. This is a pre-existing confusion, flagged here as a follow-up spec item, **not fixed in this plan**. Fix would require either forcing entrypoint mode when running top-level, or emitting a prelude for module-mode too. Out of scope.

**Session budget:** 2 sessions.

---

## Step 5 — `@game` Phase 1: Minimal skeleton

### Where the code lives

**New file:** `src/dialects/game_dialect.nim`. Matches the existing naming (`loop_dialect.nim`, etc.).

Unlike the existing dialects, which plug into the evaluator, `game_dialect.nim` runs at **preprocess time**. The preprocess pass already handles `#preprocess` and `#[expr]`; it gets one more case: when it encounters a `@game` meta-word followed by a block, it calls `game_dialect.expand(block) -> seq[KtgValue]` and splices the result in place.

The expansion is **syntactic only**. No evaluation, no context, no side effects — just AST rewriting.

### Backend abstraction (built in from Phase 1)

The `GameBackend` type is defined in `game_dialect.nim`:

```nim
type
  GameBackend* = object
    name*: string
    bindings*: seq[KtgValue]
      ## Bindings block to splice at the top of the expanded program.
    loadShell*: proc(body: seq[KtgValue]): seq[KtgValue]
      ## Wraps user load logic in the target's load hook.
    updateShell*: proc(body: seq[KtgValue]): seq[KtgValue]
    drawShell*: proc(body: seq[KtgValue]): seq[KtgValue]
    keypressedShell*: proc(body: seq[KtgValue]): seq[KtgValue]
    setColorCall*: proc(r, g, b: KtgValue): seq[KtgValue]
    drawRectCall*: proc(x, y, w, h: KtgValue): seq[KtgValue]
    quitCall*: proc(): seq[KtgValue]
    isKeyDown*: proc(key: KtgValue): seq[KtgValue]
```

(Field list is a sketch. Finalized during Phase 1 implementation by auditing exactly what `docs/pong-generated.ktg` touches. Every field returns a `seq[KtgValue]` — a Kintsugi AST snippet spliced into the expansion.)

Phase 1 delivers `love2dBackend: GameBackend` as the single concrete instance, registered via `const backends = {"love2d": love2dBackend}.toTable`. The dialect's core walker **never mentions LÖVE2D by name**. It only calls `backend.drawRectCall(...)`, etc.

### Grammar accepted in Step 5

```
@game [
  target: 'love2d
  constants [ SCREEN-W: 800  SCREEN-H: 600  ... ]
  scene 'main [
    entity player [pos 20 260  rect 12 80  color 0.9 0.9 1]
    entity ball   [pos 396 296 rect 8 8    color 1 0.8 0.2]
    draw [ ... ]
  ]
  go 'main
]
```

### Dialect walker steps

1. Look up `target` in the backend registry. Unknown target → compile-time error with line number.
2. Splice `backend.bindings` at the top of the expansion.
3. Walk `constants [...]`, turn each `NAME: value` into `@const NAME: value`.
4. Walk `scene 'main [...]`:
   - For each `entity <name> [...]`: build `<name>: context [...]` with fields derived from the fixed vocabulary — `pos X Y` → `x: X  y: Y`, `rect W H` → `w: W  h: H`, `color R G B` → `cr: R  cg: G  cb: B`.
   - Collect the `draw [...]` block body.
5. Emit `love/load: function [] [ <backend.loadShell body> ]`.
6. Emit `love/update: function [dt] [ ]` — empty.
7. Emit `love/draw: function [] [ <per-entity rect emission via backend.setColorCall + backend.drawRectCall> ; user draw block ]`.

### Three-layer golden files (new convention for dialect tests)

```
tests/golden/
  game_pong_stub.ktg            ; user input: @game block + header
  game_pong_stub_expanded.ktg   ; post-dialect expansion: plain Kintsugi
  game_pong_stub.lua            ; final compiled Lua
```

- `.ktg` → `_expanded.ktg`: the dialect's output. If this diff changes, the dialect changed.
- `_expanded.ktg` → `.lua`: the emitter's output. If this diff changes, the emitter changed.
- `.ktg` → `.lua`: end-to-end. If this diff changes without the above two changing, something drifted.

Test runner compiles each `.ktg` twice — once with `dryExpand` (for `_expanded.ktg` comparison) and once with normal compile (for `.lua` comparison). Both must match.

**Pretty-printing for `_expanded.ktg`:** `dryExpand` returns the expanded `seq[KtgValue]` AST. Comparison against `_expanded.ktg` requires a deterministic pretty-printer that produces valid Kintsugi source. Step 5's scope includes either (a) reusing `src/core/types.nim`'s existing `display` proc if it already produces round-trippable source, or (b) adding a minimal `prettyPrintBlock(vals: seq[KtgValue]) -> string` helper in `src/emit/lua.nim` alongside the emitter. Verification: feeding a pretty-printed output back through `parseSource` must yield the same AST. The pretty-printer is a pure formatter — no semantic transforms — and its own golden coverage is the `_expanded.ktg` files themselves (if the pretty-printer changes its output shape, every dialect golden updates).

### Deliverable

- `src/dialects/game_dialect.nim` with the `GameBackend` type, the `love2dBackend` instance, the `expand` entry point, and the `backends` registry.
- The preprocess pass wired to call `game_dialect.expand` on `@game [...]` meta-words.
- A deterministic pretty-printer for `seq[KtgValue]` (new or reused from `display`).
- `examples/game-pong-stub/main.ktg` — the shortest valid `@game` program. 3 entities drawn, no movement, no input. Compiles with `bin/kintsugi -c`, runs in LÖVE2D, paddles and ball sit on screen.
- Three golden files: `game_pong_stub.ktg`, `game_pong_stub_expanded.ktg`, `game_pong_stub.lua`.

### Exit gate

The expanded Kintsugi at `_expanded.ktg` must not contain bloat. If it has unnecessary wrapper blocks, dead helpers, or anything that doesn't appear in `docs/pong-generated.ktg`, the component grammar is wrong. Stop and rework before Step 6. The reference is the hand-written paper sketch — the dialect should approach it, not diverge.

**Session budget:** 1-2 sessions.

---

## Step 6 — `@game` Phase 2: Handlers, state, and baseline `self` substitution

### Grammar additions

```
scene 'main [
  state [ paused?: true  game-font: none ]
  entity player [
    pos 20 260  rect 12 80  color 0.9 0.9 1
    field score 0
    update [
      if lk/isDown "w" [self/y: self/y - (PADDLE-SPEED * dt)]
      if lk/isDown "s" [self/y: self/y + (PADDLE-SPEED * dt)]
    ]
  ]
  on-key "space"  [paused?: not paused?]
  on-key "escape" [quit]
]
```

### Dialect walker additions

1. `state [...]` — lift each entry to a top-level set-word (outside scene).
2. `field name default` inside `entity` — add `name: default` to the entity's context.
3. `update [body]` inside entity — call `substituteSelf(body, entityName)`, splice into `love/update` body in declaration order. First implementation handles straight `self/field` and `self/field: expr` inside nested `if`/`match`/`loop` blocks — the shapes Pong needs.
4. `on-key "key" [body]` — collect into a list; emit one `match` statement in `love/keypressed` with one arm per collected key.
5. `quit` in any handler body — replace with `backend.quitCall()` splice.

### Deliverable

- Pong without collision. Paddles move via keyboard, CPU paddle tracks the ball, score draws but doesn't increment, space pauses, escape quits. No bouncing yet.
- Three golden files: `game_pong_nocollide.ktg`, `game_pong_nocollide_expanded.ktg`, `game_pong_nocollide.lua`.

### Exit gate

`_expanded.ktg` passes the compile pipeline cleanly. Resulting Lua is readable top to bottom. No runtime helpers beyond what Step 4's lean-lua goldens already show. No `self/` references leaking into the expansion (a linter test scans for this).

**Session budget:** 2 sessions.

---

## Step 7 — `@game` Phase 3: Substitution pass hardening

Step 6 shipped a minimal `substituteSelf`. Step 7 hardens it for every shape the roadmap describes and adds explicit error handling.

### Deliverables

1. **Error cases become compile errors with line numbers.**
   - Bare `self` (not followed by `/field`) in update block: "bare `self` is not valid; use `self/<field>`".
   - `self` anywhere in a scene-level `draw [...]` block: "draw is scene-level; `self` has no binding here".
   - `self` in `on-key` handlers: same error; handlers are scene-scoped.
   - `it` outside of a `collide` block (anticipating Phase 4): same class of error.

2. **Nested shape coverage.** The substitution walks into every nested block: `if`, `match` arms, `loop` bodies, `either` branches, `attempt` handlers. Unit tests for each shape.

3. **Non-mutating.** The pass returns a new AST; input never mutated.

4. **Unit test file:** `tests/test_game_dialect_substitution.nim`. Each test is one input AST shape + expected output AST shape, written directly in Nim. No `.ktg` files — these are low-level invariant tests.

5. **Matching `substituteIt` helper** for Phase 4's `collide` blocks, shipped alongside `substituteSelf` with symmetric error handling.

### Exit gate

Every shape of `self/...` that Pong and a hand-sketched Breakout need is covered. If the substitution starts needing special-cases for closures or block literals, the grammar is too loose — shrink the grammar before adding substitution complexity. The hardening also confirms the substitution is purely syntactic: no evaluation, no context, no reentrancy.

**Session budget:** 1 session.

---

## Step 8 — `@game` Phase 4: Tag-based collision enumeration

### Grammar additions

```
entity player [... tags [paddle]]
entity cpu    [... tags [paddle]]
entity ball   [... tags [ball]]

scene 'main [
  collide ball 'paddle [
    ball/dx: negate ball/dx
    ball/speed: ball/speed + 20
  ]
]
```

### Dialect walker additions

1. `tags [name ...]` on an entity — populate a tag → entities map during the scene walk.
2. `collide self-entity 'tag-or-entity [body]`:
   - If the second arg is a lit-word (tag), enumerate all entities with that tag in scene-declaration order.
   - If the second arg is a word (entity name), single pair.
   - For each (self, other) pair, emit:
     ```
     if all? [
       <self>/x < (<other>/x + <other>/w)
       <other>/x < (<self>/x + <self>/w)
       <self>/y < (<other>/y + <other>/h)
       <other>/y < (<self>/y + <self>/h)
     ] [ <substituteIt(body, other)> ]
     ```
   - The AABB template is emitted verbatim. No helper function. Flat unroll.

### Deliverable

- Pong with working collision. Ball bounces off paddles, speed ramps, scoring works.
- Three golden files: `game_pong.ktg`, `game_pong_expanded.ktg`, `game_pong.lua`. These supersede Step 6's `game_pong_nocollide.*` files — keep those as regression tests for the no-collision shape.

### Exit gate

Emitted Kintsugi contains **zero runtime tag-lookup**. No `for tag in paddles`. No dispatch table. Collision code is a flat sequence of `if all? [...]` blocks, one per (entity, tagged-other) pair. If a runtime loop appears anywhere in the expansion, Phase 4 is wrong — back up and fix the enumeration.

**Session budget:** 1-2 sessions.

---

## Step 9 — `@game` Phase 5: Playdate backend

### Deliverable

1. **New file:** `src/dialects/game_playdate.nim`. Separate from `game_dialect.nim` to keep `GameBackend` instance definitions isolated. `game_dialect.nim` imports and registers `playdateBackend`.
2. `playdateBackend: GameBackend` — concrete instance with Playdate-specific bindings (`playdate.graphics`, `playdate.buttonIsPressed`, etc.), Lua 5.4 output, no `setColor` (Playdate is monochrome). For `setColorCall`, the Phase 1 default is to emit a Playdate fill-pattern selection call that maps RGB brightness to one of Playdate's built-in patterns; if that turns out to add visual noise during Step 9 testing, the field becomes a no-op and the Phase 1 abstraction gains a note. The decision is made once, during Step 9 implementation.
3. Registry: `const backends = {"love2d": love2dBackend, "playdate": playdateBackend}.toTable`.
4. Three golden files: `game_pong_playdate.ktg`, `game_pong_playdate_expanded.ktg`, `game_pong_playdate.lua`. Same `@game` body as `game_pong.ktg` with only `target: 'love2d` → `target: 'playdate` swapped.

### Measurement (the Phase 1 contract)

`GameBackend`'s field count at the end of Step 9 exceeds the Phase 1 count by **at most 2**. Any more means the Phase 1 abstraction was too narrow. Widening the struct is acceptable but documented in the spec as a lesson about initial shape.

### Exit gate

A user takes the Phase 4 Pong source, changes only `target: 'love2d` to `target: 'playdate`, compiles, and the result runs on the Playdate simulator with the same gameplay. If ANY other source line has to change, the abstraction leaks and Phase 5 is wrong.

**Session budget:** 2 sessions.

---

## Session budget summary

| Step | Work | Sessions |
|------|------|----------|
| 1 | Test infra + golden capture | 1 |
| 2 | Lean-lua Phase 1 (tostring/IIFE/_add) | 2 |
| 3 | Lean-lua Phase 2 (pairs/match/string ops) | 1-2 |
| 4 | Lean-lua Phase 3 (none/make/prelude) | 2 |
| 5 | `@game` Phase 1 (skeleton) | 1-2 |
| 6 | `@game` Phase 2 (handlers/state) | 2 |
| 7 | `@game` Phase 3 (substitution hardening) | 1 |
| 8 | `@game` Phase 4 (tag collisions) | 1-2 |
| 9 | `@game` Phase 5 (Playdate backend) | 2 |

**Total: ~13-17 sessions.** Each row is independently shippable.

## Commit granularity

- Each step is its own commit chain. Merge to master after each step unless mid-step.
- Golden file changes are always co-committed with the emitter/dialect change that caused them. Never commit a golden regeneration as a standalone commit.
- No destructive history operations. Steps 1-9 form a linear history we can bisect.

## Named abort conditions

Hard stops. If any trigger, stop and reassess before continuing.

1. **Step 2 overruns to >3 sessions.** Phase 1 IIFE elimination is scoped at 2; 50% overrun means the "clean the corner, whole floor is dirty" trap. Audit what got messier and decide whether the approach or scope is wrong.
2. **A golden regen is "nuclear."** If a small semantic change forces every line of every golden to change, the emitter is too fragile. Fix fragility before piling on more work.
3. **Dialect core ends up with LÖVE2D-specific strings anywhere.** Any literal like `"love.graphics"` appearing in `game_dialect.nim` outside the `love2dBackend` instance. Fix before Step 6.
4. **Step 9 needs >2 new `GameBackend` fields.** Phase 1 abstraction was too narrow. Document the miss and add the fields, but note the cost.
5. **Any phase's golden file contains a runtime helper named after the dialect** (`_game_*`, `_collide_*`, etc.). Zero runtime presence is non-negotiable.
6. **Confidence roadmap's "3 sessions without visible output" rule.** If after Step 5 + Step 6 there isn't a running pong-nocollide in LÖVE2D, stop and diagnose.

## Soft risks (watch but not block on)

- **Lean-lua Phase 3 `none?` detection** may want whole-program flow analysis. Cap at a conservative heuristic: emit sentinel only when the program contains a `none?` check AND the checked value could legitimately be Lua-nil. Wrong heuristic still emits correct code — just with an unnecessary sentinel.
- **Phase 2.4 string ops audit** might find helpers that genuinely can't be replaced. Fine — deliverable is "audit + decision per helper," not "delete all helpers."
- **`substituteSelf` interacting with `do`/`bind`/`compose`** — interpreter-only operators shouldn't appear inside `@game` at all. If they do, compile error with clear message.

## Exit gates (end-of-plan)

**Lean-lua done (end of Step 4):**

- `hello.lua` golden has zero prelude, zero helpers, zero IIFEs, zero defensive `tostring`.
- `pong.lua` golden has zero prelude and zero `_add`/`_make` calls.
- `combat.lua` golden's prelude is ≤ 10 lines, each helper justified.
- All metric tests pass.
- `nimble test` green.

**`@game` done (end of Step 9):**

- `tests/golden/game_pong.lua` (LÖVE2D) and `tests/golden/game_pong_playdate.lua` (Playdate) both pass golden comparison.
- Both `.lua` files came from the same `@game` body, differing only in `target:` and expected output.
- No `self/` references in any `_expanded.ktg`.
- No dialect-named runtime helpers in any `.lua`.
- `GameBackend` field count is within +2 of Phase 1 count.

**Plan done:** both streams done, `examples/` contains running LÖVE2D and Playdate Pong builds.

## What the plan is NOT

- Not a language feature blitz. Apart from `@game` itself, no new natives, no new syntax, no new primitive types. The confidence roadmap's freeze applies to everything except `@game` and emitter cleanup.
- Not a refactoring project. `lua.nim` may shrink as lean-lua removes code paths, but the emitter's architecture stays the same.
- Not a documentation project. The `_expanded.ktg` goldens ARE the documentation.
- Not a performance project. Compile-time speed isn't on the radar; runtime Lua performance is someone else's target.

## Follow-up items (explicitly out of scope)

- `@method` for user object definitions.
- `hello.ktg` no-header-missing-prelude fix (entrypoint vs module-mode prelude handling).
- Breakout (`@game` Phase 6 from the original roadmap).
- Custom user components beyond `pos`/`rect`/`color`/`field`/`tags`.
- Interpreter-time `@game` evaluation.
- Animation/tweening sub-dialect.
- Real ECS.

---

## Appendix: String helpers audit (Phase 2.4)

Decision per helper. `keep` means the helper stays in the prelude; `inline` means the helper is replaced by a direct `string.*` call and the helper is dropped.

### `_split`
**Decision: keep.**
Lua has `string.gmatch(s, "[^" .. d .. "]+")` which approximates split-on-delimiter, but:
- Empty delimiter (split into chars) is not expressible with `gmatch`.
- Escaping special pattern characters inside `d` would require extra logic.
The helper's 10-line implementation is clearer than escaping gmatch dynamically.

### `_replace`
**Decision: keep.**
`string.gsub(s, old, new)` requires `old` to be escaped for Lua patterns. Our `_replace` does literal (non-pattern) find/replace, which is simpler and more predictable than gsub + pattern escaping.

### `_subset`
**Decision: inline for string arg (already implemented).**
`string.sub(s, start, stop)` is a direct equivalent for string inputs. Block inputs still need inline loop-building; unknown types keep `_subset`. The existing `exprHandlers["subset"]` already branches on `inferSeqType`: `stString` emits `string.sub`, `stBlock` inlines a slice loop, `stUnknown` keeps the helper.

### `_insert`
**Decision: keep.**
String insertion uses concatenation which is fine inline, but block insertion is `table.insert(t, i, v)` - also fine inline. However, the helper unifies the two branches and the emitter doesn't always know the type. Keep for safety; revisit if type inference improves.

### `_remove`
**Decision: keep.**
Same reasoning as `_insert`. Dual-mode helper unifies string/block removal.

### `_sort`
**Decision: keep.**
`table.sort(x)` works in-place on blocks. The helper wraps this to also handle strings (by char) and to return the table. Keep for the return-value convention.

**Net result: one helper partial inline (`_subset` for known strings, already in place), five helpers kept with justification. Lean-lua Phase 2.4 done.**

---

## Appendix: GameBackend field count measurement (Step 9 exit gate)

**Phase 1 field count (Step 5, 2026-04-13):** 10 fields

1. `name` - target identifier string
2. `bindings` - Kintsugi `bindings [...]` block spliced at top of expansion
3. `loadShell` - wraps load body in target's load callback
4. `updateShell` - wraps update body in target's update callback
5. `drawShell` - wraps draw body in target's draw callback
6. `keypressedShell` - wraps keypressed body in target's keypressed callback
7. `setColorCall` - emits target's setColor invocation
8. `drawRectCall` - emits target's filled-rectangle invocation
9. `quitCall` - emits target's quit/exit invocation
10. `isKeyDown` - emits target's key-is-down query

**Phase 5 field count (Step 9):** 11 fields

New fields added during Steps 5-9:

11. `printCall` - emits target's text-rendering invocation (added to support `text-print` abstraction during Step 9's one-line-delta exit gate fix)

**Delta:** +1 field.

**Verdict:** Within the +2 field budget. Phase 1 abstraction shape held.

**Design lesson:** The original Phase 1 abstraction missed `printCall` because Step 5's pong-stub had no HUD. Only when Step 9 required a Playdate target with a truly one-line source delta did the need for a cross-target text-rendering primitive surface. Adding it cost one field and one `substituteCalls` dispatch case. The `isKeyDown` field (which existed in Phase 1) went unused through Steps 5-8 because user code wrote `love/keyboard/isDown` directly; Step 9's fix also repurposed `isKeyDown` through the new `substituteCalls` pass and made the field actually reachable via the `key-down?` user-facing abstraction.

**Follow-up:** Phase 6 tasks (animation, real ECS, custom components) may need additional backend fields. The +2 budget was set against Phase 1-5 scope; Phase 6 may legitimately require expansion.
