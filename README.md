# Kintsugi

Kintsugi is a homoiconic, dynamically-typed programming language with rich built-in datatypes, preprocessing, and a number of useful facilities powered by DSLs called "dialects". Influenced by REBOL, Red, Common Lisp, D, Lua, Kotlin, and Raku.

> [!CAUTION]
> This language is in active development. Things will break and explode.

```rebol
; ============================================================
; Learn Kintsugi in Y Minutes
; ============================================================
;
; Kintsugi is a homoiconic, dynamically-typed programming
; language with rich built-in datatypes, preprocessing,
; and a number of useful facilities powered by DSLs called
; "dialects".
;
; Influenced by REBOL, Red, Common Lisp, D, Lua, Kotlin, and
; Raku.
;
; Dialects (file header determines target):
;
;   Kintsugi/Script   - the base language (interpreted)
;   Kintsugi/Lua      - compiles to Lua 5.1 (Playdate, LÖVE2D)
;   Kintsugi/JS       - compiles to JavaScript
;   Kintsugi/WASM     - compiles to WebAssembly
;
; "Kintsugi" alone means Kintsugi/Script.
; Compilation targets extend Script — they never remove
; features, only add target-specific capabilities.
;
; File extensions:
;   .ktg - For all source files.
;
; ============================================================


; ============================================================
; DATATYPES
; ============================================================
; Kintsugi has many built-in datatypes. Every value carries
; its type at runtime. Type names are suffixed with !

; --- Scalars ---

my-int: 42                              ; integer!
negative: -7                            ; integer!
my-float: 3.14                          ; float!
my-char: "A"                           ; string! (single-character sugar)
my-pair: 100x200                        ; pair! (2D coordinates)
my-version: 1.2.3                       ; tuple! (versions, colors, IPs)

; --- Logic ---
; true and false are literals. on/off/yes/no are words bound
; to logic values — available as aliases in normal code, but
; usable as keywords inside dialects without collision.

a: true                                 ; logic!
b: false
c: on                                   ; same as true
d: off                                  ; same as false
e: yes                                  ; same as true
f: no                                   ; same as false

; --- None ---

empty: none                             ; none! (null/nil)

; --- Temporal ---

my-date: 2026-03-15                     ; date!
my-time: 14:30:00                       ; time!

; --- Text ---

my-string: "Hello, world"              ; string!
escaped: "Line one\nLine two"          ; \n is newline escape

; --- Identifiers & Resources ---

my-file: %path/to/file.txt             ; file!
my-url: https://example.com/api        ; url!
my-email: user@example.com             ; email!

; --- Composite ---

my-block: [1 2 "three" 4.0]            ; block! (the universal container)
nested: [[1 2] [3 4] [5 6]]            ; blocks nest freely
code-as-data: [print "I am data"]      ; code is just a block
my-paren: (1 + 2)                       ; paren! evaluates immediately: 3


; ============================================================
; VARIABLES & WORDS
; ============================================================
; Words are the primary identifiers. A prefix or suffix
; controls how the word evaluates.
;
;   word    - evaluate / lookup
;   word:   - set-word (bind a value)
;   :word   - get-word (get without calling)
;   'word   - lit-word (the symbol itself)
;   @word   - meta-word (lifecycle hooks / metamethods)
;
; The same system applies to paths:
;   path/to          - evaluate / lookup
;   path/to:         - set-path (assign through path)
;   :path/to         - get-path (get without calling)
;   'path/to         - lit-path (the path as data)

name: "Kintsugi"                        ; set-word  (bind a value)
; name                                  ; word      (evaluate / lookup)
ref: :name                              ; get-word  (get without calling)
sym: 'name                              ; lit-word  (the symbol itself)

; Words can contain letters, digits, hyphens, ?, !, _, ~
is-valid?: true
my-variable!: 42

; --- Sigils ---
; Every prefix, suffix, and punctuation character in Kintsugi
; has a fixed meaning. Nothing is arbitrary.
;
; Word prefixes (change how the word evaluates):
;   :    - get-word   (retrieve value without calling)
;   '    - lit-word   (the symbol itself, unevaluated)
;   @    - meta-word  (lifecycle hooks, runtime metadata)
;
; Word suffixes (naming conventions enforced by type):
;   :    - set-word   (bind a value)
;   !    - type name  (integer!, string!, user!, etc.)
;   ?    - predicate  (returns logic! — empty?, none?, odd?)
;
; Other sigils:
;   #    - preprocessor / compile-time (#preprocess, #[expr])
;   %    - file path  (%path/to/file.txt)
;   $    - money      ($19.99)
;   /    - path separator or refinement (obj/field, func/refine)


; ============================================================
; EVALUATION MODEL & ARITHMETIC
; ============================================================
; Kintsugi evaluates left to right with no operator precedence.
; Use parens to control evaluation order. Operators are just
; infix functions — none is special.

x: 10
y: 3
print x + y                             ; 13
print x - y                             ; 7
print x * y                             ; 30
print x / y                             ; 3.333... (/ always returns float!)
print x % y                             ; 1
print 2 + 3 * 4                         ; 20 (left to right, NOT 14)
print 2 + (3 * 4)                       ; 14 (parens force order)

; Use round for integer results from division
print round/down 10 / 3                 ; 3 (truncate toward zero)
print round 3.7                         ; 4 (nearest)
print round/up 3.2                      ; 4 (away from zero)

; --- Comparisons ---

print 5 > 3                             ; true
print 5 < 3                             ; false
print 5 = 5                             ; true
print 5 <> 3                            ; true
print 5 >= 5                            ; true
print 3 <= 5                            ; true

; --- Logic ---
; and/or are infix, short-circuit, and return the determining
; value (not just true/false).
; Only false and none are falsy. 0, "", and [] are truthy.

print not 1 = 2                         ; true
print 1 = 1 and 2 = 2                  ; true
print 1 = 2 or 2 = 2                   ; true

; Short-circuit behavior
; name: input or "anonymous"            ; default if input is falsy

; all/any — block-based short-circuit for N values
; all evaluates each expression; returns last if all truthy, first falsy otherwise
; any evaluates each expression; returns first truthy, or none
; connection: any [try-primary try-secondary try-local]
; ready: all [db-connected? cache-warm? config-loaded?]

; --- None and type errors ---
; Operations on none with mismatched types raise a type
; error. There is no silent none propagation.
;
;   none + 5  => ERROR: Expected number!, got none!
;
; Use try or attempt for safe pipelines.


; ============================================================
; CONTROL FLOW
; ============================================================

; if — evaluates block when condition is truthy
print if true [42]                      ; 42

; either — two branches, always returns a value
sign: function [n] [
  either n > 0 [1] [
    either n < 0 [-1] [0]
  ]
]

; unless — negated if
; unless empty? data [process data]     ; (illustrative)

; --- Loops ---
; loop is the only looping construct. See LOOP DIALECT below.
; For conditional loops, use loop with if/break:

; "while" pattern
n: 1
factorial: 1
loop [
  if n > 5 [break]
  factorial: factorial * n
  n: n + 1
]
print factorial                         ; 120

; "until" pattern
counter: 0
loop [
  counter: counter + 1
  if counter = 10 [break]
]
print counter                           ; 10


; ============================================================
; FUNCTIONS
; ============================================================
; The spec block inside 'function' is a dialect. Words,
; type blocks, refinements, and return: have special meaning.
;
; Type annotations are enforced at runtime — passing the
; wrong type raises a type error. A future compiler can
; trust these annotations for static optimization.

; Basic definition
add: function [a b] [a + b]

; Type constraints (enforced at call time)
add-typed: function [a [integer!] b [integer!] return: [integer!]] [
  a + b
]
; add-typed "hi" 3                      ; ERROR: a expects integer!, got string!

; Typesets for polymorphism
double: function [value [number!]] [
  value * 2
]
print double 5                          ; 10
print double 2.5                        ; 5.0

; Refinements add optional behavior
greet: function [name [string!] /loud] [
  message: join "Hello, " name
  if loud [message: uppercase message]
  print message
]

greet "world"                           ; Hello, world
greet/loud "world"                      ; HELLO, WORLD

; Functions are first-class values
operation: :add                         ; get-word grabs the function value
operation 3 4                           ; => 7

; Higher-order — pass functions with get-word
print apply :add [3 4]                  ; => 7

; Early return
clamp: function [val lo hi] [
  if val < lo [return lo]
  if val > hi [return hi]
  val
]

; Closures capture their defining context
make-adder: function [n] [function [x] [x + n]]
add5: make-adder 5
print add5 10                           ; 15


; ============================================================
; BLOCK OPERATIONS
; ============================================================

data: [10 20 30 40 50]

print length? data                      ; 5
print empty? []                         ; true
print pick data 3                       ; 30
print first data                        ; 10
print last data                         ; 50

; Membership and lookup
print has? data 30                      ; true
print index? data 30                    ; 3 (1-based)
print has? "hello world" "world"        ; true

; Select — key-value lookup in flat blocks
config: [width 800 height 600 depth 32]
print select config 'width              ; 800
print select config 'depth              ; 32

; Mutation
; insert <series> <value> <position>
; remove <series> <position-or-key>
buf: [1 2 3]
append buf 4                            ; [1 2 3 4]
insert buf 0 1                          ; insert 0 at position 1
remove buf 1                            ; remove at position 1

; Copy creates an independent block
original: [1 2 3]
clone: copy original
append clone 99
print length? original                  ; 3

; Multiple assignment
set [a b c] [1 2 3]
print a                                 ; 1
print b                                 ; 2
print c                                 ; 3

; Reduce — evaluate a block, return results as a block
x: 10
reduce [x + 1 x * 2 "hello"]           ; => [11 20 "hello"]


; ============================================================
; STRING OPERATIONS
; ============================================================
; Strings are double-quoted. Multiline strings use curly
; braces. Concatenation uses join (two values) or rejoin
; (block of values).

; --- Multiline strings ---

message: {
  Hello,
  This is a multiline string.
  It preserves line breaks.
}

; --- Interpolation via rejoin ---
; rejoin evaluates a block and joins all results into a string.

name: "Ray"
age: 30
print rejoin ["Hello, " name "!"]                ; Hello, Ray!
print rejoin [name " is " age " years old"]      ; Ray is 30 years old
print rejoin ["2 + 2 = " (2 + 2)]               ; 2 + 2 = 4

; --- String functions ---

print length? "hello"                   ; 5
print join "hello" " world"             ; hello world
print join "val: " [1 " + " 2]         ; val: 1 + 2 (block is rejoin'd)
print trim "  hello  "                  ; hello
print index? "hello world" "world"      ; 7
print has? "hello world" "world"        ; true
print split "a,b,c" ","                 ; ["a" "b" "c"]
print uppercase "hello"                 ; HELLO
print lowercase "HELLO"                 ; hello
print replace "hello world" "world" "Ray" ; hello Ray

; --- Escape sequences ---
; \n = newline, \" = quote, \\ = backslash, \t = tab

print "line one\nline two"


; ============================================================
; MAP TYPE
; ============================================================
; map! is a hash-based key-value store for fast lookup.

m: make map! [name: "Ray" age: 30 role: "developer"]

; Access
print m/name                            ; Ray
print m/age                             ; 30
print select m 'role                    ; developer

; Mutation
m/email: "ray@example.com"
remove m 'age

; Predicates
print has? m 'name                      ; true
print length? m                         ; number of key-value pairs


; ============================================================
; TYPE SYSTEM
; ============================================================
; Gradual typing. No implicit coercion. Three operations:
;
;   is?  type! value  — check (returns logic!)
;   to   type! value  — convert (scalars only, throws on failure)
;   [param [type!]]   — constrain (in function specs, enforced at call time)
;
; Type annotations on function params are enforced at runtime.
; A future compiler can trust these annotations for optimization.

; --- Introspection ---
type? 42                                ; => integer!
type? "hello"                           ; => string!
type? [1 2 3]                           ; => block!

; --- Type predicates ---
integer? 42                             ; => true
string? "hello"                         ; => true
none? none                              ; => true
function? :add                          ; => true

; --- Type checking (is?) ---
; is? checks whether a value matches a type. Works with
; built-in types, @type values, and raw parse rule blocks.
is? integer! 42                         ; => true
is? string! 42                          ; => false

; --- Type conversion (to) ---
; to converts between scalar types. It does not apply to
; composite or structural types — those are checked, not converted.
to integer! "42"                        ; => 42
to string! 42                           ; => "42"
to float! 7                             ; => 7.0
to block! "hello"                       ; => ["hello"]
to word! "hello"                        ; => word
to set-word! "x"                        ; => set-word
to lit-word! "name"                     ; => lit-word
to meta-word! "add"                     ; => meta-word
codepoint "A"                           ; => 65
from-codepoint 65                       ; => "A"
to integer! true                        ; => 1
to float! false                         ; => 0.0

; --- Built-in type unions ---
; number!     = integer! | float!
; any-word!   = word! | set-word! | get-word! | lit-word! | meta-word!
; scalar!     = integer! | float! | date! | time! | pair! | tuple!
; any-type!   = matches any type

; --- Custom types (@type) ---
; @type defines types via parse rules. Union types use |.
; Structural types use parse rule syntax (lit-words + types).
coordinate!: @type [pair! | block!]
response!: @type [string! | block! | none!]

; --- Where clauses (@type/where) ---
positive!: @type/where [integer!] [it > 0]
; f: function [x [positive!]] [x * 2]
; f 5                                   ; 10
; f -3                                  ; ERROR: x fails where clause

; --- Typed blocks ---
; Constrain element types in function params:
; sum: function [nums [block! integer!]] [...]
; sum [1 2 3]                           ; ok
; sum [1 "two" 3]                       ; ERROR: expects block! of integer!

; --- Math utilities ---
print min 3 7                           ; 3
print max 3 7                           ; 7
print abs -42                           ; 42
print negate 5                          ; -5
print odd? 7                            ; true
print even? 8                           ; true


; ============================================================
; ERROR HANDLING
; ============================================================
; Errors are raised with 'error'. Protected calls with 'try'.
; try returns a result! block with a known structure:
;   [ok: <logic!> value: <any> kind: <lit-word!|none> message: <string!|none> data: <any|none>]

; --- Raising errors ---
; error <kind:lit-word> <message:string|none> <data:any|none>

safe-divide: function [x y] [
  if y = 0 [error 'division-by-zero "cannot divide by zero" none]
  x / y
]

; --- try (protected call) ---

result: try [safe-divide 10 2]
select result 'ok                       ; true
select result 'value                    ; 5.0

result: try [safe-divide 10 0]
select result 'ok                       ; false
select result 'kind                     ; 'division-by-zero
select result 'message                  ; "cannot divide by zero"

; --- try/handle ---
; Handler receives kind, message, data.
; /handle refinement adds 1 extra arg (the handler function).

result: try/handle [safe-divide 10 0] function [kind msg data] [
  print rejoin ["Caught: " msg]
  0
]
select result 'value                    ; 0


; ============================================================
; LOOP DIALECT
; ============================================================
; loop is the only looping construct. The block inside loop
; is a dialect when it starts with 'for' or 'from'.
; Otherwise, the entire block is the body (infinite loop).
;
; Refinements:
;   loop            - side effects only, returns none
;   loop/collect    - gathers body results into a block
;   loop/fold       - accumulates: first var is accumulator,
;                     first iteration skips body and inits acc
;   loop/partition  - body is predicate; iteration values go
;                     into [truthy falsy] based on result
;
; Dialect keywords:
;   for   - declare iteration variable(s)
;   in    - the data to iterate over
;   from  - counting start value
;   to    - counting end value
;   by    - step value (default: 1 or -1 based on direction)
;   when  - guard clause (filter)
;   it    - implicit variable when for is omitted

; --- Basic iteration ---

loop [for [item] in [1 2 3 4 5] [print item]]

; --- Counting ---

loop [for [n] from 1 to 10 [print n]]

; Counting with step
loop [from 0 to 100 by 5 [print it]]

; Counting down (direction inferred)
loop [from 10 to 1 [print it]]

; --- Collecting ---

squares: loop/collect [for [n] from 1 to 5 [n * n]]
probe squares                           ; 1 4 9 16 25

; Implicit collect — no body, collects the value itself
numbers: loop/collect [from 1 to 10]    ; => [1 2 3 4 5 6 7 8 9 10]

; --- Filtering ---

evens: loop/collect [
  for [n] in [1 2 3 4 5 6 7 8]
  when [even? n]
  [n]
]
probe evens                             ; 2 4 6 8

; --- Folding ---

total: loop/fold [for [acc n] from 1 to 10 [acc + n]]
print total                             ; 55

; --- Partitioning ---

set [evens odds] loop/partition [for [x] from 1 to 8 [even? x]]
probe evens                             ; 2 4 6 8
probe odds                              ; 1 3 5 7

; --- Break inside loop ---

partial: loop/collect [
  for [x] from 1 to 5 [
    if x = 4 [break]
    x * 10
  ]
]
probe partial                           ; 10 20 30


; ============================================================
; MATCH DIALECT
; ============================================================
; Pattern matching with destructuring. First match wins.
;
; Pattern elements:
;   literal    - matches exactly (integers, strings, etc.)
;   bare word  - captures/binds the value at this position
;   type!      - matches any value of that type
;   (expr)     - evaluate expression, match against result
;   'word      - matches the literal word
;   _          - wildcard (matches anything, doesn't bind)
;   when       - guard clause
;   default:   - fallback if nothing matched

match [1 2 3] [
  [1 2 3]  [print "got 1 2 3"]
  [1 _ 3]  [print "1, anything, 3"]
  [_]      [print "catch-all"]
  default: [print "nothing matched"]
]

; Destructuring
match [10 20] [
  [0 0]   [print "origin"]
  [x 0]   [print rejoin ["x-axis at " x]]
  [0 y]   [print rejoin ["y-axis at " y]]
  [x y]   [print rejoin [x ", " y]]
]

; Type matching in patterns
; match some-value [
;   [integer!]  ["got int"]
;   [string!]   ["got string"]
;   [_]         ["other"]
; ]

; Guards
match 25 [
  [n] when [n < 13]  [print "child"]
  [n] when [n < 20]  [print "teenager"]
  [n] when [n < 65]  [print "adult"]
  [_]                [print "senior"]
]


; ============================================================
; CONTEXTS & BINDING
; ============================================================
; Contexts are local environment definitions — a set of
; words and their values. Runtime type: context!
;
; Created by:
;   context   - explicit context creation
;   function  - parameters and local words
;
; bind rebinds words in a block to resolve in a given context.
; It mutates the block in place.

; context creates a named environment
point: context [x: 10 y: 20]
point/x                                 ; => 10
point/y                                 ; => 20

; Set-path assignment works
point/x: 30
point/x                                 ; => 30

; bind rebinds words to a context
code: [x + y]
bind code point
do code                                 ; => 30

; Introspection
words-of point                          ; => [x y]


; ============================================================
; LIFECYCLE HOOKS
; ============================================================
; @enter and @exit are meta-words (type: meta-word!) that
; fire at scope boundaries inside any evaluated block.
; Meta-words are a distinct word type with the @ prefix.
;
;   @enter  - runs when entering a scope (once)
;   @exit   - runs when leaving a scope (once, always runs,
;             even on error — like finally)
;
; @exit is the primary resource cleanup mechanism.

; if true [
;   @enter [resource: acquire-lock "database"]
;   @exit  [release-lock resource]
;   result: query resource "SELECT * FROM users"
;   print result
; ]


; ============================================================
; PARSE DIALECT
; ============================================================
; Rule-based pattern matching on strings and blocks.
; One system, two modes — same combinators for both.
; The only difference is what "an element" means:
; a character in strings, a value in blocks.
;
; Parse returns logic! (true if rules matched the full input).
; Extraction uses set-word inside rules — binds into the
; caller's context.
;
; Combinators:
;   |         - ordered alternative (lowest precedence)
;   end       - match end of input
;   skip      - match any single element
;   some      - one or more matches
;   any       - zero or more matches
;   opt       - zero or one match
;   not       - negative lookahead (doesn't consume)
;   ahead     - positive lookahead (doesn't consume)
;   to        - scan to (not past) a match
;   thru      - scan through (past) a match
;   into      - descend into nested block
;   quote     - match literally (escape keywords)
;   N rule    - repeat exactly N times
;   N M rule  - repeat between N and M times
;   collect   - wraps rule; keep inside appends to collected
;   keep      - inside collect, appends matched value
;   break     - exit some/any loop with success
;   fail      - force backtracking
;   (...)     - evaluate expression as side effect
;   [...]     - sub-rule grouping
;
; String character classes:
;   alpha digit space upper lower alnum
;
; Block matching extras:
;   'word   - match literal word
;   type!   - match by datatype

; --- String parsing ---

parse "user@example.com" [
  name: some [alpha | digit | "."]
  "@"
  domain: some [alpha | digit | "." | "-"]
]
; name => "user", domain => "example.com"

; --- Block parsing ---

parse [name "Alice" age 25] [
  'name who: string!
  'age years: integer!
]
; who => "Alice", years => 25

; --- Composable rules ---
digit-run: [some digit]
date-rule: [year: digit-run "-" month: digit-run "-" day: digit-run]
parse "2026-03-15" date-rule
; year => "2026", month => "03", day => "15"

; --- Collect/keep ---
parse [1 "a" 2 "b" 3] [
  nums: collect [some [keep integer! | skip]]
]
; nums => [1 2 3]


; ============================================================
; STRUCTURAL TYPES
; ============================================================
; A type name (word!) bound to a parse rule block defines a
; structural type. Use it anywhere a type constraint is expected.
; is? is sugar for parse — returns logic!

user!: @type ['name string! 'age integer! 'roles block!]

is? user! [name "Alice" age 25 roles ["admin"]]   ; => true
is? user! [name "Alice"]                           ; => false

; Structural types work in function params
greet-user: function [u [user!]] [
  print select u 'name
]

; Structural types compose — they're just blocks.
; base!: ['name string! 'age integer!]
; admin!: [base! 'permissions block!]


; ============================================================
; ATTEMPT DIALECT
; ============================================================
; Resilient pipelines with error handling and retries.
; Each step receives the previous result as 'it'.
;
; Dialect keywords:
;   source   - initial operation
;   then     - chain step (previous result is 'it')
;   when     - guard (short-circuit to none if falsy)
;   on       - handle a named error
;   retries  - retry count on error
;   fallback - last resort
;
; Without source, returns a reusable pipeline function.

result: attempt [
  source ["  Hello, World  "]
  then   [trim it]
  then   [lowercase it]
  then   [split it ", "]
]

; Reusable pipeline (no source = function)
clean: attempt [
  when [not empty? it]
  then [trim it]
  then [lowercase it]
]
clean "  HELLO  "                       ; => "hello"
clean ""                                ; => none

; Error handling in pipelines
; result: attempt [
;   source [fetch-data url]
;   then   [process it]
;   on 'network-error [print "failed" none]
;   retries 3
;   fallback [none]
; ]


; ============================================================
; BLOCKS & HOMOICONICITY
; ============================================================
; Code is data. Data is code. Blocks hold code or data
; without evaluating. do bridges data and execution.
;
; In compiled targets, homoiconicity lives at preprocess
; time — the preprocessor is the full language, and it
; generates the static code that gets compiled.

data: [print "Hello"]

; Inspect code as data
length? data                            ; => 2
first data                              ; => 'print (a word)
second data                             ; => "Hello" (a string)

; Execute data as code
do [print "I was data, now I am running"]

; Compose — build blocks from templates
; Evaluates parens, leaves everything else as data.
target: "Alice"
code: compose [greet (target) 42]       ; => [greet "Alice" 42]

; Reduce — evaluate every expression, return results
reduce [1 + 2 3 * 4 "hello"]           ; => [3 12 "hello"]

; Construct word types programmatically
to word! "hello"                        ; => word
to set-word! "x"                        ; => set-word
to lit-word! "name"                     ; => lit-word
to meta-word! "add"                     ; => meta-word

; Generate code dynamically
do compose [(to set-word! "greeting") "hello world"]
print greeting                          ; hello world


; ============================================================
; PREPROCESSING
; ============================================================
; Preprocessing runs before evaluation. The preprocessor is
; the full Kintsugi language — not a limited macro system.
;
; Two forms:
;   #preprocess [block]  — evaluate block; emit injects code
;   #[expr]              — inline; evaluate expr, inject result
;
; Available in the preprocess context:
;   platform  - current target ('script, 'lua, 'js, 'wasm)
;   emit      - inject a block into the output program

#preprocess [
  either platform = 'script [
    emit [print "Running in Script mode"]
  ] [
    emit [print "Running on a compilation target"]
  ]
]

; Code generation — generates get-name, get-age, get-email
#preprocess [
  loop [
    for [field] in [name age email] [
      emit compose [
        (to set-word! join "get-" field) function [obj] [
          select obj (to lit-word! field)
        ]
      ]
    ]
  ]
]

; Inline preprocess — inject a value
; x: #[1 + 2]                          ; x = 3 (evaluated at preprocess time)
; y: 10 + #[3 * 4]                     ; y = 22


; ============================================================
; REQUIRE & MODULES
; ============================================================
; require loads a file, evaluates it in an isolated context,
; and returns the resulting context. The header (if present)
; is consumed — not part of the returned context.
;
; Refinements:
;   /header  - return the header block instead of the context
;
; Visibility:
;   By default, everything is public.
;   If exports: is declared in the header, only listed words
;   are visible — everything else is private.
;
; Caching: same path returns same context (no re-evaluation).
; Circular dependencies are detected and raise an error.

; math-utils: require %lib/math-utils.ktg
; math-utils/add 3 4                   ; => 7

; Header introspection
; info: require/header %lib/math-utils.ktg
; select info 'name                     ; => 'math-utils

; --- What a module file looks like ---
;
; Kintsugi [
;   name: 'math-utils
;   version: 1.0.0
;   exports: [add clamp]              ; only these are public
; ]
;
; add: function [a b] [a + b]
; clamp: function [val lo hi] [min hi max lo val]
; _helper: function [x] [x * x]      ; private (not exported)


; ============================================================
; HEADER DIALECT
; ============================================================
; Programs may begin with a header block. The header word
; is the dialect and determines the compilation target.
; Headers are optional — a headerless file is just code.
;
; Dialect words:
;   Kintsugi          — Script (interpreted)
;   Kintsugi/Lua      — compiles to Lua 5.1
;   Kintsugi/JS       — compiles to JavaScript
;   Kintsugi/WASM     — compiles to WebAssembly
;
; Header keywords:
;   name:         - module name (lit-word)
;   date:         - creation or last-modified date
;   file:         - the source file
;   version:      - semantic version (tuple!)
;   exports:      - public words (if present, all else is private)
;   modules:      - dependencies (resolved via require)

Kintsugi [
  name: 'script-spec
  date: 2026-03-19
  file: %script-spec.ktg
  version: 0.3.0
]


; ============================================================
; PUTTING IT ALL TOGETHER
; ============================================================

; --- Quicksort ---

qsort: function [blk] [
  if (length? blk) <= 1 [return blk]
  pivot: first blk
  rest: copy blk
  remove rest 1
  set [lo hi] loop/partition [for [x] in rest [x < pivot]]
  result: qsort lo
  append result pivot
  loop [for [x] in qsort hi [append result x]]
  result
]

unsorted: [3 1 4 1 5 9 2 6 5 3]
sorted: qsort unsorted
probe sorted                            ; 1 1 2 3 3 4 5 5 6 9

; --- Fibonacci ---

fib: function [n] [
  seq: [0 1]
  loop [
    from 1 to (n - 2) [
      a: pick seq ((length? seq) - 1)
      b: last seq
      append seq (a + b)
    ]
  ]
  seq
]

probe fib 10                            ; 0 1 1 2 3 5 8 13 21 34
```
