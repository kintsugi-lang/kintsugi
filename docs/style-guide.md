# Kintsugi Style Guide

---

## Naming

### Words

Use kebab-case for everything.

```
player-health: 100
max-speed: 12
is-alive?: true
calc-damage: function [attacker defender] [...]
```

### Predicates

End with `?`. Return `true` or `false`.

```
alive?: function [unit [unit!]] [unit/hp > 0]
empty?: function [blk [block!]] [(length blk) = 0]
```

### Types

Capitalized. Defined with `object`.

```
Unit: object [...]
Ability: object [...]
Tilemap: object [...]
```

### Constructors

Prefix with `make-`. Return an instance.

```
make-warrior: function [name [string!]] [
  make Unit [name: name hp: 100 attack: 15]
]
```

### Constants

No special naming. Use `@const` when compiling for Lua `<const>` annotation.

```
@const MAX-ROUNDS: 20
@const TILE-SIZE: 32
```

---

## Type Annotations

Annotate function parameters. This isn't ceremony - the compiler uses annotations to produce cleaner Lua output (fewer `tostring` wrappers, better field access).

```
; good - compiler knows field types, emits clean Lua
calc-damage: function [attacker [unit!] ability [ability!] defender [unit!]] [
  attacker/attack + ability/power - defender/defense
]

; bad - compiler wraps every field access in tostring()
calc-damage: function [attacker ability defender] [
  attacker/attack + ability/power - defender/defense
]
```

Annotate when the type is an object, string, integer, float, or block. Skip annotations on parameters where the type is obvious or irrelevant.

```
; good - useful annotations
apply-ability: function [user [unit!] ability [ability!] target [unit!]] [...]
count-alive: function [team [block!]] [...]
clamp: function [val [integer!] lo [integer!] hi [integer!]] [...]

; fine - type doesn't affect output quality
print-banner: function [msg] [print rejoin ["=== " msg " ==="]]
```

---

## Object Definitions

Use `field/required` and `field/optional` for typed fields. Group related fields together.

```
Unit: object [
  field/required [name [string!]]
  field/required [hp [integer!]]
  field/required [max-hp [integer!]]
  field/optional [status [string!] "normal"]
]
```

Use `fields` bulk syntax when you have many fields in two clear groups.

```
Tile: object [
  fields [
    required [
      x [integer!]
      y [integer!]
      type [string!]
    ]
    optional [
      walkable [logic!] true 
      cost [integer!] 1
    ]
  ]
]
```

### Instances

Align values in related groups of `make` calls.

```
slash:    make Ability [name: "Slash"    power: 25  kind: "physical"]
fireball: make Ability [name: "Fireball" power: 30  kind: "fire"]
heal:     make Ability [name: "Heal"     power: 20  kind: "heal"]
```

Break long `make` calls across lines. Put each field group on its own line.

```
make Unit [
  name: n  hp: 100  max-hp: 100
  attack: 15  defense: 10  speed: 8
  abilities: ["slash"]
]
```

---

## Functions

### Short functions on one line

```
alive?: function [unit [unit!]] [unit/hp > 0]
name-of: function [unit [unit!]] [unit/name]
negate: function [n [integer!]] [0 - n]
```

### Multi-line functions

Body on the next line, indented 2 spaces.

```
clamp: function [val [integer!] lo [integer!] hi [integer!]] [
  if val < lo [return lo]
  if val > hi [return hi]
  val
]
```

### Implicit return

The last expression in a function body is the return value. Use it. Reserve `return` for early exits.

```
; good - last expression is the return value
calc-damage: function [attacker [unit!] ability [ability!] defender [unit!]] [
  dmg: attacker/attack + ability/power - defender/defense
  if dmg < 1 [dmg: 1]
  dmg
]

; bad - unnecessary explicit return
calc-damage: function [attacker [unit!] ability [ability!] defender [unit!]] [
  dmg: attacker/attack + ability/power - defender/defense
  if dmg < 1 [dmg: 1]
  return dmg
]
```

### Refinements

Use refinements for optional behavior variants, not for overloading.

```
sort/by items function [x] [x/name]
random/int 6
loop/collect [for [x] in items when [x > 0] do [x * 2]]
```

---

## Control Flow

### Prefer `if` for single branches

```
if hp < 0 [hp: 0]
if empty? enemies [return none]
```

