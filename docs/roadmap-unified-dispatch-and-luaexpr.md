# Focused session: unified dispatch + LuaExpr + tail consolidation

Follow-on to the main burndown (see `~/.claude/plans/all-right-plan-the-fluffy-pelican.md`). Captures the coherent block of work that was deliberately deferred out of the incremental burndown because the items are mutually dependent and best done in a single focused session with a fresh context window.

## Status — 2026-04-18

### Phase A — COMPLETE

All form migrations landed. From `emitExpr` elif chain into `exprHandlers`:
function, does, context, try, try/handle, scope, loop, attempt, match,
rejoin, rejoin/with, find, reverse, if, either, capture, loop/collect,
loop/fold, loop/partition, import, import/using. From `emitBlock` inline
branches into `stmtHandlers`: if, either, unless, loop, match. Dead
`emittedTypePredicates` field removed. `MethodChainBarriers` const
deleted — replaced by `methodChainBarriers: HashSet[string]` derived at
module init from `stmtHandlers.keys` plus explicit control-flow expr
handler list plus dialect-internal keywords. `resolvePathCall` helper
extracted — shared between `emitExpr`'s path-access branch and
`emitBlock`'s stmt path branch.

Tests 1616 green, goldens byte-identical.

LOC: `src/emit/lua.nim` 4796 -> 4727. Total `src/emit/*.nim` 5349 -> 5280.

## Phase B — findLastStmtStart pure walk (~1 day)

Depends on Phase A item 1 (`consumesArgs` metadata on handlers).

1. **Write `advanceExpr(vals, pos, bindings): int`** — pure AST walker that
   mirrors `emitExpr`'s arg consumption without output. For each `wkWord`,
   looks up `consumesArgs` from handler table, else uses `bindings` arity.
   Handles literals, parens, blocks, infix chains, method chains as the
   real emitter does. Unit test each branch (one test per form) asserting
   `advanceExpr`'s returned position matches `emitExpr`'s `pos` under
   `withDryRun`.

2. **Replace `findLastStmtStart` body** — loop calling `advanceExpr` until
   end; return last start.

3. **Delete `withDryRun` template + `inDryRun` field** on `LuaEmitter`.

4. **Regression test** — `f: does [import %x.ktg]` run twice; verify
   `pendingDepWrites` contains one entry per dep, not two.

Acceptance: `withDryRun` grep returns nothing in `src/emit/`. Tests green.
`src/emit/lua.nim` around 4300 lines.

## Phase C — LuaExpr typed expressions (6-8 days)

Biggest refactor. Do NOT start without fresh context. Kept here for shape.

1. **Add type** in `src/emit/helpers.nim`:
   ```nim
   type
     LuaExprKind* = enum lxLiteral, lxCall, lxInfix, lxTableCtor, lxOther
     LuaExpr* = object
       text*: string
       case kind*: LuaExprKind
       of lxInfix: prec*: int
       else: discard
   ```
2. **Parallel typed handlers behind `-d:luaExprTyped`.** Every expr handler
   gains a `…Typed` variant returning `LuaExpr`. Old variant calls typed
   one, projects `.text`.
3. **Batch migration** (one commit each): math handlers, string handlers,
   series handlers, type-predicate handlers, `emitExpr`'s infix chain,
   control-flow forms, capture-based forms. Measure after each batch.
4. **Flip default, delete string path.** Keep `lxOther{text}` as escape
   hatch for statement-capture output (via `withCapture`).
5. **Delete string-grep helpers**: `needsParens`, `parenIfComposed`,
   `wrapIfTableCtor`, `wrapForPrint` first-char classification,
   `isFieldSafeForConcat` string walking, `emitExpr`'s infix-chain tail
   string reasoning.

Acceptance: `grep -E 'needsParens|parenIfComposed|wrapIfTableCtor|wrapForPrint' src/emit/*.nim` returns nothing. `src/emit/lua.nim` around 2800 lines.

Abort criterion: if >30% of handler emit sites need `lxOther`, the type
isn't carrying enough info. Back out; unify `withCapture` first.

## Phase D — Final consolidation (~1-1.5 days)

Post-A, post-C. Each item independent:

- **4.5.4** — Collapse remaining `emitExpr` `wkWord` arm special cases
  (`none` sentinel, `system/env/*`, residual path handling) into handler
  table. Target: `wkWord` arm ≤ 40 lines.
- **4.5.5** — Replace `emitBlock`'s per-form tail with a handler-table
  loop + set-word / path-call / generic-expr fallbacks. Target: ≤ 50 lines
  for the body of `emitBlock`.
