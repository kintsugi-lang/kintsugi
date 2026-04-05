# Kintsugi Language Specification — Open Questions

Every question in this document must be answered with a **rule** before the rewrite begins. Rules come first, examples verify them. If you can't state the rule, write `UNDECIDED` and move on — honest gaps are better than ambiguous examples.

---

## 1. Evaluation Order

Left to right, no precedence, functions consume N args greedily. But:

### 1.1 Per-type evaluation rules

What happens when the evaluator encounters each value type?

| Value Type   | Evaluation Rule                                                                                       |
|--------------|-------------------------------------------------------------------------------------------------------|
| `integer!`   | Returns self                                                                                          |
| `float!`     | Returns self                                                                                          |
| `string!`    | Returns self                                                                                          |
| `logic!`     | Returns self                                                                                          |
| `none!`      | Returns self                                                                                          |
| `money!`     | Returns self                                                                                          |
| `pair!`      | Returns self                                                                                          |
| `tuple!`     | Returns self                                                                                          |
| `date!`      | Returns self                                                                                          |
| `time!`      | Returns self                                                                                          |
| `file!`      | Returns self                                                                                          |
| `url!`       | Returns self                                                                                          |
| `email!`     | Returns self                                                                                          |
| `block!`     | Returns self (unevaluated)                                                                            |
| `paren!`     | Evaluates contents, returns last value                                                                |
| `word!`      | Looks up in context. If result is callable, calls it (consuming N args). Otherwise returns the value. |
| `set-word!`  | Evaluates RHS (with infix), binds result in current scope. Returns the value.                         |
| `get-word!`  | Returns bound value without calling, even if callable.                                                |
| `lit-word!`  | Returns the word as a symbol value.                                                                   |
| `meta-word!` | Depends on context but usually does something magical/behind-the-scenes                               |
| `path!`      | Evaluates head, navigates segments. If final value is callable, calls it.                             |
| `set-path!`  | Evaluates RHS, assigns through path.                                                                  |
| `get-path!`  | Returns value at path without calling.                                                                |
| `lit-path!`  | Returns the path as data.                                                                             |
| `op!`        | Errors if bare or no valid operands                                                                   |
| `map!`       | Returns self                                                                                          |
| `context!`   | Returns self                                                                                          |
| `function!`  | Returns a plain callable, uncalled                                                                    |
| `native!`    | Not sure when you'd see this.                                                                         |
| `type!`      | Returns self                                                                                          |

### 1.2 Infix resolution

- Which words are treated as infix? `+`, `-`, `*`, `/`, `%`, `=`, `<>`, `<`, `>`, `<=`, `>=`, `and`, `or` — is that exhaustive? **More or less.**
- Can users define new infix words? **No.**
- After evaluating a value, when does the evaluator check for infix? Always? Only for certain types? **Only for op!**

### 1.3 Function call mechanics

- A function with arity N always consumes exactly N values from the stream. No exceptions. **Confirmed.**
- When consuming arguments, are those arguments themselves evaluated (including their own infix)? Or just the next atom? **Arguments are evaluated in order, including infix**
- What happens when there aren't enough values left in the block? Error immediately, or only at block end? **Errors out**

---

## 2. Scope Boundaries & The Unified Context Model

### 2.0 Core insight: contexts are everything

**DECIDED:** Contexts are the universal construct. Closures, objects, modules, and scopes are all contexts. A function closing over variables is just a function whose words are bound to an enclosing context. There is no separate closure mechanism.

This means:
- A function is a block + a context it evaluates in
- A closure is a function whose context has a parent context
- A module is a context returned by `load/eval`
- An object method is a function whose context includes `self`
- `words-of` works on any of these — they're all contexts

### 2.1 Context vs Object — the mutability split

**DECIDED:** Mutability is determined by type, not by annotation.

| Type       | Mutable? | Use case                                               |
|------------|----------|--------------------------------------------------------|
| `context!` | Yes      | Instances, state, scopes, closures, working data       |
| `object!`  | No       | Prototypes, modules, type definitions, shared behavior |

Rules:
- `context [...]` creates a mutable `context!`
- `object [...]` creates an immutable `object!` (prototype)
- `make Prototype [...]` returns a mutable `context!` (instance)
- `load/eval` returns an immutable `object!` (module)
- Mutation of an `object!` is an error (loud, not silent)
- `freeze ctx` upgrades a `context!` to an `object!` (one-way)
- `freeze/deep ctx` does so recursively
- `frozen? val` predicate returns true for `object!` values

Assignment is **by reference** for both types. `a: b` does not copy for non-scalar types. Use `copy` for an independent copy.

### 2.2 Scope table

Which constructs create a new child scope?

| Construct                | New Scope? | Sees Parent? | Can Mutate Parent? |
|--------------------------|------------|--------------|--------------------|
| `function` body          | x          | x            |                    |
| `context [...]`          | x          | x            |                    |
| `loop` body              | x          | x            |                    |
| `if` / `either` branches |            | x            | x                  |
| `match` handler blocks   | x          | x            |                    |
| `attempt` steps          | x          | x            | x (indirectly)     |
| `do` of a block          | x          | x            | x                  |
| `parse` handler blocks   | x          | x            |                    |
| Object method bodies     |            | x            | x                  |
| `@enter` / `@exit` hooks | x          | x            | x                  |

### 2.3 Variable binding

**DECIDED:** Set-word **always shadows.** It creates a new binding in the current scope. No write-through. No `persist`/`global` keyword. No exceptions.

To mutate shared state, use a context and set-path:
```
state: context [counter: 0]
loop [from 1 to 10 [
  state/counter: state/counter + 1   ; mutates context through reference
]]
print state/counter                    ; 10
```

This works because contexts are shared by reference (section 3.0) and set-path mutates the referenced context. No new mechanism needed — the object model already handles this.

Closures capture by **reference** (they hold a reference to the enclosing context, not a copy of its values). A closure can read parent-scope variables through the context chain. It cannot rebind them via set-word — only mutate contexts via set-path.

---

## 3. Mutation Rules

### 3.0 Core rule

**DECIDED:** Assignment is by reference. All compound values (blocks, maps, contexts) are shared, not copied. This matches Lua's table semantics (the compilation target).

```
a: [1 2 3]
b: a
append b 4
; a is now [1 2 3 4] — same block, shared reference
```

`copy` creates an independent value. This is explicit, never automatic.

### 3.1 Mutability by type

**DECIDED:**
- `context!` — mutable. Set-path works, field mutation works.
- `object!` — immutable. Mutation attempts are errors.
- `block!` — mutable (`append`, `insert`, `remove` mutate in place).
- `string!` — immutable. String operations return new strings.
- `map!` — mutable (add/remove keys).
- All scalar types — immutable by nature (values, not containers).

### 3.2 Mutable operations

| Operation                                 | Mutates in place?                     | Returns what? |
|-------------------------------------------|---------------------------------------|---------------|
| `append block value`                      | x                                     | block!        |
| `append string value`                     | ERROR — strings are immutable         | error!        |
| `insert block value pos`                  | x                                     | block!        |
| `remove block pos`                        | x                                     | block!        |
| `set-path! (ctx/field: val)`              | Yes on `context!`, ERROR on `object!` | type-of val   |
| `sort block`                              | x                                     | none!         |
| String operations (trim, uppercase, etc.) | No — return new strings               | string!       |

### 3.3 Copy semantics

- `copy` is shallow or deep? **shallow**
- Is there a `copy/deep`? **there should be**
- What gets copied for each type? Blocks copy the value array. Maps copy entries. Contexts copy bindings. Functions — can they be copied? **I would imagine they need to be copied to be a copy**
- Does `copy` of an `object!` produce a `context!` (mutable copy) or another `object!` (immutable copy)? **context!**

---

## 4. Type Conversion Matrix

Every conversion is either a rule or `ERROR`. No gaps. Grouped by source type for readability.

### 4.1 Resolved ambiguities

- `to integer! 3.7` → **3** (truncate toward zero)
- `to integer! "3.7"` → **3** (parse then truncate)
- `to string! [1 2 3]` → **"123"** (rejoin, no separator)
- `to block! "hello"` → **["hello"]** (wrap, not split into chars)
- `to logic! 0` → **ERROR** (numbers and logic are different domains — use `either` or comparison)
- `to money! 42` → **$42.00** (dollars, not cents)

### 4.2 Full conversion matrix

**From `integer!`:**

| Target     | Rule                                            |
|------------|-------------------------------------------------|
| `integer!` | identity                                        |
| `float!`   | widen: `42` → `42.0`                            |
| `string!`  | decimal: `42` → `"42"`                          |
| `logic!`   | ERROR — numbers and logic are different domains |
| `block!`   | wrap: `42` → `[42]`                             |
| `money!`   | dollars: `42` → `$42.00` (4200 cents)           |
| `pair!`    | ERROR                                           |
| `tuple!`   | ERROR                                           |
| `date!`    | ERROR                                           |
| `time!`    | seconds: `90` → `00:01:30`                      |
| `word!`    | ERROR                                           |
| `file!`    | ERROR                                           |
| `url!`     | ERROR                                           |
| `email!`   | ERROR                                           |
| `map!`     | ERROR                                           |

**From `float!`:**

| Target     | Rule                                                        |
|------------|-------------------------------------------------------------|
| `integer!` | truncate toward zero: `3.7` → `3`, `-2.9` → `-2`            |
| `float!`   | identity                                                    |
| `string!`  | decimal: `3.14` → `"3.14"`                                  |
| `logic!`   | ERROR — numbers and logic are different domains             |
| `block!`   | wrap: `3.14` → `[3.14]`                                     |
| `money!`   | dollars and cents: `19.99` → `$19.99` (1999 cents)          |
| `pair!`    | ERROR                                                       |
| `tuple!`   | ERROR                                                       |
| `date!`    | ERROR                                                       |
| `time!`    | seconds: `90.5` → `00:01:30` (fractional seconds truncated) |
| `word!`    | ERROR                                                       |
| `file!`    | ERROR                                                       |
| `url!`     | ERROR                                                       |
| `email!`   | ERROR                                                       |
| `map!`     | ERROR                                                       |

