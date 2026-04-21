> **HISTORICAL REFERENCE ONLY.** This document summarizes design exploration, abandoned approaches, and past audit findings that shaped Kintsugi. It is not authoritative for the current language. For the current language, see `design-bible.md`. Statements here may contradict shipping behavior by design — the point is context, not correctness.

# Kintsugi Historical Record

## Overview

Kintsugi evolved from a TypeScript implementation (~11,000 lines) through a Nim rewrite (~9,280 lines at summarization time). This document captures the key design axes explored, rejected approaches, and critical audit findings that informed the current language, compiler, and runtime. Originals of the underlying docs were removed once this summary existed — use `git log docs/` to recover them if the history itself is needed.

## Type System Evolution

The language committed early to a rich type system with concrete value types beyond JSON primitives: monetary amounts, pairs, tuples, dates, times, files, URLs, emails, and structured types (blocks, contexts, prototypes). Runtime overhead is minimal, and the expressiveness for game dev and scripting carried its weight.

**Core equality mechanics.** Equality was implemented three times (`valuesEqual`, `valEq`, `matchValuesEqual`) with subtle divergences (word comparison, block structural equality). The design decision: one canonical equality function with 10 rules — numeric cross-type (int/float), structural recursion for blocks/maps/contexts, case-sensitive strings, identity for functions. This settled confusion about `=` vs `==` (loose vs strict).

**Type erasure in compilation.** Tension: function parameter annotations are enforced in the interpreter but silently erased in Lua. Three approaches were considered — pure erasure, compile-time `@enter`/`@exit` contracts with debug/release build modes, or explicit `@check` opt-in. Shipped design: annotations erase completely in Lua; `@type` custom types synthesize predicates only when referenced by `is?` or `match`; `@type/guard` marks opt-in compileability for user functions in where-guards. `@enter`/`@exit` never shipped.

## Dialect Design — Not Syntax

Debated whether `loop`, `match`, `attempt` should be language keywords or user-implemented. The dialect protocol won: each dialect is a native function that receives unevaluated block data and interprets it with its own vocabulary. This kept the evaluator core lean while enabling rich DSLs.

**Parse dialect scope.** The TypeScript era shipped a parse dialect (recursive descent PEG engine with backtracking). It did not survive the Nim rewrite — the interpreter has no parse implementation today. The rationale at the time was that PEG cannot reasonably compile to Lua without shipping a hefty runtime; users who need parsing are expected to use `@preprocess` for compile-time work, or hand-roll recognizers over blocks.

**Loop variable scoping.** A subtle aliasing source. Loop variables originally leaked into parent scope after iteration. The model shifted to block-scoped loop variables — implementation caught up incrementally.

## String Handling — Critical Design Gap

**Mutability asymmetry.** TypeScript's `String.replace` replaces only the first match. Early design allowed `append` on both blocks and strings (mutating strings by reference, which is a lie in JS). Audit fix: `append` mutates blocks only; string operations return new strings. Concatenation uses `rejoin [...]` or f-strings. A string `+` operator was considered and dropped — it would have violated immutability.

**Boundary validation.** `substring` silently returned empty on negative length; time literals accepted `25:61:99`. Both were fixed with explicit bounds checks raising typed errors.

## Emitter Architecture — The Largest Refactor

**The dispatch split problem.** Early Lua emitter had three semi-independent paths:
- `emitExpr` (expression context)
- `emitBlock` (statement context)
- `emitBlockReturn` / `findLastStmtStart` (return context)

Each construct (`if`, `either`, `match`, `loop`) was implemented 2–3 times with subtle divergences. A unified `emitVal(ctx: EmitContext)` dispatch redesign was proposed and deferred — high-risk 3–4 day refactor with huge payoff. Work continued with the multi-path design.

**Binding prescan.** The emitter needs function arities before emission to decide whether a path-lookup is a call or a value. The prescan walked only top-level functions; nested/conditional definitions caused "function or value?" ambiguities. A recursive prescan design existed but required careful handling to avoid false positives.

