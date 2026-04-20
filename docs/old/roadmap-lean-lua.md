# Roadmap: Lean Lua Output

Kintsugi's relationship to Lua should be like TypeScript's to JavaScript. The language adds structure, safety, and expressiveness at dev time. The compiled output is clean, idiomatic Lua that a human could have written. No runtime library, no wrappers, no ceremony.

The goal: if you showed someone the Lua output without context, they'd think a competent Lua programmer wrote it.

---

## Principle: Same Observable Effect, Not Same Mechanism

The emitter should not replicate the interpreter's internal operations. It should produce Lua code with the same observable behavior. `tostring()` wrapping, IIFE patterns, helper functions - these are implementation details that should only appear when Lua genuinely can't express the semantics directly.

---

## Phase 1: Remove Unnecessary Wrapping **[DONE]**

### 1.1 Kill defensive `tostring()` in rejoin

Lua's `..` operator auto-coerces numbers to strings. Only booleans and nil need `tostring()`.

**Current:** `"HP: " .. tostring(hp) .. "/" .. tostring(max_hp)`
**Target:** `"HP: " .. hp .. "/" .. max_hp`

When the emitter can infer the type is numeric or string (field access on a typed object, arithmetic result, string literal), skip `tostring`. Default to `tostring` only for truly unknown types.

### 1.2 Kill unnecessary IIFE wrappers

Many constructs emit `(function() ... end)()` when a simpler Lua pattern exists.

**`if` as expression:**
- Current: `(function() if cond then return x end end)()`
- Target: `cond and x or nil` (when safe) or just hoist to a local + if/else

**`either` as expression:**
- Current: `(function() if cond then return a else return b end end)()`
- Target: `cond and a or b` (when `a` is never false/nil) or a local + if/else

**`loop/collect`:**
- Current: `(function() local r = {} ... return r end)()`
- This one is probably fine - Lua has no list comprehension. But the inner body can be tightened.

### 1.3 Kill `_add()` helper

Currently `+` on integers emits `_add(a, b)` which does `math.floor(a + b + 0.5)` to handle float drift. But integer + integer in Lua is already exact (LuaJIT uses doubles, which are exact for integers up to 2^53). The rounding is only needed for money arithmetic.

**Current:** `_add(x, 1)`
**Target:** `(x + 1)`

Only emit `_add` when one operand could be money or float.

---

## Phase 2: Idiomatic Lua Patterns **[DONE]**

### 2.1 Method calls via `:` syntax

Two mechanisms for marking methods:

**In object definitions:** `@method` tags a function so path calls emit `:` syntax.
```
Enemy: object [
  field/optional [hp [integer!] 100]
  @method damage: function [amount [integer!]] [self/hp: self/hp - amount]
]
; enemy -> damage 25  => enemy:damage(25)
```

**In bindings:** `'method` binding kind, same syntax as `'call`.
```
bindings [
  player-update "player.update" 'method 1    ; emits player:update(dt)
]
```

### 2.2 `for/in` as `ipairs` vs `pairs`

Currently `for [x] in block` always emits `ipairs`. When iterating a context or map, emit `pairs` instead.

### 2.3 `match` as clean if/elseif

Match already compiles to if/elseif. But the conditions can be tighter:
- Literal match: `x == "hello"` not `x == "hello" and true`
- Single-element patterns don't need the `and` chain
- Type matches: `type(x) == "number"` not a helper function

### 2.4 String operations as methods

Lua strings have methods. Use them.

**Current:** `_split(s, ",")` or helper function
**Target:** Could leverage Lua string patterns where applicable

---

## Phase 3: Erase Kintsugi Completely **[DONE]**

### 3.1 No prelude for simple programs

If a program uses only basic types (numbers, strings, booleans, tables), emit zero prelude. No `_NONE`, no `_add`, no `_make`, no helper functions.

Track which helpers are actually needed (already partially done via `usedHelpers`) and emit nothing when the set is empty.

### 3.2 `none` as `nil`

Currently `none` emits as a sentinel `_NONE` table to distinguish from Lua's `nil` in some contexts. For most programs, `nil` is sufficient. Only emit the sentinel when the program actually distinguishes between "missing" and "none" (rare in game code).

### 3.3 `object` as plain table

Object definitions are already plain Lua tables. `make` uses `_make` helper. But `_make` is just a shallow copy + type tag. For objects without type checking, inline the copy:

**Current:** `_make(Enemy, {hp = 100}, "enemy")`
**Target:** `{hp = 100, speed = 1.0, name = nil}` (inline all defaults + overrides)

When `is?` type checking is used, keep the `_type` tag. When it's not, skip it.

### 3.4 `freeze`/`frozen?` already erased

These are already no-ops. Good.

### 3.5 Type annotations erased

Already done for `@type`. Function parameter types are already erased. Object field types are erased. This is correct.

---

## Phase 4: Output Quality Metrics **[DONE]**

How to measure progress:

1. **Line count ratio:** Kintsugi lines vs Lua lines. Target: 1:1 or better.
2. **Helper count:** Number of prelude helpers used. Target: zero for simple programs.
3. **IIFE count:** Number of `(function() ... end)()` patterns. Each one is a missed optimization.
4. **`tostring` count:** Each unnecessary `tostring` is wasted ceremony.
5. **Readability:** Can a Lua programmer read the output without knowing Kintsugi exists?

### Test: compile combat.ktg and review

The combat sim is the benchmark. Every phase should measurably improve its compiled output. Track the output over time.

---

## Non-Goals

- **Source maps:** Not needed. Errors in compiled Lua are debugged by reading the Kintsugi source.
- **Minification:** Game runtimes don't need it. Readable output is more valuable.
- **Lua version abstraction:** Target LuaJIT and Lua 5.4 directly. Don't abstract over differences - use `#ifdef`-style platform checks where needed.