**From `string!`:**

| Target     | Rule                                                                       |
|------------|----------------------------------------------------------------------------|
| `integer!` | parse: `"42"` → `42`, `"3.7"` → `3` (parse then truncate), `"abc"` → ERROR |
| `float!`   | parse: `"3.14"` → `3.14`, `"abc"` → ERROR                                  |
| `string!`  | identity                                                                   |
| `logic!`   | `"true"` → `true`, `"false"` → `false`, else ERROR                         |
| `block!`   | wrap: `"hello"` → `["hello"]`                                              |
| `money!`   | parse: `"19.99"` → `$19.99`, `"abc"` → ERROR                               |
| `pair!`    | parse: `"100x200"` → `100x200`, malformed → ERROR                          |
| `tuple!`   | parse: `"1.2.3"` → `1.2.3`, malformed → ERROR                              |
| `date!`    | parse: `"2026-03-15"` → `2026-03-15`, malformed → ERROR                    |
| `time!`    | parse: `"14:30:00"` → `14:30:00`, malformed → ERROR                        |
| `word!`    | create: `"hello"` → `hello` (word value)                                   |
| `file!`    | create: `"path/to/file"` → `%path/to/file`                                 |
| `url!`     | create: `"https://example.com"` → `https://example.com`                    |
| `email!`   | create: `"user@example.com"` → `user@example.com`                          |
| `map!`     | ERROR                                                                      |

**From `logic!`:**

| Target     | Rule                                            |
|------------|-------------------------------------------------|
| `integer!` | ERROR — logic and numbers are different domains |
| `float!`   | ERROR — logic and numbers are different domains |
| `string!`  | `true` → `"true"`, `false` → `"false"`          |
| `logic!`   | identity                                        |
| `block!`   | wrap: `true` → `[true]`                         |
| `money!`   | ERROR                                           |
| `pair!`    | ERROR                                           |
| `tuple!`   | ERROR                                           |
| `date!`    | ERROR                                           |
| `time!`    | ERROR                                           |
| `word!`    | ERROR                                           |
| `file!`    | ERROR                                           |
| `url!`     | ERROR                                           |
| `email!`   | ERROR                                           |
| `map!`     | ERROR                                           |

**From `none!`:**

| Target     | Rule     |
|------------|----------|
| `integer!` | ERROR    |
| `float!`   | ERROR    |
| `string!`  | `"none"` |
| `logic!`   | `false`  |
| `block!`   | ERROR    |
| `money!`   | ERROR    |
| `pair!`    | ERROR    |
| `tuple!`   | ERROR    |
| `date!`    | ERROR    |
| `time!`    | ERROR    |
| `word!`    | ERROR    |
| `file!`    | ERROR    |
| `url!`     | ERROR    |
| `email!`   | ERROR    |
| `map!`     | ERROR    |

**From `block!`:**

| Target     | Rule                                                |
|------------|-----------------------------------------------------|
| `integer!` | ERROR                                               |
| `float!`   | ERROR                                               |
| `string!`  | rejoin elements (no separator): `[1 2 3]` → `"123"` |
| `logic!`   | ERROR                                               |
| `block!`   | identity                                            |
| `money!`   | ERROR                                               |
| `pair!`    | 2 integers: `[10 20]` → `10x20`, else ERROR         |
| `tuple!`   | N integers: `[1 2 3]` → `1.2.3`, else ERROR         |
| `date!`    | ERROR                                               |
| `time!`    | ERROR                                               |
| `word!`    | ERROR                                               |
| `file!`    | ERROR                                               |
| `url!`     | ERROR                                               |
| `email!`   | ERROR                                               |
| `map!`     | key-value pairs: `[a: 1 b: 2]` → map with a=1, b=2  |

**From `money!`:**

| Target     | Rule                             |
|------------|----------------------------------|
| `integer!` | cents: `$19.99` → `1999`         |
| `float!`   | dollars: `$19.99` → `19.99`      |
| `string!`  | formatted: `$19.99` → `"$19.99"` |
| `logic!`   | ERROR                            |
| `block!`   | wrap: `$19.99` → `[$19.99]`      |
| `money!`   | identity                         |
| `pair!`    | ERROR                            |
| `tuple!`   | ERROR                            |
| `date!`    | ERROR                            |
| `time!`    | ERROR                            |
| `word!`    | ERROR                            |
| `file!`    | ERROR                            |
| `url!`     | ERROR                            |
| `email!`   | ERROR                            |
| `map!`     | ERROR                            |

**From `pair!`:**

| Target     | Rule                               |
|------------|------------------------------------|
| `integer!` | ERROR                              |
| `float!`   | ERROR                              |
| `string!`  | formatted: `100x200` → `"100x200"` |
| `logic!`   | ERROR                              |
| `block!`   | decompose: `100x200` → `[100 200]` |
| `money!`   | ERROR                              |
| `pair!`    | identity                           |
| `tuple!`   | ERROR                              |
| `date!`    | ERROR                              |
| `time!`    | ERROR                              |
| `word!`    | ERROR                              |
| `file!`    | ERROR                              |
| `url!`     | ERROR                              |
| `email!`   | ERROR                              |
| `map!`     | ERROR                              |

**From `tuple!`:**

| Target     | Rule                                  |
|------------|---------------------------------------|
| `integer!` | ERROR                                 |
| `float!`   | ERROR                                 |
| `string!`  | formatted: `1.2.3` → `"1.2.3"`        |
| `logic!`   | ERROR                                 |
| `block!`   | decompose: `1.2.3` → `[1 2 3]`        |
| `money!`   | ERROR                                 |
| `pair!`    | ERROR (tuples can have != 2 elements) |
| `tuple!`   | identity                              |
| `date!`    | ERROR                                 |
| `time!`    | ERROR                                 |
| `word!`    | ERROR                                 |
| `file!`    | ERROR                                 |
| `url!`     | ERROR                                 |
| `email!`   | ERROR                                 |
| `map!`     | ERROR                                 |

**From `date!`:**

| Target     | Rule                                              |
|------------|---------------------------------------------------|
| `integer!` | ERROR — Use a function like `date/epoch` instead. |
| `float!`   | ERROR                                             |
| `string!`  | ISO format: `2026-03-15` → `"2026-03-15"`         |
| `logic!`   | ERROR                                             |
| `block!`   | decompose: `2026-03-15` → `[2026 3 15]`           |
| `money!`   | ERROR                                             |
| `pair!`    | ERROR                                             |
| `tuple!`   | ERROR                                             |
| `date!`    | identity                                          |
| `time!`    | ERROR                                             |
| `word!`    | ERROR                                             |
| `file!`    | ERROR                                             |
| `url!`     | ERROR                                             |
| `email!`   | ERROR                                             |
| `map!`     | ERROR                                             |

**From `time!`:**

| Target     | Rule                                  |
|------------|---------------------------------------|
| `integer!` | total seconds: `14:30:00` → `52200`   |
| `float!`   | total seconds: `14:30:00` → `52200.0` |
| `string!`  | formatted: `14:30:00` → `"14:30:00"`  |
| `logic!`   | ERROR                                 |
| `block!`   | decompose: `14:30:00` → `[14 30 0]`   |
| `money!`   | ERROR                                 |
| `pair!`    | ERROR                                 |
| `tuple!`   | ERROR                                 |
| `date!`    | ERROR                                 |
| `time!`    | identity                              |
| `word!`    | ERROR                                 |
| `file!`    | ERROR                                 |
| `url!`     | ERROR                                 |
| `email!`   | ERROR                                 |
| `map!`     | ERROR                                 |

**From `word!` (and all word subtypes):**

| Target     | Rule                                                         |
|------------|--------------------------------------------------------------|
| `integer!` | ERROR                                                        |
| `float!`   | ERROR                                                        |
| `string!`  | name: `'hello` → `"hello"`                                   |
| `logic!`   | ERROR                                                        |
| `block!`   | wrap: `'hello` → `['hello]`                                  |
| `money!`   | ERROR                                                        |
| `pair!`    | ERROR                                                        |
| `tuple!`   | ERROR                                                        |
| `date!`    | ERROR                                                        |
| `time!`    | ERROR                                                        |
| `word!`    | convert subtype: `to set-word! 'hello` → `hello:` (set-word) |
| `file!`    | ERROR                                                        |
| `url!`     | ERROR                                                        |
| `email!`   | ERROR                                                        |
| `map!`     | ERROR                                                        |

Note: `to word! "x"`, `to set-word! "x"`, `to get-word! "x"`, `to lit-word! "x"`, `to meta-word! "x"` all create the appropriate word subtype from a string. Word-to-word subtype conversion also works: `to set-word! 'hello` produces a set-word with name "hello".

**From `file!`, `url!`, `email!`:**

| Target     | Rule                                                                                              |
|------------|---------------------------------------------------------------------------------------------------|
| `string!`  | extract text: `%path/to/file` → `"path/to/file"`, `https://example.com` → `"https://example.com"` |
| `block!`   | wrap                                                                                              |
| All others | ERROR                                                                                             |

These are text-resource types. They convert to string (extract the text content) and nothing else.

**From `map!`:**

| Target     | Rule                                             |
|------------|--------------------------------------------------|
| `block!`   | flatten: map with a=1, b=2 → `[a: 1 b: 2]`       |
| `string!`  | ERROR (use a function if you need serialization) |
| All others | ERROR                                            |

**From `context!`:**

| Target     | Rule                                               |
|------------|----------------------------------------------------|
| `block!`   | save serializable data fields and return as block! |
| `map!`     | save serializable data fields and return as map!   |
| `object!`  | freeze: one-way upgrade, same as `freeze ctx`      |
| All others | ERROR                                              |

