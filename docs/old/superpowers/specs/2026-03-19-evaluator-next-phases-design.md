# Kintsugi Evaluator — Next Phases Design

**Date:** 2026-03-19
**Status:** Approved
**Scope:** Parse dialect, object, error handling, stdlib, loop refinements

## Context

The evaluator has phases 1-5 complete: runtime values, contexts, core eval loop, 42 native words, user-defined functions with closures, and the loop dialect with `collect`. 208 tests pass.

This spec covers the next set of features, ordered by dependency. Lifecycle hooks, `#preprocess`, `require`, `use`, and `bind` are deferred.

## Intentional Spec Deviations

These decisions override the original script-spec.ktg where they conflict:

- `money!` removed — `$19.99` evaluates to `float!`
- `find` replaced by `has?` (logic), `index?` (integer/none), `select` (value lookup)
- `insert` takes 3 args: `insert <series> <value> <position>`
- `remove` takes 2 args: `remove <series> <position-or-key>`
- `/` always produces `float!` — use `round/down` for truncation
- `false` and `none` are the only falsy values (0 is truthy)
- No series-position return types — all lookups return scalars (targets JS/C/WASM)
- Parse uses set-word for extraction instead of `copy`/`set` keywords
- No position save/restore in parse
- No `use` or `bind` — deferred until needed

---

## 1. Parse Dialect

### Overview

One parsing system with two modes: string parsing (characters) and block parsing (values). Same combinators, same extraction syntax. The only difference is what constitutes "an element" — a character in strings, a value in blocks.

Parse returns `logic!` — `true` if rules matched the full input, `false` otherwise. Failure is silent; no diagnostics.

Parse is a native that interprets its rule block directly — it walks the block as data, not by evaluating it. Keywords like `some`, `any`, `to`, etc. are recognized by name during rule interpretation, not looked up as native words. This means the stdlib `any` (short-circuit OR) and the parse combinator `any` (0+ matches) coexist without conflict.

### Combinators (20)

| Combinator | Behavior |
|---|---|
| `\|` | Ordered alternative — try left, backtrack to right on failure. Lowest precedence: splits the entire rule at that level. Use `[...]` sub-rules to group. `[alpha \| digit "x"]` means "try `alpha`, or try `digit "x"`". |
| `end` | Match end of input |
| `skip` | Match any single element (one char or one value) |
| `some` | 1+ matches of following rule |
| `any` | 0+ matches of following rule |
| `opt` | 0 or 1 match of following rule (always succeeds) |
| `not` | Negative lookahead — fail if rule matches, don't consume |
| `ahead` | Positive lookahead — succeed if rule matches, don't consume |
| `to` | Scan forward to (not past) a match |
| `thru` | Scan forward through (past) a match |
| `into` | Descend into a nested block, parse contents with sub-rule |
| `quote` | Match next value literally (escape parse keywords in block parsing) |
| `N rule` | Repeat rule exactly N times (N is an integer literal) |
| `N M rule` | Repeat rule between N and M times (two consecutive integer literals before a non-integer rule). N must be <= M. |
| `break` | Exit enclosing `some`/`any` loop with success |
| `fail` | Force current rule to fail, trigger backtracking |
| `collect`/`keep` | `collect` wraps a rule; `keep` inside it appends matched value to collected block |
| `(...)` | Evaluate expression as side effect during parse |
| `[...]` | Sub-rule grouping |

### Block Parsing Extras

- `'word` — matches a literal word (e.g., `'name` matches the word `name`)
- `type!` — matches any value of that type (e.g., `integer!` matches `42`). Recognized by words ending in `!`.

### String Parsing Character Classes

Built-in words recognized inside parse rules when operating on strings:

- `alpha` — letters a-z, A-Z
- `digit` — 0-9
- `space` — whitespace characters
- `upper` — A-Z
- `lower` — a-z
- `alnum` — letters and digits

String literals match exactly. `"hello"` matches those 5 characters. A space in a literal matches exactly one space.

### Extraction

Set-word inside a parse rule captures what the following rule matches into the **caller's context** (the context where `parse` was called, not an internal context).

```
; String parsing — captures substring
parse "user@example.com" [
  name: some [alpha | digit | "."]
  "@"
  domain: some [alpha | digit | "." | "-"]
]
; name = "user", domain = "example.com"

; Block parsing — captures value
parse [name "Alice" age 25] [
  'name who: string!
  'age years: integer!
]
; who = "Alice", years = 25
```

