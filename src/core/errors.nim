## Error formatting: render a KtgError with a source-line preview + caret.
##
## The evaluator stamps `line` onto errors via evalBlock's try/except wrapper.
## Path errors also carry `path` (the full path expression) and `pathSeg` (the
## failing segment). Given the original source text, this module turns that
## into a human-readable preview like:
##
##   Error [type]: cannot navigate path on integer!
##     in path: enemy/pos/x (at /pos)
##     at line 5:
##          | enemy: 42
##          | enemy/pos/x: 10
##          | ^

import std/strutils
import types

proc sourceLine*(source: string, line: int): string =
  ## Return the 1-based `line` of `source`, or "" if out of range.
  if line <= 0: return ""
  var curLine = 1
  var start = 0
  for i in 0 ..< source.len:
    if curLine == line:
      # find end of line
      var endPos = i
      while endPos < source.len and source[endPos] != '\n':
        endPos += 1
      return source[start ..< endPos]
    if source[i] == '\n':
      curLine += 1
      start = i + 1
  if curLine == line and start <= source.len:
    return source[start ..< source.len]
  ""

proc caretColumn(srcLine, pathWord: string): int =
  ## If the source line contains the path word, return its 0-based column.
  ## Otherwise return -1 (caller skips the caret).
  if pathWord.len == 0: return -1
  let idx = srcLine.find(pathWord)
  if idx < 0: return -1
  idx

proc formatError*(source: string, e: KtgError): string =
  ## Render a KtgError with optional source preview and caret. Works even
  ## when `source` is empty or the line is unknown — degrades to kind + msg.
  var s = "Error [" & e.kind & "]: " & e.msg
  if e.path.len > 0:
    s &= "\n  in path: " & e.path
    if e.pathSeg.len > 0 and e.pathSeg != e.path:
      s &= " (at /" & e.pathSeg & ")"
  if e.line > 0:
    s &= "\n  at line " & $e.line & ":"
    let srcLine = sourceLine(source, e.line)
    if srcLine.len > 0:
      let trimmed = srcLine.strip(leading = true, trailing = false)
      let leadingCount = srcLine.len - trimmed.len
      let prefix = "    "
      s &= "\n" & prefix & "| " & trimmed
      var col = caretColumn(srcLine, e.path)
      if col < 0 and e.pathSeg.len > 0:
        col = caretColumn(srcLine, e.pathSeg)
      if col >= leadingCount:
        s &= "\n" & prefix & "| " & repeat(' ', col - leadingCount) & "^"
  if e.stack.len > 0:
    s &= "\nStack trace:"
    for frame in e.stack:
      s &= "\n  " & frame.name & " at line " & $frame.line
  s