**From `object!`:**

| Target     | Rule                                                       |
|------------|------------------------------------------------------------|
| `context!` | mutable copy: same as `copy obj` (returns mutable context) |
| All others | same as `context!` above                                   |

**From `function!` / `native!`:**

| Target | Rule                                  |
|--------|---------------------------------------|
| All    | ERROR — functions are not convertible |

### 4.3 Design notes

- **`to` never coerces silently.** Every conversion is explicit. If it can fail (string parsing), it throws a `'type` error.
- **Numbers and logic don't cross.** `to integer! true` is ERROR. `to logic! 0` is ERROR. These are different domains. If you need 0/1 from a boolean, use `either flag [1] [0]`. If you need a boolean from a number, use a comparison: `n > 0`. The only exception: `to logic! none` → `false` (none is absence, and absence is falsy) and `to string!` works on everything for display.
- **`to block!` wraps by default.** `to block! x` → `[x]` for most types. Pair/tuple decompose because they have natural element structure. Maps flatten because they have natural key-value structure.
- **`to string!` on blocks uses rejoin (no separator).** `[1 2 3]` → `"123"`. If you want spaces, use `rejoin` with explicit spacing or `join`.
- **`to integer!` on money returns cents.** `$19.99` → `1999`. This preserves precision. `to float!` returns dollars (`19.99`) for display convenience but loses the exact-arithmetic guarantee.
- **`to integer!` on time returns total seconds.** `14:30:00` → `52200`. Reversible: `to time! 52200` → `14:30:00`.
- **Date-to-integer is UNDECIDED.** Epoch representations are ambiguous (epoch days? Unix timestamp? Julian?). Prefer explicit functions (`date/epoch`, `date/julian`) over `to`.

### 4.4 Literal validation rules

**DECIDED:** The lexer validates literal values at parse time. Malformed literals are `'syntax` errors, not silently wrong values.

| Literal type | Validation |
|--------------|------------|
| `pair!` (`NxN`) | Both components must be valid integers within int32 range |
| `tuple!` (`N.N.N`) | Each component must be 0-255 |
| `date!` (`YYYY-MM-DD`) | Month 1-12, day 1-31, no empty components |
| `time!` (`HH:MM:SS`) | Empty components default to 0 (e.g., `14:30` = `14:30:00`) |
| `money!` (`$N.NN`) | Must have at least one digit (not `$.` or `$`) |

**Parser limits:** Maximum nesting depth of 256 for blocks and parens. Exceeding this is a `'parse` error.

---

## 5. Equality Semantics

**One function. One set of rules. No special cases.**

### 5.0 Equality rules

1. **Numeric equality is cross-type.** `integer!` and `float!` compare by numeric value. `42 = 42.0` is true.
2. **Money is its own domain.** `$42.00 = 42` is false. Money and numbers don't cross — same principle as logic/number separation. Compare money to money.
3. **Value types compare structurally, deep recursive.** Blocks, pairs, tuples — compared element by element, recursively. `[1 [2 3]] = [1 [2 3]]` is true.
4. **Maps compare structurally, order-independent.** Same keys with same values = equal, regardless of insertion order.
5. **Contexts compare structurally.** Same field names with same values = equal. This means two independently created contexts with identical fields are equal.
6. **Strings are case-sensitive.** `"abc" = "ABC"` is false.
7. **Words are case-insensitive, same-subtype only.** `'hello = 'Hello` is true (both lit-words, same name). `'hello = first [hello]` is false (lit-word vs word — different subtypes). Matching REBOL: word subtypes are different types with different evaluation behavior. Equal things should behave the same. To compare names across subtypes, convert to string: `(to string! a) = (to string! b)`. Note: `first [hello]` returns a `word!` as-is from the block — extraction doesn't change types.
8. **Functions compare by identity.** Same function reference = equal. Two functions with identical bodies are NOT equal — identity, not structure.
9. **None equals only none.** `none = none` is true. `none = false` is false. None is absence, false is a value.
10. **Cross-type comparisons are false.** If types don't match and no rule above applies, `=` returns false. Never an error.

| Comparison                   | Result | Rule                                           |
|------------------------------|--------|------------------------------------------------|
| `42 = 42.0`                  | true   | Numeric cross-type (rule 1)                    |
| `$42.00 = 42`                | false  | Money is its own domain (rule 2)               |
| `[1 2] = [1 2]`              | true   | Deep structural (rule 3)                       |
| `[1 [2 3]] = [1 [2 3]]`      | true   | Deep structural recursive (rule 3)             |
| `none = none`                | true   | None equals none (rule 9)                      |
| `none = false`               | false  | None is not false (rule 9)                     |
| `'hello = 'Hello`            | true   | Words case-insensitive (rule 7)                |
| `'hello = first [hello]`     | false  | lit-word vs word — different subtypes (rule 7) |
| `100x200 = 100x200`          | true   | Pair structural (rule 3)                       |
| `1.2.3 = 1.2.3`              | true   | Tuple structural (rule 3)                      |
| Map with same keys/values    | true   | Map structural, order-independent (rule 4)     |
| Context with same fields     | true   | Context structural (rule 5)                    |
| Two references to same block | true   | Same reference, trivially structural (rule 3)  |
| Function = same function     | true   | Identity (rule 8)                              |
| `"abc" = "ABC"`              | false  | Strings case-sensitive (rule 6)                |

### 5.1 Inequality and ordering

**`<>` is always `not =`.** No exceptions. No type where neither `=` nor `<>` is true.

**`<` is defined only for ordered types:**
- `integer!`, `float!` — numeric ordering (cross-type: `3 < 4.5` works)
- `money!` — by cent value
- `string!` — lexicographic, case-sensitive
- `date!` — chronological
- `time!` — chronological

Using `<` on unordered types (blocks, contexts, functions, etc.) is an ERROR. You can check equality on anything, but ordering requires an ordered type.

---

## 6. Truthiness

Rule: **only `false` and `none` are falsy. Everything else is truthy.**

Confirm or change each:

| Value         | Truthy? |
|---------------|---------|
| `0`           | true    |
| `0.0`         | true    |
| `""`          | true    |
| `[]`          | true    |
| `$0.00`       | true    |
| `0x0`         | true    |
| `00:00:00`    | true    |
| Empty map     | true    |
| Empty context | true    |

If all of these are truthy, state that explicitly and own it. If any should be falsy, change the rule.

---

## 7. Error Taxonomy

### 7.1 Standard error kinds

Error kinds are lit-words. Users can define their own kinds via `error`. The standard kinds are:

| Kind         | Triggered by                                                                    | Message format                                                                              | Data contains                 |
|--------------|---------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|
| `'type`      | Wrong type passed to function, set-path on `object!`, type constraint violation | `"expected integer!, got string!"` or `"param 'x' expects integer!, got string!"`           | The offending value           |
| `'arity`     | Too few values left in block for function to consume                            | `"add expects 2 arguments, got 1"`                                                          | none                          |
| `'undefined` | Word lookup fails — name has no binding in scope chain                          | `"hello has no value"`                                                                      | The word as a lit-word        |
| `'math`      | Division by zero, modulo by zero, money overflow, invalid arithmetic            | `"division by zero"`, `"modulo by zero"`, `"money overflow"`                                | none                          |
| `'range`     | Index out of bounds on `pick`, `insert`, `remove`                               | `"index 6 out of range for block of length 5"`                                              | The index as integer          |
| `'syntax`    | Malformed literal in lexer (bad pair, tuple overflow, invalid date/time/money)   | `"invalid pair literal: 100xx200"`, `"month out of range (1-12): 13"`                       | none                          |
| `'parse`     | Parse dialect fails to match, malformed rules, nesting depth exceeded            | `"parse failed at position 12"`, `"Maximum nesting depth (256) exceeded"`                   | The remaining unmatched input |
| `'loop`      | Invalid loop parameters (zero step)                                             | `"loop step cannot be zero"`                                                                | none                          |
| `'attempt`   | Invalid attempt configuration (negative retries)                                | `"retries must be non-negative"`                                                            | none                          |
| `'load`      | File not found, circular dependency, malformed header                           | `"file not found: %lib/missing.ktg"` or `"circular dependency: %a.ktg -> %b.ktg -> %a.ktg"` | The file path                 |
| `'frozen`    | Attempt to mutate an `object!` (frozen context)                                 | `"cannot mutate frozen object"`                                                             | The object                    |
| `'make`      | Required field missing in `make`, invalid override type                         | `"required field 'name' not provided"`                                                      | The prototype                 |
| `'self`      | Attempt to rebind `self` inside a method                                        | `"cannot rebind self"`                                                                      | none                          |
| `'name-collision` | `object` auto-generation would overwrite existing word                     | `"person! already exists"`                                                                  | The existing value            |
| `'user`      | Raised explicitly by user code via `error`                                      | User-provided                                                                               | User-provided                 |

Additional kinds may be added for specific domains (e.g., `'io` for file read/write failures, `'format` for string-to-value parsing failures in `to`). User code can raise any lit-word as a kind — the list above is the standard set, not a closed enum.

### 7.2 Error structure

**DECIDED:** `try` returns a `context!` with path access. Contexts are the universal construct — errors are no exception.

**On success:**
```
result: try [10 + 5]
result/ok        ; true
result/value     ; 15
result/kind      ; none
result/message   ; none
result/data      ; none
```

**On failure:**
```
result: try [10 / 0]
result/ok        ; false
result/value     ; none
result/kind      ; 'math
result/message   ; "division by zero"
result/data      ; none
```

The result context always has the same five fields: `ok`, `value`, `kind`, `message`, `data`. This makes it predictable — you can always check `result/ok` without worrying about which fields exist.

