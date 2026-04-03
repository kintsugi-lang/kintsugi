## Test that the executable spec (full-spec.ktg) runs without errors.
## This is the ultimate integration test — if the spec runs, the language works.

import std/[os, strutils]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerPrototypeDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval

let specPath = currentSourcePath().parentDir / ".." / "examples" / "full-spec.ktg"
var src = readFile(specPath)

# Strip the header if present (Kintsugi [...] at the top)
# The header is a word followed by a block — skip past it
block stripHeader:
  let trimmed = src.strip
  if trimmed.startsWith("Kintsugi"):
    # Find the closing ] of the header block
    var depth = 0
    var i = 0
    var inHeader = false
    while i < src.len:
      if src[i] == '[' and not inHeader:
        inHeader = true
        depth = 1
      elif src[i] == '[' and inHeader:
        depth += 1
      elif src[i] == ']' and inHeader:
        depth -= 1
        if depth == 0:
          src = src[i+1 .. ^1]
          break
      i += 1

echo "Running full-spec.ktg..."
echo "  File: " & specPath
echo "  Size: " & $src.len & " bytes"
echo "  Lines: " & $src.countLines
echo ""

let eval = makeEval()
var lineErrors: seq[string] = @[]

try:
  discard eval.evalString(src)
  echo "full-spec.ktg completed successfully."
  echo ""
  echo "Output lines: " & $eval.output.len
  echo ""
  echo "=== SPEC TEST PASSED ==="
except KtgError as e:
  echo "=== SPEC TEST FAILED ==="
  echo ""
  echo "Error [" & e.kind & "]: " & e.msg
  if e.stack.len > 0:
    for frame in e.stack:
      echo "  in " & frame.name & " @ " & frame.file & "#L" & $frame.line
  echo ""
  echo "Output before failure (" & $eval.output.len & " lines):"
  for i, line in eval.output:
    if i >= eval.output.len - 10:  # show last 10 lines
      echo "  " & line
  quit(1)
except CatchableError as e:
  echo "=== SPEC TEST FAILED ==="
  echo "Unexpected error: " & e.msg
  quit(1)
