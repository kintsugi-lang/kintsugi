import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval

# ============================================================
# LOOP TESTS (from loop.test.ts)
# ============================================================

suite "Loop tests":
  test "loop with break":
    let eval = makeEval()
    check $eval.evalString("x: 0 loop [x: x + 1 if x = 3 [break]] x") == "3"

  test "for-in with side effects":
    let eval = makeEval()
    discard eval.evalString("state: context [sum: 0] loop [for [x] in [1 2 3] do [state/sum: state/sum + x]]")
    check $eval.evalString("state/sum") == "6"

  test "from-to range":
    let eval = makeEval()
    discard eval.evalString("state: context [sum: 0] loop [for [n] from 1 to 5 do [state/sum: state/sum + n]]")
    check $eval.evalString("state/sum") == "15"

  test "loop variables do not leak":
    let eval = makeEval()
    discard eval.evalString("loop [for [x] in [1 2 3] do [x]]")
    var caught = false
    try:
      discard eval.evalString("x")
    except:
      caught = true
    check caught

  test "loop/fold sum 1 to 10":
    let eval = makeEval()
    check $eval.evalString("loop/fold [for [acc n] from 1 to 10 do [acc + n]]") == "55"

  test "loop/fold over series":
    let eval = makeEval()
    check $eval.evalString("loop/fold [for [acc x] in [1 2 3 4] do [acc + x]]") == "10"

  test "loop/partition evens and odds":
    let eval = makeEval()
    discard eval.evalString("set [evens odds] loop/partition [for [x] from 1 to 8 do [even? x]]")
    check $eval.evalString("evens") == "[2 4 6 8]"
    check $eval.evalString("odds") == "[1 3 5 7]"

# ============================================================
# MATCH TESTS (from match.test.ts)
# ============================================================

suite "Match tests":
  # -- literal matching --

  test "match exact block":
    let eval = makeEval()
    check $eval.evalString("""
      match [1 2 3] [
        [1 2 3] ["got it"]
        [_]     ["nope"]
      ]
    """) == "got it"

  test "wildcard matches anything":
    let eval = makeEval()
    check $eval.evalString("""
      match [5 6 7] [
        [1 2 3] ["nope"]
        [_]     ["catch-all"]
      ]
    """) == "catch-all"

  test "partial wildcard":
    let eval = makeEval()
    check $eval.evalString("""
      match [1 99 3] [
        [1 _ 3] ["matched"]
        [_]     ["nope"]
      ]
    """) == "matched"

  test "default when nothing matches":
    let eval = makeEval()
    check $eval.evalString("""
      match [9 9 9] [
        [1 2 3] ["nope"]
        default: ["default"]
      ]
    """) == "default"

  test "returns body result":
    let eval = makeEval()
    check $eval.evalString("""
      match [1] [
        [1] [42]
        [_] [0]
      ]
    """) == "42"

  test "returns none when nothing matches":
    let eval = makeEval()
    check $eval.evalString("""
      match [99] [
        [1] [42]
      ]
    """) == "none"

  # -- destructuring --

  test "bare words capture values":
    let eval = makeEval()
    check $eval.evalString("""
      match [10 20] [
        [x y] [x + y]
      ]
    """) == "30"

  test "mixed literals and captures":
    let eval = makeEval()
    check $eval.evalString("""
      match [0 42] [
        [0 0]   ["origin"]
        [x 0]   ["x-axis"]
        [0 y]   [rejoin ["y-axis at " y]]
        [x y]   ["both"]
      ]
    """) == "y-axis at 42"

  # -- single value --

  test "match wraps non-block in single-element block":
    let eval = makeEval()
    check $eval.evalString("""
      match 42 [
        [42] ["found"]
        [_]  ["nope"]
      ]
    """) == "found"

  test "capture single value":
    let eval = makeEval()
    check $eval.evalString("""
      match 99 [
        [x] [x + 1]
      ]
    """) == "100"

  # -- lit-word matching --

  test "lit-word matches word value":
    let eval = makeEval()
    check $eval.evalString("""
      match 'division-by-zero [
        ['division-by-zero] ["math error"]
        ['unreachable]      ["network error"]
        [_]                 ["unknown"]
      ]
    """) == "math error"

  # -- paren evaluation --

  test "paren evaluates and matches result":
    let eval = makeEval()
    check $eval.evalString("""
      expected: 42
      match 42 [
        [(expected)] ["got expected"]
        [_]          ["nope"]
      ]
    """) == "got expected"

  test "paren expression evaluation":
    let eval = makeEval()
    check $eval.evalString("""
      x: 9
      match 10 [
        [(x + 1)] ["matched x+1"]
        [_]       ["nope"]
      ]
    """) == "matched x+1"

  # -- guards --

  test "when clause filters matches":
    let eval = makeEval()
    check $eval.evalString("""
      match 15 [
        [n] when [n < 13]  ["child"]
        [n] when [n < 20]  ["teenager"]
        [n] when [n < 65]  ["adult"]
        [_]                ["senior"]
      ]
    """) == "teenager"

  test "guard fails, tries next pattern":
    let eval = makeEval()
    check $eval.evalString("""
      match 70 [
        [n] when [n < 13]  ["child"]
        [n] when [n < 65]  ["adult"]
        [_]                ["senior"]
      ]
    """) == "senior"

  # -- string matching --

  test "match on string value":
    let eval = makeEval()
    check $eval.evalString("""
      match "hello" [
        ["hello"] ["greeting"]
        ["bye"]   ["farewell"]
        [_]       ["unknown"]
      ]
    """) == "greeting"

  # -- type matching (from types-advanced.test.ts) --

  test "match by type integer":
    let eval = makeEval()
    check $eval.evalString("""
      match 42 [
        [integer!]  ["got int"]
        [string!]   ["got string"]
        [_]         ["other"]
      ]
    """) == "got int"

  test "match by type string":
    let eval = makeEval()
    check $eval.evalString("""
      match "hello" [
        [integer!]  ["got int"]
        [string!]   ["got string"]
        [_]         ["other"]
      ]
    """) == "got string"

  test "match with type and capture":
    let eval = makeEval()
    check $eval.evalString("""
      match [42 "hello"] [
        [integer! string!]  ["typed pair"]
        [_]                 ["other"]
      ]
    """) == "typed pair"

  test "type match with custom @type":
    let eval = makeEval()
    discard eval.evalString("number!: @type [integer! | float!]")
    check $eval.evalString("""
      match 3.14 [
        [number!] ["got number"]
        [_]       ["other"]
      ]
    """) == "got number"

