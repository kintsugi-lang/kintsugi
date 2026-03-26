import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, object_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerObjectDialect()
  eval

suite "object creation":
  test "basic object creation":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field [x [integer!] 0]
        field [y [integer!] 0]
      ]
      type Point
    """)
    check $result == "object!"

  test "make creates mutable instance":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field [x [integer!] 0]
        field [y [integer!] 0]
      ]
      p: make Point [x: 10 y: 20]
      p/x
    """)
    check $result == "10"

  test "auto-generated constructor":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field [x [integer!]]
        field [y [integer!]]
      ]
      p: make-point 10 20
      p/y
    """)
    check $result == "20"

  test "auto-generated type predicate":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field [x [integer!]]
        field [y [integer!]]
      ]
      p: make-point 10 20
      point? p
    """)
    check $result == "true"

suite "object fields":
  test "required field validation":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Person: object [
          field [name [string!]]
          field [age [integer!]]
        ]
        p: make Person []
      """)

  test "type check on overrides":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Point: object [
          field [x [integer!] 0]
          field [y [integer!] 0]
        ]
        p: make Point [x: "hello"]
      """)

  test "field with default is optional in make":
    let eval = makeEval()
    let result = eval.evalString("""
      Config: object [
        field [host [string!]]
        field [port [integer!] 8080]
      ]
      c: make Config [host: "localhost"]
      c/port
    """)
    check $result == "8080"

  test "mixed required and defaulted fields":
    let eval = makeEval()
    let result = eval.evalString("""
      Account: object [
        field [owner [string!]]
        field [balance [integer!] 0]
        field [active [logic!] true]
        deposit: function [amount [integer!]] [
          self/balance: self/balance + amount
        ]
      ]
      a: make Account [owner: "Ray"]
      a/deposit 100
      a/balance
    """)
    check $result == "100"

suite "object mutability":
  test "object is immutable":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Point: object [
          field [x [integer!] 0]
          field [y [integer!] 0]
        ]
        Point/x: 999
      """)

  test "instance is mutable":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field [x [integer!] 0]
        field [y [integer!] 0]
      ]
      p: make Point [x: 10 y: 20]
      p/x: 999
      p/x
    """)
    check $result == "999"

suite "object methods":
  test "self binding":
    let eval = makeEval()
    let result = eval.evalString("""
      Counter: object [
        field [count [integer!] 0]
        increment: does [
          self/count: self/count + 1
        ]
        get-count: does [
          self/count
        ]
      ]
      c: make Counter []
      c/increment
      c/increment
      c/increment
      c/get-count
    """)
    check $result == "3"

  test "self cannot be rebound":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Thing: object [
          field [val [integer!] 0]
          rebind-self: does [
            self: 42
          ]
        ]
        t: make Thing []
        t/rebind-self
      """)

  test "methods with parameters":
    let eval = makeEval()
    let result = eval.evalString("""
      Enemy: object [
        field [hp [integer!] 100]
        damage: function [amount [integer!]] [
          self/hp: self/hp - amount
        ]
      ]
      goblin: make Enemy []
      goblin/damage 10
      goblin/hp
    """)
    check $result == "90"

  test "methods alongside fields":
    let eval = makeEval()
    let result = eval.evalString("""
      Greeter: object [
        field [name [string!]]
        greet: function [] [
          join "Hello, " self/name
        ]
      ]
      g: make Greeter [name: "World"]
      g/greet
    """)
    check $result == "Hello, World"

suite "object instances":
  test "independent instances":
    let eval = makeEval()
    let result = eval.evalString("""
      Counter: object [
        field [count [integer!] 0]
        increment: does [
          self/count: self/count + 1
        ]
      ]
      a: make Counter []
      b: make Counter []
      a/increment
      a/increment
      b/increment
      a/count + b/count
    """)
    check $result == "3"

  test "name collision detection":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        point!: 42
        Point: object [
          field [x [integer!] 0]
        ]
      """)
