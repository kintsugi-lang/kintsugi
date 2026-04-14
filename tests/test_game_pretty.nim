import std/unittest
import ../src/core/[types, pretty, equality]
import ../src/parse/parser

proc roundTrip(src: string) =
  let ast = parseSource(src)
  let pretty = prettyPrintBlock(ast)
  let ast2 = parseSource(pretty)
  check ast.len == ast2.len
  for i in 0 ..< ast.len:
    check valuesEqual(ast[i], ast2[i])

suite "pretty print round trip":
  test "empty block": roundTrip("[]")
  test "integers and words": roundTrip("x: 42  y: 7  [x y]")
  test "nested blocks": roundTrip("foo: [bar [1 2 3] baz]")
  test "string with newline escape":
    let src = "msg: \"line one\\nline two\""
    let ast = parseSource(src)
    let pretty = prettyPrintBlock(ast)
    let ast2 = parseSource(pretty)
    check ast2[1].kind == vkString
    check ast2[1].strVal == "line one\nline two"
  test "set-word, lit-word, meta-word, get-word":
    roundTrip("name: value  'lit  @const  :getter")
  test "refinement word": roundTrip("loop/collect [for [x] in xs do [x]]")
  test "paren distinct from block": roundTrip("[a (b c) d]")
  test "pair and tuple": roundTrip("p: 100x200  v: 1.2.3")