**`try/handle` — handler receives the error context:**
```
result: try/handle [10 / 0] function [err] [
  ; err is a context with kind, message, data
  print rejoin ["Caught: " err/message]
  0    ; recovery value
]
result/ok       ; true (handler recovered)
result/value    ; 0
```

When a handler is provided and the body fails, the handler receives an error context (with `kind`, `message`, `data` fields). If the handler returns a value, `try` wraps it as a success result. If the handler itself throws, `try` returns that as a failure.

**Raising errors:**
```
error 'user "something went wrong" none
error 'validation "email is invalid" bad-email
```

`error` takes three args: kind (lit-word), message (string or none), data (any or none). Always throws — never returns.

### 7.3 Stack traces

**DECIDED:** Errors carry both source location and a call stack.

Each stack frame records:
- **Context name** (function name, object name, or `<anonymous>`)
- **File path** (if loaded via `load/eval`, otherwise `<repl>` or `<input>`)
- **Line number** (from the lexer — tokens carry line info)

**Truncation:** Last 5 frames only. Deep stacks show the most recent context, not the full history.

**Preprocess errors** are distinguished from runtime errors with a header label.

Formatted output:

```
======== RUNTIME ERROR ========
division by zero @ %examples/game.ktg#L12
    in safe-divide @ %examples/game.ktg#L10
    in update @ %examples/game.ktg#L45
    in Enemy/on-hit @ %examples/game.ktg#L30
    in <top-level> @ %examples/game.ktg#L80
```

```
======== PREPROCESS ERROR ========
platform-name has no value @ %examples/game.ktg#L5
    in #preprocess @ %examples/game.ktg#L3
```

Notes:
- The header (`RUNTIME ERROR` / `PREPROCESS ERROR`) distinguishes the phase.
- The message line shows the error message, file, and line where it occurred.
- Stack frames show `in <context-name> @ <file>#L<line>` — tracing back through the scope chain.
- "in" prefix because each frame is a context the error passed through — functions, methods, top-level.

---

## 8. Dialect Protocol

If dialects are the architecture, they need a formal contract.

### 8.0 Core insight: a dialect is a scoped vocabulary

**DECIDED:** A dialect is not a function that hand-parses a block. A dialect is a **scoped context that changes what words mean.** Entering a dialect block means "I'm working in this vocabulary now." Leaving it means words go back to normal.

```
entity [...]  ; "I'm describing a game object now"
scene [...]   ; "I'm placing things in a world now"
parse [...]   ; "I'm matching patterns now"
config [...]  ; "I'm declaring settings now"
```

This is more powerful than `with`/`using` statements from other languages — those operate within the host language's semantics. A dialect **changes the semantics of the block.** The words inside mean different things. Not scoped resource management — scoped *language*.

The compiler is itself a dialect — a Kintsugi program that reads Kintsugi blocks and emits Lua. Output backends are dialects. This is the homoiconic payoff: dialects describing themselves to other dialects.

### 8.1 Vocabulary and scope

- How does a dialect declare the words it claims?
- What happens when two nested dialects claim the same word? (Rule: nearest enclosing dialect that declared it owns the word.)

**DECIDED:** Dialect vocabulary words are **not global.** Two tiers:

- **Core dialects** (`loop`, `parse`, `match`, `object`, `if`, `either`) live in the global context. They're the language. Available everywhere, like `print` or `append`.
- **Domain dialects** (`entity`, `scene`, `input`, `tween`) are imported via `load/eval`, like any module. They only exist in scopes that imported them.

```
game: load/eval %lib/game.ktg

; game/scene is available here because we imported it
level: game/scene [
  spawn Enemy at 100x200 layer 'enemies
]

; 'spawn', 'at', 'layer' are NOT global words
; they only mean something to the scene dialect reading that block
```

This means adding game dialects doesn't pollute the global namespace. A user who doesn't `load/eval` the game library never sees `entity`, `scene`, or `tween`. Core language stays clean.

### 8.2 Block consumption and the set-word collision resolution

**DECIDED:** Dialect blocks are **inert data.** The parent scope never evaluates them. The dialect reads the block as data and interprets it according to its own rules.

This resolves the set-word collision problem entirely:

```
name: "Ray"
parse data [
  name: some alpha    ; this is NOT a set-word assignment in parent scope
                      ; parse reads 'name:' as "capture here" in its own vocabulary
]
; 'name' in parent scope is still "Ray" — untouched
```

The key insight: `[name: some alpha]` is a block. Blocks are inert. The evaluator hands the block to `parse` as data. Parse walks through it and interprets `name:` as a capture instruction. The parent evaluator never sees `name:` as a set-word to execute. No collision, no write-through, no namespace corruption.

How the captured value gets back to the caller is a per-dialect design decision:
- Parse could return a context with captures: `result: parse data [...]; result/name`
- Parse could use `collect`/`keep` to return values explicitly
- Parse could bind into the caller's scope (current behavior — but this should be opt-in, not default)

Open questions:
- How does a dialect walk the block? Position by position? Via parse rules?
- When it encounters a word it doesn't own, does it: pass through as data? Error?
- **DECIDED (preference):** Dialects should compose **sequentially** (pipelines), not recursively. Each dialect transforms data and hands it to the next. Nesting is supported but not encouraged. Flat pipelines are readable, greppable, debuggable.

### 8.3 Context interaction

Given that dialect blocks are inert data (8.2), the question becomes: **how does a dialect return results to the caller?**

Options:
- **Return a value.** `loop/collect` returns a block. `parse` returns `logic!`. Caller assigns: `result: parse data [...]`
- **Return a context with named results.** `result: parse data [name: some alpha]` → `result/name`
- **Bind into caller's scope (current parse behavior).** Convenient but implicit. Should this be opt-in?

The dialect should not silently modify the caller's context. Results flow back through return values, not side effects. This is the explicit-over-DWIM principle.

### 8.4 Return values

- What can a dialect return? A single value? Multiple values?
- Can it return nothing (side effects only)?
- How do refinements on dialect calls work? (`loop/collect` vs `loop/fold`)

### 8.5 User-defined dialects

- Can users define their own dialects?
- If yes, what's the mechanism? A special function form? A `dialect` constructor?
- If no, is this planned? What are the constraints?
- Game-domain dialects (`entity`, `scene`, `input`, `tween`) would ideally be user-definable or at least stdlib-definable using the same protocol as built-in dialects.

### 8.6 Compiler visibility

- How does the compiler know what a dialect does?
- Does each dialect declare lowering rules (how it maps to output)?
- Can a dialect be interpreter-only, compiler-only, or both?
- **Key question:** If the compiler is a dialect, and dialects declare lowering rules as data, then adding a new dialect automatically teaches the compiler how to emit code for it. Is this the model?

---

## 9. Function Spec Dialect

### 9.1 Complete grammar

**DECIDED:**

```
spec: [
  param                          ; untyped positional
  param [type!]                  ; typed positional
  param [type1! | type2!]        ; union typed
  param [block! type!]           ; block with element constraint
  /refinement                    ; boolean flag, no params
  /refinement param [type!]      ; refinement with one typed param
  /refinement p1 [type!] p2 [type!]  ; refinement with multiple params
  return: [type!]                ; return type
]
```

**`opt` is removed from the language.** It was redundant everywhere:
- In function params: fixed arity means you always pass a value. Use refinements for optional behavior.
- In object fields: `@default` is replaced by the `field` dialect keyword inside `object`. `field [name [type!] default]` for defaulted, `field [name [type!]]` for required.

**Resolved questions:**

- **Multiple refinement parameters:** Yes. A refinement can be followed by multiple parameter words, each with optional type constraints. All are consumed when the refinement is active.
- **Refinement default values:** No. Refinements are either active or inactive. When inactive, the refinement word is `false` and its parameters are `none`.
- **`opt` removed:** Redundant. Fixed arity means you always pass a value. Use refinements for optional behavior.
- **`@default` replaced by `field` dialect.** `field [name [type!] default]` inside object blocks. Scoped to the object dialect — can't be confused with function params or anything else.
- **Optional refinement parameters:** No. When a refinement is active, all its parameters must be provided. The refinement itself is the optionality mechanism.
- **Rest-args / variadic:** No. Functions have fixed arity, always. Accept a `block!` parameter and iterate over it if you need variable arguments.
- **`/local` variables (REBOL-style):** Unnecessary. Set-word always shadows (section 2.3), so local variables are just set-words in the function body. No need for a `/local` hack.
- **Return type violation:** Error. `'type` error at return time. Type annotations are enforced, not decorative.

### 9.2 Type constraint enforcement

**DECIDED:**

- **Checked at call time AND return time.** Parameters checked on entry, return type checked on exit. Annotations are a contract, not documentation.
- **Error kind:** `'type` for both parameter and return violations.
- **Compiled output:** Type checks are **erased by default** in compiled Lua. The compiler uses type info for optimization and specialization, not runtime checking. The interpreter always checks — that's your dev-mode safety net. A debug compile flag could optionally emit asserts for compiled output.

---

## 10. Parse Dialect Formal Grammar

**DECIDED:** Parse follows REBOL/Red semantics with one key departure: capture binding. Set-words inside parse build a result context returned by parse, rather than mutating the caller's scope (consistent with section 8.2 — dialect blocks are inert data, dialects don't silently modify the caller).

### 10.1 Combinators

