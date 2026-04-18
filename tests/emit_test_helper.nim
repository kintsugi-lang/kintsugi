## Test-only helper. Preserves the old `emitLua` convenience signature
## (compiled Lua returned as a single blob with prelude inline) that many
## emitter tests were written against. Kept out of the public emitter
## API so production callers (CLI, playground) work against the explicit
## emitLuaSplit / emitLuaModule signatures.
##
## All test files that previously called `emitLua` import this module.

import std/strutils
import ../src/core/types
import ../src/eval/evaluator
import ../src/emit/lua

proc emitLua*(ast: seq[KtgValue], sourceDir: string = "",
              eval: Evaluator = nil): string =
  ## Compile an entrypoint AST and return prelude + source concatenated
  ## as a single chunk. Strips the `require('prelude')` / `import 'prelude'`
  ## line that emitLuaSplit inserts into source — that line only makes
  ## sense when the two outputs land as separate files. In the combined
  ## form the helper bodies live inline.
  ##
  ## Dep writes (from `import %path`) are discarded — tests that need to
  ## observe them should call `emitLuaSplit` directly.
  let r = emitLuaSplit(ast, sourceDir, "", eval)
  if r.prelude.len == 0:
    return r.prelude & r.source
  const requireLine = "require('prelude')\n"
  const playdateLine = "import 'prelude'\n"
  let src =
    if r.source.startsWith(requireLine): r.source[requireLine.len .. ^1]
    elif r.source.startsWith(playdateLine): r.source[playdateLine.len .. ^1]
    else: r.source
  r.prelude & src
