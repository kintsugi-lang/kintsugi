# Kintsugi TODO

## Priority 1 — Tier 3: Compiled Homoiconicity

The contract: the preprocessor is for metaprogramming, the compiler is for execution.
Homoiconic words work in compiled targets when the compiler can resolve them statically.
If it can't, it's a compile error pointing the programmer to `#preprocess`.

### Lowering Pass (lower.ts)
* `compose` — walk block literal, lower each paren expression, compile error if any paren isn't statically resolvable
* `reduce` — lower each expression group in a literal block, compile error if block is a variable
* `bind` — resolve as identity when context is known at compile time, compile error otherwise
* `words-of` — emit string array literal for known contexts, runtime key extraction for unknown
* `do` — compile error: "use #preprocess for compile-time evaluation"
* Wire `all`, `any`, `apply`, `set` through lowering (these are control flow, not homoiconic — straightforward)

### Emitter Support
* Emit `compose`/`reduce`/`bind`/`words-of` results in Lua backend
* Emit runtime `words-of` helper for dynamic contexts (all targets)
* Compile error messages with "use #preprocess" guidance

### Validation
* Validation tests for each Tier 3 word (interpreter vs compiled output)
* Compile error tests for the restricted cases

## Priority 2 — K/JS Target

* K/JS backend emitter (same IR, emit-js.ts)
* JS prelude (equivalent of Lua prelude)
* Tier 3 runtime restrictions apply identically
* CLI routing for `Kintsugi/JS [...]` header
* Validation tests (interpreter vs JS output)

## Priority 3 — Polish

### Language
* sort and sort/with — sorting blocks with custom comparators
* Math functions — sqrt, power
* copy/part — refinement for partial copies
* I/O operations — read, write for file access

### Compiler Quality
* Better error messages from lowering pass (line numbers, context)

### Documentation
* Spec update — document Tier 3 compilation contract
* Spec update — document `#preprocess` as the metaprogramming bridge
