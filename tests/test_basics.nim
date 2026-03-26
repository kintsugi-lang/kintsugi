import std/unittest
import ../src/core/types
import ../src/core/equality
import ../src/parse/lexer
import ../src/parse/parser

suite "types":
  test "display values":
    let i = ktgInt(42)
    let f = ktgFloat(3.14)
    let s = ktgString("hello")
    let t = ktgLogic(true)
    let n = ktgNone()
    let p = ktgPair(100, 200)
    let w = ktgWord("test", wkWord)
    let sw = ktgWord("test", wkSetWord)

    check $i == "42"
    check $f == "3.14"
    check $s == "hello"
    check $t == "true"
    check $n == "none"
    check $p == "100x200"
    check $w == "test"
    check $sw == "test:"

suite "truthiness":
  test "truthy values":
    check isTruthy(ktgInt(0))
    check isTruthy(ktgString(""))
    check isTruthy(ktgBlock())

  test "falsy values":
    check not isTruthy(ktgLogic(false))
    check not isTruthy(ktgNone())

suite "equality":
  test "numeric cross-type":
    check valuesEqual(ktgInt(42), ktgFloat(42.0))

  test "money is its own domain":
    check not valuesEqual(ktgMoney(4200), ktgInt(42))
    check valuesEqual(ktgMoney(1999), ktgMoney(1999))

  test "structural deep":
    check valuesEqual(ktgBlock(@[ktgInt(1), ktgInt(2)]), ktgBlock(@[ktgInt(1), ktgInt(2)]))
    check not valuesEqual(ktgBlock(@[ktgInt(1)]), ktgBlock(@[ktgInt(2)]))

  test "strings case-sensitive":
    check not valuesEqual(ktgString("abc"), ktgString("ABC"))
    check valuesEqual(ktgString("abc"), ktgString("abc"))

  test "words case-insensitive same subtype":
    check valuesEqual(ktgWord("hello", wkLitWord), ktgWord("Hello", wkLitWord))
    check not valuesEqual(ktgWord("hello", wkLitWord), ktgWord("hello", wkWord))

  test "none equals only none":
    check valuesEqual(ktgNone(), ktgNone())
    check not valuesEqual(ktgNone(), ktgLogic(false))

  test "cross-type is false":
    check not valuesEqual(ktgInt(1), ktgString("1"))

suite "context":
  test "parent-child lookup and shadowing":
    let parent = newContext()
    parent.set("x", ktgInt(10))

    let child = parent.child
    child.set("y", ktgInt(20))

    check $child.get("x") == "10"
    check $child.get("y") == "20"

    child.set("x", ktgInt(99))
    check $child.get("x") == "99"
    check $parent.get("x") == "10"

suite "lexer":
  test "set-word and integer":
    let tokens = tokenize("x: 42")
    check tokens.len == 2
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkSetWord
    check tokens[0].wordName == "x"
    check tokens[1].kind == vkInteger
    check tokens[1].intVal == 42

  test "all value types":
    let tokens = tokenize("""100x200 3.14 "hello" true none $19.99 'lit :get @meta""")
    check tokens[0].kind == vkPair
    check tokens[1].kind == vkFloat
    check tokens[2].kind == vkString
    check tokens[3].kind == vkLogic
    check tokens[4].kind == vkNone
    check tokens[5].kind == vkMoney
    check tokens[5].cents == 1999
    check tokens[6].kind == vkWord and tokens[6].wordKind == wkLitWord
    check tokens[7].kind == vkWord and tokens[7].wordKind == wkGetWord
    check tokens[8].kind == vkWord and tokens[8].wordKind == wkMetaWord

suite "parser":
  test "flat":
    let ast = parseSource("x: 42")
    check ast.len == 2
    check ast[0].wordName == "x"
    check ast[1].intVal == 42

  test "nested blocks":
    let ast = parseSource("[1 2 [3 4]]")
    check ast.len == 1
    check ast[0].kind == vkBlock
    check ast[0].blockVals.len == 3
    check ast[0].blockVals[2].kind == vkBlock
    check ast[0].blockVals[2].blockVals.len == 2

  test "parens":
    let ast = parseSource("(1 + 2)")
    check ast.len == 1
    check ast[0].kind == vkParen
    check ast[0].parenVals.len == 3