- **4.5.8** — Prune `LuaEmitter` fields. After Phase A: check
  `customTypes` vs `customTypeRules` redundancy. After Phase B: delete
  `inDryRun`. After Phase C: may be able to delete `stdlibPreludeLua`
  (cache, inline into `buildPrelude` — see src/emit/lua.nim:4737 writer
  and :4074 reader, single write-then-read pattern).

Acceptance: `wc -l src/emit/*.nim` ≤ 2500 total. `nimble test` green.
Goldens byte-identical or explicitly regenerated.

## Current vs. plan delta

| Checkpoint | LOC `src/emit/*.nim` | Notes |
|---|---|---|
| Pre-session | 5349 | Forms inline in elif chains |
| Post-session (now) | 5311 | Most forms in handler tables |
| After Phase A remainder | ~4900 | Handler struct + MethodChainBarriers gone |
| After Phase B | ~4800 | Pure walker, dry-run deleted |
| After Phase C | ~2900 | LuaExpr typed |
| After Phase D | ~2500 | Final consolidation |

## Context

At the end of the incremental burndown session, `src/emit/lua.nim` stood at **~4200 lines** (from a starting point of 5117). All surface-level correctness issues were fixed; legacy forms were culled; the filesystem-side-effect path was cleaned up; pure helpers, prelude constants, and globals were split into their own modules.

The remaining work is a single architectural transformation. Doing it as four separate small PRs would require rewriting the same code multiple times — the unified dispatch tables want a typed expression representation; the typed expression wants pure AST walks instead of emit-probe; the match/scope consolidation wants unified dispatch as its base. They belong together.

**End state target:** `src/emit/lua.nim` ≤ 2500 lines. Zero string-grep heuristics in emitter logic. Single source of truth for each control-flow form.

## Prerequisite: independent items must be landed first

This session assumes the following were completed in the preceding incremental session (in `all-right-plan-the-fluffy-pelican.md` terms):

- Phase 2.5 — `@enter`/`@exit` emission
- Phase 4 / P1#9 — `isPureExpressionBody` replaces `handler.len <= 3` heuristic
- Phase 4 — `emitLua` wrapper deleted, tests migrated
- Phase 4.5.1 — match emitters unified into one `emitMatch(sink: MatchSink, ...)`
- Phase 4.5.2 — `scope` unified (stmt and expr share one proc)
- Phase 4.5.3 — single `VarInfo` / `varTable` replaces `varTypes`/`varSeqTypes`/`concatSafeVars`/`funcReturnTypes`
- Phase 4.5.6 — `prescanBlock` + `inferBindings` merged into one pass
- Phase 4.5.7 — IIFE-inline literal-safe branches measured and dropped if <5% output size win

If any of those slipped, start this session by finishing them. Each is tractable standalone; they just add friction to the dispatch rewrite if carried forward.

## Phase A — Unified dispatch tables (3–4 days)

Fold the ~700-line `elif name ==` chains in `emitExpr` and `emitBlock` into the handler tables.

### Handler type extension

```nim
type
  HandlerFlags* = object
    isControlFlow*: bool   ## Acts as a `->` chain barrier. Replaces
                           ## MethodChainBarriers hand-list (see helpers).
    exprForm*: bool        ## Can appear in expression position.
    stmtForm*: bool        ## Can appear in statement position.
    consumesArgs*: proc(vals: seq[KtgValue], pos: int): int
                           ## Pure AST walker — given the token stream
                           ## and the position of the form's head word,
                           ## returns the next-token position. Used by
                           ## findLastStmtStart without invoking emit.

  Handler* = object
    expr*: ExprHandler     ## nil if stmtForm-only
    stmt*: StmtHandler     ## nil if exprForm-only
    flags*: HandlerFlags
```

### Migration strategy

One form at a time. Each form goes from "elif branch" to "handler table entry" in three steps:

1. **Write the `consumesArgs` walker** for the form. Pure AST traversal — no `emitExpr` calls. Most forms are simple (e.g. `if` consumes 1 expression + 1 block = 2 token positions at fixed offsets after the head).
2. **Extract the body of the elif branch into a standalone `proc`** matching `ExprHandler` / `StmtHandler`. Register it in the table with `flags`.
3. **Delete the elif branch.**

Forms to migrate, in the recommended order (simplest first):

