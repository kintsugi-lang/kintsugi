# Roadmap: `@game` Dialect

The `@game` dialect is Kintsugi's compile-time game framework. The user writes declarative game intent inside `@game [...]`; a preprocess-time dialect walks the block and splices plain Kintsugi in its place; the existing compiler produces clean, idiomatic, zero-dependency Lua for the chosen target. Zero framework in the emitted Lua. Zero runtime overhead. Same user source retargetable across LÖVE2D, Playdate, and standalone Lua by swapping the dialect's backend.

This is what the north star meant by *"game dialects (unit, ability, synergy, pattern, scene) emerge from building Chronodistort"* — `@game` is the foundation those game dialects grow from.

---

## Why a dialect, not a framework

A runtime framework (Kaboom-style) would violate `docs/roadmap-lean-lua.md`'s "erases itself from the output" principle. Every `add([pos(), rect(), area()])` call would leave a runtime dispatch table, a scene registry, a collision loop, all in the compiled output. That's a parallel codebase shipping with every game.

A compile-time dialect runs once at compile time. The dialect walks the user's declarative intent and emits the imperative Kintsugi *the author would have written by hand* — love callbacks, entity structs, collision checks inlined, input dispatch as `match`. The emitted Kintsugi then feeds the normal compile pipeline. Output is indistinguishable from hand-written LÖVE2D code. The dialect has zero runtime footprint because it has no runtime presence.

This isn't theoretical. `/tmp/pong-generated.ktg` is the hand-written proof that the existing compiler can produce clean LÖVE2D from the shape of Kintsugi the dialect would emit.

---

## What's already proven

A paper sketch of Pong-in-`@game` exists as two files, side-by-side:
- **Left (user writes)**: ~95 lines of `@game [scene ... entity ... collide ... on-key ... draw]` declarative intent.
- **Right (dialect emits)**: ~165 lines of plain Kintsugi (`context` for entities, `love/load`/`love/update`/`love/draw`/`love/keypressed` shells, inlined AABB checks, `match` for keypressed).

Running the right side through the existing compiler produces 271 lines of clean LÖVE2D. The `@game` dialect's job is to *mechanically* produce the right side from the left side.

The paper-pushing exercise exposed four silent-correctness bugs in the emitter (either/match rhs, write-through scoping, `using` header, mixed-precedence parens) which are all fixed in the pre-work below. Future paper sketches — Breakout, Asteroids — will surface further bugs, which is how we know we're testing the right thing.

---

## Pre-work to commit before the dialect

Everything in this block is done, tested, and unstaged. Ship as one commit before starting Phase 1.

- **Bug A** — either/match on rhs of set-word no longer emits orphan target lines.
- **Bug B** — write-through scoping in compiled function bodies now matches interpreter semantics. Includes forward-reference case via a top-level `moduleNames` pre-scan.
- **Bug C** — `Kintsugi [using [math collections]]` is honored on the compile path. Stdlib source is baked into the binary via `staticRead`, `applyUsingHeader` prepends matching bodies before parsing.
- **Bug D** — parens around mixed-precedence arithmetic survive translation. `lerp`, `inverse-lerp`, `smoothstep`, `smootherstep` now compile correctly.
- **Browser playground** — `src/kintsugi_js.nim` exposes `kintsugiCompile` / `kintsugiRun` / `kintsugiVersion` as browser globals via `nim js`. Stdlib embedded. FS natives gated behind `when not defined(js)`. `getEvaluator` helper routes the evaluator handle through a JS-side global because Nim JS doesn't round-trip `cast[T](pointer)`.
- **Tests** — 23 new tests across four suites in `tests/test_emitter_fixes.nim`. `nimble test` went 1321 → 1344 OKs, zero regressions.
- **Memory** — `feedback_playground_scope.md` captures that lean-lua output concerns apply only to native compile, not the playground build.

Nothing below blocks on any of this. But this is the foundation everything else assumes.

---

## Phase 1 — Minimal `@game` skeleton **[DONE]**

Build the smallest thing that can take a `@game` block and produce a runnable Kintsugi program. No handlers yet, no collision, no input. Just entity layout + love callback shells.

**Input grammar recognized in Phase 1:**
```
@game [
  target: 'love2d
  constants [ NAME: value  ... ]
  scene 'name [
    entity name [pos x y  rect w h  color r g b]
    entity name [...]
    draw [ ... ]
  ]
  go 'name
]
```

**What the dialect emits:**
- LÖVE2D bindings block (hard-coded for target `'love2d`).
- `@const` declarations for each constants entry.
- `context [...]` entity variable declarations with all component fields inlined.
- `love/load: function [] [lw/setMode ... lw/setTitle ...]` shell.
- `love/update: function [dt] [ ]` empty shell.
- `love/draw: function [] [<per-entity draws from pos/rect/color> <user draw block>]`.
- Nothing else.

