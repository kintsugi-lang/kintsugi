## Custom type system tests for @type, @type/where, @type/enum

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

# =============================================================================
# @type union types
# =============================================================================

suite "@type union types":
  test "union type accepts first alternative":
    let eval = makeEval()
    discard eval.evalString("""string-or-none!: @type [string! | none!]""")
    check $eval.evalString("""is? string-or-none! "hello" """) == "true"

  test "union type accepts second alternative":
    let eval = makeEval()
    discard eval.evalString("""string-or-none!: @type [string! | none!]""")
    check $eval.evalString("is? string-or-none! none") == "true"

  test "union type rejects non-matching type":
    let eval = makeEval()
    discard eval.evalString("""string-or-none!: @type [string! | none!]""")
    check $eval.evalString("is? string-or-none! 42") == "false"

  test "union type in function param spec":
    let eval = makeEval()
    discard eval.evalString("""string-or-none!: @type [string! | none!]""")
    discard eval.evalString("""greet: function [name [string-or-none!]] [either none? name ["stranger"] [name]]""")
    check $eval.evalString("""greet "Ray" """) == "Ray"
    check $eval.evalString("greet none") == "stranger"

  test "union type rejects wrong type in function":
    let eval = makeEval()
    discard eval.evalString("""string-or-none!: @type [string! | none!]""")
    discard eval.evalString("""f: function [x [string-or-none!]] [x]""")
    expect KtgError:
      discard eval.evalString("f 42")

  test "three-way union type":
    let eval = makeEval()
    discard eval.evalString("""flexible!: @type [string! | integer! | none!]""")
    check $eval.evalString("""is? flexible! "hi" """) == "true"
    check $eval.evalString("is? flexible! 42") == "true"
    check $eval.evalString("is? flexible! none") == "true"
    check $eval.evalString("is? flexible! true") == "false"

# =============================================================================
# @type/where (guarded types)
# =============================================================================

suite "@type/where guarded types":
  test "where guard passes for valid value":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    check $eval.evalString("is? positive! 5") == "true"

  test "where guard fails for invalid value":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    check $eval.evalString("is? positive! -3") == "false"

  test "where guard rejects wrong base type":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    check $eval.evalString("""is? positive! "hello" """) == "false"

  test "where in function param spec":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    discard eval.evalString("""double: function [x [positive!]] [x * 2]""")
    check $eval.evalString("double 5") == "10"

  test "where rejects in function param":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    discard eval.evalString("""double: function [x [positive!]] [x * 2]""")
    expect KtgError:
      discard eval.evalString("double -3")

  test "where rejects wrong base type in function":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    discard eval.evalString("""double: function [x [positive!]] [x * 2]""")
    expect KtgError:
      discard eval.evalString("""double "hi" """)

  test "where with string length guard":
    let eval = makeEval()
    discard eval.evalString("""short-string!: @type/where [string!] [3 > length? it]""")
    check $eval.evalString("""is? short-string! "ab" """) == "true"
    check $eval.evalString("""is? short-string! "abcde" """) == "false"

  test "where with zero check":
    let eval = makeEval()
    discard eval.evalString("""nonzero!: @type/where [integer!] [it <> 0]""")
    check $eval.evalString("is? nonzero! 5") == "true"
    check $eval.evalString("is? nonzero! 0") == "false"

# =============================================================================
# @type/enum
# =============================================================================