| # | Form | Expr | Stmt | Notes |
|---|---|---|---|---|
| 1 | `try` | ✓ | | simple IIFE |
| 2 | `try/handle` | ✓ | | simple IIFE + handler block |
| 3 | `context` | ✓ | | table emission |
| 4 | `does` | ✓ | | func def with empty spec |
| 5 | `function` | ✓ | | func def |
| 6 | `capture` | ✓ | | dialect; already isolated |
| 7 | `attempt` | ✓ | | dialect; already isolated |
| 8 | `find` | ✓ | | type-aware helper |
| 9 | `reverse` | ✓ | | type-aware helper |
| 10 | `rejoin` / `rejoin/with` | ✓ | | special-case concat emit |
| 11 | `scope` | ✓ | ✓ | post 4.5.2, already one proc |
| 12 | `if` | ✓ | ✓ | simple |
| 13 | `unless` | | ✓ | stmt-only |
| 14 | `either` | ✓ | ✓ | two blocks |
| 15 | `loop` | ✓ | ✓ | dialect |
| 16 | `match` | ✓ | ✓ | post 4.5.1, single `emitMatch` |
| 17 | `import` / `import/using` | ✓ | | already special-cased for path collision |

### After migration

- **`MethodChainBarriers` const is deleted.** Replaced by `h.flags.isControlFlow` lookup.
- The two `->` barrier code paths in `emitMethodChain` use the handler flag, not a name list.
- `emitExpr`'s `wkWord` arm drops from ~640 lines to ~80 (table lookup + generic call/var reference fallback).
- `emitBlock`'s per-form branches drop from ~500 lines to ~50 (table lookup + set-word + path-call fallbacks).

### Checkpoint at Phase A close

Commit with tag. Full goldens + tests green. LOC target: `src/emit/lua.nim` around 3200–3400.

## Phase B — Pure AST walker for `findLastStmtStart` (0.5 day)

`findLastStmtStart` currently runs `emitExpr` under `withDryRun` to advance position. Replace with a pure walker that calls each handler's `consumesArgs`.

```nim
proc findLastStmtStart(e: LuaEmitter, vals: seq[KtgValue]): int =
  var stmtStarts: seq[int] = @[]
  var pos = 0
  while pos < vals.len:
    stmtStarts.add(pos)
    pos = advanceStatement(e, vals, pos)  # no emit; uses handler metadata
  if stmtStarts.len > 0: stmtStarts[^1] else: 0
```