**Type inference leakage.** `varTypes`, `varSeqTypes`, `contextVars`, `funcReturnTypes` tracked metadata in separate tables that could fall out of sync. A unified `VarInfo` table was proposed and deferred as optimization.

## Simplification Opportunities Identified

Seven refactoring candidates were audited and scored. Most were deferred pending confidence in the language itself:

1. **Shared function spec parser** — three independent parsers for `function [params /refinements] -> returnType`.
2. **Auto-generated arity table** — ~120 lines hardcoded in emitter, must stay in sync with interpreter natives.
3. **Loop spec parser unification** — interpreter and emitter each parsed `for/in/from/to/by/when` independently.
4. **Match pattern compilation** — two 100+ line procs (`emitMatchStmt`, `emitMatchExpr`) duplicated logic.
5. **IO accessor factory** — ~11 trivial date/time accessors repeated boilerplate.
6. **Path resolution consolidation** — set-path largely duplicated `navigatePath`.
7. **Context/Prototype merge** — `vkContext` and `vkPrototype` nearly identical; merge save-value is ~100 LOC but risk is high.

**Refactors that did land:** dispatch tables for native emission (removed ~500 elif branches), `compareValues` extraction (consolidated three equality implementations), `seriesAt` helper (unified `first`/`second`/`last`/`pick`), `withCapture` template (consolidated 18 save/restore sites).

## Compiler Quality & Error Handling

**Recursion depth limit.** Parser enforced `MaxNestingDepth = 256` but the evaluator had no equivalent guard. Mutual recursion could overflow stack. Fix: `callStack.len > 512` guard at function entry, graceful typed error.

**Error path coverage.** A comprehensive audit found ~20 bugs ranging from silent failures (series ops using shallow `==` instead of deep equality) to missing emitter branches (various dialects without emitter paths) to fragile control flow (match emitter not supporting multi-element destructuring). All resolved by mid-April 2026.

**Clean compile errors.** Features that cannot compile raise specific errors pointing users to `@preprocess` as the escape hatch. Enforced via `compilable: false` on interpreter-only natives and `InterpreterOnlyNatives` in `src/emit/lua.nim`.

## Rough Edges — Deferred by Design

Several tensions were identified but **deferred pending real usage**, per the rule: "do not guess at features — each item has a revisit trigger."

**Hygienic templates** — `@template` is pure textual substitution; it cannot inspect call-site scope. Lisp-style macro hygiene would require 1500–2500 LOC redesign. Revisit when a real program needs it.

**Namespacing and modules** — No package manager, no versioning, flat imports. Namespaces could wrap exports in contexts, versions could pin lockfiles, a registry could come later. Revisit when two same-project files collide on an exported name.

**Tooling** — Emacs mode only. Tree-sitter grammar is the highest-ROI item (2 weeks, unlocks VS Code/Helix/Neovim/GitHub for free). LSP is months of work and helps one editor. Formatter is medium-effort. All deferred.

**Type enforcement on set-word/set-path** — `@type` definitions synthesize predicates in Lua only when referenced. Field-type validation on assignment (e.g., assigning a float to `pos.x` when `pos` is `pair!`) was not implemented in the interpreter. Tracking gap, not a bug.

## Object / Prototype / `@type` Unification Question

`@type` (structural custom types) and `object!` (prototype-based with nominal tagging via `_type` field) coexist. The distinction adds duplicate branches across `types.nim`, `equality.nim`, `evaluator.nim`, `natives.nim`, and the emitter.

**Proposal D** in the type erasure audit: unify them. A single `@type` declaration that can be struct-shaped (fields named in object syntax) becomes nominal-with-tag; other shapes stay structural. The object dialect would desugar to `@type` + `make` sugar.

**Decision at the time:** Defer. The current model works (proto objects have `__fields` metadata enabling type checking). Full unification was framed as a 3-month redesign. Current successor work picks this up under "merge dispatch, keep kinds" (Option B) — unify the predicate machinery while preserving `object!` as a distinct value kind.

## Confidence Building — Real Code First

A 2026-04-15 pivot recognized that after 12,000 lines of compiler, 1,344+ tests, and clean Lua output, the language still felt unstable because **nothing real had shipped in it**. The plan:

