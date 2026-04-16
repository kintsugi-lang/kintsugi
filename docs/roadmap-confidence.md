# Building Confidence in Kintsugi

## Context

The question isn't rhetorical. There are 12,000 lines of compiler, 1,344+ tests, clean Lua output, type inference, six dialects, and a principled design bible. That's a lot of evidence the language works. So why does it still feel like it might not?

The causes:
1. **Nothing real has shipped in it.**
2. **Every session surfaces a rough edge.** The design still feels unstable.
3. **The compile pipeline is opaque.** Preprocess, prescan, inference, emission — the output isn't always predictable.

These three are the same problem seen from different angles. Without real use, design instability can't be found until a test happens to catch it. Without a clear pipeline mental model, fixes are local rather than principled. And without shipping, there's no way to prove the fixes are right.

The meta-observation: the session that wrote this plan fixed silent string correctness bugs in `first`/`last`/`pick`, rewrote the attempt emitter, eliminated four helpers, and added full sequence-type inference. None of that was planned — it surfaced because of an audit. That's the pattern. A language is only trusted after it's been stressed.

## Diagnosis

The confidence gap is not a tooling gap or a documentation gap. It's a **calibration gap**. It's unclear where the language is strong and where it's weak because it hasn't been applied to a non-trivial target worth finishing.

`combat.ktg` is a benchmark. Pong is a demo. Neither is a program worth missing if it didn't exist. Calibration needs something:
- Small enough to finish (one to three sessions)
- Non-trivial enough to exercise multiple dialects and the type system
- Worth wanting to exist when it's done

## Strategy

Three moves, executed simultaneously over the next few sessions:

### 1. Ship one small game

Pick one. Build it end-to-end. Do not add features to the language unless the game genuinely can't be expressed without them. The game is the calibration instrument, not another benchmark.

Candidates, ranked by signal:

- **Breakout** — physics (collisions), input, data-driven levels, state machine (playing/lost/won). Exercises `pair!`, `object`, `match`, `loop`. Canonical.
- **Asteroids** — vector math (pair arithmetic), wrapping, spawner logic. Stresses the pair type and math stdlib hard.
- **Match-3** — grid, `loop/collect`, `match` for piece types, score accumulation. Exercises the collection ops we just added parity for.

Recommendation: **Breakout**. Smallest scope, broadest language surface. Target LOVE2D; bindings already exist in `lib/love2d.ktg`.

**Update 2026-04-15:** The @game dialect (phases 1-5 of roadmap-game-dialect.md) is complete. Pong runs on both LOVE2D and Playdate targets. 648 LOC across game_dialect.nim, game_backend.nim, game_playdate.nim. 38+ tests passing. Breakout has not been started yet.

### 2. Feature freeze on the language itself

No new natives, no new dialects, no new syntax until the game ships. The freeze is load-bearing. Every feature adds surface area, and instability shows up first at the seams between features.

If the game blocks on something, three choices in priority order:
1. Work around it in user code
2. Fix a bug (must come with a test)
3. Break the freeze (must come with a written justification in the commit)

Option 3 should be rare. If it happens twice, the language design has a real problem that should be named.

### 3. Keep a running compile-pipeline notebook

Not a doc written upfront. A file appended to every time the question "why did the emitter do that?" comes up. Path: `docs/compile-pipeline.md`. Format:

```
## 2026-04-13 — inferSeqType on function return types

Saw: `x: uppercase s` → x wasn't tracked as a string var
Traced: funcReturnTypes only catches explicit annotations, not natives
Fix: added StringReturnNatives list in inferSeqType
Learned: type inference has three sources — literals, annotations, native tables.
  Natives need curation or the inference silently falls back to stUnknown.
```

Each entry is a unit of understanding earned. After three or four entries, there's a map of the pipeline that didn't exist before, and writing it *during* the work means each entry is grounded in a concrete problem.

## Concrete first session

1. Commit the current state. Clean checkpoint.
2. Create `examples/breakout/` and start the game. Use `lib/love2d.ktg`.
3. Structure it minimally: paddle, ball, bricks, game loop. Get a ball bouncing first.
4. When friction hits, stop. Write the notebook entry. Decide: work around, fix, or break freeze. Log it.
5. End session when the ball bounces off paddle and walls. Don't chase "done" yet.

## Signals to watch

**On track when:**
- Breakout progresses faster than expected
- Notebook entries are small and explanatory, not "wat"
- Freeze holds — no language changes needed

**Off track when:**
- The same category of bug hits three times (emitter type tracking is still leaky)
- Notebook entries start with "I don't understand why..." and never resolve
- The urge to add natives to make a specific line shorter keeps appearing

**Calibration points** (stop and reassess):
- After 2 sessions: how much of Breakout exists? How many notebook entries?
- After 3 sessions: if Breakout isn't playable, something is wrong — either scope or language. Stop and diagnose.

## Files to watch

The files most likely to surface issues during the build:

- `src/emit/lua.nim` — type inference, dialect lowering, helper decisions
- `src/dialects/loop_dialect.nim` — game loops use this constantly
- `src/dialects/match_dialect.nim` — state machines, collision response
- `src/dialects/object_dialect.nim` — game entities
- `lib/love2d.ktg` — LÖVE2D bindings; likely gaps here
- `lib/math.ktg` — vector math

## What to re-read before starting

- `docs/design-bible.md` — the principles being committed to
- `examples/pong/main.ktg` — the closest existing LÖVE2D game; structural reference, not copy-paste source
- `docs/style-guide.md` — the house rules

## Verification

Confidence is earned when all three are true:

1. **Breakout is playable end-to-end.** Start, lose, restart.
2. **Fewer than three language changes happened during development.** The instability hypothesis was wrong — the design is stable and the rough edges were surface, not structural.
3. **`docs/compile-pipeline.md` can explain any Kintsugi program's compilation without reading the emitter source.** The pipeline isn't opaque anymore because it was mapped from the outside in, one problem at a time.

If any of the three don't hold, the specific one that fails tells you where to invest next.

## What this is not

- Not a feature roadmap. No new capabilities are promised.
- Not a tutorial or documentation project.
- Not a refactoring plan. The current code is the starting line, not the problem.

It's one thing: build something real, with the tools available, and let the process teach what to trust.