### Composable Rules

Rules are blocks. Bind a block to a word, reference that word in a rule — parse looks it up in the caller's context and expands it as a sub-rule. If the word resolves to a block, that block is used as a sub-rule. If it doesn't resolve (or resolves to a non-block), parse treats it as a literal match in block mode or fails in string mode.

```
digit-run: [some digit]
date-rule: [year: digit-run "-" month: digit-run "-" day: digit-run]
parse "2026-03-15" date-rule
; year = "2026", month = "03", day = "15"
```

### collect/keep

`collect` wraps a rule section. `keep` inside it appends the matched value to a collected block. A set-word before `collect` captures the collected block into that word in the caller's context:

```
parse [1 "a" 2 "b" 3 "c"] [
  nums: collect [some [keep integer! | skip]]
]
; nums = [1 2 3]
```

### is?

Separate native, arity 2. Sugar for parse. `is? value rule` is equivalent to `parse value rule`. Returns `logic!`.

```
user~: ['name string! 'age integer! 'roles block!]
is? [name "Alice" age 25 roles ["admin"]] user~   ; true
is? [name "Alice"] user~                           ; false
```

### error

`error` takes a lit-word for the error name. This is intentionally restrictive — error names are static identifiers, not computed values. Use a different lit-word for each error case. If programmatic error names are needed in the future, a `make error!` form can be added.

### Implementation Scope

Block parsing: fully implemented.
String parsing: registered but throws "not yet implemented" for now.

---

## 2. Object

`object` is a native that takes a block, evaluates it in a new child context, and returns an `object!` value wrapping that context.

```
point: object [x: 10 y: 20]
point/x                         ; 10
point/y                         ; 20
```

Set-path assignment works:

```
point/x: 30
point/x                         ; 30
```

`object!` already exists in the value type system. The `object` native evaluates the body block in a child context and wraps the result.

No object cloning or prototypal extension in this phase. No `use` or `bind` — deferred until needed.

---

## 3. Error Handling

`try` returns a **result!** — a block with set-word/value pairs that describes the outcome of a protected call. Result is a convention, not a new runtime type — it's a `block!` with a known shape.

### Result Shape

Every result has five fields:

```
[ok: <logic!> value: <any> kind: <lit-word! | none> message: <string! | none> data: <any | none>]
```

**Success:**

```
[ok: true value: 5 kind: none message: none data: none]
```

**Failure (no data):**

```
[ok: false value: none kind: 'division-by-zero message: "cannot divide by zero" data: none]
```

**Failure (with data):**

```
[ok: false value: none kind: 'invalid-age message: "too old" data: [value: 150]]
```

**Failure (with chained error as data):**

```
[ok: false value: none kind: 'fetch-failed message: "could not load" data: [ok: false value: none kind: 'unreachable message: "host not found" data: none]]
```

Access fields via `select`:

```
result: try [something dangerous]
either select result 'ok [
  print select result 'value
] [
  print rejoin [select result 'kind ": " select result 'message]
]
```

This works because `select` scans for a matching word and returns the next value. The existing `valEq` function matches lit-words against set-words by name.

### error

Raises an error. Takes 1-3 arguments: a lit-word (error kind), optional string message, optional data (any value).

```
error 'unreachable                                          ; kind only
error 'division-by-zero "cannot divide by zero"             ; kind + message
error 'invalid-age "age cannot be negative" [value: -5]     ; kind + message + data
error 'fetch-failed "could not load" prev-result            ; data can be anything
```

Error kind is a lit-word — static identifiers, intentionally restrictive. Implemented as a native that throws `KtgError`. Registered with arity 3; `message` and `data` default to `none` when not provided.

### try

Protected call. Evaluates a block and catches any `KtgError`. Returns a result block.

```
try [10 / 2]
; => [ok: true value: 5 kind: none message: none data: none]

try [10 / 0]
; => [ok: false value: none kind: 'division-by-zero message: "cannot divide by zero" data: none]
```

### try/handle

Refinement on `try`. Takes a block and a handler function. On error, the handler receives the error kind, message, and data. Handler's return value becomes the result's `value` field.

