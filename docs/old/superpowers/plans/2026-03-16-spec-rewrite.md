# Script Spec Rewrite Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `specs/script-spec.ktg` to match the audit at `docs/superpowers/specs/2026-03-16-spec-audit-design.md`.

**Architecture:** Single-file rewrite of the language spec. Every section is touched but the overall structure is preserved. Changes fall into categories: string concat rewrites, none-propagation removal, loop keyword changes, attempt dialect trimming, stdlib/core reclassification, and adding missing entries (`do`, `function`, `apply`, `open`, operators).

**Tech Stack:** Plain text (.ktg file). No build, no tests — this is a specification document.

---

## Chunk 1: Sections that need no or minimal changes

These sections are correct as-is or need only string-concat fixes.

### Task 1: Header Dialect (lines 1-61)

**Files:**
- Modify: `specs/script-spec.ktg:1-61`

- [ ] **Step 1: Review** — No changes needed. Header section is already correct.

### Task 2: Datatypes (lines 64-128)

**Files:**
- Modify: `specs/script-spec.ktg:64-128`

- [ ] **Step 1: Review** — No changes needed. All datatypes are core. Curly-brace strings are kept (user reinstated them).

### Task 3: Words (lines 131-150)

**Files:**
- Modify: `specs/script-spec.ktg:131-150`

- [ ] **Step 1: Review** — No changes needed. Already correct.

### Task 4: Binding & Contexts (lines 153-181)

**Files:**
- Modify: `specs/script-spec.ktg:153-181`

- [ ] **Step 1: Review** — No changes needed. Already correct.

---

## Chunk 2: Typesets & Functions — reclassify type predicates, fix string concat

### Task 5: Typesets section (lines 184-225)

**Files:**
- Modify: `specs/script-spec.ktg:184-225`

- [ ] **Step 1: Add stdlib note to type predicates**

Change lines 212-216 from:

```
; Type predicates
integer? 42                             ; => true
number? 3.14                            ; => true
iterable? "abc"                         ; => true
none? none                              ; => true
```

To:

```
; Type predicates (stdlib — defined as type? checks)
integer? 42                             ; => true
number? 3.14                            ; => true
iterable? "abc"                         ; => true
none? none                              ; => true
```

### Task 6: Function Dialect section (lines 227-281)

**Files:**
- Modify: `specs/script-spec.ktg:227-281`

- [ ] **Step 1: Fix string concat in greet function**

Change line 255 from:

```
  message: "Hello, " + name
```

To:

```
  message: join "Hello, " name
```

- [ ] **Step 2: Note that `uppercase` is stdlib**

Change line 256 from:

```
  if loud [message: uppercase message]
```

No change needed — `uppercase` is stdlib but will be available. Leave as-is. The spec shows usage regardless of where the word lives.

---

## Chunk 3: Blocks, Eval Model, Block Ops — add `do` entry, fix none propagation

### Task 7: Blocks & Homoiconicity (lines 283-319)

**Files:**
- Modify: `specs/script-spec.ktg:283-319`

- [ ] **Step 1: Add explicit `do` documentation**

After line 295 (the compose explanation), before `data: [print "Hello"]`, add a paragraph:

```
; do evaluates a block as code. It is the bridge between
; data and execution — the fundamental operation that makes
; homoiconicity useful.
```

This is documentation only — `do` is already used in examples.

### Task 8: Evaluation Model & Arithmetic (lines 322-363)

**Files:**
- Modify: `specs/script-spec.ktg:322-363`

- [ ] **Step 1: Review** — No changes needed. Arithmetic and comparison examples are already correct. Operators are numeric-only, which is consistent.

### Task 9: Block Operations (lines 366-403)

**Files:**
- Modify: `specs/script-spec.ktg:366-403`

- [ ] **Step 1: Remove `reverse` from core mutation examples**

Change lines 386-391 from:

```
; Mutation
buf: [1 2 3]
append buf 4
insert buf 1 0
remove buf 1
reverse buf
```

To:

```
; Mutation
buf: [1 2 3]
append buf 4
insert buf 1 0
remove buf 1
```

- [ ] **Step 2: Fix `none?` usage (stdlib) in pick example**

Line 379: `print none? pick data 99` — `none?` is stdlib. Change to use `type?`:

```
print (type? pick data 99) = none!      ; true
```

### Task 10: Control Flow — remove none propagation, remove `unless` (lines 475-535)