**Deliverable:** `examples/game-pong-stub.ktg` — the shortest valid `@game` program. Three entities drawn to screen, no movement, no input. Compile with `bin/kintsugi -c`, run in LÖVE2D, see paddles and ball sit there.

**Exit gate:** compiled Lua for the stub is indistinguishable from hand-written LÖVE2D scaffolding. If the emitted Kintsugi is bloated or weird, the component grammar is wrong — stop and rework before adding handlers.

---

## Phase 2 — Handlers and state **[DONE]**

Add the imperative escape-hatch blocks that make the dialect useful for a real game.

**New grammar:**
```
scene 'name [
  state [name: value  ...]
  entity name [
    pos x y  rect w h
    field score 0       ; custom field
    update [ ... ]      ; per-entity update block, self -> this entity
  ]
  on-key "space" [ ... ]
  on-key "escape" [ quit ]
]
```

**What the dialect emits:**
- `state [...]` entries become top-level set-word declarations lifted out of the scene block.
- `update [body]` blocks are lifted into `love/update: function [dt] [...]` with `self/field` references rewritten to `<entity-name>/field` (the substitution pass — see next section).
- `on-key` handlers become `match key [...]` arms inside `love/keypressed: function [key] [...]`.

**Deliverable:** Pong without collision. Paddles move, CPU tracks the ball position, scoreboard draws, space pauses, escape quits. No scoring and no bouncing yet.

**Exit gate:** the emitted Kintsugi for Pong-without-collision passes through the compile pipeline cleanly and the resulting Lua is readable top to bottom.

---

## Phase 3 — The `self` substitution pass **[DONE]**

This is the one genuinely novel piece of machinery the dialect needs. Every other dialect feature is straightforward block-walking + `@compose`. This one requires rewriting references.

**The mechanic:** inside an `entity name [update [body]]` block, `self/<field>` in `body` is a convenience binding — the user writes `self/y: self/y + 1` and the dialect substitutes `name/y: name/y + 1` when it lifts the body into `love/update`. Same for `on-collide entity [...]` where `self` is the entity and `it` is the other entity.

**Rules the substitution must enforce:**
- Only `self/<field>` is rewritten. Bare `self` is illegal and raises a dialect-level error at compile time with a line number.
- The substitution is syntactic (walks AST nodes and replaces word values). No evaluation.
- Nested blocks inside update/collide are walked recursively — `if cond [self/y: ...]` rewrites the inner set-path.
- `self` in a `draw [...]` block is illegal (draw is scene-level, not entity-scoped).

**Deliverable:** a `substituteSelf(block, entityName)` helper inside the dialect that takes a block AST and an entity name and returns a new block AST with `self/x` replaced by `<entityName>/x`. Unit-tested against shapes like `[self/y: self/y - (speed * dt)  if self/y < 0 [self/y: 0]]`.

**Exit gate:** the helper handles every shape of `self/...` that Pong and a hand-sketched Breakout need. If the substitution needs special-casing for closures or block literals, the grammar is too loose — tighten before moving on.

---

## Phase 4 — Tag-based collision enumeration **[DONE]**

Tags make the dialect composable. Users write `collide ball 'paddle [...]` once; the dialect expands it to one AABB-check block per tagged entity at compile time.

**Grammar:**
```
entity player [... tags [paddle]]
entity cpu    [... tags [paddle]]
entity ball   [... tags [ball]]

collide ball 'paddle [
  ; self = ball, it = <each tagged entity>
  ball/dx: negate ball/dx
]
```

**What the dialect emits:**
- For each entity tagged `paddle`, one inlined AABB-overlap `if` block containing the collide body with `it` substituted to that entity's name.
- The emission order is scene-declaration order (deterministic).
- If the tag expression is an entity name instead of a tag word (e.g. `collide ball player`), emit a single block for that pair.

**Deliverable:** Pong with working ball/paddle collision. Paddle hits bounce the ball and increment its speed. No scoring yet.

**Exit gate:** the tag-enumeration rewrite is a flat compile-time expansion — no runtime tag lookup, no dispatch table. If the emitted Kintsugi has a `for [tag] in paddles do` loop anywhere, that's a runtime framework hiding in plain sight and Phase 4 is wrong.

---

## Phase 5 — Second backend **[DONE]**

Stay in `@game [target: 'love2d]` through Phases 1-4. At Phase 5, add one more backend to prove target-swappability is structural, not a one-off.

**Recommended second target:** Playdate (Lua 5.4). Reason: the tightest constraint environment Kintsugi targets, so anything that works for Playdate works everywhere. Also the most different surface from LÖVE2D (different input API, different draw calls, no setColor, monochrome display).

