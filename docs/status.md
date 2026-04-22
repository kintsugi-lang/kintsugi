# Status

**Version at freeze:** 0.5.2 (2026-04-22)
**State:** Active development paused. Language is usable at current version. No breaking changes planned. No work committed to a 1.0.

This document captures where Kintsugi landed and what was planned but not shipped, so future-me or anyone picking this up has a clean entry point.

---

## What Ships and Works

- **Core language**: left-to-right evaluation, 28 built-in types, blocks/contexts/objects, dialects (loop, match, attempt, object), @type (with /enum, /where, /guard), tagged unions with exhaustive match, @template and @preprocess metaprogramming.
- **Interpreter**: full language, REPL with multiline input, stdlib modules loaded via `import`.
- **Compiler targets**: LOVE2D (LuaJIT), Playdate (Lua 5.4), standalone Lua (Lua 5.4). Single-file prelude + source output, tree-shaken helpers.
- **Bindings dialect**: `'call`, `'const`, `'alias`, `'assign`, `'method`, `'variadic` (with `returns N`). Target sub-blocks for multi-target modules.
- **Stdlib modules**: `math`, `collections`, `color`, `coroutine`, `io`.
- **Test coverage**: ~40 test files, cross-mode parity suite, golden `.ktg` → `.lua` fixtures, emitter metrics.
- **Tooling**: Emacs major mode (`kintsugi-mode/`), web playground (`playground/`, wraps WASM build).

See `CHANGELOG.md` for the full shipping history, `docs/design-bible.md` for the language spec, `full-spec.ktg` for the executable tour.

---

## Pending Roadmap

Items that had concrete designs or partial work at freeze time, ordered roughly by impact.

### Type System

- **Phase-2 type unification.** `@type` and `object!` share a `typeDefs` registry but still back to separate storage (`CustomType` vs `KtgObject`). Collapse into one representation, flip object dispatch fully nominal-by-tag, remove the dual path. Phase-1 landed in 0.5.1; phase-2 deferred.
- **Trim the type zoo.** `money!`, `email!`, `url!`, `file!`, `date!`, `time!` carry implementation, doc, and test weight that doesn't serve the stated game-dev focus. Candidate for demotion to opt-in stdlib modules, leaving ~14 core types.

### Emitter

- **Decompose `src/emit/lua.nim`.** 5420 LOC single file. Every bugfix navigates the whole surface. Natural split:
  - `emit/expressions.nim` — value/call/path/operator emission
  - `emit/dialects.nim` — loop/match/attempt/object lowering
  - `emit/prelude.nim` — helper gating + tree-shaking
  - `emit/bindings.nim` — bindings dialect resolution
  - `emit/strict.nim` — strict-globals pass
  - `emit/driver.nim` — pipeline glue
  No behavior change, purely mechanical. ~1 week of work.
- **Trailing-return cleanup.** Emitted functions sometimes carry an unintended `return <last-expr>` when the function body's last form is a mutating statement that also evaluates to a value (see `reset_ball` in `tests/golden/pong.lua`). Tighten the "expression in tail position" detector.
- **Backend-portable architecture.** If a second compile target ever becomes interesting (JS, WASM, something embedded), extract lowering passes from codegen so the emitter becomes `AST → lowered AST → per-backend codegen`. Dialect lowering, import resolution, strict-globals, template expansion, and `@preprocess` are backend-agnostic. Current `lua.nim` collapses all of this into one monolith. See the "AST Is the IR" section in design-bible; the principle survives this split.

### Toolchain

- **Tree-sitter grammar.** Unblocks syntax highlighting in every modern editor, GitHub rendering, and is a prerequisite for a proper LSP. Non-trivial: Kintsugi's `word-with-dashes`, path syntax, and set/get/lit/meta prefixes need careful terminal rules.
- **Formatter (`kintsugi fmt`).** Reuses the existing parser. Smallest tooling investment with real payoff. Kills style churn in reviews.
- **LSP**. Goto-definition, hover, strict-globals diagnostics in-editor. Larger commitment; only worth it if adoption materializes.