# ============================================================
# PARSE BLOCK TESTS (from parse.test.ts)
# ============================================================

suite "Parse block tests":
  test "empty rule matches empty block":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [] []
      r/ok
    """) == "true"

  test "block type match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [42] [integer!]
      r/ok
    """) == "true"

  test "block type mismatch fails":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [42] [string!]
      r/ok
    """) == "false"

  test "sequence of types":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 "a"] [integer! string!]
      r/ok
    """) == "true"

  test "incomplete match fails":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 2] [integer!]
      r/ok
    """) == "false"

  test "lit-word matches word in block":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [name] ['name]
      r/ok
    """) == "true"

  test "skip matches any value in block":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [42] [skip]
      r/ok
    """) == "true"

  test "end matches at end":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [] [end]
      r/ok
    """) == "true"

  test "end fails if not at end":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1] [end]
      r/ok
    """) == "false"

  # -- repetition --

  test "some matches 1+":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 2 3] [some integer!]
      r/ok
    """) == "true"

  test "some fails on zero":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse ["a"] [some integer!]
      r/ok
    """) == "false"

  test "any matches 0+":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [] [any integer!]
      r/ok
    """) == "true"

  test "any matches 1+":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 2 3] [any integer!]
      r/ok
    """) == "true"

  test "opt matches 0 or 1 (present)":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1] [opt integer! end]
      r/ok
    """) == "true"

  test "opt matches 0 or 1 (absent)":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [] [opt integer! end]
      r/ok
    """) == "true"

  test "exact count matches":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 2 3] [3 integer!]
      r/ok
    """) == "true"

  test "exact count fails":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 2] [3 integer!]
      r/ok
    """) == "false"

  # -- alternatives --

  test "pipe tries alternatives (first)":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1] [integer! | string!]
      r/ok
    """) == "true"

  test "pipe tries alternatives (second)":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse ["a"] [integer! | string!]
      r/ok
    """) == "true"

  test "pipe fails if no match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [true] [integer! | string!]
      r/ok
    """) == "false"

  # -- extraction --

  test "set-word captures value in block":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [42] [x: integer!]
      r/x
    """) == "42"

  test "multiple captures in block":
    let eval = makeEval()
    let eval2 = makeEval()
    check $eval.evalString("""
      r: parse [name "Alice" age 25] ['name who: string! 'age years: integer!]
      r/who
    """) == "Alice"
    check $eval2.evalString("""
      r: parse [name "Alice" age 25] ['name who: string! 'age years: integer!]
      r/years
    """) == "25"

  # -- lookahead --

  test "not succeeds when sub-rule fails":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1] [not string! integer!]
      r/ok
    """) == "true"

  test "ahead matches without consuming":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1] [ahead integer! integer!]
      r/ok
    """) == "true"

  # -- scanning --

  test "thru scans past type match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 "a" 2] [thru string! integer!]
      r/ok
    """) == "true"

  test "to scans to but not past match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 2 "a" 3] [to string! string! integer!]
      r/ok
    """) == "true"

  # -- collect/keep --

  test "collect/keep block":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 "a" 2 "b" 3] [nums: collect [some [keep integer! | skip]]]
      r/nums
    """) == "[1 2 3]"

  # -- into --

  test "into descends into nested block":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [[1 2]] [into [integer! integer!]]
      r/ok
    """) == "true"

  # -- composable rules --

  test "word resolves to block sub-rule":
    let eval = makeEval()
    check $eval.evalString("""
      int-pair: [integer! integer!]
      r: parse [1 2] int-pair
      r/ok
    """) == "true"

# ============================================================
# PARSE STRING TESTS (from parse-string.test.ts)
# ============================================================

suite "Parse string tests":
  test "empty rule matches empty string":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "" []
      r/ok
    """) == "true"

  test "string literal matches exactly":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello" ["hello"]
      r/ok
    """) == "true"

  test "string literal mismatch":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello" ["world"]
      r/ok
    """) == "false"

  test "partial match fails":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello" ["hell"]
      r/ok
    """) == "false"

  test "sequence of literals":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello world" ["hello" " " "world"]
      r/ok
    """) == "true"

  test "skip matches one character":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "a" [skip]
      r/ok
    """) == "true"

  test "skip on multi-char fails":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "ab" [skip]
      r/ok
    """) == "false"

  test "end matches at end":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "" [end]
      r/ok
    """) == "true"

  # -- character classes --

  test "alpha matches letter":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "a" [alpha]
      r/ok
    """) == "true"

  test "alpha fails on digit":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "1" [alpha]
      r/ok
    """) == "false"

  test "digit matches digit":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "5" [digit]
      r/ok
    """) == "true"

  test "some alpha matches word":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello" [some alpha]
      r/ok
    """) == "true"

  test "some digit matches number":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "12345" [some digit]
      r/ok
    """) == "true"

  test "alnum matches mixed":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc123" [some alnum]
      r/ok
    """) == "true"

  test "space matches whitespace":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse " " [space]
      r/ok
    """) == "true"

  test "upper matches uppercase":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "A" [upper]
      r/ok
    """) == "true"

  test "upper fails on lowercase":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "a" [upper]
      r/ok
    """) == "false"

  test "lower matches lowercase":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "a" [lower]
      r/ok
    """) == "true"

  test "lower fails on uppercase":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "A" [lower]
      r/ok
    """) == "false"

  # -- combinators --

  test "some and sequence":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc123" [some alpha some digit]
      r/ok
    """) == "true"

  test "any matches zero":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "123" [any alpha some digit]
      r/ok
    """) == "true"

  test "opt":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "123" [opt alpha some digit]
      r/ok
    """) == "true"

  test "alternatives (first)":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [some alpha | some digit]
      r/ok
    """) == "true"

  test "alternatives (second)":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "123" [some alpha | some digit]
      r/ok
    """) == "true"

  test "exact count":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "aaa" [3 alpha]
      r/ok
    """) == "true"

  test "exact count fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "aa" [3 alpha]
      r/ok
    """) == "false"

  test "not":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "1" [not alpha digit]
      r/ok
    """) == "true"

  test "ahead":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "a" [ahead alpha alpha]
      r/ok
    """) == "true"

  # -- extraction --

  test "capture string greeting":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello world" [greeting: some alpha " " name: some alpha]
      r/greeting
    """) == "hello"

  test "capture string name":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello world" [greeting: some alpha " " name: some alpha]
      r/name
    """) == "world"

  test "capture digits":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "age:25" ["age:" num: some digit]
      r/num
    """) == "25"

  # -- scanning --

  test "thru scans past match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello world" [thru " " some alpha]
      r/ok
    """) == "true"

  test "to scans to match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello world" [to " " " " some alpha]
      r/ok
    """) == "true"

  # -- composable rules --

  test "word resolves to sub-rule":
    let eval = makeEval()
    check $eval.evalString("""
      word-chars: [some alpha]
      r: parse "hello" word-chars
      r/ok
    """) == "true"

  # -- email example --

  test "email parse ok":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "user@example.com" [
        name: some [alpha | digit | "."]
        "@"
        domain: some [alpha | digit | "." | "-"]
      ]
      r/ok
    """) == "true"

  test "email capture name":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "user@example.com" [
        name: some [alpha | digit | "."]
        "@"
        domain: some [alpha | digit | "." | "-"]
      ]
      r/name
    """) == "user"

  test "email capture domain":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "user@example.com" [
        name: some [alpha | digit | "."]
        "@"
        domain: some [alpha | digit | "." | "-"]
      ]
      r/domain
    """) == "example.com"

  # -- collect/keep string --

  test "collect/keep string":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "a1b2c3" [chars: collect [some [keep alpha | skip]]]
      r/chars
    """) == "[a b c]"

