import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

let eval = newEvaluator()
eval.registerNatives()
eval.registerDialect(newLoopDialect())
eval.registerMatch()
eval.registerPrototypeDialect()
eval.registerAttempt()
eval.registerParse()

discard eval.evalString("""
  Card: prototype [
    field/required [name [string!]]
    field/optional [balance [money!] $0.00]
  ]
""")

echo "card! exists: ", eval.global.has("card!")
echo "card? exists: ", eval.global.has("card?")
echo "make-card exists: ", eval.global.has("make-card")

discard eval.evalString("c: make-card \"Ray\"")
echo "c type: ", $eval.evalString("type c")
echo "card? c: ", $eval.evalString("card? c")
echo "is? card! c: ", $eval.evalString("is? card! c")

# Test the function param check
try:
  discard eval.evalString("""
    f: function [x [card!]] [x]
    f c
  """)
  echo "f c: passed"
except KtgError as e:
  echo "f c FAILED: ", e.kind, " - ", e.msg
