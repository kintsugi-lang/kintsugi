import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

let eval = newEvaluator()
eval.registerNatives()
eval.registerDialect(newLoopDialect())
eval.registerMatch()
eval.registerObjectDialect()
eval.registerAttempt()
eval.registerParse()

echo "--- #preprocess test ---"
try:
  discard eval.evalString("#preprocess [emit [x: 42]]")
  echo "x = " & $eval.evalString("x")
except KtgError as e:
  echo "ERROR: " & e.kind & " - " & e.msg