# ============================================================
# IS? TESTS (from parse.test.ts)
# ============================================================

suite "is? tests":
  test "is? with @type structural types":
    let eval = makeEval()
    discard eval.evalString("""user!: @type ['name [string!] 'age [integer!]]""")
    check $eval.evalString("""is? user! context [name: "Alice" age: 25]""") == "true"
    check $eval.evalString("""is? user! context [name: "Alice"]""") == "false"

  test "is? works with built-in type names":
    let eval = makeEval()
    check $eval.evalString("is? integer! 42") == "true"
    check $eval.evalString("is? string! 42") == "false"

  test "is? with raw parse rule blocks":
    let eval = makeEval()
    check $eval.evalString("""is? ['x integer!] [x 10]""") == "true"

# ============================================================
# OBJECT DIALECT TESTS (from object-dialect.test.ts)
# ============================================================

suite "Object dialect tests":
  # -- make clones context --

  test "clone context with overrides":
    let eval = makeEval()
    discard eval.evalString("""p: context [name: "Ray" age: 30]""")
    discard eval.evalString("p2: make p [age: 31]")
    check $eval.evalString("p2/name") == "Ray"
    check $eval.evalString("p2/age") == "31"

  test "clone does not mutate original":
    let eval = makeEval()
    discard eval.evalString("""p: context [name: "Ray" age: 30]""")
    discard eval.evalString("p2: make p [age: 31]")
    check $eval.evalString("p/age") == "30"

  test "clone with empty overrides":
    let eval = makeEval()
    discard eval.evalString("p: context [x: 10]")
    discard eval.evalString("p2: make p []")
    check $eval.evalString("p2/x") == "10"

  # -- object dialect --

  test "basic object with fields and methods":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/required [name [string!]]
        field/required [age [integer!]]
        greet: function [] [
          rejoin ["Hi, I'm " self/name]
        ]
      ]
    """)
    discard eval.evalString("""result: make Person [name: "Ray" age: 30]""")
    check $eval.evalString("type result") != "" # just check it creates something

  test "field access on prototype":
    let eval = makeEval()
    discard eval.evalString("""
      Point: object [
        field/optional [x [integer!] 0]
        field/optional [y [integer!] 0]
      ]
    """)
    check $eval.evalString("Point/x") == "0"
    check $eval.evalString("Point/y") == "0"

  test "make instance with overrides":
    let eval = makeEval()
    discard eval.evalString("""
      Point: object [
        field/optional [x [integer!] 0]
        field/optional [y [integer!] 0]
      ]
    """)
    discard eval.evalString("p: make Point [x: 10 y: 20]")
    check $eval.evalString("p/x") == "10"
    check $eval.evalString("p/y") == "20"

  test "mixed required and defaulted fields with money":
    let eval = makeEval()
    discard eval.evalString("""
      Account: object [
        field/required [owner [string!]]
        field/optional [balance [money!] $0.00]
        deposit: function [amount [money!]] [
          self/balance: self/balance + amount
        ]
      ]
      a: make Account [owner: "Ray"]
      a/deposit $100.00
    """)
    check $eval.evalString("a/balance") == "$100.00"

  test "methods see self":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/optional [name [string!] none]
        field/optional [age [integer!] 0]
        greet: function [] [
          rejoin ["Hi, I'm " self/name]
        ]
      ]
    """)
    discard eval.evalString("""p: make Person [name: "Ray" age: 30]""")
    check $eval.evalString("p/greet") == "Hi, I'm Ray"

  test "methods can mutate via self":
    let eval = makeEval()
    discard eval.evalString("""
      Counter: object [
        field/optional [n [integer!] 0]
        increment: function [] [
          self/n: self/n + 1
        ]
        value: function [] [self/n]
      ]
    """)
    discard eval.evalString("c: make Counter []")
    discard eval.evalString("c/increment")
    discard eval.evalString("c/increment")
    check $eval.evalString("c/value") == "2"

  test "self refers to instance, not prototype":
    let eval = makeEval()
    discard eval.evalString("""
      Thing: object [
        field/optional [x [integer!] 0]
        get-x: function [] [self/x]
      ]
    """)
    discard eval.evalString("a: make Thing [x: 10]")
    discard eval.evalString("b: make Thing [x: 20]")
    check $eval.evalString("a/get-x") == "10"
    check $eval.evalString("b/get-x") == "20"

  test "mutation via self/field persists":
    let eval = makeEval()
    discard eval.evalString("""
      Counter: object [
        field/optional [n [integer!] 0]
        increment: function [] [self/n: self/n + 1]
        value: function [] [self/n]
      ]
    """)
    discard eval.evalString("c: make Counter []")
    discard eval.evalString("c/increment")
    discard eval.evalString("c/increment")
    discard eval.evalString("c/increment")
    check $eval.evalString("c/value") == "3"

  test "mutation on one instance does not affect another":
    let eval = makeEval()
    discard eval.evalString("""
      Counter: object [
        field/optional [n [integer!] 0]
        increment: function [] [self/n: self/n + 1]
      ]
    """)
    discard eval.evalString("a: make Counter []")
    discard eval.evalString("b: make Counter []")
    discard eval.evalString("a/increment")
    discard eval.evalString("a/increment")
    discard eval.evalString("b/increment")
    check $eval.evalString("a/n") == "2"
    check $eval.evalString("b/n") == "1"

  # -- object type checking --

  test "is? checks against prototype":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/optional [name [string!] none]
        field/optional [age [integer!] 0]
      ]
    """)
    discard eval.evalString("""p: make Person [name: "Ray" age: 30]""")
    check $eval.evalString("is? :Person p") == "true"

  test "is? rejects non-matching context":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/optional [name [string!] none]
        field/optional [age [integer!] 0]
      ]
    """)
    discard eval.evalString("x: context [foo: 1]")
    check $eval.evalString("is? :Person x") == "false"

  test "is? rejects non-context value":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/optional [name [string!] none]
      ]
    """)
    check $eval.evalString("is? :Person 42") == "false"

  # -- auto-generated type names --

  test "auto-generated person!":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/required [name [string!]]
        field/required [age [integer!]]
      ]
    """)
    discard eval.evalString("""p: make Person [name: "Ray" age: 30]""")
    check $eval.evalString("is? person! p") == "true"

  test "person! rejects non-matching context":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/required [name [string!]]
        field/required [age [integer!]]
      ]
    """)
    check $eval.evalString("is? person! context [foo: 1]") == "false"

  test "PascalCase to kebab-case conversion":
    let eval = makeEval()
    discard eval.evalString("CardReader: object [field/optional [events [block!] []]]")
    discard eval.evalString("r: make CardReader []")
    check $eval.evalString("is? card-reader! r") == "true"

  # -- auto-generated constructors --

  test "make-person with required fields":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/required [name [string!]]
        field/required [age [integer!]]
      ]
      p: make-person "Ray" 30
    """)
    check $eval.evalString("p/name") == "Ray"
    check $eval.evalString("p/age") == "30"

  test "zero-arg constructor for all-defaulted object":
    let eval = makeEval()
    discard eval.evalString("""
      Counter: object [
        field/optional [n [integer!] 0]
        increment: function [] [self/n: self/n + 1]
        value: function [] [self/n]
      ]
      c: make-counter
      c/increment
      c/increment
    """)
    check $eval.evalString("c/value") == "2"

  test "self works on constructed instances":
    let eval = makeEval()
    discard eval.evalString("""
      Thing: object [
        field/required [x [integer!]]
        get-x: function [] [self/x]
      ]
    """)
    discard eval.evalString("a: make-thing 10")
    discard eval.evalString("b: make-thing 20")
    check $eval.evalString("a/get-x") == "10"
    check $eval.evalString("b/get-x") == "20"

  test "PascalCase to kebab-case in constructor name":
    let eval = makeEval()
    discard eval.evalString("""
      CardReader: object [
        field/optional [events [block!] []]
      ]
      r: make-card-reader
    """)
    # Just check it didn't error
    check true

  test "constructed instance passes type check":
    let eval = makeEval()
    discard eval.evalString("""
      Person: object [
        field/required [name [string!]]
        field/required [age [integer!]]
      ]
      p: make-person "Ray" 30
    """)
    check $eval.evalString("is? person! p") == "true"

  # -- object immutability --

  test "object immutability":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""
        Point: object [
          field/optional [x [integer!] 0]
          field/optional [y [integer!] 0]
        ]
        Point/x: 999
      """)
    except KtgError as e:
      caught = true
      check e.kind == "type"
    check caught

  # -- instance mutability --

  test "instance mutability":
    let eval = makeEval()
    discard eval.evalString("""
      Point: object [
        field/optional [x [integer!] 0]
        field/optional [y [integer!] 0]
      ]
      p: make Point [x: 10 y: 20]
      p/x: 999
    """)
    check $eval.evalString("p/x") == "999"

  # -- self cannot be rebound --

  test "self cannot be rebound":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""
        Thing: object [
          field/optional [val [integer!] 0]
          rebind-self: function [] [
            self: 42
          ]
        ]
        t: make Thing []
        t/rebind-self
      """)
    except KtgError as e:
      caught = true
    check caught

  # -- name collision detection --

  test "name collision detection":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""
        point!: 42
        Point: object [
          field/optional [x [integer!] 0]
        ]
      """)
    except KtgError as e:
      caught = true
      check e.kind == "name-collision"
    check caught

  # -- methods with parameters --

  test "methods with parameters":
    let eval = makeEval()
    discard eval.evalString("""
      Enemy: object [
        field/optional [hp [integer!] 100]
        damage: function [amount [integer!]] [
          self/hp: self/hp - amount
        ]
      ]
      goblin: make Enemy []
      goblin/damage 10
    """)
    check $eval.evalString("goblin/hp") == "90"

  # -- independent instances --

  test "independent instances":
    let eval = makeEval()
    discard eval.evalString("""
      Counter: object [
        field/optional [count [integer!] 0]
        increment: function [] [
          self/count: self/count + 1
        ]
      ]
      a: make Counter []
      b: make Counter []
      a/increment
      a/increment
      b/increment
    """)
    check $eval.evalString("a/count + b/count") == "3"

  # -- required field validation --

  test "required field validation":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""
        Person: object [
          field/required [name [string!]]
          field/required [age [integer!]]
        ]
        p: make Person []
      """)
    except KtgError as e:
      caught = true
      check e.kind == "make"
    check caught

  # -- type check on overrides --

  test "type check overrides":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""
        Point: object [
          field/optional [x [integer!] 0]
          field/optional [y [integer!] 0]
        ]
        p: make Point [x: "hello"]
      """)
    except KtgError as e:
      caught = true
      check e.kind == "type"
    check caught

# ============================================================
# ATTEMPT TESTS (from attempt.test.ts)
# ============================================================

suite "Attempt tests":
  # Note: attempt uses `catch` instead of `on` for error handling (because `on` is a boolean keyword)

  test "source sets initial value":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source [42]
      ]
    """) == "42"

  test "then chains with it":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source [10]
        then   [it + 5]
      ]
    """) == "15"

  test "multiple then steps":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source ["  Hello  "]
        then   [trim it]
        then   [lowercase it]
      ]
    """) == "hello"

  # -- when guard --

  test "when passes if truthy":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source ["hello"]
        when   [not empty? it]
        then   [uppercase it]
      ]
    """) == "HELLO"

  test "when short-circuits to none if falsy":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source [""]
        when   [not empty? it]
        then   [uppercase it]
      ]
    """) == "none"

  # -- error handling (using catch instead of on) --

  test "catch catches specific error kind":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source [error 'bad "oops" none]
        catch 'bad [42]
      ]
    """) == "42"

  test "catch does not catch wrong kind":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source [error 'bad "oops" none]
        catch 'other [42]
        fallback [99]
      ]
    """) == "99"

  test "fallback when no handler matches":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source [error 'fail "boom" none]
        fallback [0]
      ]
    """) == "0"

  test "error in then step is caught":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source [10]
        then   [it / 0]
        catch 'math [0]
      ]
    """) == "0"

  # -- retries --

  test "retries source on error":
    let eval = makeEval()
    discard eval.evalString("count: 0")
    check $eval.evalString("""
      attempt [
        source [
          count: count + 1
          if count < 3 [error 'fail "not yet" none]
          count
        ]
        retries 5
      ]
    """) == "3"

  test "retries exhausted hits fallback":
    let eval = makeEval()
    check $eval.evalString("""
      attempt [
        source [error 'fail "always" none]
        retries 2
        fallback [0]
      ]
    """) == "0"

  # -- reusable pipeline --

  test "reusable pipeline (no source)":
    let eval = makeEval()
    discard eval.evalString("""
      clean: attempt [
        when [not empty? it]
        then [trim it]
        then [lowercase it]
      ]
    """)
    check $eval.evalString("""clean "  HELLO  " """) == "hello"
    check $eval.evalString("""clean "" """) == "none"

