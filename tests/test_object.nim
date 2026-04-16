import std/[unittest, strutils]
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
        field/optional [x [integer!] 0]
        field/optional [y [integer!] 0]
      ]
      type Point
    """)
    check $result == "object!"

  test "make creates mutable instance":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field/optional [x [integer!] 0]
        field/optional [y [integer!] 0]
      ]
      p: make Point [x: 10 y: 20]
      p/x
    """)
    check $result == "10"

  test "auto-generated type predicate":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field/required [x [integer!]]
        field/required [y [integer!]]
      ]
      p: make Point [x: 10 y: 20]
      point? p
    """)
    check $result == "true"

suite "object fields":
  test "required field validation":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Person: object [
          field/required [name [string!]]
          field/required [age [integer!]]
        ]
        p: make Person []
      """)

  test "type check on overrides":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Point: object [
          field/optional [x [integer!] 0]
          field/optional [y [integer!] 0]
        ]
        p: make Point [x: "hello"]
      """)

  test "field with default is optional in make":
    let eval = makeEval()
    let result = eval.evalString("""
      Config: object [
        field/required [host [string!]]
        field/optional [port [integer!] 8080]
      ]
      c: make Config [host: "localhost"]
      c/port
    """)
    check $result == "8080"

  test "mixed required and defaulted fields":
    let eval = makeEval()
    let result = eval.evalString("""
      Account: object [
        field/required [owner [string!]]
        field/optional [balance [integer!] 0]
        field/optional [active [logic!] true]
        deposit: function [amount [integer!]] [
          self/balance: self/balance + amount
        ]
      ]
      a: make Account [owner: "Ray"]
      a/deposit 100
      a/balance
    """)
    check $result == "100"

suite "object immutability":
  test "object is frozen":
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
      caught = e.kind == "frozen"
    check caught

  test "instance is mutable":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field/optional [x [integer!] 0]
        field/optional [y [integer!] 0]
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
        field/optional [count [integer!] 0]
        increment: function [] [
          self/count: self/count + 1
        ]
        get-count: function [] [
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
          field/optional [val [integer!] 0]
          rebind-self: function [] [
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
        field/optional [hp [integer!] 100]
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
        field/required [name [string!]]
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
      a/count + b/count
    """)
    check $result == "3"

  test "type name registered on object":
    let eval = makeEval()
    discard eval.evalString("""
      Point: object [
        field/optional [x [integer!] 0]
      ]
    """)
    check $eval.evalString("type point!") == "type!"

suite "freeze":
  test "freeze converts context to object":
    let eval = makeEval()
    let r = eval.evalString("""
      ctx: context [x: 1 y: 2]
      obj: freeze :ctx
      frozen? :obj
    """)
    check r.boolVal == true

  test "frozen object rejects mutation":
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("""
        ctx: context [x: 1]
        obj: freeze :ctx
        obj/x: 99
      """)
    except KtgError as e:
      caught = e.kind == "frozen"
    check caught

  test "freeze/deep recursively freezes nested contexts":
    let eval = makeEval()
    let r = eval.evalString("""
      inner: context [val: 42]
      outer: context [child: :inner]
      obj: freeze/deep :outer
      frozen? obj/child
    """)
    check r.boolVal == true

  test "freeze on already-frozen object is no-op":
    let eval = makeEval()
    let r = eval.evalString("""
      Point: object [field/optional [x [integer!] 0]]
      obj: freeze :Point
      frozen? :obj
    """)
    check r.boolVal == true

  test "frozen? returns false for context":
    let eval = makeEval()
    let r = eval.evalString("""
      ctx: context [x: 1]
      frozen? :ctx
    """)
    check r.boolVal == false

  test "object keyword produces frozen value":
    let eval = makeEval()
    let r = eval.evalString("""
      Point: object [field/optional [x [integer!] 0]]
      frozen? :Point
    """)
    check r.boolVal == true

  test "type on a make'd instance reports the object name":
    let eval = makeEval()
    discard eval.evalString("""
      Enemy: object [field/optional [hp [integer!] 0]]
      goblin: make Enemy [hp: 30]
    """)
    check $eval.evalString("type goblin") == "enemy!"
    ## Kebab-cased: SuperHero -> super-hero!
    discard eval.evalString("""
      SuperHero: object [field/optional [power [integer!] 0]]
      hero: make SuperHero [power: 99]
    """)
    check $eval.evalString("type hero") == "super-hero!"
    ## Plain contexts still report context!.
    check $eval.evalString("type context [x: 1]") == "context!"

  test "frozen-object mutation error suggests make":
    let eval = makeEval()
    var caught = ""
    try:
      discard eval.evalString("""
        Point: object [field/optional [x [integer!] 0]]
        Point/x: 99
      """)
    except KtgError as e:
      caught = e.msg
    check "make" in caught
    check "mutable context" in caught

suite "set-path type enforcement":
  test "set-path enforces field type on typed object":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Point: object [
          field/optional [x [integer!] 0]
          field/optional [y [integer!] 0]
        ]
        p: make Point [x: 10 y: 20]
        p/x: "not an integer"
      """)

  test "set-path allows correct type on typed object":
    let eval = makeEval()
    let result = eval.evalString("""
      Point: object [
        field/optional [x [integer!] 0]
        field/optional [y [integer!] 0]
      ]
      p: make Point [x: 10 y: 20]
      p/x: 999
      p/x
    """)
    check $result == "999"

  test "set-path allows correct type on string field":
    let eval = makeEval()
    let result = eval.evalString("""
      Box: object [
        field/optional [contents [string!] "empty"]
      ]
      b: make Box []
      b/contents: "anything"
      b/contents
    """)
    check $result == "anything"

  test "set-path enforces custom type on field":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        direction!: @type/enum ['north | 'south | 'east | 'west]
        Ship: object [
          field/required [heading [direction!]]
        ]
        s: make Ship [heading: 'north]
        s/heading: "invalid"
      """)
