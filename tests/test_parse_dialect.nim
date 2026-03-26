import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, parse_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerParse()
  eval

# ============================================================
# 1. String parsing: literal match
# ============================================================

suite "String parsing: literal match":
  test "string literal match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello" ["hello"]
      r/ok
    """) == "true"

  test "string literal fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello" ["world"]
      r/ok
    """) == "false"

  test "string partial fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "hello world" ["hello"]
      r/ok
    """) == "false"

  test "string multi literal":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "helloworld" ["hello" "world"]
      r/ok
    """) == "true"

# ============================================================
# 2. Character classes
# ============================================================

suite "Character classes":
  test "char class alpha":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [some alpha]
      r/ok
    """) == "true"

  test "char class digit":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "123" [some digit]
      r/ok
    """) == "true"

  test "char class alnum":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc123" [some alnum]
      r/ok
    """) == "true"

  test "char class fail on non-alpha":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc123" [some alpha]
      r/ok
    """) == "false"

# ============================================================
# 3. some / any / opt
# ============================================================

suite "some / any / opt":
  test "some basic":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "aaa" [some "a"]
      r/ok
    """) == "true"

  test "some fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "bbb" [some "a"]
      r/ok
    """) == "false"

  test "any basic":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "aaa" [any "a"]
      r/ok
    """) == "true"

  test "any zero":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "" [any "a"]
      r/ok
    """) == "true"

  test "opt present":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "ab" [opt "a" "b"]
      r/ok
    """) == "true"

  test "opt absent":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "b" [opt "a" "b"]
      r/ok
    """) == "true"

# ============================================================
# 4. to / thru
# ============================================================

suite "to / thru":
  test "to basic":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abcxyz" [to "x" "xyz"]
      r/ok
    """) == "true"

  test "thru basic":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abcxyz" [thru "x" "yz"]
      r/ok
    """) == "true"

# ============================================================
# 5. skip / end
# ============================================================

suite "skip / end":
  test "skip basic":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [skip skip skip]
      r/ok
    """) == "true"

  test "end on empty":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "" [end]
      r/ok
    """) == "true"

  test "end after match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "a" ["a" end]
      r/ok
    """) == "true"

# ============================================================
# 6. Block parsing: literal match
# ============================================================

suite "Block parsing: literal match":
  test "block literal string match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse ["hello" "world"] ["hello" "world"]
      r/ok
    """) == "true"

  test "block literal string fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse ["hello" "world"] ["hello" "earth"]
      r/ok
    """) == "false"

  test "block literal int (quoted)":
    let eval = makeEval()
    # Use quote to match literal integers in block mode
    check $eval.evalString("""
      r: parse [1 2 3] [quote 1 quote 2 quote 3]
      r/ok
    """) == "true"

# ============================================================
# 7. Block parsing: type match
# ============================================================

suite "Block parsing: type match":
  test "block type match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 "hello" true] [integer! string! logic!]
      r/ok
    """) == "true"

  test "block type fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 "hello"] [string! integer!]
      r/ok
    """) == "false"

# ============================================================
# 8. Block parsing: 'word match
# ============================================================

suite "Block parsing: lit-word match":
  test "block lit-word match":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [north south] ['north 'south]
      r/ok
    """) == "true"

  test "block lit-word fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [north south] ['east 'south]
      r/ok
    """) == "false"

# ============================================================
# 9. Capture with set-words
# ============================================================

suite "Capture with set-words":
  test "capture string digits":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "42hello" [num: some digit word: some alpha]
      r/num
    """) == "42"

  test "capture string alpha":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "42hello" [num: some digit word: some alpha]
      r/word
    """) == "hello"

  test "capture block value":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [42 "hello"] [n: integer! s: string!]
      r/n
    """) == "42"

# ============================================================
# 10. collect / keep
# ============================================================

suite "collect / keep":
  test "collect/keep block":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse [1 "a" 2 "b" 3] [nums: collect [some [keep integer! | skip]]]
      r/nums
    """) == "[1 2 3]"

  test "collect/keep string":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "a1b2c3" [chars: collect [some [keep alpha | skip]]]
      r/chars
    """) == "[a b c]"

# ============================================================
# 11. Alternatives with |
# ============================================================

suite "Alternatives with |":
  test "alternative first":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [some alpha | some digit]
      r/ok
    """) == "true"

  test "alternative second":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "123" [some alpha | some digit]
      r/ok
    """) == "true"

  test "alternative fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [some digit | "xyz"]
      r/ok
    """) == "false"

  test "alternative sequence":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "cd" ["a" "b" | "c" "d"]
      r/ok
    """) == "true"

# ============================================================
# 12. Nested rules with [sub-rule]
# ============================================================

suite "Nested rules with [sub-rule]":
  test "sub-rule grouping":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abba" [some ["a" | "b"]]
      r/ok
    """) == "true"

  test "sub-rule grouping fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abca" [some ["a" | "b"]]
      r/ok
    """) == "false"

# ============================================================
# 13. not / ahead
# ============================================================

suite "not / ahead":
  test "not lookahead":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [not "x" some alpha]
      r/ok
    """) == "true"

  test "not lookahead fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [not "a" some alpha]
      r/ok
    """) == "false"

  test "ahead lookahead":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [ahead "a" some alpha]
      r/ok
    """) == "true"

# ============================================================
# 14. quote
# ============================================================

suite "quote":
  test "quote keyword escape":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse ["skip" "end"] [quote "skip" quote "end"]
      r/ok
    """) == "true"

# ============================================================
# 15. N rule (exactly N times)
# ============================================================

suite "N rule (exactly N times)":
  test "N times":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "aaa" [3 "a"]
      r/ok
    """) == "true"

  test "N times fail":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "aa" [3 "a"]
      r/ok
    """) == "false"

# ============================================================
# 16. fail keyword
# ============================================================

suite "fail keyword":
  test "fail keyword with alt":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [fail | some alpha]
      r/ok
    """) == "true"

# ============================================================
# 17. Success / failure overall
# ============================================================

suite "Success / failure overall":
  test "success full consume":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc" [some alpha]
      r/ok
    """) == "true"

  test "failure partial consume":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "abc123" [some alpha]
      r/ok
    """) == "false"

  test "success empty input":
    let eval = makeEval()
    check $eval.evalString("""
      r: parse "" [any alpha]
      r/ok
    """) == "true"

# ============================================================
# 18. Combined: email-like parse from spec
# ============================================================

suite "Combined: email-like parse from spec":
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