| Combinator               | Matches                                                                  | Consumes input?      | Backtracks?                                                             |
|--------------------------|--------------------------------------------------------------------------|----------------------|-------------------------------------------------------------------------|
| `literal` (string/value) | Exact match against input element(s)                                     | Yes                  | Yes                                                                     |
| `skip`                   | Any single element                                                       | Yes                  | Yes                                                                     |
| `end`                    | End of input (nothing remaining)                                         | No                   | Yes                                                                     |
| `some rule`              | One or more matches of rule                                              | Yes                  | Yes — if first match succeeds but later fails, backtracks entire `some` |
| `any rule`               | Zero or more matches of rule                                             | Only if matched      | No — always succeeds (zero matches is success)                          |
| `opt rule`               | Zero or one match of rule                                                | Only if matched      | No — always succeeds                                                    |
| `not rule`               | Negative lookahead — succeeds if rule fails                              | No (lookahead)       | No — succeeds or fails without consuming                                |
| `ahead rule`             | Positive lookahead — succeeds if rule matches                            | No (lookahead)       | No — succeeds or fails without consuming                                |
| `to rule`                | Scans forward to (but not past) a match                                  | Yes (up to match)    | Yes                                                                     |
| `thru rule`              | Scans forward through (past) a match                                     | Yes (through match)  | Yes                                                                     |
| `into rule`              | Descend into a nested block, apply rule inside it                        | Yes (the block)      | Yes                                                                     |
| `quote value`            | Match value literally (escape keywords)                                  | Yes                  | Yes                                                                     |
| `N rule`                 | Exactly N repetitions of rule                                            | Yes                  | Yes                                                                     |
| `N M rule`               | Between N and M repetitions of rule                                      | Yes                  | Yes                                                                     |
| `collect [rule]`         | Wraps rule; `keep` inside appends to collected block                     | Same as inner rule   | Same as inner rule                                                      |
| `keep rule`              | Inside `collect`: match rule and append matched value to collected block | Yes                  | Yes                                                                     |
| `break`                  | Exit enclosing `some`/`any` loop with success                            | No                   | No                                                                      |
| `fail`                   | Force failure, trigger backtracking                                      | No                   | Yes — forces backtrack                                                  |
| `(expr)`                 | Evaluate expression as side effect; always succeeds                      | No                   | No                                                                      |
| `[sub-rule]`             | Group rules into a sub-rule (for precedence)                             | Same as contents     | Same as contents                                                        |
| `rule1 \| rule2`         | Ordered alternative — try rule1, if it fails try rule2                   | Same as matched rule | Yes — backtracks rule1 before trying rule2                              |

### 10.2 Precedence

**DECIDED (REBOL rules):**
- `|` has **lowest precedence.** `a b | c d` means `[a b] | [c d]` — the alternative is between the two sequences, not between `b` and `c`.
- `some`, `any`, `opt`, `not`, `ahead` bind to the **next single rule.** `some a | b` means `[some a] | b` — "one or more a's, OR one b."
- Use `[sub-rule]` grouping to override: `some [a | b]` means "one or more of (a or b)."

### 10.3 Capture and binding

**DECIDED:**

Two extraction mechanisms, each with a clear role:

- **`name: rule`** — captures a **single value** (last match wins). Builds a field on the result context. Does NOT bind into the caller's scope (section 8.2 — dialect blocks are inert data). If the same set-word fires multiple times (e.g., inside `some`), only the last captured value is kept. No implicit accumulation.
- **`name: collect [rule]`** — **explicit accumulation.** `keep` inside `collect` appends matched values to a block. The block becomes a field on the result context via the set-word. `collect` without a set-word is a no-op — the collected values have nowhere to go and are discarded.
- **`keep`** outside `collect` is an ERROR.
- **Nested `collect`:** Yes. Inner `collect` produces a nested block inside the outer `collect`'s results.

```
; set-word captures single values
result: parse "user@example.com" [
  name: some [alpha | digit | "."]
  "@"
  domain: some [alpha | digit | "." | "-"]
]
result/ok        ; true
result/name      ; "user"
result/domain    ; "example.com"

; set-word inside some — last match wins, no accumulation
result: parse "1,2,3" [some [num: some digit opt ","]]
result/num       ; "3" (last capture, not a block)

; collect/keep for explicit accumulation — must be named
result: parse [1 "a" 2 "b" 3] [
  nums: collect [some [keep integer! | skip]]
]
result/nums      ; [1 2 3]

; unnamed collect does nothing — no set-word, nowhere to go
parse data [collect [some [keep integer! | skip]]]
; collected values discarded
```

**`parse/ok` refinement:** unwraps to `logic!` when you only care about match success, no captures needed.

```
if parse/ok input [some digit] [print "all numbers"]
```

### 10.4 String mode specifics

**Character classes (REBOL standard set):**

| Class   | Characters                      |
|---------|---------------------------------|
| `alpha` | `a-z`, `A-Z`                    |
| `digit` | `0-9`                           |
| `alnum` | `a-z`, `A-Z`, `0-9`            |
| `space` | space, tab, newline, carriage return |
| `upper` | `A-Z`                           |
| `lower` | `a-z`                           |
| `newline` | `\n`, `\r\n`                  |

**Custom character classes:** Yes, via `set!`. A `set!` is a first-class type — an unordered collection of unique values with O(1) membership testing. Works on any value type: characters, words, integers, whatever. `charset` is sugar for `make set!` from a string.

```
; character sets for parse
hex-chars: charset "0123456789abcdef"
parse input [some hex-chars]           ; O(1) per character

; word sets — same type, same interface
directions: make set! ['north 'south 'east 'west]
has? directions 'north                 ; true

; combine existing classes and literals
ident-start: charset [alpha "_"]
ident-char: charset [alnum "_" "-"]
parse input [ident-start some ident-char]
```

`set!` is also useful beyond parse — flags, permissions, collision layers, entity tags:
```
collision-layers: make set! ['enemies 'terrain 'pickups]
has? collision-layers 'enemies    ; true
```

The compiler optimizes by representation: character-only sets emit bit arrays in Lua (integer bit math). Mixed or word sets emit hash table lookups. The user sees one type, one interface.

### 10.5 Block mode specifics

- **`type!`** — matches any value of that type. Yes, consumes the matched value. `integer!` matches and consumes `42`.
- **`'word`** — matches literal word by name. Case-insensitive (matching REBOL and section 5 rule 7 for same-subtype words). Consumes the matched word.
- **`(expression)`** — as a match target, evaluates the expression and matches the result against the current input position. Yes, can be used for computed matching.

### 10.6 Success, failure, and return value

**DECIDED:**
- **Parse succeeds only if ALL input is consumed.** Partial matches are failures. This is REBOL behavior.
- **Return value:** Parse returns a `context!` with an `ok` field (logic!) plus any set-word captures and collect results.

```
; success, no captures
result: parse "abc" [some alpha]
result/ok    ; true

; failure
result: parse "abc123" [some alpha]
result/ok    ; false (digits unconsumed)

; success with captures
result: parse "42,hello" [
  num: some digit
  ","
  word: some alpha
]
result/ok    ; true
result/num   ; "42"
result/word  ; "hello"
```

If you only care about success/failure: `(parse data rules)/ok` or use in a conditional: `if (parse data rules)/ok [...]`

**Convenience:** A bare `parse` in a conditional context could potentially auto-unwrap to `ok` — UNDECIDED, may be too magical. For now, always access `/ok` explicitly.

---

## 11. Object Protocol

### 11.0 Core model

**DECIDED:** `object!` and `context!` are the two sides of the same coin.

- `object [...]` returns an **immutable `object!`** — the prototype. Fields are declared with the `field` keyword. Everything else in the block is the prototype body (methods). It cannot be mutated after creation.
- `make Prototype [overrides]` returns a **mutable `context!`** — an instance. It has the prototype's fields (with overrides applied) and methods bound to the instance via `self`.
- The prototype is the blueprint. Instances are living mutable state. Two types, two rules.

This means:
- `Enemy/hp: 200` is an ERROR (object is immutable)
- `goblin/hp: 50` works (instance is a context, mutable)
- Modules returned by `load/eval` are `object!` — immutable, safe from corruption
- `freeze` upgrades a `context!` to `object!` when you want to lock it down

### 11.1 What `make` does, step by step

**DECIDED:** `make` stamps a copy. No delegation, no prototype chain, no link back.

For `make Prototype [overrides]`:
1. **Shallow copy** prototype fields into a new `context!`. Values are copied, but nested blocks/contexts/maps are shared by reference (consistent with section 3.0 — assignment is by reference).
2. **Apply overrides** — field values from the override block replace copied values. Type-checked against field specs if the prototype has them.
3. **Validate required fields** — any `field` declaration without a default value that wasn't provided in overrides raises a `'make` error.
4. **Bind methods** — `self` is bound to the new instance. Every function in the context gets `self` pointing to this specific instance.
5. **Return** a mutable `context!`.

The instance has no reference to the prototype. All fields and methods are owned by the instance. Modifying the prototype after `make` (impossible anyway — it's `object!`) would have no effect on existing instances.

For `make instance [overrides]` (cloning):
- Same steps. Instance is a `context!`, so `make` shallow-copies its fields, applies overrides, rebinds `self` to the new copy. Returns a new `context!`. The original instance is unaffected.

For `make map! [...]`, `make set! [...]`:
- Type dispatch. `make` checks the first argument's type. If it's an `object!` or `context!`, stamps an instance. If it's a type value (`map!`, `set!`), constructs that type from the block. Same word, different behavior based on what you're making from. The first argument answers "what am I making."

### 11.2 Self

**DECIDED:**

- **`self` is a word** bound in each method's scope at `make` time. Not a special form — just a regular word that points to the instance context.
- **Bound at `make` time.** When `make` copies methods into the new instance, it binds `self` to that instance. Each instance's methods have their own `self` pointing to their own context.
- **Can be passed to external functions.** `do-something self` works — `self` is a value like any other. The receiving function gets a reference to the context.
- **Cannot be rebound.** `self: other-object` raises a `'self` error. `self` is read-only within methods. You can mutate `self/field` (set-path on the context) but you can't reassign what `self` points to.
- **Nested objects:** Inner `self` shadows outer `self`. If an object's method creates another object, the inner object's methods see their own `self`. The outer `self` is not accessible from the inner method — same shadowing rules as everything else (section 2.3).