suite "@type/enum":
  test "enum accepts valid member":
    let eval = makeEval()
    discard eval.evalString("""direction!: @type/enum ['north | 'south | 'east | 'west]""")
    check $eval.evalString("is? direction! 'north") == "true"
    check $eval.evalString("is? direction! 'south") == "true"

  test "enum rejects non-member":
    let eval = makeEval()
    discard eval.evalString("""direction!: @type/enum ['north | 'south | 'east | 'west]""")
    check $eval.evalString("is? direction! 'up") == "false"

  test "enum rejects non-lit-word":
    let eval = makeEval()
    discard eval.evalString("""direction!: @type/enum ['north | 'south | 'east | 'west]""")
    check $eval.evalString("""is? direction! "north" """) == "false"
    check $eval.evalString("is? direction! 42") == "false"

  test "enum in function param":
    let eval = makeEval()
    discard eval.evalString("""direction!: @type/enum ['north | 'south | 'east | 'west]""")
    discard eval.evalString("""describe: function [d [direction!]] [join "going " to string! d]""")
    check $eval.evalString("describe 'north") == "going north"

  test "enum rejects wrong value in function":
    let eval = makeEval()
    discard eval.evalString("""direction!: @type/enum ['north | 'south | 'east | 'west]""")
    discard eval.evalString("""describe: function [d [direction!]] [d]""")
    expect KtgError:
      discard eval.evalString("describe 'up")

  test "enum is case-SENSITIVE":
    let eval = makeEval()
    discard eval.evalString("""status!: @type/enum ['Active | 'Inactive | 'Pending]""")
    check $eval.evalString("is? status! 'Active") == "true"
    check $eval.evalString("is? status! 'active") == "false"  # case mismatch
    check $eval.evalString("is? status! 'ACTIVE") == "false"  # case mismatch

  test "non-enum @type lit-words are case-INSENSITIVE":
    let eval = makeEval()
    discard eval.evalString("""direction!: @type ['north | 'south | 'east | 'west]""")
    check $eval.evalString("is? direction! 'north") == "true"
    check $eval.evalString("is? direction! 'NORTH") == "true"   # case insensitive
    check $eval.evalString("is? direction! 'North") == "true"   # case insensitive

# =============================================================================
# is? with custom types
# =============================================================================

suite "is? with custom types":
  test "is? with union type":
    let eval = makeEval()
    discard eval.evalString("""num!: @type [integer! | float!]""")
    check $eval.evalString("is? num! 42") == "true"
    check $eval.evalString("is? num! 3.14") == "true"
    check $eval.evalString("""is? num! "hello" """) == "false"

  test "is? with guarded type":
    let eval = makeEval()
    discard eval.evalString("""even!: @type/where [integer!] [(it % 2) = 0]""")
    check $eval.evalString("is? even! 4") == "true"
    check $eval.evalString("is? even! 3") == "false"

  test "is? with enum type":
    let eval = makeEval()
    discard eval.evalString("""color!: @type/enum ['red | 'green | 'blue]""")
    check $eval.evalString("is? color! 'red") == "true"
    check $eval.evalString("is? color! 'yellow") == "false"

# =============================================================================
# Function param with custom type
# =============================================================================

suite "Function param with custom type":
  test "custom union type in param spec":
    let eval = makeEval()
    discard eval.evalString("""number!: @type [integer! | float!]""")
    discard eval.evalString("""add-one: function [x [number!]] [x + 1]""")
    check $eval.evalString("add-one 5") == "6"
    check $eval.evalString("add-one 2.5") == "3.5"

  test "custom type rejection in function":
    let eval = makeEval()
    discard eval.evalString("""number!: @type [integer! | float!]""")
    discard eval.evalString("""add-one: function [x [number!]] [x + 1]""")
    expect KtgError:
      discard eval.evalString("""add-one "hello" """)

# =============================================================================
# @type structural context validation
# =============================================================================