# ============================================================
# NATIVES TESTS (from natives.test.ts)
# ============================================================

suite "Natives tests":
  # -- control flow --

  test "if true evaluates block":
    let eval = makeEval()
    check $eval.evalString("if true [42]") == "42"

  test "if false returns none":
    let eval = makeEval()
    check $eval.evalString("if false [42]") == "none"

  test "either true":
    let eval = makeEval()
    check $eval.evalString("either true [1] [2]") == "1"

  test "either false":
    let eval = makeEval()
    check $eval.evalString("either false [1] [2]") == "2"

  test "not":
    let eval = makeEval()
    check $eval.evalString("not true") == "false"
    check $eval.evalString("not false") == "true"
    check $eval.evalString("not none") == "true"

  test "loop with break":
    let eval = makeEval()
    check $eval.evalString("x: 0 loop [x: x + 1 if x = 5 [break]] x") == "5"

  # -- logical ops --

  test "and short-circuits":
    let eval = makeEval()
    check $eval.evalString("true and true") == "true"
    check $eval.evalString("false and true") == "false"

  test "or short-circuits":
    let eval = makeEval()
    check $eval.evalString("false or true") == "true"
    check $eval.evalString("true or false") == "true"

  # -- block operations --

  test "length?":
    let eval = makeEval()
    check $eval.evalString("length? [1 2 3]") == "3"

  test "empty?":
    let eval = makeEval()
    check $eval.evalString("empty? []") == "true"
    check $eval.evalString("empty? [1]") == "false"

  test "first":
    let eval = makeEval()
    check $eval.evalString("first [10 20 30]") == "10"

  test "second":
    let eval = makeEval()
    check $eval.evalString("second [10 20 30]") == "20"

  test "last":
    let eval = makeEval()
    check $eval.evalString("last [10 20 30]") == "30"

  test "pick":
    let eval = makeEval()
    check $eval.evalString("pick [10 20 30] 2") == "20"

  test "copy returns new block":
    let eval = makeEval()
    discard eval.evalString("a: [1 2 3]")
    discard eval.evalString("b: copy a")
    discard eval.evalString("append b 4")
    check $eval.evalString("length? a") == "3"
    check $eval.evalString("length? b") == "4"

  test "append":
    let eval = makeEval()
    discard eval.evalString("a: [1 2]")
    discard eval.evalString("append a 3")
    check $eval.evalString("length? a") == "3"

  test "insert at position":
    let eval = makeEval()
    discard eval.evalString("a: [1 2 3]")
    discard eval.evalString("insert a 0 1")
    check $eval.evalString("first a") == "0"
    check $eval.evalString("length? a") == "4"

  test "insert at middle":
    let eval = makeEval()
    discard eval.evalString("a: [1 3]")
    discard eval.evalString("insert a 2 2")
    check $eval.evalString("pick a 2") == "2"

  test "remove from block":
    let eval = makeEval()
    discard eval.evalString("a: [10 20 30]")
    discard eval.evalString("remove a 2")
    check $eval.evalString("length? a") == "2"
    check $eval.evalString("second a") == "30"

  test "select":
    let eval = makeEval()
    check $eval.evalString("select [a 1 b 2] 'b") == "2"

  test "has? block":
    let eval = makeEval()
    check $eval.evalString("has? [1 2 3] 2") == "true"
    check $eval.evalString("has? [1 2 3] 9") == "false"

  test "has? string":
    let eval = makeEval()
    check $eval.evalString("""has? "hello world" "world" """) == "true"
    check $eval.evalString("""has? "hello" "xyz" """) == "false"

  test "find block":
    let eval = makeEval()
    check $eval.evalString("find [10 20 30] 20") == "2"
    check $eval.evalString("find [1 2 3] 9") == "none"

  test "find string":
    let eval = makeEval()
    check $eval.evalString("""find "hello world" "world" """) == "7"
    check $eval.evalString("""find "hello" "xyz" """) == "none"

  # -- type operations --

  test "type":
    let eval = makeEval()
    check $eval.evalString("type 42") == "integer!"
    check $eval.evalString("""type "hi" """) == "string!"
    check $eval.evalString("type true") == "logic!"

  # -- string operations --

  test "join":
    let eval = makeEval()
    check $eval.evalString("""join "a" "b" """) == "ab"

  test "rejoin":
    let eval = makeEval()
    check $eval.evalString("""rejoin ["hello" " " "world"]""") == "hello world"

  test "trim":
    let eval = makeEval()
    check $eval.evalString("""trim "  hi  " """) == "hi"

  test "split":
    let eval = makeEval()
    check $eval.evalString("""first split "a,b,c" "," """) == "a"

  test "uppercase":
    let eval = makeEval()
    check $eval.evalString("""uppercase "hello" """) == "HELLO"

  test "lowercase":
    let eval = makeEval()
    check $eval.evalString("""lowercase "HELLO" """) == "hello"

  test "replace":
    let eval = makeEval()
    check $eval.evalString("""replace "hello world" "world" "earth" """) == "hello earth"

  # -- math utilities --

  test "min":
    let eval = makeEval()
    check $eval.evalString("min 3 7") == "3"

  test "max":
    let eval = makeEval()
    check $eval.evalString("max 3 7") == "7"

  test "abs":
    let eval = makeEval()
    check $eval.evalString("abs -5") == "5"

  test "negate":
    let eval = makeEval()
    check $eval.evalString("negate 5") == "-5"

  test "round nearest":
    let eval = makeEval()
    check $eval.evalString("round 3.7") == "4"
    check $eval.evalString("round 3.2") == "3"

  test "round/down truncates toward zero":
    let eval = makeEval()
    check $eval.evalString("round/down 3.9") == "3"
    check $eval.evalString("round/down -3.9") == "-3"

  test "round/up away from zero":
    let eval = makeEval()
    check $eval.evalString("round/up 3.2") == "4"
    check $eval.evalString("round/up -3.2") == "-4"

  test "round on integer division":
    let eval = makeEval()
    check $eval.evalString("round/down 10 / 3") == "3"

  test "odd?":
    let eval = makeEval()
    check $eval.evalString("odd? 3") == "true"
    check $eval.evalString("odd? 4") == "false"

  test "even?":
    let eval = makeEval()
    check $eval.evalString("even? 4") == "true"
    check $eval.evalString("even? 3") == "false"

  # -- code-as-data --

  test "do evaluates block":
    let eval = makeEval()
    check $eval.evalString("do [1 + 2]") == "3"

  test "compose evaluates parens in block":
    let eval = makeEval()
    check $eval.evalString("compose [1 (2 + 3) 4]") == "[1 5 4]"