```
Enemy: object [
  field [hp [integer!] 100]

  damage: function [amount [integer!]] [
    self/hp: self/hp - amount    ; mutates this instance's hp
  ]

  clone: does [
    make self []                  ; pass self to make — works, it's just a value
  ]
]

goblin: make Enemy []
goblin/damage 10
print goblin/hp                   ; 90
```

### 11.3 Auto-generation

**DECIDED:**

- `Person: object [...]` auto-generates `person!` (custom type) and `make-person` (constructor function). Always, for any `object` definition assigned to a set-word.
- **Lowercase names work the same.** `thing: object [...]` generates `thing!` and `make-thing`.
- **Collision is an error.** If `person!` or `make-person` already exists in scope, `object` raises a `'name-collision` error. Explicit — no silent overwrites.
- **No opt-out.** Auto-generation is part of what `object` does. If you don't want it, use `context` instead — but then you don't get field specs, defaults, or type validation.

```
Person: object [
  name [string!]
  age [integer!]
]

; auto-generated:
; person!       — custom type, is? person! checks for name and age fields
; make-person   — constructor: make-person "Ray" 30
;                 args match required fields in declaration order

p: make-person "Ray" 30       ; sugar for: make Person [name: "Ray" age: 30]
is? person! p                  ; true
```

### 11.4 No prototype chains

**DECIDED:** No delegation. No chains. `make` is a stamp.

- Accessing a field not on the instance is an `'undefined` error. The prototype is not consulted.
- There is no `prototype-of`. Instances don't know where they came from. They're just contexts with fields.
- No inheritance — single or multiple. Composition via embedding: put a context inside another context's field.

```
; no inheritance — compose instead
Damageable: object [
  field [hp [integer!] 100]
  damage: function [amount [integer!]] [self/hp: self/hp - amount]
]

Enemy: object [
  field [stats [context!]]
  field [speed [float!] 40.0]
]

goblin: make Enemy [stats: make Damageable []]
goblin/stats/damage 10
print goblin/stats/hp    ; 90
```

This is more verbose than inheritance but there's no ambiguity about where a field comes from. No diamond problem, no method resolution order, no spooky action through a prototype chain. You see the path, you know the source.

---

## 12. Loading, Modules, and Serialization

### 12.0 Core insight: `load` unifies everything

**DECIDED:** `require` is replaced by `load` — one word with refinements that unifies module loading, data loading, config loading, and save file reading. They're all the same operation: read a file, parse or evaluate its contents, return a context.

```
; module — evaluate code, freeze, cache
math: load/eval %lib/math.ktg         ; returns object! (frozen, cached)

; save file — parse as data, return mutable
state: load %save.dat                  ; returns context! (mutable)

; config — parse as data, freeze
config: load/freeze %config.ktg       ; returns object! (frozen)

; header inspection
info: load/header %lib/math.ktg       ; returns the header block
```

Refinements:
- `load` (no refinement) — parse file as data, return mutable `context!`
- `load/eval` — evaluate the code in an isolated context, freeze to `object!`, cache by path. This is what `require` was.
- `load/freeze` — parse as data, freeze to `object!`. For config.
- `load/header` — return just the header block.
- `load/fresh` — combinable with `/eval`, skips cache for one call.

The data format is Kintsugi literal syntax — no JSON, no TOML, no custom format:

```
; save.dat — just Kintsugi values, parsed by the existing lexer
[
  player [hp: 45 pos: 160x120 facing: 'down]
  scene [
    entities [
      [type: 'Slime hp: 20 pos: 80x60]
      [type: 'Slime hp: 30 pos: 240x80]
    ]
  ]
]
```

And `save` is the inverse:

```
save %save.dat game-state
; writes the context's data fields as Kintsugi literal syntax
```

Implications:
- The existing lexer and parser handle all file reading — modules, config, save files
- Modules, configs, and saves are the same thing with different freeze/eval options
- `load/eval` results are `object!` — immutable, safe, cached. Same guarantees as the old `require`
- A module is still just a context: you can pass it to functions, inspect with `words-of`, mock in tests

### 12.1 Serialization rules

**DECIDED:** Serialization is data only. No function serialization.

What `save` writes:
- Scalar values (integer, float, string, logic, none, money, pair, tuple, date, time) — written as literals
- `block!` — written as `[...]` with contents serialized recursively
- `map!` — written as `[key: value ...]`
- `context!` — written as `[field: value ...]` for data fields only
- `file!`, `url!`, `email!` — written as literals

What `save` skips:
- `function!` / `native!` — not serialized. Methods come from the prototype on reload.
- `object!` — referenced by prototype name, not serialized inline
- `op!`, `type!` — internal, not serialized

Reload pattern:
```
; save
save %save.dat player     ; writes: [hp: 45 pos: 160x120 facing: 'down ...]

; load — prototype provides methods, save provides state
data: load %save.dat
p: make Player data
```

This works because the `object!`/`context!` split already separates behavior (prototype, not saved) from state (instance data, saved).

Open questions:
- How are nested contexts handled? Recursive serialization?
- How are prototype references stored? By name string? What if the prototype isn't in scope on load?
- Should `save` have refinements for filtering fields? `save/only %file obj [hp pos]`
- Could a `save` dialect be cleaner than refinements?

### 12.2 Module loading details (load/eval)

**DECIDED:**

- Header is parsed first, then body is evaluated in an isolated context. The result is filtered by `exports` (if present), frozen to `object!`, cached by fully resolved absolute path.
- The loaded module does NOT see the caller's context. Isolation is total.
- The loaded module DOES see the global context (built-in functions, types, core dialects). Otherwise it couldn't use `print`, `function`, `loop`, etc.
- **Caching:** keyed by fully resolved absolute path. `require %../lib/math.ktg` from different directories resolves to the same absolute path, hits the same cache entry. Symlinks resolve to their target before caching.
- `load/fresh` bypasses cache for one call. No mechanism to clear the whole cache — if you need that, restart the interpreter.
- Cache stores `object!` values (immutable). Every consumer gets the same reference. Sharing is safe.

### 12.3 Circular dependencies

**DECIDED:** Always an error. `'load` error with the circular chain in the message:

```
; ERROR 'load: circular dependency: %a.ktg -> %b.ktg -> %a.ktg
```

Detected at file granularity. If A requires B and B requires A, it errors when B tries to load A and finds A is already in the loading stack. No lazy resolution — the dependency graph must be a DAG.

If you have two modules that genuinely need each other's functions, factor the shared parts into a third module that both import. This is the standard solution in every language.

### 12.4 Header

**DECIDED:** The header is minimal. Its job is to mark a file as a Kintsugi entry point and declare the target dialect. Everything inside the header block is optional metadata for tooling — the language doesn't use it.

```
Kintsugi []                        ; script, no metadata
Kintsugi [version: 1.0.0]         ; script with metadata (tooling can read it)
Kintsugi/Lua []                    ; compiles to Lua
Kintsugi/Lua [version: 1.0.0]     ; compiles to Lua, with metadata
```

The header existing = this is an entry point / loadable module.
The dialect path = compilation target (`Kintsugi` = script, `Kintsugi/Lua` = Lua output).
The block contents = optional, freeform, for humans and tools.

No required fields. No fields with language-level effects. Common conventions:

| Field | Type | Purpose |
|-------|------|---------|
| `name:` | `lit-word!` | Module identifier (for humans/tooling) |
| `version:` | `tuple!` | Semver (for humans/tooling) |
| `date:` | `date!` | Last modified (for humans/tooling) |
| `file:` | `file!` | Source path (for humans/tooling) |

None of these are required. None affect evaluation. They're conventions, not contracts.

### 12.5 Exports

**DECIDED:** `exports` is a **body-level word**, not a header field. It controls what `require`/`load/eval` returns.

```
Kintsugi []

exports [add subtract clamp]

add: function [a b] [a + b]
subtract: function [a b] [a - b]
clamp: function [val lo hi] [min hi max lo val]
helper: function [x] [x * x]     ; not in exports — invisible to consumers
```

Rules:
- `exports` takes a block of words. Only those words appear in the returned `object!`. Everything else is private.
- If `exports` is never called, everything is public.
- `exports` can include type names: `exports [add person!]`.
- **No re-export mechanism.** If you want to forward a word from another module, bind it in your scope with a get-word before the module freezes:

```
math: require %lib/math.ktg
lerp: :math/lerp              ; forward math's lerp as your own

exports [lerp my-function]    ; consumers see lerp and my-function
```

This is explicit, visible, greppable. No magic re-export syntax.

- **`rethrow`** is sugar for re-raising a caught error with its original stack trace preserved. Not related to exports but same "forwarding" pattern:

```
result: try [dangerous-thing]
if not result/ok [rethrow result]    ; preserves original stack
```

---

## 13. Preprocessing

### 13.1 Scope

**DECIDED:** `#preprocess` runs the full language. It's not a limited macro system — it's the interpreter evaluating a block before the main program runs.

Available in the preprocess context:
- **`platform`** — a lit-word: `'script` or `'lua` (set by the compiler based on the header dialect)
- **`emit`** — a function that injects a block into the output program
- **Everything else** — the full language. All built-in functions, all dialects, all types.

Rules:
- `#preprocess` can call `require` to load modules. Useful for build-time utilities, code generators, etc.
- `#preprocess` can define functions and types *within its own block* for its own use. These do NOT leak into the output program — they exist only during preprocessing.
- **Emitted code is not evaluated during preprocessing.** `emit` injects blocks into the output stream. A later `#preprocess` block cannot call a function that was emitted by an earlier one — emitted code hasn't been evaluated yet, it's queued for the main program.
- Multiple `#preprocess` blocks in a file share a preprocessing context. Variables set in one block are visible to later blocks.