**Files:**
- Modify: `specs/script-spec.ktg:475-535`

- [ ] **Step 1: Remove `unless` example**

Delete lines 490-493:

```
; unless — negated if
unless empty? collection [
  process collection
]
```

Add a note instead:

```
; unless (stdlib) — negated if, equivalent to: if not
```

- [ ] **Step 2: Replace none propagation section**

Replace lines 526-531:

```
; --- None propagation ---
; Operations on none produce none (no crash). This makes
; pipelines safe without explicit nil checks.

print none + 5                          ; none
print none and true                     ; none (short-circuit)
```

With:

```
; --- None and type errors ---
; Operations on none with mismatched types raise a type
; error. There is no silent none propagation.
;
;   none + 5  => ERROR: Expected number!, got none!
;
; Use explicit checks or attempt for safe pipelines.
; Short-circuit operators still work with none:

print none and true                     ; none (short-circuit)
```

---

## Chunk 4: String Operations — fix string concat, annotate stdlib words

### Task 11: String Operations section (lines 406-445)

**Files:**
- Modify: `specs/script-spec.ktg:406-445`

- [ ] **Step 1: Update section header**

Change lines 408-410 from:

```
; Strings are double-quoted. Multiline strings use curly
; braces. F-strings (f"...") interpolate paren expressions.
```

To:

```
; Strings are double-quoted. Multiline strings use curly
; braces. F-strings (f"...") interpolate paren expressions.
; String concatenation uses join, not +.
```

- [ ] **Step 2: Annotate stdlib words in string functions**

Change lines 429-439 from:

```
; --- String functions ---

print length? "hello"                   ; 5
print join "hello" " world"             ; "hello world"
print trim "  hello  "                  ; "hello"
print uppercase "hello"                 ; "HELLO"
print lowercase "HELLO"                 ; "hello"
print find "hello world" "world"        ; 7 (1-based index, or none)
print replace "hello world" "world" "Ray" ; "hello Ray"
print split "a,b,c" ","                 ; ["a" "b" "c"]
print rejoin ["hello" " " "world"]      ; "hello world"
```

To:

```
; --- String functions (core) ---

print length? "hello"                   ; 5
print join "hello" " world"             ; "hello world"
print trim "  hello  "                  ; "hello"
print find "hello world" "world"        ; 7 (1-based index, or none)
print split "a,b,c" ","                 ; ["a" "b" "c"]

; --- String functions (stdlib) ---

print uppercase "hello"                 ; "HELLO"
print lowercase "HELLO"                 ; "hello"
print replace "hello world" "world" "Ray" ; "hello Ray"
print rejoin ["hello" " " "world"]      ; "hello world"
```

---

## Chunk 5: Map, Loop Dialect — fix loop keywords

### Task 12: Map Type section (lines 448-472)

**Files:**
- Modify: `specs/script-spec.ktg:448-472`

- [ ] **Step 1: Review** — No changes needed. Map section is already correct.

### Task 13: Loop Dialect — replace ascending/descending with `by` (lines 538-686)

**Files:**
- Modify: `specs/script-spec.ktg:538-686`

- [ ] **Step 1: Update dialect keyword documentation**

Replace lines 558-573:

```
; Dialect keywords:
;   for              - declare iteration variable(s)
;   in               - the data to iterate over
;   from             - counting start value
;   to               - counting end value
;   ascending        - count up (default)
;   ascending/by X   - count up by X
;   descending       - count down
;   descending/by X  - count down by X
;   when             - guard clause (filter)
;   it               - implicit variable in counting form
;                      (when for is omitted)
;
; The last block in the dialect is always the body.
; If loop/collect has no body block, it collects the
; current iteration value implicitly.
```

With:

```
; Dialect keywords:
;   for              - declare iteration variable(s)
;   in               - the data to iterate over
;   from             - counting start value
;   to               - counting end value
;   by               - step value (default: 1 or -1 based on direction)
;   when             - guard clause (filter)
;   it               - implicit variable in counting form
;                      (when for is omitted)
;
; Direction is inferred: from <= to counts up, from > to
; counts down. Explicit by overrides the default step but
; must not contradict the direction. from N to N is one
; iteration.
;
; The last block in the dialect is always the body.
; If loop/collect has no body block, it collects the
; current iteration value implicitly.
```

- [ ] **Step 2: Fix counting with step example**

Replace lines 613-618:

```
; Counting with step
loop [
  from 0 to 100
  ascending/by 5
  [print it]
]
```

