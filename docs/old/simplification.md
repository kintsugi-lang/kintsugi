# Kintsugi Simplification Plan

Updated 2026-04-08. Several refactorings have been completed; remaining items are listed below.

---

## Completed

| Refactoring | Lines Saved | Notes |
|-------------|-------------|-------|
| S1+S10. Emitter dispatch tables | ~500 | 81 expr handlers, 6 stmt handlers; elif chain from ~70 to ~16 branches |
| S3. `compareValues` extraction | ~60 | 4 one-liners replace 60 lines of duplicated comparison logic |
| S4. `seriesAt` helper | ~40 | `first`/`second`/`last`/`pick` are thin wrappers |
| S9. `withCapture` template | ~75 | 18 save/restore instances converted |

---

## Remaining

### S2. Share the function spec parser (currently implemented 3 times)

**Files:**
- `src/eval/natives.nim` — interpreter's `function` native
- `src/emit/lua.nim` — emitter's `parseSpec`
- `src/emit/lua.nim` — emitter's prescan

**Savings:** ~100 lines

**Solution:** Create a single `parseSpec` in `src/core/types.nim` that returns a `ParsedSpec` object. All three consumers call it.

---

### S5. Auto-generate `initNativeBindings` from the evaluator

**File:** `src/emit/lua.nim:125-243`
**Savings:** ~120 lines (plus eliminates sync bugs)

**Problem:** The emitter has a hardcoded ~120-line arity table that must be manually kept in sync with `natives.nim`. Every time a native is added or its arity changes, two files need updating.

**Solution:** Define the arity table once in a shared module that both the evaluator and emitter import, or use a Nim macro to generate both from a single declaration.

---

### S6. Factor `emitMatchStmt` and `emitMatchExpr` to share pattern compilation

**File:** `src/emit/lua.nim`
**Savings:** ~80 lines

**Problem:** Two 100+ line procs that parse the same pattern/guard/handler structure, differing only in whether they emit `if/elseif` statements or wrap in an IIFE.

**Solution:** Extract `compilePatterns(rulesBlock) -> seq[CompiledArm]`. Then each emitter consumes the arms in its own way (~20 lines each instead of ~100).

---

### S7. Factor the loop spec parser to be shared between interpreter and emitter

**Files:**
- `src/dialects/loop_dialect.nim:26-96` — interpreter
- `src/emit/lua.nim:516-677` — emitter

**Savings:** ~80 lines

**Solution:** Create a `LoopSpec` type and `parseLoopSpec` in a shared location. Both the interpreter and emitter consume the same parsed spec.

---

### S8. Use a factory for `time/*` and `date/*` accessor contexts

**File:** `src/eval/natives_io.nim:128-224`
**Savings:** ~70 lines

**Problem:** Each time/date accessor is a separately constructed `KtgNative` with full boilerplate. 96 lines for 11 trivial field accessors.

**Solution:** `makeAccessor(ctxName, fieldName, extractor)` factory.

---

### S11. Consider merging `vkContext` and `vkPrototype`

**Files:** Affects `types.nim`, `equality.nim`, `evaluator.nim`, `natives.nim`, `lua.nim`
**Savings:** ~100 lines across the codebase

**Risk:** **High** — semantic change touching every layer

**Problem:** Prototypes are essentially frozen contexts with field specs. The distinction adds duplicate branches everywhere.

**Solution:** A single `vkObject` with `frozen: bool` and optional `fieldSpecs`. Mutation checks become `if obj.frozen: raise ...` instead of separate type handling.

**Recommendation:** Do last, or skip entirely if the complexity doesn't cause problems in practice.

---

### S12. Consolidate set-path logic with `navigatePath`

**File:** `src/eval/evaluator.nim`
**Savings:** ~60 lines

**Problem:** Set-path largely duplicates `navigatePath` but with mutation at the end.

**Solution:** Factor into `resolvePath` that returns the parent container and final segment name, then set-path just does the final assignment.

---

## Summary

| Refactoring | Lines Saved | Risk | Priority |
|-------------|-------------|------|----------|
| S2. Shared spec parser | ~100 | Low | High — eliminates sync bugs |
| S5. Auto-generate arity table | ~120 | Low | High — eliminates sync bugs |
| S7. Shared loop spec parser | ~80 | Low | High — eliminates sync bugs |
| S6. Match pattern compiler | ~80 | Low | Medium |
| S8. IO accessor factory | ~70 | Low | Medium |
| S12. Shared path resolution | ~60 | Low | Medium |
| S11. Merge context/prototype | ~100 | High | Low |
| **Total remaining** | **~610** | | |

**Recommended order:** S2 → S5 → S7 → S6 → S8 → S12 → S11