```
; first preprocess block sets up helpers
#preprocess [
  fields: [name age email]
]

; second preprocess block uses them
#preprocess [
  loop [for [field] in fields [
    emit compose [
      (to set-word! join "get-" field) function [obj] [
        obj/(to lit-word! field)
      ]
    ]
  ]]
]
```

Errors in `#preprocess` blocks produce `PREPROCESS ERROR` in the formatted output (section 7.3).

### 13.2 Inline preprocess

**DECIDED:**

- `#[expr]` evaluates `expr` at preprocess time and injects the result value in place.
- Any value type can be injected — scalars, blocks, words, etc. The result replaces `#[...]` in the AST.
- `#[...]` can appear **anywhere a value can appear** — top-level, inside block literals, as function arguments.
- `#[...]` **cannot appear inside strings.** Strings are not interpolated. Use `rejoin` for string building.

```
x: #[1 + 2]                     ; x = 3 (computed at preprocess time)
data: [#[platform] #[1 + 2]]    ; data = ['script 3] or ['lua 3]
```

### 13.3 Platform values

**DECIDED:**

- `platform` is a **word** bound in the preprocess context. Not a function, not extensible by users.
- Set by the compiler/interpreter based on the header dialect:
  - `Kintsugi []` or no header → `'script`
  - `Kintsugi/Lua []` → `'lua`
- Future targets add new values: `Kintsugi/Luau` → `'luau`, etc. The word is set by the toolchain, not by user code.

---

## 14. Compilation Boundary

### 14.0 Core decisions

**DECIDED:**
- **Lua only.** JS and WASM backends are dropped. Remove from header dialect enum.
- **Zero-dependency output.** Compiled Lua must not require LuaRocks or any external packages. If runtime support is needed, it's emitted inline by the compiler — only what's used, dead code eliminated.
- **The compiler is a dialect.** A Kintsugi program that reads Kintsugi blocks and emits Lua strings, using match/parse on AST data. Output backends are interchangeable dialects (`Kintsugi/Lua` emits Lua, a hypothetical `Kintsugi/Luau` emits Roblox Luau, etc.).
- **Rich compile-time, lean runtime.** Dialects, type checking, parse, pattern matching — all resolve at compile time. The output is flat Lua: tables, functions, if-chains, for-loops. The Playdate doesn't need to know Kintsugi exists.
- **Two strategies for features that don't map to Lua:**
  - **A) Restrict the compiled subset.** Some features are interpreter-only. Document clearly.
  - **B) Specialize aggressively.** `match` becomes an if-chain. `object` becomes a table + constructor. `parse` on a literal format unrolls to string ops. Emit specialized code per use site, not generic runtime.
  - Prefer B where possible, fall back to A for truly dynamic features (`do`, `bind`, `compose` on runtime blocks).
- **`Kintsugi/Config`** — a potential output dialect that emits pure Lua tables (data only, no functions, no control flow). For game config, level data, settings.

### 14.1 What compiles?

**DECIDED:**

| Feature | Compiles? | Strategy |
|---------|----------|----------|
| Arithmetic | Yes | Direct Lua operators |
| Functions | Yes | `local function name(...)` |
| Closures | Yes | Lua closures (Lua has native closure support) |
| Control flow (if/either/unless) | Yes | `if/elseif/else/end` |
| Loop dialect | Yes | `for i=start,end,step` or `for _,v in ipairs(t)` |
| Match dialect | Yes | Specializes to if-chain with equality/type checks |
| Object dialect | Yes | Specializes to table + constructor function |
| Parse dialect | Compile-time only | Rules resolve during compilation. Parse extracts data that feeds into the compiled program. Parse cannot run at runtime in compiled output. |
| Attempt dialect | Yes | Specializes to pcall chain with error handling |
| `do` on dynamic blocks | No | Interpreter-only. Requires runtime evaluator. |
| `compose` on dynamic blocks | No | Interpreter-only. Requires runtime AST manipulation. |
| `compose` on literal blocks | Yes | Resolved at compile time — values are inlined. |
| `bind` | No | Interpreter-only. Requires runtime word rebinding. |
| `reduce` | Yes | Evaluates each expression, emits as Lua table construction. |
| `#preprocess` | Runs at compile time | Full language available. Output is injected into the compiled program. Not present in Lua output. |
| `#[expr]` | Runs at compile time | Result value inlined into the compiled output. |
| `require` / `load/eval` | Yes | Module is compiled separately. `require` emits Lua `require()` or inlines the module. |
| `load` (data) | Yes | Emits Lua code that reads and parses the file at runtime. Or: the data file is inlined at compile time if path is a literal. |
| Type checking at runtime | Erased by default | Compiler uses types for optimization. No runtime checks in output. Debug flag can emit asserts. |
| Custom `@type` validation | Erased by default | Same as above — compile-time knowledge, not runtime checks. |
| `@enter` / `@exit` hooks | Yes | Emit as inline code at scope entry/exit. `@exit` wraps body in pcall-based finally pattern. |
| `freeze` / `frozen?` | No-op | Interpreter concern only. In compiled Lua, all values are tables — mutability is the Lua runtime's domain. `freeze` erased, `frozen?` always returns `false`. |

### 14.2 What's the error when you use an interpreter-only feature in compiled code?

**DECIDED:** Compile-time error. Loud and immediate.

```
======== COMPILE ERROR ========
Interpreter-Only Feature
'do' cannot be used in Kintsugi/Lua — it requires runtime evaluation @ %game.ktg#L42
  hint: use #preprocess to evaluate dynamic blocks at compile time
```

- Using `do`, `bind`, or `compose` on non-literal blocks in `Kintsugi/Lua` code is a compile-time error.
- The error message suggests alternatives (e.g., `#preprocess` for compile-time evaluation).
- No silent omission, no runtime error. You find out before the Lua is generated.
- No separate lint mode needed — the compiler IS the lint. If it compiles, it runs.

### 14.3 Output dialect model

If the compiler is a dialect, then different output targets are different dialects:

```
Kintsugi/Lua [...]     ; emits Lua 5.1 — LÖVE2D, Playdate, Defold
Kintsugi/Config [...]  ; emits Lua tables — data only, no code
; Future possibilities (not committed):
; Kintsugi/Luau [...]  ; emits Luau — Roblox
; Kintsugi/Teal [...]  ; emits Teal-annotated Lua
```

Each output dialect is a set of match/emit rules. Adding a new target means writing a new set of rules, not modifying the compiler core.

### 14.4 Hot-reload model

**DECIDED:** The interpreter and compiler are two execution strategies for the same source code. Blocks being inert data is what makes both work.

- **Dev mode (interpreter):** Dialects interpret blocks at runtime. Every evaluation is live. Change a `.ktg` file, the interpreter re-evaluates, game state updates. No restart. Dialects are evaluated lazily every time the block is reached.
- **Ship mode (compiler):** Dialects resolve to flat Lua at compile time. Output is static. No dialect runtime on the device.

There is no intermediate "compile before interpret" step that would kill liveness. The interpreter does not pre-resolve dialects. This is essential for the dev experience.

### 14.5 Native compute kernels (future — Phase 5)

**NOT YET COMMITTED.** Build this when a real game drops below 30fps on the Playdate, not before.

`native` is a keyword that routes a function to the C emitter instead of the Lua emitter. Same Kintsugi syntax, different output.

```
; Lua path — normal function
update: function [entities [block!] dt [float!]] [
  loop [for [e] in entities [
    e/x: e/x + e/vx * dt
    e/y: e/y + e/vy * dt
  ]]
]

; C path — same syntax, compiles to C instead
update-fast: native [
  entities [block! entity!]    ; fully typed — compiler knows struct layout
  dt [float!]
] [
  loop [for [e] in entities [
    e/x: e/x + e/vx * dt
    e/y: e/y + e/vy * dt
  ]]
]
```

**Constraints inside `native` blocks:**
- Every value must be typed. No `any-type!`. The C emitter needs sizes.
- No allocation. No `append`, `make`, `copy`. Operate on data passed in.
- No dynamic dispatch. No `match`, `do`, or calling Kintsugi functions from C.
- No strings. Numbers, pairs, and typed struct fields only.
- Essentially: math on arrays of structs.

**What the compiler generates (two artifacts):**

C side — compiled with the Playdate SDK's ARM toolchain (or system compiler for LÖVE2D):
```c
typedef struct { float x, y, vx, vy; int hp; } Entity;

static int update_fast_c(lua_State* L) {
    // unpack args from Lua stack, loop, push result
}

void register_natives(PlaydateAPI* pd) {
    pd->lua->registerFunction(update_fast_c, "update_fast");
}
```

Lua side — the rest of the game, calls the C function as if it were Lua:
```lua
update_fast(entities, dt)  -- calls into C via Playdate's registered function
```

**Playdate double deployment:** Panic's SDK requires C and Lua as separate compilation targets. The `native` keyword generates both halves. The developer writes one function in Kintsugi, the build script handles the split. This is unavoidable architecture from Panic's side.

**The Nim host language helps here:** Since the Kintsugi compiler is already in C-land (Nim compiles to C), linking and build integration with the Playdate SDK's C toolchain is straightforward.

---

## 15. API Design Principle

### 15.0 Explicit primitives, compositional magic

**DECIDED:** Primitives are small and explicit. DWIM ("Do What I Mean") polymorphism is built by users on top of explicit primitives, not baked into the language.

```
; WRONG — magic 'read' that figures out what to do
read source   ; file? url? string? who knows

; RIGHT — explicit primitives
read-file %data.txt
fetch https://example.com/api

; Users can build DWIM on top in five lines if they want
read: function [source] [
  match type source [
    file!   [read-file source]
    url!    [fetch source]
    string! [read-file to file! source]
  ]
]
```

The reverse isn't true — you can't build explicit on top of DWIM. Explicit primitives mean:
- Greppable: you can find all file reads or all HTTP calls
- Auditable: security boundaries are visible
- Type-checkable: the compiler knows what's happening
- Debuggable: error messages are specific ("file not found" not "read failed")