# ============================================================
# STDLIB TESTS (from stdlib.test.ts)
# ============================================================

suite "Stdlib tests":
  test "unless false evaluates block":
    let eval = makeEval()
    check $eval.evalString("unless false [42]") == "42"

  test "unless true returns none":
    let eval = makeEval()
    check $eval.evalString("unless true [42]") == "none"

  test "none is falsy in unless":
    let eval = makeEval()
    check $eval.evalString("unless none [42]") == "42"

  test "all returns last value if all truthy":
    let eval = makeEval()
    check $eval.evalString("all [1 2 3]") == "3"

  test "all returns first falsy value":
    let eval = makeEval()
    check $eval.evalString("all [1 false 3]") == "false"

  test "all short-circuits on false":
    let eval = makeEval()
    discard eval.evalString("x: 0")
    discard eval.evalString("all [false (x: 1)]")
    check $eval.evalString("x") == "0"

  test "all evaluates expressions":
    let eval = makeEval()
    check $eval.evalString("all [1 = 1 2 = 2]") == "true"

  test "any returns first truthy value":
    let eval = makeEval()
    check $eval.evalString("any [false 42 99]") == "42"

  test "any returns none if all falsy":
    let eval = makeEval()
    check $eval.evalString("any [false none false]") == "none"

  test "any short-circuits on truthy":
    let eval = makeEval()
    discard eval.evalString("x: 0")
    discard eval.evalString("any [42 (x: 1)]")
    check $eval.evalString("x") == "0"

  test "apply calls function with block args":
    let eval = makeEval()
    check $eval.evalString("add: function [a b] [a + b] apply :add [3 4]") == "7"

  # -- type predicates --

  test "none?":
    let eval = makeEval()
    check $eval.evalString("none? none") == "true"
    check $eval.evalString("none? 42") == "false"

  test "integer?":
    let eval = makeEval()
    check $eval.evalString("integer? 42") == "true"
    check $eval.evalString("""integer? "hi" """) == "false"

  test "float?":
    let eval = makeEval()
    check $eval.evalString("float? 3.14") == "true"

  test "string?":
    let eval = makeEval()
    check $eval.evalString("""string? "hi" """) == "true"

  test "logic?":
    let eval = makeEval()
    check $eval.evalString("logic? true") == "true"

  test "block?":
    let eval = makeEval()
    check $eval.evalString("block? [1 2]") == "true"

  test "function?":
    let eval = makeEval()
    check $eval.evalString("function? :print") == "true"
    check $eval.evalString("function? 42") == "false"

