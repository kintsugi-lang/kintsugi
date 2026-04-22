## Phase-1 TypeDef consolidation: unified registry is populated on
## every @type and object registration, and is?/match dispatch
## routes through it.

import std/[unittest, tables]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect]

proc makeEval(): Evaluator =
  let e = newEvaluator()
  e.registerNatives()
  e.registerDialect(newLoopDialect())
  e.registerMatch()
  e.registerObjectDialect()
  e.registerAttempt()
  e

suite "typeDefs registry population":

  test "@type/enum registers tkEnum":
    let e = makeEval()
    discard e.evalString("color!: @type/enum ['red | 'green | 'blue]")
    check "color!" in e.typeDefs
    check e.typeDefs["color!"].kind == tkEnum
    check e.typeDefs["color!"].custom != nil

  test "@type union registers tkUnion":
    let e = makeEval()
    discard e.evalString("scalar!: @type [integer! | string!]")
    check "scalar!" in e.typeDefs
    check e.typeDefs["scalar!"].kind == tkUnion

  test "@type/where registers tkGuard":
    let e = makeEval()
    discard e.evalString("positive!: @type/where [integer!] [it > 0]")
    check "positive!" in e.typeDefs
    check e.typeDefs["positive!"].kind == tkGuard

  test "@type structural registers tkStruct":
    let e = makeEval()
    discard e.evalString("""person!: @type ['name [string!] 'age [integer!]]""")
    check "person!" in e.typeDefs
    check e.typeDefs["person!"].kind == tkStruct

  test "object registration registers tkObjectRef":
    let e = makeEval()
    discard e.evalString("""
      Enemy: object [
        field/required [hp [integer!]]
      ]
    """)
    check "enemy!" in e.typeDefs
    check e.typeDefs["enemy!"].kind == tkObjectRef
    check e.typeDefs["enemy!"].obj != nil

suite "typeDef-backed dispatch":

  test "is? on enum routed through typeDefs":
    let e = makeEval()
    discard e.evalString("dir!: @type/enum ['north | 'south]")
    check $e.evalString("is? dir! 'north") == "true"
    check $e.evalString("is? dir! 'east") == "false"

  test "is? on object routed through typeDefs":
    let e = makeEval()
    discard e.evalString("""
      Enemy: object [
        field/required [hp [integer!]]
      ]
    """)
    discard e.evalString("goblin: make Enemy [hp: 30]")
    check $e.evalString("is? enemy! goblin") == "true"
    check $e.evalString("is? :Enemy goblin") == "true"