### Prefer `either` for two branches

```
allies: either is-team-a [team-a] [team-b]
```

### Prefer `match` for multiple branches

```
match ability/kind [
  ["heal"]    [heal-target user target]
  ["dot"]     [apply-dot user target]
  default     [attack-target user ability target]
]
```

### Guard clauses first

Exit early. Don't nest the main logic inside conditions.

```
; good
pick-enemy: function [enemies [block!]] [
  living: loop/collect [for [e] in enemies when [alive? e] do [e]]
  if empty? living [return none]
  pick living (random/int length living)
]

; bad - unnecessary nesting
pick-enemy: function [enemies [block!]] [
  living: loop/collect [for [e] in enemies when [alive? e] do [e]]
  either empty? living [none] [
    pick living (random/int length living)
  ]
]
```

---

## Arithmetic

No operator precedence. Left to right. Use parens when mixing operations.

```
; clear - one operation type
dmg: attacker/attack + ability/power - defender/defense

; clear - parens make mixed operations explicit
area: (width * height) + (border * 2)

; confusing - mixed operations without parens
area: width * height + border * 2    ; this is ((width * height) + border) * 2
```

---

## Blocks and Iteration

### loop/collect for filtering and mapping

```
living: loop/collect [for [u] in units when [alive? u] do [u]]
names: loop/collect [for [u] in units do [u/name]]
```

### loop/fold for accumulation

```
total: loop/fold [for [acc n] in scores do [acc + n]]
```

### Plain loop for side effects

```
loop [for [u] in units do [
  print rejoin [u/name ": " u/hp " HP"]
]]
```

### Use `when` guards over `if` inside loop bodies

```
; good
loop/collect [for [u] in units when [alive? u] do [u]]

; less good
loop/collect [for [u] in units do [
  if alive? u [u]
]]
```

---

## String Building

Use `rejoin` with a block. Break long rejoins across lines.

```
; short
print rejoin ["HP: " unit/hp "/" unit/max-hp]

; long - break at natural boundaries
print rejoin [
  "  " user/name " uses " ability/name " on " target/name
  " for " dmg " damage"
  " (" target/hp "/" target/max-hp ")"
]
```

Don't use `+` for string concatenation. It's an error by design.

---

## Indexing

Kintsugi is 1-based, matching Lua.

```
first items          ; items at index 1
second items         ; items at index 2
last items           ; items at last index
pick items 3         ; items at index 3
random/int 6         ; random integer from 1 to 6
find items "sword"   ; returns 1-based index, or none
```

---

## Comments

Use `;` comments. Explain why, not what.

```
; good - explains intent
; sort/by is ascending, so negate speed for descending
turn-order: function [all-units [block!]] [
  sort/by all-units function [u [unit!]] [negate u/speed]
]

; bad - restates the code
; sort all units by speed
turn-order: function [all-units [block!]] [
  sort/by all-units function [u [unit!]] [negate u/speed]
]
```

Use section headers for major file structure.

```
; ============================================================
; Combat helpers
; ============================================================
```

---

## File Structure

1. Header
2. Object definitions
3. Instance creation
4. Helper functions
5. Main logic

```
Kintsugi [name: 'my-game]

; --- Types ---
Unit: object [...]

; --- Data ---
warrior: make Unit [...]

; --- Functions ---
alive?: function [unit [unit!]] [...]

; --- Main ---
loop [...]
```

---

## Compilation

Kintsugi compiles to clean Lua. Write code that compiles well.

- Annotate function parameters with types
- Prefer `match` over chains of `if`/`either` - compiles to `if`/`elseif`
- Use `loop/collect` in assignment position - compiles without IIFE
- Use `sort/by` in assignment position - compiles without IIFE
- Use scalar values with `has?` - compiles to inline `==` loop

Things that are fine in the interpreter but compile poorly:
- `@parse` - interpreter-only, does not compile
- `do` on dynamic blocks - requires runtime evaluation
- `bind` / `compose` on dynamic blocks - requires runtime evaluation

---

## Don'ts

- Don't convert between `logic!` and `integer!`. Use comparisons.
- Don't compare `money!` to numbers. They're different domains.
- Don't rely on operator precedence. There is none.
- Don't use 0-based indexing. Everything is 1-based.
- Don't try to mutate strings. They're immutable. Use `rejoin`, `replace`, `uppercase`, etc.
