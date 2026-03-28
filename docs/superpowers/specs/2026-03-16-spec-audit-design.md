# Kintsugi Spec Audit — Core vs. Stdlib

**Date:** 2026-03-16
**Goal:** Identify the minimal set of core primitives that make Kintsugi *Kintsugi*, and push everything derivable to a stdlib written in Kintsugi itself.

**Authority:** This document overrides the existing language spec (`specs/script-spec.ktg`) wherever they conflict. The language spec will be rewritten to match these decisions.

## Design Philosophy

- **REBOL-minimal:** Words, paths, blocks-as-data, `do`, `compose`, `parse`, and binding/contexts are the DNA. They stay.
- **All four dialects are core:** `loop`, `match`, `parse`, `attempt`. They define the language's character and can't be cleanly bootstrapped from simpler pieces without losing dialect-parsing semantics.
- **Block/sequence access stays core:** These operations are so pervasive in block-heavy code that pushing them to stdlib would make the language painful before stdlib loads.
- **Stdlib must be written in Kintsugi.** If a word can't be implemented using core primitives, it belongs in core. Every stdlib candidate below has a verified implementation path.
- **Stdlib loads before user code.** The runtime guarantees that stdlib words are available when user programs execute.

## Core Primitives

### Words & Binding
`do`, `compose`, `function`, `object`, `use`, `bind`, `set`, `apply`

### Control Flow
`if`, `either`, `not`, `and`, `or`, `all`, `any`, `break`, `return`

### Operators

Arithmetic: `+`, `-`, `*`, `/`, `%`

Comparison: `=`, `<>`, `<`, `>`, `<=`, `>=`

`+` is numeric-only. String concatenation uses `join` (two values) or `rejoin` (block of values).

### Sequence Access
`first`, `second`, `third`, `last`, `pick`, `select`, `length?`, `empty?`

### Mutation
`append`, `insert`, `remove`, `copy`

### Strings
`join`, `rejoin`, `find` (strings only — block `find` is stdlib), `split`, `trim`

`rejoin` reduces a block and joins all values into a string (no spaces). It is the primary interpolation mechanism, replacing f-strings. Requires reduce semantics, so it must be core.

### Types
`typeset`, `type?`, `to`, `is?`

`to` handles all explicit conversions including `char! <-> integer!` (required for stdlib to implement `uppercase`/`lowercase`).

### Errors
`error`, `try`, `try/handle`

These are the low-level error primitives. `attempt` is the high-level dialect built on top.

### I/O & Debug
`print`, `probe`, `require`, `open`

### Maps
`make map!`

### Dialects

**Loop** — `for`, `in`, `from`, `to`, `by`, `when`, `it`, plus refinements `loop/collect`, `loop/fold`, `loop/partition`.

`by` semantics:
- Takes a positive or negative step value (e.g., `by 5`, `by -3`).
- Default step: `1` when `from <= to`, `-1` when `from > to`.
- Error if `by` contradicts direction (e.g., `from 1 to 10 by -2`).
- `from N to N` is one iteration (the value N).

**Match** — literal matching, `_` wildcard, bare-word capture, `(expr)` evaluation, `'word` lit-matching, `when` guards, `default:` fallback.

**Attempt** — `source`, `then`, `when`, `on`, `retries`, `delay`, `fallback`. No-source form returns a reusable `function!`.

`when` semantics in attempt: evaluates a condition against `it` (the current pipeline value). If truthy, the value passes through. If falsy, the pipeline short-circuits and returns `none`. This parallels loop's `when` (guard/filter) but applies to a single value rather than iterations.

Migration from removed keywords:
- `map [expr]` → `then [expr]` (identical — both transform `it`)
- `filter [cond]` → `when [cond]` (drops pipeline if falsy)
- `fold` → use `loop/fold` instead (data transformation belongs in loop)
- `limit` → use `loop` with a counter or `break` (iteration control belongs in loop)

**Parse** — `some`, `any`, `opt`, `copy`, `to`, `thru`, `not`, `ahead`, `end`, `skip`, `|`.

Note: `to` is context-dependent — it means "advance to" inside parse rules, "counting end" inside loop, and "type conversion" as a standalone word.

### Preprocessing
`#preprocess`, `platform`, `emit`, `require`, `target`

### Lifecycle Hooks
`@enter`, `@exit`, `@first`, `@last`

## Stdlib (written in Kintsugi)

Each word below has a verified implementation path using core primitives.

| Word | Implementation sketch |
|---|---|
| `unless` | `function [cond body] [if not cond body]` |
| `min` | `function [a b] [either a < b [a] [b]]` |
| `max` | `function [a b] [either a > b [a] [b]]` |
| `abs` | `function [x] [either x < 0 [0 - x] [x]]` |
| `negate` | `function [x] [0 - x]` |
| `odd?` | `function [x] [(x % 2) = 1]` |
| `even?` | `function [x] [(x % 2) = 0]` |
| `reverse` | Loop counting down + `pick` + `append` into new block |
| `replace` | `find` + `remove` + `insert` |
| `uppercase` | Char-code arithmetic via `to integer!` / `to char!` |
| `lowercase` | Char-code arithmetic via `to integer!` / `to char!` |
| ~~`rejoin`~~ | ~~Promoted to core — requires reduce semantics~~ |
| `form` | `to string!` + `join` |
| `reform` | `to string!` + `join` with spaces |
| `find` (on blocks) | `loop` + comparison |
| `range` | `loop/collect [from start to end]` |
| `integer?` | `function [x] [(type? x) = integer!]` |
| `float?` | `function [x] [(type? x) = float!]` |
| `string?` | `function [x] [(type? x) = string!]` |
| `number?` | `function [x] [(type? x) = number!]` (typeset check) |
| `logic?` | `function [x] [(type? x) = logic!]` |
| `char?` | `function [x] [(type? x) = char!]` |
| `block?` | `function [x] [(type? x) = block!]` |
| `function?` | `function [x] [(type? x) = function!]` |
| `none?` | `function [x] [(type? x) = none!]` |
| `iterable?` | `function [x] [(type? x) = iterable!]` (typeset check) |

## Changes to Existing Spec

### Cut entirely
- **None propagation** — Operations on `none` with mismatched types raise a type error (`Expected number!, got none!`). No silent propagation.
- **`+` for string concatenation** — `+` is numeric-only. Use `join` or `rejoin`. All spec examples using `"str" + value` have been rewritten.
- **F-strings** — Cut. `rejoin` with blocks serves the same purpose and keeps interpolation within the existing block/evaluation model.

### Dialect changes
- **Loop:** `ascending`, `descending`, `ascending/by`, `descending/by` replaced by a single `by` keyword. See Loop dialect section above for full semantics.
- **Attempt:** `map`, `filter`, `fold`, `limit` removed. `filter` replaced by `when`. See Attempt dialect section above for migration paths. Attempt is an error-handling dialect, not a data-transformation dialect. Loop handles the data side.

### Added explicitly
- **`do`** — Evaluate a block as code. Was used throughout the spec but never given its own entry.
- **`function`** — The function constructor. Was used throughout but not listed as a core primitive.
- **`apply`** — Call a function with a block of arguments.
- **`open`** — Create a port from a URL. Required for I/O.
- **Operators** — Arithmetic and comparison operators listed explicitly as core.