Delete `withDryRun` template. Delete `inDryRun` field on `LuaEmitter`. Tests: add one that compiles a function body with `import %path` to verify dep files are written ONCE (the dry-run bug's original symptom).

## Phase C — `LuaExpr` type (6–8 days, the largest sub-phase)

Replace the emitter's use of raw strings for expression representation with a small typed sum:

```nim
type
  LuaExprKind* = enum
    lxLiteral   ## "42", "\"str\"", "true", "nil", table literal
    lxCall      ## any function-call shape
    lxInfix     ## binary operator composition with known precedence
    lxTableCtor ## "{a, b, c}" needing paren-wrap for indexing
    lxOther     ## everything else; escape hatch for statement-capture output

  LuaExpr* = object
    text*: string            ## the emitted Lua text
    case kind*: LuaExprKind
    of lxInfix: prec*: int
    else: discard
```

### What this deletes

- `needsParens` (string-grep for " and "/" or ") — `lxInfix` carries precedence directly.
- `parenIfComposed` — precedence-aware wrap based on `lxInfix.prec`.
- `wrapIfTableCtor` — `lxTableCtor` tagged at emission site.
- `wrapForPrint`'s first-char heuristic — `lxLiteral` covers the classification.
- `isFieldSafeForConcat`'s string walking — typed output from field access.
- The infix-chain post-amble's string-based precedence reasoning at `emitExpr` tail.

### Threading strategy

Two-step:

1. **Type-flag behind `-d:luaExprTyped`.** Every handler gains a parallel `…Typed` variant that returns `LuaExpr`. Old variants stay, calling the typed one with `.text` projection. Tests work either way.
2. **Per-handler batch migration** (math → string → series → type-preds → infix chain → control-flow forms → capture-based forms last, since `withCapture` still returns raw strings for statement blocks).
3. **Flip default, delete string path.** `lxOther{text}` stays as the escape hatch for statement-capture outputs.

### What this does NOT do

`withCapture` (capture emitter output into a string buffer for statement blocks) stays as-is. `LuaExpr` is for expressions — statement blocks are fundamentally string-buffer territory. The escape hatch `lxOther` covers the cases where captured-block output is embedded into an expression (IIFE wrappers).

### Checkpoint at Phase C close

Commit with tag. Full goldens + tests green. LOC target: ~2700–2900.

## Phase D — Final consolidation (1–1.5 days)

Post-dispatch-unified and post-LuaExpr, several items become cheap:

- **4.5.4 — Collapse remaining `emitExpr` wkWord arm special cases** (`none` sentinel, `system/env/*` path, `system/platform`, etc.) into the handler table. Target: `wkWord` arm ≤ 40 lines.
- **4.5.5 — Delete overlapping stmt dispatch.** `emitBlock` becomes a ~40 line loop: handler lookup → call handler → fall-through to set-word / path-call / generic-expr.
- **4.5.8 — Prune LuaEmitter fields.** After Phase 4.5.3's VarInfo consolidation and Phase B's dry-run deletion, `customTypes` (redundant with `customTypeRules`), `emittedTypePredicates` (write-only?), and `stdlibPreludeLua` (cache, inline into buildPrelude) all go. Each removal deletes its field + save/restore sites.

### Final acceptance

- `wc -l src/emit/*.nim` ≤ 2500 total.
- `nimble test` green.
- Full golden suite byte-identical (or regenerated once with size-reduction documented in commit).
- `grep -E 'needsParens|parenIfComposed|wrapForPrint|wrapIfTableCtor|withDryRun|MethodChainBarriers' src/emit/*.nim` returns nothing.
- `grep -E 'elif name == "' src/emit/lua.nim | wc -l` is < 10 (only generic-case fallbacks remain).
- CLI + playground smoke test.

## Risk register

| Risk | Mitigation |
|---|---|
| Golden regressions during Phase A per-form migration | Commit after each form; run goldens; byte-identical or fix immediately. |
| LuaExpr behind `-d:luaExprTyped` means two parallel code paths for N days | Keep the flag live for < 1 week. Migrate all handlers in one compressed push; flip and delete. |
| Statement-capture via `withCapture` clashes with `LuaExpr` | Accept `lxOther{text: string}` as escape hatch; don't force typing there. |
| `consumesArgs` walkers get arity wrong for edge cases | Each form's walker has a dedicated unit test asserting the walker's position match with what `emitExpr` produces under `withDryRun` (during the transition). |
| Autocompact interrupts mid-rewrite | Commit after each of A/B/C/D as a natural checkpoint. Plan doc is the anchor to resume from. |

## Order of operations

```
Phase A (dispatch unification)
   ├─ migrate forms 1-11 in any order (independent)
   ├─ migrate forms 12-17 (depend on 1-11 to establish the pattern)
   └─ delete MethodChainBarriers, emitExpr wkWord elif chain, emitBlock elif chain
   ┆ COMMIT + TAG
Phase B (findLastStmtStart pure walk)
   ├─ implement advanceStatement using handler.consumesArgs
   ├─ replace findLastStmtStart body
   └─ delete withDryRun + inDryRun
   ┆ COMMIT
Phase C (LuaExpr)
   ├─ add -d:luaExprTyped flag + parallel typed handlers
   ├─ migrate handlers batch by batch
   ├─ flip default, delete string path
   └─ delete needsParens / parenIfComposed / wrapIfTableCtor / etc.
   ┆ COMMIT + TAG
Phase D (final consolidation)
   ├─ 4.5.4 + 4.5.5
   ├─ 4.5.8
   └─ final LOC audit
   ┆ COMMIT + TAG
```

## Critical files

Primary surface:
- `src/emit/lua.nim` — every phase touches; target final state ≤ 1800 lines here.
- `src/emit/helpers.nim` — delete string-grep helpers in Phase C.

Secondary:
- `src/emit/prelude_consts.nim` — no changes expected unless helpers are removed.
- `src/emit/globals.nim` — no changes.
- `tests/golden/*.ktg/.lua` — regression net; avoid regeneration if possible.

## When to abort

If Phase A stalls on a single form for more than half a day — meaning its `consumesArgs` walker is genuinely hard to write without running emit — stop and escalate. Most likely cause: the form has data-driven behavior that depends on the token value itself (e.g., refinement paths like `loop/collect` vs `loop/fold`). Solution: those get a small enum dispatch inside one walker, not separate handlers.

If LuaExpr in Phase C starts requiring an lxOther escape hatch at > 30% of handler emit sites, back out. The type isn't carrying enough information; retry after more focused `withCapture` unification.

## End-of-session deliverables

- Plan commits at each checkpoint with the LOC delta in the message.
- Tests + goldens green.
- No new TODO comments in the emitter.
- `docs/roadmap-unified-dispatch-and-luaexpr.md` updated to mark what was done / what (if anything) got deferred again.
