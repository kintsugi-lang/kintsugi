# Kintsugi Language Design Audit

Audited: 2026-03-22
Codebase: ~11,000 lines TypeScript, 499 tests across 26 files

---

## What's Working Well

**The evaluation model is clean and correct.** The left-to-right, no-precedence evaluator with position-threading (`[KtgValue, number]` tuples) is a faithful implementation of the REBOL evaluation model. The infix loop (`while nextIsInfix`) is tidy. This is the right model for the language.

**The type system hits a sweet spot.** 26 concrete types + 5 unions + custom structural types with `where` guards gives enough expressiveness without becoming a type theory thesis. The single `matchesType()` checkpoint in `type-check.ts` is a genuinely good design decision — one source of truth, no drift.

**The dialect approach is architecturally sound.** Loop, match, parse, object, attempt as native-function-hosted DSLs keeps the core evaluator lean (~560 lines) while giving each dialect room to breathe. This is one of Kintsugi's real strengths over REBOL — the dialects feel less magical and more principled.

**The IR design is well-layered.** The three-tier compilation model (trivial / desugared / runtime) is a pragmatic choice that makes multi-target codegen tractable. Every IR node carrying a type means static backends (WASM) can optimize later without re-architecting.

**The module system is simple and correct.** Circular dependency detection, header-based export filtering, caching. Right for the target audience.

---

## Real Design Issues

### 1. `append` mutates blocks but returns a new string — inconsistency

`natives.ts:190-199`:
Block append mutates in place and returns the same block. String append returns a NEW string. A user writing `result: append data item` will get different semantics depending on whether `data` is a block or string. In a glue scripting language where you're constantly switching between blocks and strings, this will cause bugs.

**Recommendation:** Pick one contract. Since Kintsugi strings are immutable JS strings under the hood, either:
- (a) Make `append` always return the result and document blocks as mutated as a side effect (current behavior, but document it clearly), or
- (b) Make block `append` also return a new block for consistency with strings. Safer for a scripting language where people don't think about aliasing.

Option (b) is more appropriate for the target audience (glue scripts, game dev).

### 2. `valuesEqual` doesn't compare blocks, pairs, tuples, maps, or contexts

`evaluator.ts:597-608` — the equality function returns `false` for any two blocks, even identical ones like `[1 2 3] = [1 2 3]`. Same for pairs, tuples, maps.

For a glue scripting language this is a significant gap. People will write `if result = [1 2 3] [...]` and be confused when it's always false.

**Recommendation:** Add structural equality for blocks (recursive), pairs (`x = x and y = y`), tuples (elementwise), and maps (key/value equality). REBOL does this. Lua does this for tables via metamethods.

### 3. `try` returns a raw block with set-words — not a proper result type

`natives.ts:946-957` returns a block of unevaluated set-words and values — essentially a serialized context. To access `result/ok`, the user needs to evaluate this block into a context first, or use `select`. This is friction in an error-handling path where you want things to be simple.

**Recommendation:** Return a `context!` directly from `try` instead of a block. The user can immediately do `result/ok` and `result/value` without an extra step.

### 4. The `char!` type doesn't exist at runtime

The lexer produces `CHAR` tokens for single-character strings but `astToValue` converts them to `string!`. There's no `char!` runtime type, no `char?` predicate, no documentation.

**Recommendation:** Remove `CHAR` from the token types and just make it `STRING`. Since Kintsugi targets Lua/JS (both have no char type), dropping it is defensible and simplifies the pipeline.

### 5. `replace` only replaces the first occurrence

JavaScript's `String.replace` with a string argument only replaces the first match. For a glue scripting language, "replace all" is almost always what people want.

**Recommendation:** Use `replaceAll`. If both behaviors are needed, add a `/first` refinement for single-replacement.

### 6. Division always returns `float!` — even `10 / 2`

Integer division producing a float is surprising in a language with distinct integer and float types. `10 / 2` gives `2.0` (float!) not `2` (integer!).

**Recommendation:** Return integer when both operands are integer and the result is exact (no remainder). `10 / 3` -> float, `10 / 2` -> integer.

### 7. `round` refinements should also exist as standalone functions

`round/down` and `round/up` work in the interpreter but refinements on math functions create complexity in compiled output. Standalone `floor` and `ceil` would compile more cleanly to Lua's `math.floor`/`math.ceil`.

**Recommendation:** Add `floor` and `ceil` as standalone natives alongside `round`.

### 8. The `loop` dialect binds variables in the parent context — no scope isolation

Loop variables leak into the surrounding scope. After `loop [for [i] from 1 to 10 [...]]`, `i` is `10` in the parent scope. For game dev loops that run every frame, this creates subtle aliasing bugs when nested loops share variable names.

**Recommendation:** Consider creating a child context for each iteration. If users need the final value, they can use `loop/collect` or `loop/fold`.

### 9. No `sort`

For glue scripts, sorting is as fundamental as `append` or `split`. Without it, users implement quicksort by hand (as in `hello.ktg`). A language that has `$19.99` as a literal type but makes you write your own sort is an uncomfortable developer experience.

### 10. `valueToString` has a duplicate `case 'op!'` branch

`values.ts:221-223` — two `case 'op!'` branches. The second is dead code. TypeScript won't catch this because `switch` allows duplicate cases.

---

## Things That Look Odd But Are Fine

**No operator precedence.** Correct for the REBOL lineage. Left-to-right evaluation with parens for grouping is simpler to reason about in a homoiconic language. The evaluator is cleaner for it.

**`either` instead of `if/else`.** The right call for a language where blocks are first-class. Both branches are treated symmetrically as data.

**Braced strings `{...}`.** Works well for glue scripts constructing shell commands, SQL, HTML with embedded quotes.

**`?` and `!` in identifiers.** `length?` for predicates and `integer!` for types — unambiguous in the token stream and reads naturally.

**`on`/`off`/`yes`/`no` as word-bound logic aliases.** Clever — dialects can reclaim these words for their own keywords without collision.

**`money!` stored as cents.** Correct for game dev and avoids floating-point issues.

---

## Smaller Observations

- **`and`/`or` don't truly short-circuit.** They're registered as ops with `(l, r) =>` which means both sides are already evaluated before the op function runs. `false and (expensive-call)` evaluates the expensive call. For true short-circuit, these need special-casing in the evaluator like `all`/`any` are. This is a semantic bug.

- **`context` creates a child of `callerCtx`** — contexts inherit all bindings from the enclosing scope. If you want true isolation (game dev state objects), document that `object` is the isolated form.

- **The `#preprocess`/`#inline` split is well-designed** for the three-target model. Better than C macros.

- **The module system's global cache** is module-level singleton state. Multiple `Evaluator` instances in the same process share the cache. Fine for CLI scripting, but problematic if Kintsugi is ever embedded as a library.

---

## Priority Fixes

1. **Add `sort`** — biggest usability gap
2. **Fix `and`/`or` short-circuit** — semantic bug
3. **Add block/pair/tuple equality** — `valuesEqual` missing obvious cases
4. **Make `replace` replace all** — glue scripts need this
5. **Fix `valueToString` duplicate case** — dead code
6. **Consider integer division** — `10 / 2` should return integer when exact