```
result: try/handle [10 / 0] function [kind msg data] [
  print rejoin ["Caught: " msg]
  0
]
; result => [ok: false value: 0 kind: 'division-by-zero message: "cannot divide by zero" data: none]
```

---

## 4. Stdlib

Small natives that fill gaps in the current implementation.

### unless

Negated `if`. Evaluates block when condition is falsy. Returns block result or `none`.

```
unless empty? data [process data]
```

### all

Block-based short-circuit AND. Evaluates each expression in the block left to right (the block is evaluated expression by expression, not treated as inert data). Returns the last value if all truthy, otherwise returns the first falsy value.

```
ready: all [connected? loaded? valid?]
```

Implementation: `all` receives the block as inert data (arity 1), then internally evaluates each expression using `evalNext` on the block's values.

### any (stdlib function)

Block-based short-circuit OR. Same evaluation semantics as `all`. Returns the first truthy value, or `none` if all falsy.

```
connection: any [try-primary try-secondary fallback]
```

No conflict with the parse combinator `any` — parse interprets its rule block directly and never looks up `any` as a native word.

### apply

Calls a function with arguments from a block. The block's values are evaluated and passed as positional arguments.

```
apply :add [3 4]                ; 7
apply :print [42]               ; prints 42
```

### Type Predicates

One per type, registered programmatically during native setup. Each is a native that compares `val.type` directly in TypeScript (not implemented as Kintsugi functions, since `type!` equality comparison would need special handling). Returns `logic!`.

- `none?`, `integer?`, `float?`, `string?`, `logic?`, `char?`, `block?`, `function?`, `object?`, `pair?`, `tuple?`, `date?`, `time?`, `binary?`, `file?`, `url?`, `email?`, `word?`, `map?`

Implementation: loop over a list of type names, register each as `native(name + '?', 1, (args) => ({ type: 'logic!', value: args[0].type === typeName }))`.

---

## 5. Loop Refinements

The `loop` native must be updated to read its refinements (from path-based calls like `loop/fold`) and pass them to `evalLoop` in `dialect-loop.ts`. The `LoopRefinement` type already has slots for these values.

### loop/fold

Accumulator pattern. The first variable in the `for` block is the accumulator.

**First iteration:** the body is skipped. The accumulator is initialized to the first iteration value (the element or range value). Iteration continues from the second value onward.

**Subsequent iterations:** `acc` holds the previous body result.

Returns the final accumulator value.

```
total: loop/fold [for [acc n] from 1 to 10 [acc + n]]
; First iteration: acc = 1, skip body
; Second iteration: acc = 1, n = 2, body = 1 + 2 = 3
; Third iteration: acc = 3, n = 3, body = 3 + 3 = 6
; ...
; total = 55
```

### loop/partition

Splits iteration values by a predicate. The body acts as the predicate — if it returns truthy, the current iteration **value** (the loop variable, not the predicate result) goes into the first block; if falsy, into the second. Returns a block of two blocks: `[truthy-block falsy-block]`.

```
set [evens odds] loop/partition [for [x] from 1 to 8 [even? x]]
; evens = [2 4 6 8]
; odds = [1 3 5 7]
```

---

## 6. Deferred

The following are explicitly deferred to later phases:

- **Lifecycle hooks** (`@enter`, `@exit`, `@first`, `@last`) — needs solid error handling first
- **`#preprocess`** — metaprogramming on top of a not-yet-complete language
- **`require`** — needs file I/O and header parsing
- **`use`** — achievable with zero-arg functions
- **`bind`** — metaprogramming, no current need
- **String parsing implementation** — `parse` on strings is registered but stubbed
- **`attempt` dialect** — depends on error handling being stable
- **Object cloning/extension** — no `make object!` or prototypal extension yet

---

## Build Order

1. **Stdlib** — `unless`, `all`, `any`, `apply`, type predicates (no dependencies)
2. **Loop refinements** — `loop/fold`, `loop/partition` (extends existing dialect-loop.ts, wire refinements through `loop` native)
3. **Object** — `object` native (extends existing context system)
4. **Native refinement args** — add `refinementArgs` to `KtgNative` so refinements can consume extra arguments (e.g., `try/handle` takes a handler fn)
5. **Error handling** — `error`, `try`, `try/handle` (returns result! — block with `[ok: value: kind: message: data:]`)
6. **Parse dialect** — block parsing, `is?` (biggest piece, benefits from everything above being stable)