With:

```
; Counting with step
loop [
  from 0 to 100
  by 5
  [print it]
]
```

- [ ] **Step 3: Fix counting down example**

Replace lines 620-621:

```
; Counting down
loop [from 100 to 1 descending [print it]]
```

With:

```
; Counting down (direction inferred from 100 > 1)
loop [from 100 to 1 [print it]]
```

- [ ] **Step 4: Fix counting down with step example**

Replace lines 623-628:

```
; Counting down with step
loop [
  from 100 to 1
  descending/by 3
  [print it]
]
```

With:

```
; Counting down with step
loop [
  from 100 to 1
  by -3
  [print it]
]
```

- [ ] **Step 5: Fix string concat in loop index example**

Replace line 593:

```
  [print index + ": " + item]
```

With:

```
  [print f"(index): (item)"]
```

---

## Chunk 6: Match Dialect — fix string concat

### Task 14: Match Dialect (lines 689-742)

**Files:**
- Modify: `specs/script-spec.ktg:689-742`

- [ ] **Step 1: Fix string concat in destructuring examples**

Replace lines 716-718:

```
  [x 0]   [print "x-axis at " + x]     ; x captures, 0 is literal
  [0 y]   [print "y-axis at " + y]     ; 0 is literal, y captures
  [x y]   [print x + ", " + y]         ; both capture
```

With:

```
  [x 0]   [print f"x-axis at (x)"]     ; x captures, 0 is literal
  [0 y]   [print f"y-axis at (y)"]     ; 0 is literal, y captures
  [x y]   [print f"(x), (y)"]          ; both capture
```

- [ ] **Step 2: Fix string concat in parens example**

Replace line 726:

```
  [x]           [print "got " + x + " instead"]
```

With:

```
  [x]           [print f"got (x) instead"]
```

---

## Chunk 7: Error Handling — fix string concat

### Task 15: Error Handling section (lines 909-970)

**Files:**
- Modify: `specs/script-spec.ktg:909-970`

- [ ] **Step 1: Fix string concat in result checking**

Replace lines 953-957:

```
either first result [
  print "Got: " + second result
] [
  print "Error: " + second result + " - " + third result
]
```

With:

```
either first result [
  print f"Got: (second result)"
] [
  print f"Error: (second result) - (third result)"
]
```

- [ ] **Step 2: Fix string concat in log-handler**

Replace lines 963-966:

```
log-handler: function [name [lit-word!] message [string!]] [
  print "Caught " + name + ": " + message
  0
]
```

With:

```
log-handler: function [name [lit-word!] message [string!]] [
  print f"Caught (name): (message)"
  0
]
```

---

## Chunk 8: Attempt Dialect — full rewrite

### Task 16: Attempt Dialect section (lines 973-1114)

**Files:**
- Modify: `specs/script-spec.ktg:973-1114`

- [ ] **Step 1: Rewrite section header and keyword docs**

Replace lines 973-1001:

```
; ============================================================
; ATTEMPT DIALECT
; ============================================================
; A dialect for error handling and data transformation.
;
; source/then are for arbitrary operations (side effects,
; multi-step logic). map/filter/fold/limit are for common
; data transformations. Mix them freely.
;
; Dialect keywords:
;   source   - the initial operation / data source
;   then     - chain the next step (previous result is 'it')
;   map      - transform a value (result becomes 'it')
;   filter   - keep value if block is truthy, skip if falsy
;   fold     - accumulate (acc + 'it')
;   limit    - stop after N items
;   it       - the previous step's result
;   on       - handle a named error
;   retries  - how many times to retry on error
;   delay    - ms between retries
;   fallback - last resort if everything fails
;
; Without 'source', attempt returns a function! — a reusable
; pipeline description that can be applied to data later.
;
; Convention: loop/collect + attempt = stream processing.
; loop provides the iteration, attempt describes the
; per-item pipeline. Each item flows through attempt and
; loop/collect gathers the results.
```

With:

```
; ============================================================
; ATTEMPT DIALECT
; ============================================================
; A dialect for resilient operations — error handling,
; retries, and step-by-step pipelines. For data
; transformation (map, filter, fold), use loop instead.
;
; Dialect keywords:
;   source   - the initial operation / data source
;   then     - chain the next step (previous result is 'it')
;   when     - guard: if falsy, short-circuit and return none
;   it       - the previous step's result
;   on       - handle a named error
;   retries  - how many times to retry on error
;   delay    - ms between retries
;   fallback - last resort if everything fails
;
; Without 'source', attempt returns a function! — a reusable
; pipeline description that can be applied to data later.
;
; Convention: loop/collect + attempt = stream processing.
; loop provides the iteration, attempt describes the
; per-item pipeline. Each item flows through attempt and
; loop/collect gathers the results.
```