suite "@type structural context validation":
  test "structural type matches context with all fields":
    let eval = makeEval()
    discard eval.evalString("""person!: @type ['name [string!] 'age [integer!]]""")
    check $eval.evalString("""is? person! context [name: "Alice" age: 30]""") == "true"

  test "structural type rejects context missing field":
    let eval = makeEval()
    discard eval.evalString("""person!: @type ['name [string!] 'age [integer!]]""")
    check $eval.evalString("""is? person! context [name: "Alice"]""") == "false"

  test "structural type rejects wrong field type":
    let eval = makeEval()
    discard eval.evalString("""person!: @type ['name [string!] 'age [integer!]]""")
    check $eval.evalString("""is? person! context [name: "Alice" age: "thirty"]""") == "false"

  test "structural type accepts context with extra fields":
    let eval = makeEval()
    discard eval.evalString("""person!: @type ['name [string!] 'age [integer!]]""")
    check $eval.evalString("""is? person! context [name: "Alice" age: 30 email: "alice@example.com"]""") == "true"

  test "structural type matches block as key-value pairs":
    let eval = makeEval()
    discard eval.evalString("""point!: @type ['x [integer!] 'y [integer!]]""")
    check $eval.evalString("""is? point! [x 10 y 20]""") == "true"

  test "structural type rejects non-context non-block":
    let eval = makeEval()
    discard eval.evalString("""person!: @type ['name [string!] 'age [integer!]]""")
    check $eval.evalString("is? person! 42") == "false"

# =============================================================================
# Typed blocks [block! integer!]
# =============================================================================

suite "Typed blocks [block! integer!]":
  test "typed block accepts homogeneous block":
    let eval = makeEval()
    discard eval.evalString("""f: function [nums [block! integer!]] [first nums]""")
    check $eval.evalString("f [1 2 3]") == "1"

  test "typed block rejects mixed block":
    let eval = makeEval()
    discard eval.evalString("""f: function [nums [block! integer!]] [first nums]""")
    expect KtgError:
      discard eval.evalString("""f [1 "two" 3]""")

  test "untyped block accepts anything":
    let eval = makeEval()
    discard eval.evalString("""f: function [data [block!]] [length? data]""")
    check $eval.evalString("""f [1 "a" true]""") == "3"

  test "typed block with string elements":
    let eval = makeEval()
    discard eval.evalString("""f: function [words [block! string!]] [first words]""")
    check $eval.evalString("""f ["hello" "world"]""") == "hello"

  test "typed block rejects wrong element type":
    let eval = makeEval()
    discard eval.evalString("""f: function [words [block! string!]] [first words]""")
    expect KtgError:
      discard eval.evalString("f [1 2 3]")

# =============================================================================
# @type rejection tests
# =============================================================================

suite "@type rejection tests":
  test "union type rejects completely wrong type":
    let eval = makeEval()
    discard eval.evalString("""num-or-str!: @type [integer! | string!]""")
    check $eval.evalString("is? num-or-str! true") == "false"
    check $eval.evalString("is? num-or-str! none") == "false"

  test "guarded type rejects on guard failure":
    let eval = makeEval()
    discard eval.evalString("""age!: @type/where [integer!] [it >= 0]""")
    check $eval.evalString("is? age! -1") == "false"
    check $eval.evalString("is? age! 0") == "true"
    check $eval.evalString("is? age! 150") == "true"

  test "enum type is exhaustive":
    let eval = makeEval()
    discard eval.evalString("""bool-like!: @type/enum ['yes | 'no]""")
    check $eval.evalString("is? bool-like! 'yes") == "true"
    check $eval.evalString("is? bool-like! 'no") == "true"
    check $eval.evalString("is? bool-like! 'maybe") == "false"
    check $eval.evalString("is? bool-like! true") == "false"

# =============================================================================
# Custom types in match dialect
# =============================================================================

suite "Custom types in match":
  test "match with union custom type":
    let eval = makeEval()
    discard eval.evalString("""number!: @type [integer! | float!]""")
    check $eval.evalString("""
      match 42 [
        [number!] ["got number"]
        [_]       ["other"]
      ]
    """) == "got number"

  test "match with float matches union type":
    let eval = makeEval()
    discard eval.evalString("""number!: @type [integer! | float!]""")
    check $eval.evalString("""
      match 3.14 [
        [number!] ["got number"]
        [_]       ["other"]
      ]
    """) == "got number"

  test "match falls through when custom type does not match":
    let eval = makeEval()
    discard eval.evalString("""number!: @type [integer! | float!]""")
    check $eval.evalString("""
      match "hello" [
        [number!] ["got number"]
        [_]       ["other"]
      ]
    """) == "other"