### Stdlib and SDK

- **`lib/love2d.ktg` shipped bindings.** Today each LOVE2D game hand-writes its bindings block. For a LOVE2D-focused target this is overcautious — the SDK surface is stable and worth shipping. Current decision (each game binds what it uses, documented 2026-04-20) should be reconsidered if the language narrows to LOVE2D as primary target.
- **`lib/playdate.ktg` shipped bindings.** Same reasoning for the Playdate SDK.
- **Math stdlib gaps.** `lerp`, `clamp`, `sign`, `smoothstep`, and `pair!`-aware vector helpers are game-dev staples; some are present, the set is uneven.

### Tests and Docs

- **Test folder cleanup.** Accrued dev scaffolding: `test_bugfixes.nim` + `test_bugfixes2.nim`, `test_session_0327.nim`, `test_final_gaps.nim` + `test_remaining_features.nim` + `test_stdlib_gaps.nim`, `test_game_dialect/` directory residue after the dialect was ripped. Consolidate by topic, delete dead scaffolding.
- **`full-spec.ktg` split.** 1878 lines. Promise "readable in an hour" doesn't survive the length. Split into a ~500-line core tour and a reference section.
- **CLI ergonomics.** `kintsugi new <name>` scaffold, `kintsugi build` one-command LOVE2D `.love` packaging. Not shipped.

### Language Questions Left Open

- **`@type` + `object!` unification** (see Phase-2 above). Two mechanisms with overlapping semantics today.
- **`'override` binding kind.** Declared in `docs/bindings.md` as reserved/internal; never stabilized as user surface.
- **Inheritance / polymorphism story for objects.** Stamp model with `merge` mixin composition ships today; no method-override path. Intentional simplicity but awkward for larger entity hierarchies in games.

---

## Why Development Paused

Kintsugi is a well-engineered tool that does not yet have a well-engineered audience. The stated goal — "pleasant developer experience for Lua game devs" — runs into three structural problems:

1. **Every concentrated Lua-adjacent audience in 2026 is either owned by an incumbent (Fennel on LÖVE2D, Luau on Roblox), culturally resistant to AI-assisted development (Playdate, PICO-8), or too diffuse to market to (modding in general).**
2. **Toolchain gap.** "Pleasant DX" without LSP, formatter, or tree-sitter is a promise the language can't keep yet. Building those is months more work before the language competes on its own pitch.
3. **Opportunity cost for the author.** Continuing to polish the compiler is time not spent making and shipping the games the language exists to serve. The better return on investment is to use boring, mature tools (LÖVE2D + plain Lua, or similar), ship games, and learn from that experience whether a Kintsugi-shaped tool is still wanted.

The work is real. The emitter output is clean. The design is coherent. None of that is lost by pausing. If the author returns to language work after a year of making games in other tools, they return with sharper instincts about what games actually need — which is a better starting point than "I'll just build the language first."

---

## If You Want To Pick This Up

Whether "you" is future-me or someone else entirely:

1. **Read `docs/design-bible.md` first.** It is authoritative. Nothing else in the repo supersedes it. The principles (Simple / Robust / Explicit) have held across the whole 0.x line — respect them or fork.
2. **Run `nimble test`.** If it passes, the language is working. If it doesn't, start there.
3. **Read `full-spec.ktg` end-to-end.** Slow but gives you the feel of the language faster than any other single read.
4. **Pick one item from "Pending Roadmap" above.** Don't pick multiple. Most items above are 1-2 weeks of focused work; do them one at a time with a commit + CHANGELOG entry per finish.
5. **Freeze language-surface changes behind explicit design bible updates.** The language shape is settled at 0.5.2. New syntax, new meta-words, new dialects require justifying against the Decision Checklist at the bottom of `design-bible.md`.

The bar for restarting regular development: a concrete use case the author is personally building, that the language serves better than alternatives. Absent that, polish is yak-shaving.

---

## One-Line Summary

Kintsugi at 0.5.2 is a finished-feeling pre-1.0 that works, is principled, and sits on ice until a real use case pulls it forward.