- [ ] **Step 2: Keep error handling examples as-is (lines 1003-1036)**

Lines 1003-1036 (error handling, retry policies, multiple handlers) — no changes needed. These use `source`, `then`, `on`, `retries`, `delay`, `fallback` which are all retained.

- [ ] **Step 3: Rewrite data transformation section**

Replace lines 1038-1053:

```
; --- Data transformation ---

result: attempt [
  source [range 1 100]
  map    [it * 2]
  filter [it > 50]
  limit  10
  fold   [acc + it]
]

cleaned: attempt [
  source ["  Hello, World  "]
  then   [trim it]
  then [lowercase it]
  then [split it ", "]
]
```

With:

```
; --- Pipelines with when ---
; when acts as a guard: if the condition is falsy,
; the pipeline short-circuits and returns none.

cleaned: attempt [
  source ["  Hello, World  "]
  then   [trim it]
  then   [lowercase it]
  then   [split it ", "]
]

; For data transformation over collections, use loop:
result: loop/fold [
  for [acc n]
  in loop/collect [from 1 to 100]
  when [n * 2 > 50]
  [acc + (n * 2)]
]
```

- [ ] **Step 4: Rewrite transform + error handling section**

Replace lines 1055-1065:

```
; --- Transform + error handling ---

result: attempt [
  source   [fetch-data url]
  map      [parse-row it]
  filter   [valid? it]
  fold     [append acc it]
  on 'network-error [print "failed" []]
  retries  3
  fallback [[]]
]
```

With:

```
; --- Pipeline + error handling ---

result: attempt [
  source   [fetch-data url]
  then     [parse-row it]
  when     [valid? it]
  on 'network-error [print "failed" none]
  retries  3
  fallback [none]
]
```

- [ ] **Step 5: Rewrite reusable pipelines section**

Replace lines 1067-1084:

```
; --- Reusable pipelines (no source = returns a function) ---

doubler: attempt [map [it * 2]]

big-squares: attempt [
  map    [it * it]
  filter [it > 50]
]

summarize: attempt [
  filter [it > 0]
  fold   [acc + it]
]

; Apply them
doubler range 1 10                      ; => [2 4 6 8 10 12 14 16 18 20]
big-squares range 1 20                  ; => [64 81 100 121 ... 400]
summarize [3 -1 4 -1 5 9]              ; => 21
```

With:

```
; --- Reusable pipelines (no source = returns a function) ---

validate-and-trim: attempt [
  when     [not empty? it]
  then     [trim it]
]

safe-parse: attempt [
  then     [parse-json it]
  on 'parse-error [none]
]

; Apply them
validate-and-trim "  hello  "           ; => "hello"
validate-and-trim ""                    ; => none (when short-circuits)
safe-parse "{bad json"                  ; => none (error handled)
```

- [ ] **Step 6: Rewrite stream processing section**

Replace lines 1086-1114:

```
; --- Stream processing (loop/collect + attempt) ---
; loop iterates, attempt transforms each item,
; loop/collect gathers the results.

results: loop/collect [
  for [user]
  in raw-users
  [
    attempt [
      source [user]
      then   [trim it]
      map    [parse-name it]
      filter [valid? it]
      on 'parse-error [none]
    ]
  ]
]

; Same thing with a named pipeline
clean-user: attempt [
  then   [trim it]
  map    [parse-name it]
  filter [valid? it]
]

results: loop/collect [
  for [user] in raw-users
  [clean-user user]
]
```

With:

```
; --- Stream processing (loop/collect + attempt) ---
; loop iterates, attempt handles per-item resilience,
; loop/collect gathers the results.

results: loop/collect [
  for [user]
  in raw-users
  [
    attempt [
      source [user]
      then   [trim it]
      then   [parse-name it]
      when   [valid? it]
      on 'parse-error [none]
    ]
  ]
]

; Same thing with a named pipeline
clean-user: attempt [
  then   [trim it]
  then   [parse-name it]
  when   [valid? it]
]

results: loop/collect [
  for [user] in raw-users
  [clean-user user]
]
```

---