**The litmus test:** if the failure modes are different, the words should be different. File-not-found and DNS-resolution-failure are not the same error.

**Where DWIM is fine:** within the language for conceptually identical operations. `size?` on blocks, strings, maps, and contexts. `to` with an explicit target type. The *output type* is always explicit even when the input is polymorphic.

---

## 16. Context-Aware Operations and Destructuring

### 16.0 `size?` replaces `length?`

**DECIDED:** `size?` is the canonical word for "how many elements." It works on anything with a count:

```
size? [1 2 3]         ; 3 — elements in block
size? "hello"         ; 5 — characters in string
size? my-map          ; 4 — key-value pairs
size? my-context      ; 6 — fields in context
```

`length?` may exist as an alias for REBOL familiarity, but `size?` is the primary name. It's neutral — doesn't imply linearity.

### 16.1 Operations that work on contexts

**DECIDED:** Predicates and key-based operations work on contexts. Positional operations don't.

| Operation | Works on `context!`? | Behavior |
|-----------|---------------------|----------|
| `size?` | Yes | Number of fields |
| `empty?` | Yes | True if no fields |
| `has? ctx 'field` | Yes | True if field exists |
| `select ctx 'field` | Yes | Returns field value |
| `words-of ctx` | Yes | Returns field names as block |
| `ctx/field` | Yes | Path access (already works) |
| `first` | No — contexts have no order |
| `last` | No — contexts have no order |
| `pick` | No — contexts have no order |
| `append` | No — use set-path for mutation |
| `insert` | No — use set-path for mutation |
| `remove` | UNDECIDED — `remove ctx 'field`? Or not worth it? |

### 16.2 `set` is context-aware for destructuring

**DECIDED:** `set` destructures both blocks (by position) and contexts (by name).

```
; block — positional destructuring
set [a b c] [1 2 3]            ; a=1, b=2, c=3

; context — named destructuring (matches word names to field names)
result: parse data [name: some alpha "@" domain: some alpha]
set [name domain] result        ; name=result/name, domain=result/domain

; cherry-pick fields
set [domain] result             ; just domain, ignore the rest
```

On a block: `set` maps target words to source values by position.
On a context: `set` maps target words to source fields by name. Only fields whose names match a word in the target block are extracted.

This means dialect results (which are contexts) destructure cleanly:
```
set [ok name domain] parse data [name: some alpha "@" domain: some alpha]
if ok [print rejoin [name " at " domain]]
```

---

## 17. Game Dialects as Product

### 16.0 The stdlib is the pitch

**DECIDED:** The standard library's primary focus should be game development, not generic programming utilities. The language dialects (`loop`, `parse`, `match`, `object`) are the engine. The game dialects are the product.

Priority stdlib modules:
- `entity.ktg` — declarative game object definitions with fields, events, state
- `scene.ktg` — entity placement, layers, spatial queries
- `input.ktg` — declarative input binding (pressed, held, released)
- `tween.ktg` — declarative animation (from, to, ease, duration)
- `state-machine.ktg` — declarative state transitions

Secondary (still needed, lower priority):
- `math.ktg` — vectors, interpolation, easing curves (exists, needs expansion)
- `collections.ktg` — sort, filter, map (exists, needs sort)
- `string.ktg` — utility functions (exists)

The game dialects must be **written in Kintsugi** using the same dialect protocol as built-in dialects. They are proof that the architecture works and the reason someone would choose Kintsugi over Fennel.

The goal: a game developer writes what their game *is* and what it *does*, not how to wire up tables and callbacks. If defining an enemy with events, a scene with entity placements, and input with bindings isn't dramatically simpler than the Lua/Fennel equivalent, the language hasn't earned its complexity.

---

## Summary of Decisions Made

These emerged from design conversations on 2026-03-24 and are now load-bearing:

1. **Contexts are the universal construct.** Closures, objects, modules, scopes — all contexts. No separate closure mechanism.
2. **`context!` is mutable, `object!` is immutable.** The type determines mutability, not annotations. `freeze` upgrades context to object (one-way). `freeze/deep` does so recursively.
3. **Assignment is by reference.** Compound values (blocks, maps, contexts) are shared. `copy` for independence is explicit.
4. **Strings are immutable.** `append` on strings is an error. Use `join`/`rejoin`.
5. **`load` unifies modules, config, and save files.** `load/eval` replaces `require` (evaluate + freeze + cache). `load` returns mutable data. `load/freeze` returns immutable data. One word, one codepath, Kintsugi literal syntax as the universal data format.
6. **Lua only.** JS and WASM dropped. Zero-dependency Lua output.
7. **Dialects are scoped vocabularies.** Not functions that hand-parse blocks. A dialect changes what words mean inside its block. The compiler is a dialect.
8. **Sequential composition over recursive nesting.** Dialects should compose as pipelines. Nesting is supported but not encouraged.
9. **Prototypes are immutable, instances are mutable.** `object [...]` → `object!` (frozen blueprint). `make Prototype [...]` → `context!` (living state).
10. **Dialect blocks are inert data.** The parent scope never evaluates a dialect's block. Set-words inside a dialect block are interpreted by the dialect, not by the parent evaluator. No namespace collision, no write-through, no set-word bleeding.
11. **Core dialects are global, domain dialects are imported.** `loop`, `parse`, `match`, `object` live in the global context. `entity`, `scene`, `tween` come from `load/eval`. Game dialects don't pollute the language namespace.
12. **Explicit primitives, compositional DWIM.** Small explicit functions at the base. Users build polymorphic wrappers on top via `match` on types. If failure modes differ, the words differ.
13. **Hot-reload via lazy dialect evaluation.** Interpreter evaluates dialects at runtime (live, reloadable). Compiler resolves dialects at compile time (static, lean). Same source, different execution strategy. No AOT preprocessing that would kill liveness.
14. **Game dialects are the product.** The stdlib prioritizes `entity`, `scene`, `input`, `tween` over generic utilities. These are proof the architecture works and the reason to choose Kintsugi.
15. **Serialization is data only.** `save` writes scalar values, blocks, maps, and context data fields. Functions are not serialized — methods come from the prototype on reload. `save`/`load` + `make Prototype` round-trips cleanly because the object/context split already separates behavior from state.
16. **Kintsugi syntax is the data format.** No JSON, no TOML. Save files, config files, and module source are all Kintsugi literal syntax parsed by the same lexer. The language is its own serialization format.
17. **Parse returns a context, not a boolean.** Set-word captures inside parse build fields on a result context. `result/ok` for success, `result/name` for captures. Dialects never silently mutate the caller's scope.
18. **`size?` replaces `length?`.** Neutral name that works on blocks, strings, maps, and contexts. `length?` may alias it.
19. **`set` is context-aware.** Destructures blocks by position, contexts by name. Dialect results (contexts) destructure cleanly: `set [ok name] parse data [...]`.
20. **Positional ops don't work on contexts.** `first`, `last`, `pick` require ordered types. Contexts are unordered — use path access or `select`.
21. **`set!` is a first-class type.** Unordered unique collections with O(1) membership testing. Works on any value type — characters, words, integers. Used in parse for custom character classes (`charset`), and generally for flags, permissions, collision layers. Compiler optimizes representation: bit arrays for character sets, hash tables for everything else.
22. **`make` is a stamp, not delegation.** Shallow copy of all fields into a new `context!`. No link back to prototype. No prototype chain. No inheritance. Compose via embedding.
23. **`self` is a word, not magic.** Bound at `make` time. Can be passed around. Cannot be rebound (`'self` error). Inner objects shadow outer `self`.
24. **Auto-generation collisions are errors.** `Person: object [...]` generates `person!` and `make-person`. If either already exists, `'name-collision` error. No silent overwrites.
25. **Header is minimal.** `Kintsugi []` or `Kintsugi/Lua []` — marks entry point and target dialect. Block contents are optional metadata for tooling. No required fields. No fields with language-level effects.
26. **`exports` is a body-level word, not a header field.** Takes a block of words. Controls what `require`/`load/eval` returns. Absent = everything public. No re-export mechanism — forward with get-words explicitly. No underscore-prefix convention — visibility is controlled by the exports list, not naming.
27. **Circular dependencies are always errors.** Detected at file level. Dependency graph must be a DAG. Factor shared code into a third module.
28. **`rethrow` preserves original stack.** Sugar for re-raising a caught error without losing the original stack trace.
29. **`#preprocess` is the full language.** Not a limited macro system. Can `require` modules, use dialects, define local helpers. Emitted code is not evaluated during preprocessing — it's injected into the output stream. Multiple `#preprocess` blocks share a preprocessing context.
30. **`#[expr]` is inline preprocess.** Appears anywhere a value can. Cannot appear inside strings. Result replaces the expression in the AST.
31. **`platform` is a word, not extensible.** Set by the toolchain: `'script` or `'lua`. Future targets add new values.
32. **Interpreter-only features are compile-time errors.** `do`, `bind`, `compose` on dynamic blocks — using these in `Kintsugi/Lua` code fails at compile time with a helpful message and alternative suggestion. No silent omission.
33. **Type checks erased in compiled output.** Compiler uses types for optimization and specialization. No runtime checks in Lua output by default. Debug flag can emit asserts.
34. **Parse is compile-time only in compiled targets.** Rules resolve during compilation. Parse extracts data that feeds into the program. Cannot run at runtime in Lua output.

---

## Priority

Answer sections 1-6 first. These are the foundation — everything else depends on them. Sections 7-8 next — they define the error and dialect contracts. Sections 9-14 can be answered incrementally as each feature gets reimplemented.

For anything where you genuinely don't know the answer yet: write `UNDECIDED — [brief note on the tradeoff]` and move on. A spec with honest gaps is a tool. A spec with hidden assumptions is a trap.