1. Build one small game (Breakout recommended) end-to-end, solving real problems.
2. Feature freeze on the language — only bugfixes and workarounds, no new natives/dialects.
3. Keep a running compile-pipeline notebook, capturing design lessons as they surface.

Meta-observation: a language is only trusted after it's been stressed by real use. The plan deferred all rough-edge work in favor of shipping a small, complete game.

## Abandoned Approaches

**None-propagation.** Early designs let operations on `none` silently return `none`. Changed to type errors — `none + number` raises `'type`. Makes pipelines explicit rather than silently swallowing failures.

**Operator precedence.** Debated heavily. Rejected — strict left-to-right with parens for grouping is simpler, more homoiconic, aligns with REBOL/Red lineage.

**Separate `char!` type.** Lexer produced `CHAR` tokens for single-character strings but runtime had no `char!` type. Dropped — strings are the universal sequence type.

**`append` on strings.** Never shipped. `append` mutates blocks only; strings use `rejoin`, `replace`, `uppercase`, etc.

**Integer division returning float.** `10 / 2` initially returned `2.0`. Proposal to return integer when result is exact was deferred.

**Prototype chains and delegation.** The object model uses stamp-based cloning (`make` copies, no delegation). Chains would require shared mutable state (parent pointer mutation) — not aligned with game-dev simplicity goal.

**`@compose` as a runtime surface.** Template runtime interpolation was once a named word (`@compose`, `@compose/deep`, `@compose/only`) with paren auto-interpolation on arbitrary blocks. The word was removed from the evaluator; the shared `composeWalk` proc remained, serving `@template` (call-site expansion) and `@emit` (compile-time splicing inside `@preprocess`). Prose references lingered in the design-bible until a later scrub pass.

**Tier 3 compiled homoiconicity.** A proposal outlined three tiers: Tier 1 (literals), Tier 2 (dialects + preprocessor), Tier 3 (code-as-data that compiles — `compose`, `reduce`, `bind`, `words-of` at runtime). Tier 3 never shipped. Static resolution of dynamic blocks at compile time was deemed too complex; `@preprocess` covers the practical cases.

**Build modes (debug/release).** The type erasure proposal had `--debug` and `--release` flags controlling contract assertion emission. Deferred — complete erasure is simpler; users who want assertions add them explicitly.

## Implementation History: TypeScript → Nim

The language was originally implemented in TypeScript (~11,000 lines, ~499 tests across 27 files). A Nim rewrite was planned because:
- Playdate targets embedded C (Nim compiles through C cleanly)
- `nim js` unlocks a browser playground
- Nim GC handles interpreter lifetimes cleanly

The Nim rewrite kept the evaluator model and architecture but tightened the implementation. The codebase shrunk to ~9,280 lines (excluding tests) while adding dialects, type system hardening, and a two-phase Lua emitter. Several TypeScript-era implementation friction points (1224-line natives monolith, three equality functions, runtime require for circular deps, 96 `as any` casts) were resolved structurally in Nim — cleaner types, dispatch tables, proper module isolation.

## Lessons & Patterns

**One source of truth.** Equality, spec parsing, and loop parsing were duplicated across interpreter and emitter. Each divergence was a latent bug. Lesson: shared functions or strict mirroring between paths.

**Dialect protocol abstraction.** Dialects as natives with inert block arguments let the language scale without syntax explosion. Each dialect is independently testable and versionable.

**Type annotations for compiler quality.** Function parameter and object field annotations don't enforce at runtime in Lua but enable the compiler to emit cleaner code (fewer wrappers, better field access). Right balance for a scripting language.

**Prescan before emission.** The two-phase emitter (prescan bindings, then emit) is necessary for any-target compilation.

**Confidence through real use.** No amount of test coverage can replace shipping a small real program.

## Superpowers / Process Docs

The `superpowers/` subdirectory held process-oriented specs and plans (design docs for individual audit passes, lexer fix rounds, evaluator phase plans). These were scaffolding for specific coordinated refactors, not language design. Captured here in aggregate so the details can be recovered from `git log` if ever needed; none of the individual plans are load-bearing for the current language.