**What changes in the dialect:** a `Backend` object with `(bindings, loadBody, drawEntity, keyQuery, quitCall, setColorCall)` fields. One instance per target. The dialect selects based on `target: 'love2d` vs `target: 'playdate` in the header.

**Deliverable:** the Phase 4 Pong with `target: 'playdate` compiles to a `main.lua` runnable on Playdate simulator. Same `@game` body, different emitted Lua.

**Exit gate:** a user can copy a Pong `@game` block between two files, change only `target: 'love2d` to `target: 'playdate`, and both compile and run on their respective platforms. If the user has to edit any other line, the abstraction leaks and Phase 5 is wrong.

---

## Phase 6 — Breakout as the validation game **[NOT STARTED]**

Once Pong runs on both targets, Breakout is the stress test. Breakout has things Pong doesn't:
- Many dynamic entities (bricks) — tests tag-based collision enumeration at scale.
- Spawning and destroying entities — tests entity lifecycle the dialect doesn't yet handle.
- State machines (playing / lost / won) — tests scene transitions.
- Data-driven level definitions — tests whether level layout can live inside `@game` or needs an escape hatch.

**Deliverable:** `examples/game-breakout/main.ktg`. Playable start-to-finish: launch ball, break bricks, lose lives, win or lose cleanly, restart via keypress.

**Exit gate from `docs/roadmap-confidence.md`:** "After 3 sessions, if Breakout isn't playable, something is wrong — either scope or language. Stop and diagnose." Game-dialect work is now subject to that gate.

---

## Deferred

These aren't in scope for Phase 1-6. They're worth listing so the dialect doesn't grow them prematurely.

- **Real ECS** (sparse sets, archetype tables, cache-friendly iteration). The dialect is Kaboom-scale — works great up to ~hundreds of entities. Real ECS is a months-long side project with a different payoff (10k+ entities) and would land as a separate `@ecs` dialect if ever needed.
- **Physics engine integration.** Raycasts, continuous collision, joints. Out of scope. The dialect only does AABB overlap. Games needing real physics write imperative blocks or use a Kintsugi wrapper over an external library.
- **Animation / tweening DSL.** Natural candidate for a future sub-dialect (`@anim`) that composes with `@game`. Not Phase 1-6 work.
- **Hot-reload in the interpreter.** The dialect is compile-time only; interpreter support (useful for REPL experimentation) can come after Phase 6.
- **Scene graph / parent-child transforms.** Flat entity model only. Hierarchies can come if Breakout proves they're missed.

---

## Non-goals

- Not a runtime library. If the emitted Lua mentions `_game`, `_entity`, `_collide`, or any other helper prefixed with a dialect name, the dialect is wrong. The only runtime presence allowed is what the existing emitter already emits (tree-shaken prelude helpers like `_append`, `_subset`).
- Not a framework users can extend. `@game`'s component vocabulary (`pos`, `rect`, `color`, `field`, `tags`) is fixed. Adding a new component is a dialect change, not a user-code extension. If users need custom per-entity state, they use `field name default` — not a user-defined component.
- Not target-agnostic at the emission level. The dialect has backends. Each backend is a concrete set of emit rules for one target. There is no "generic target" — that's how runtime frameworks get smuggled in.

---

## Minor cleanup items carried over

Small uncommitted items from the session that produced this roadmap, worth cleaning up either as part of the pre-work commit or as a follow-up.

- **Double-wrapped parens on function call args.** After the Bug D fix, `f (a + b)` emits as `f((a + b))`. Valid Lua, mildly ugly. Can be tightened by tracking outer operator context in the paren emit path. Low priority — correctness first.
- **`nim js` unused-import warnings.** `tables`, `sets`, `algorithm`, `parser` in `src/eval/natives_io.nim` are only used inside `when not defined(js)` blocks. On JS the imports are dead weight. Gating the imports themselves behind `when not defined(js):` would silence the warnings.
- **Duplicate `stripHeader` helpers.** Three copies across `src/kintsugi.nim`, `src/kintsugi_js.nim`, `src/emit/lua.nim` (as `stripKtgHeader`). Worth consolidating into a single exported helper from one of them, probably `lua.nim` since it's the common dependency.
- **Forward-ref `moduleNames` coverage.** The `collectModuleNames` pre-scan picks up top-level set-words. It does not pick up top-level set-paths (`obj/field: value`) or names inside top-level `if` bodies. Both are rare but worth a test case or two before someone writes code that trips them.

---

## The meta-rule

Every phase has an exit gate. If the gate fails, stop and rework — don't add the next phase on top of a leaky one. The `@game` dialect is small enough that each phase is verifiable in a session or two. If a phase grows beyond one session without a visible output, the design is wrong and the right move is to shrink the phase, not to push through.

The dialect's job is to make games shorter to write, not to make Kintsugi bigger.
