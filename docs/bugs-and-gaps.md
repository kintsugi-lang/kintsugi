# Kintsugi Bugs and Gaps

**Status:** All known bugs resolved as of 2026-04-08.

---

## Resolved

All 20 tracked bugs (B1-B15, N1-N5) have been fixed:

- **B1/B2/B5:** `_has`, `_select`, `find` use `_equals` helper for deep equality
- **B3:** `_replace` uses literal `find(..., true)` instead of pattern `gsub`
- **B4:** `either` always uses IIFE form (handles falsy true-branches)
- **B6/B7/B8:** raise `compileError` for interpreter-only features (`@parse`, sourceless `attempt`, `prototype`)
- **B9:** `deepCopyValue` handles maps, sets, prototypes
- **B10:** `size?`/`length?` share one proc
- **B11:** `_copy` uses `pairs` not `ipairs`
- **B12:** `apply` triggers `_unpack` helper
- **B13:** `compareValues` extraction eliminates fallthrough
- **B14:** match emitter handles multi-element destructuring
- **B15:** `@macro` implemented in interpreter, correctly erased in emitter, tests added
- **N1:** Time literals validated (hours 0-23, minutes 0-59, seconds 0-59)
- **N2:** `substring` rejects negative length
- **N3:** Recursion depth limit (512) with graceful `KtgError`
- **N4:** `sort/by` and `set`/`@rest` emitter support confirmed working; `@type` raises `compileError`
- **N5:** `scope []` returning none is correct behavior, not a bug
