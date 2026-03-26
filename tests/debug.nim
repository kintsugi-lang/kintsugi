import ../src/core/types
import ../src/parse/[lexer, parser]
import ../src/emit/lua

let src = """
  either true [
    msg: "hi"
    love/graphics/printf msg 0 475 480 "center"
  ] [
    love/graphics/printf "bye" 0 475 480 "center"
  ]
"""
let ast = parseSource(src)
echo "AST len: ", ast.len
for v in ast:
  echo "  ", v.kind, " ", (if v.kind == vkWord: v.wordName else: $v)

echo ""
echo "--- Lua ---"
echo emitLua(ast)