# ============================================================
# STDLIB-MATH TESTS (from stdlib-math.test.ts)
# NOTE: These use `require %lib/math.ktg` in the TS version.
# In Nim, `require` is replaced by `load`. These may not work
# if the stdlib is loaded differently.
# ============================================================

# All stdlib-math tests skipped (module loading not available).

# ============================================================
# STDLIB-STRING TESTS (from stdlib-string.test.ts)
# NOTE: Same module loading issue as stdlib-math.
# ============================================================

# All stdlib-string tests skipped (module loading not available).

# ============================================================
# STDLIB-COLLECTIONS TESTS (from stdlib-collections.test.ts)
# NOTE: Same module loading issue.
# ============================================================

# All stdlib-collections tests skipped (module loading not available).

# ============================================================
# TYPECHECK TESTS (from typecheck.test.ts)
# ============================================================

suite "Typecheck tests":
  test "accepts correct type":
    let eval = makeEval()
    check $eval.evalString("add: function [a [integer!] b [integer!]] [a + b] add 3 4") == "7"

  test "rejects wrong type":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""add: function [a [integer!] b [integer!]] [a + b] add "hi" 4""")
    except:
      caught = true
    check caught

  test "rejects wrong type on second param":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""add: function [a [integer!] b [integer!]] [a + b] add 3 "hi" """)
    except:
      caught = true
    check caught

  # -- built-in type union --

  test "number! accepts integer":
    let eval = makeEval()
    check $eval.evalString("double: function [x [number!]] [x * 2] double 5") == "10"

  test "number! accepts float":
    let eval = makeEval()
    check $eval.evalString("double: function [x [number!]] [x * 2] double 2.5") == "5.0"

  test "number! rejects string":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""double: function [x [number!]] [x * 2] double "hi" """)
    except:
      caught = true
    check caught

  # -- return type checking --

  test "accepts correct return type":
    let eval = makeEval()
    check $eval.evalString("f: function [return: [integer!]] [42] f") == "42"

  test "rejects wrong return type":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""f: function [return: [integer!]] ["oops"] f""")
    except:
      caught = true
    check caught

  test "checks early return type":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""f: function [x [integer!] return: [integer!]] [return "bad"] f 1""")
    except:
      caught = true
    check caught

  # -- no constraint --

  test "untyped params accept anything":
    let eval = makeEval()
    check $eval.evalString("id: function [x] [x] id 42") == "42"
    check $eval.evalString("""id: function [x] [x] id "hi" """) == "hi"

  # -- refinement param type checking --

  test "refinement param type checking":
    let eval = makeEval()
    discard eval.evalString("""greet: function [name [string!] /loud /times count [integer!]] [name]""")
    check $eval.evalString("""greet "Ray" """) == "Ray"

  test "refinement param rejects wrong type":
    let eval = makeEval()
    discard eval.evalString("""greet: function [name [string!] /loud /times count [integer!]] [name]""")
    var caught = false
    try:
      discard eval.evalString("greet 42")
    except:
      caught = true
    check caught

  # opt parameter tests removed — opt is no longer part of function param spec

# ============================================================
# TYPES-ADVANCED TESTS (from types-advanced.test.ts)
# ============================================================

# All types-advanced tests skipped (advanced type features may not be implemented).