## Chunk 9: Utility Words — reclassify as stdlib, fix string concat

### Task 17: Utility Words section (lines 1303-1316)

**Files:**
- Modify: `specs/script-spec.ktg:1303-1316`

- [ ] **Step 1: Reclassify utility words**

Replace lines 1303-1316:

```
; ============================================================
; UTILITY WORDS
; ============================================================

print min 3 7                           ; 3
print max 3 7                           ; 7
print abs -42                           ; 42
print negate 5                          ; -5
print odd? 7                            ; true
print even? 8                           ; true

; Probe — prints and returns (useful for debug pipelines)
result: probe (6 * 7)                   ; prints 42
print result                            ; 42
```

With:

```
; ============================================================
; UTILITY WORDS
; ============================================================
; probe is core. The rest are stdlib, defined in Kintsugi.

; Probe — prints and returns (useful for debug pipelines)
result: probe (6 * 7)                   ; prints 42
print result                            ; 42

; --- Stdlib utilities ---
print min 3 7                           ; 3
print max 3 7                           ; 7
print abs -42                           ; 42
print negate 5                          ; -5
print odd? 7                            ; true
print even? 8                           ; true
```

---

## Chunk 10: Putting It All Together — fix string concat, fix attempt usage

### Task 18: Full examples section (lines 1319-1389)

**Files:**
- Modify: `specs/script-spec.ktg:1319-1389`

- [ ] **Step 1: Review quicksort** — No changes needed. Uses only core words.

- [ ] **Step 2: Review fibonacci** — No changes needed. Uses only core words.

- [ ] **Step 3: Rewrite fetch-users to use trimmed attempt**

Replace lines 1361-1373:

```
fetch-users: function [url [url!] /max limit [integer!]] [
  attempt [
    source   [http/get url]
    then     [parse it/body [some [copy user to "^/" skip]]]
    map      [trim it]
    filter   [not empty? it]
    then     [either max [copy/part it limit] [it]]
    retries  3
    delay    500
    on 'unreachable [print "retrying..." none]
    fallback [error 'fetch-failed "could not reach server"]
  ]
]
```

With:

```
fetch-users: function [url [url!] /max limit [integer!]] [
  attempt [
    source   [http/get url]
    then     [parse it/body [some [copy user to "^/" skip]]]
    then     [trim it]
    when     [not empty? it]
    then     [either max [copy/part it limit] [it]]
    retries  3
    delay    500
    on 'unreachable [print "retrying..." none]
    fallback [error 'fetch-failed "could not reach server"]
  ]
]
```

- [ ] **Step 4: Fix string concat in final loop example**

Replace lines 1377-1388:

```
loop [
  for [user index]
  in result
  [
    if index = 1 [print "=== User List ==="]
    match user [
      ["admin" _] [print "  * " + user + " (admin)"]
      [name]      [print "  - " + name]
    ]
  ]
]
print "=== " + (length? result) + " users total ==="
```

With:

```
loop [
  for [user index]
  in result
  [
    if index = 1 [print "=== User List ==="]
    match user [
      ["admin" _] [print f"  * (user) (admin)"]
      [name]      [print f"  - (name)"]
    ]
  ]
]
print f"=== (length? result) users total ==="
```

---

## Chunk 11: Final pass and commit

### Task 19: Grep for remaining `+` string concat

- [ ] **Step 1: Search for any remaining `" +` or `+ "` patterns**

Run: `grep -n '" +\|+ "' specs/script-spec.ktg`

Fix any remaining instances by converting to `join` or f-strings.

### Task 20: Grep for removed keywords

- [ ] **Step 1: Search for `ascending`, `descending` in non-comment lines**

Run: `grep -n 'ascending\|descending' specs/script-spec.ktg`

Verify all instances are removed.

- [ ] **Step 2: Search for `map`, `filter`, `fold`, `limit` in attempt blocks**

Verify all instances in attempt contexts have been migrated to `then`/`when` or removed.

### Task 21: Commit

- [ ] **Step 1: Stage and commit**

```bash
git add specs/script-spec.ktg
git commit -m "rewrite script-spec to match core vs stdlib audit

- Replace + string concat with join/f-strings
- Remove none propagation (type errors instead)
- Replace ascending/descending with by keyword
- Trim attempt dialect: map->then, filter->when, cut fold/limit
- Reclassify stdlib words (type predicates, utilities)
- Add explicit do documentation
- Remove reverse from core mutation examples"
```
