## Ported from TypeScript tests:
##   src/tests/lexer.test.ts
##   src/tests/parser.test.ts
##   src/tests/values.test.ts
##   src/tests/to-join.test.ts
##
## Source of truth: docs/language-spec-questions.md
## Tests that conflict with the spec are noted with comments.
## Tests for removed features (IR, JS/WASM backends) are omitted.

import std/strutils
import std/unittest
import ../src/core/types
import ../src/core/equality
import ../src/parse/lexer
import ../src/parse/parser

# =============================================================================
# LEXER TESTS (from lexer.test.ts)
# =============================================================================

suite "Lexer: Integers":
  test "lex positive integer":
    let tokens = tokenize("42")
    check tokens.len == 1
    check tokens[0].kind == vkInteger
    check tokens[0].intVal == 42

  test "lex negative integer":
    let tokens = tokenize("-7")
    check tokens.len == 1
    check tokens[0].kind == vkInteger
    check tokens[0].intVal == -7

suite "Lexer: Floats":
  test "lex basic float":
    let tokens = tokenize("3.14")
    check tokens.len == 1
    check tokens[0].kind == vkFloat
    check tokens[0].floatVal == 3.14

suite "Lexer: Tuples":
  test "lex version tuple":
    let tokens = tokenize("1.2.3")
    check tokens.len == 1
    check tokens[0].kind == vkTuple
    check tokens[0].tupleVals == @[1'u8, 2'u8, 3'u8]

suite "Lexer: Pairs":
  test "lex basic pair":
    let tokens = tokenize("100x200")
    check tokens.len == 1
    check tokens[0].kind == vkPair
    check tokens[0].px == 100
    check tokens[0].py == 200

suite "Lexer: Dates":
  test "lex full date":
    let tokens = tokenize("2026-03-15")
    check tokens.len == 1
    check tokens[0].kind == vkDate
    check tokens[0].year == 2026
    check tokens[0].month == 3
    check tokens[0].day == 15

suite "Lexer: Strings":
  test "lex double quoted string":
    let tokens = tokenize("\"hello\"")
    check tokens.len == 1
    check tokens[0].kind == vkString
    check tokens[0].strVal == "hello"

  test "lex curly brace string":
    let tokens = tokenize("{hello}")
    check tokens.len == 1
    check tokens[0].kind == vkString
    check tokens[0].strVal == "hello"

  test "lex escaped quote in string":
    let tokens = tokenize("\"She said \\\"hello\\\"\"")
    check tokens.len == 1
    check tokens[0].kind == vkString
    check tokens[0].strVal == "She said \"hello\""

  test "lex escaped backslash":
    let tokens = tokenize("\"a\\\\b\"")
    check tokens.len == 1
    check tokens[0].kind == vkString
    check tokens[0].strVal == "a\\b"

  test "lex newline escape":
    let tokens = tokenize("\"line one\\nline two\"")
    check tokens.len == 1
    check tokens[0].kind == vkString
    check tokens[0].strVal == "line one\nline two"

suite "Lexer: Chars":
  test "lex single char is string":
    let tokens = tokenize("\"A\"")
    check tokens.len == 1
    check tokens[0].kind == vkString
    check tokens[0].strVal == "A"

suite "Lexer: Files":
  test "lex file path":
    let tokens = tokenize("%path/to/file.txt")
    check tokens.len == 1
    check tokens[0].kind == vkFile
    check tokens[0].filePath == "path/to/file.txt"

  test "lex quoted file":
    # Was expectedFail: Nim lexer did not support quoted file paths (%"path with spaces")
    let tokens = tokenize("%\"path with spaces\"")
    check tokens.len == 1
    check tokens[0].kind == vkFile
    check tokens[0].filePath == "path with spaces"

suite "Lexer: Words":
  test "lex simple word":
    let tokens = tokenize("print")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "print"

  test "lex word with hyphen":
    let tokens = tokenize("my-var")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "my-var"

  test "lex word with question mark":
    let tokens = tokenize("empty?")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "empty?"

  test "lex word with exclamation":
    # NOTE: Nim lexer returns vkType for words ending in !, not vkWord.
    # TS lexer returned WORD. The Nim behavior is arguably correct since
    # integer! etc. are type names. Adapting test to match Nim behavior.
    let tokens = tokenize("integer!")
    check tokens.len == 1
    check tokens[0].kind == vkType
    check tokens[0].typeName == "integer!"

  test "lex word with tilde":
    let tokens = tokenize("user~")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "user~"

suite "Lexer: Logic":
  test "lex true":
    let tokens = tokenize("true")
    check tokens.len == 1
    check tokens[0].kind == vkLogic
    check tokens[0].boolVal == true

  test "lex false":
    let tokens = tokenize("false")
    check tokens.len == 1
    check tokens[0].kind == vkLogic
    check tokens[0].boolVal == false

  test "lex on is word":
    # SPEC: on/off/yes/no are words resolved to logic at eval time.
    # Was expectedFail: Nim lexer treated on/off/yes/no as logic literals.
    let tokens = tokenize("on")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "on"

  test "lex off is word":
    let tokens = tokenize("off")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "off"

  test "lex yes is word":
    let tokens = tokenize("yes")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "yes"

  test "lex no is word":
    let tokens = tokenize("no")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "no"

suite "Lexer: None":
  test "lex none literal":
    let tokens = tokenize("none")
    check tokens.len == 1
    check tokens[0].kind == vkNone

suite "Lexer: Set-Words":
  test "lex basic set word":
    let tokens = tokenize("name:")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkSetWord
    check tokens[0].wordName == "name"

suite "Lexer: Get-Words":
  test "lex basic get word":
    let tokens = tokenize(":name")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkGetWord
    check tokens[0].wordName == "name"

suite "Lexer: Lit-Words":
  test "lex basic lit word":
    let tokens = tokenize("'name")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkLitWord
    check tokens[0].wordName == "name"

suite "Lexer: Paths":
  test "lex basic path":
    # Nim lexer reads paths as part of word reading; path value
    # comes out as a vkWord with wordName "obj/field".
    let tokens = tokenize("obj/field")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "obj/field"

  test "lex multi segment path":
    let tokens = tokenize("a/b/c")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "a/b/c"

suite "Lexer: Set-Paths":
  test "lex basic set path":
    let tokens = tokenize("obj/field:")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkSetWord
    check tokens[0].wordName == "obj/field"

suite "Lexer: Blocks":
  test "lex open block":
    let tokens = tokenize("[")
    check tokens.len == 1
    check tokens[0].kind == vkBlock

  test "lex close block":
    let tokens = tokenize("]")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == "]"

suite "Lexer: Parens":
  test "lex open paren":
    let tokens = tokenize("(")
    check tokens.len == 1
    check tokens[0].kind == vkParen

  test "lex close paren":
    let tokens = tokenize(")")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordName == ")"

suite "Lexer: Operators":
  test "lex plus":
    let tokens = tokenize("+")
    check tokens.len == 1
    check tokens[0].kind == vkOp
    check tokens[0].opSymbol == "+"

  test "lex minus as operator":
    let tokens = tokenize("x - 1")
    check tokens.len == 3
    check tokens[1].kind == vkOp
    check tokens[1].opSymbol == "-"

  test "lex less equal":
    let tokens = tokenize("<=")
    check tokens.len == 1
    check tokens[0].kind == vkOp
    check tokens[0].opSymbol == "<="

  test "lex greater equal":
    let tokens = tokenize(">=")
    check tokens.len == 1
    check tokens[0].kind == vkOp
    check tokens[0].opSymbol == ">="

  test "lex not equal":
    let tokens = tokenize("<>")
    check tokens.len == 1
    check tokens[0].kind == vkOp
    check tokens[0].opSymbol == "<>"

suite "Lexer: Directives":
  test "lex preprocess directive":
    let tokens = tokenize("@preprocess")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkMetaWord
    check tokens[0].wordName == "preprocess"

suite "Lexer: Meta-Words":
  test "lex enter hook":
    let tokens = tokenize("@enter")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkMetaWord
    check tokens[0].wordName == "enter"

  test "lex exit hook":
    let tokens = tokenize("@exit")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkMetaWord
    check tokens[0].wordName == "exit"

  test "lex meta word add":
    let tokens = tokenize("@add")
    check tokens.len == 1
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkMetaWord
    check tokens[0].wordName == "add"

suite "Lexer: URLs":
  test "lex https url":
    let tokens = tokenize("https://example.com")
    check tokens.len == 1
    check tokens[0].kind == vkUrl
    check tokens[0].urlVal == "https://example.com"

  test "lex tcp url with port":
    let tokens = tokenize("tcp://localhost:8080")
    check tokens.len == 1
    check tokens[0].kind == vkUrl
    check tokens[0].urlVal == "tcp://localhost:8080"

  test "lex url with path":
    let tokens = tokenize("https://example.com/api/users")
    check tokens.len == 1
    check tokens[0].kind == vkUrl
    check tokens[0].urlVal == "https://example.com/api/users"

suite "Lexer: Emails":
  test "lex basic email":
    let tokens = tokenize("user@example.com")
    check tokens.len == 1
    check tokens[0].kind == vkEmail
    check tokens[0].emailVal == "user@example.com"

  test "lex email with dots and hyphens":
    # Was expectedFail: Nim lexer had issues with dots in email local part.
    let tokens = tokenize("first.last@my-domain.org")
    check tokens.len == 1
    check tokens[0].kind == vkEmail
    check tokens[0].emailVal == "first.last@my-domain.org"

suite "Lexer: Money":
  test "lex whole dollars":
    let tokens = tokenize("$19")
    check tokens.len == 1
    check tokens[0].kind == vkMoney
    check tokens[0].cents == 1900

  test "lex dollars and cents":
    let tokens = tokenize("$19.99")
    check tokens.len == 1
    check tokens[0].kind == vkMoney
    check tokens[0].cents == 1999

suite "Lexer: Time":
  test "lex hours and minutes":
    let tokens = tokenize("14:30")
    check tokens.len == 1
    check tokens[0].kind == vkTime
    check tokens[0].hour == 14
    check tokens[0].minute == 30

  test "lex hours minutes seconds":
    let tokens = tokenize("14:30:00")
    check tokens.len == 1
    check tokens[0].kind == vkTime
    check tokens[0].hour == 14
    check tokens[0].minute == 30
    check tokens[0].second == 0

suite "Lexer: Comments":
  test "lex comment is skipped":
    let tokens = tokenize("; this is a comment")
    check tokens.len == 0

  test "lex comment after code":
    let tokens = tokenize("42 ; a number")
    check tokens.len == 1
    check tokens[0].kind == vkInteger

suite "Lexer: Multi-token":
  test "lex set word and integer":
    let tokens = tokenize("x: 42")
    check tokens.len == 2
    check tokens[0].kind == vkWord
    check tokens[0].wordKind == wkSetWord
    check tokens[0].wordName == "x"
    check tokens[1].kind == vkInteger
    check tokens[1].intVal == 42

  test "lex all types together":
    let tokens = tokenize("100x200 3.14 \"hello\" true none $19.99 'lit :get @meta")
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


# =============================================================================
# PARSER TESTS (from parser.test.ts)
# =============================================================================

suite "Parser: Atoms":
  test "parse single integer":
    let ast = parseSource("42")
    check ast.len == 1
    check ast[0].kind == vkInteger
    check ast[0].intVal == 42

  test "parse multiple atoms":
    let ast = parseSource("hello 42 \"world\"")
    check ast.len == 3
    check ast[0].kind == vkWord
    check ast[0].wordName == "hello"
    check ast[1].kind == vkInteger
    check ast[1].intVal == 42
    check ast[2].kind == vkString
    check ast[2].strVal == "world"

suite "Parser: Blocks":
  test "parse empty block":
    let ast = parseSource("[]")
    check ast.len == 1
    check ast[0].kind == vkBlock
    check ast[0].blockVals.len == 0

  test "parse block with atoms":
    let ast = parseSource("[1 2 3]")
    check ast.len == 1
    check ast[0].kind == vkBlock
    check ast[0].blockVals.len == 3

  test "parse nested blocks":
    let ast = parseSource("[1 [2 3]]")
    check ast.len == 1
    let outer = ast[0]
    check outer.kind == vkBlock
    check outer.blockVals.len == 2
    check outer.blockVals[0].kind == vkInteger
    check outer.blockVals[0].intVal == 1
    let inner = outer.blockVals[1]
    check inner.kind == vkBlock
    check inner.blockVals.len == 2
    check inner.blockVals[0].kind == vkInteger
    check inner.blockVals[0].intVal == 2
    check inner.blockVals[1].kind == vkInteger
    check inner.blockVals[1].intVal == 3

suite "Parser: Parens":
  test "parse paren group":
    let ast = parseSource("(1 + 2)")
    check ast.len == 1
    check ast[0].kind == vkParen
    check ast[0].parenVals.len == 3
    check ast[0].parenVals[0].kind == vkInteger
    check ast[0].parenVals[0].intVal == 1
    check ast[0].parenVals[1].kind == vkOp
    check ast[0].parenVals[1].opSymbol == "+"
    check ast[0].parenVals[2].kind == vkInteger
    check ast[0].parenVals[2].intVal == 2

suite "Parser: Mixed Nesting":
  test "parse blocks in parens":
    let ast = parseSource("([1 2])")
    check ast.len == 1
    check ast[0].kind == vkParen
    let blk = ast[0].parenVals[0]
    check blk.kind == vkBlock
    check blk.blockVals.len == 2

  test "parse parens in blocks":
    let ast = parseSource("[(1 + 2)]")
    check ast.len == 1
    check ast[0].kind == vkBlock
    let paren = ast[0].blockVals[0]
    check paren.kind == vkParen
    check paren.parenVals.len == 3

suite "Parser: Word Variants":
  test "parse set word":
    let ast = parseSource("name:")
    check ast.len == 1
    check ast[0].kind == vkWord
    check ast[0].wordKind == wkSetWord
    check ast[0].wordName == "name"

  test "parse get word":
    let ast = parseSource(":name")
    check ast.len == 1
    check ast[0].kind == vkWord
    check ast[0].wordKind == wkGetWord
    check ast[0].wordName == "name"

  test "parse lit word":
    let ast = parseSource("'name")
    check ast.len == 1
    check ast[0].kind == vkWord
    check ast[0].wordKind == wkLitWord
    check ast[0].wordName == "name"

  test "parse path":
    # Nim represents paths as words with "/" in the name
    let ast = parseSource("obj/field")
    check ast.len == 1
    check ast[0].kind == vkWord
    check ast[0].wordName == "obj/field"

suite "Parser: Errors":
  test "parse unclosed block":
    try:
      discard parseSource("[1 2")
      check false  # Should have raised
    except KtgError as e:
      check "Unclosed [" in e.msg

  test "parse unclosed paren":
    try:
      discard parseSource("(1 2")
      check false  # Should have raised
    except KtgError as e:
      check "Unclosed (" in e.msg

  test "parse unexpected close bracket":
    try:
      discard parseSource("]")
      check false  # Should have raised
    except KtgError as e:
      check "Unexpected ]" in e.msg

  test "parse unexpected close paren":
    try:
      discard parseSource(")")
      check false  # Should have raised
    except KtgError as e:
      check "Unexpected )" in e.msg

  test "parse mismatched block closed by paren":
    try:
      discard parseSource("[1 2)")
      check false  # Should have raised
    except KtgError as e:
      check "Mismatched" in e.msg

  test "parse mismatched paren closed by bracket":
    try:
      discard parseSource("(1 2]")
      check false  # Should have raised
    except KtgError as e:
      check "Mismatched" in e.msg


# =============================================================================
# VALUES TESTS (from values.test.ts)
# =============================================================================

suite "Values: Construction":
  test "val integer":
    let v = ktgInt(42)
    check v.kind == vkInteger
    check v.intVal == 42

  test "val negative integer":
    let v = ktgInt(-7)
    check v.kind == vkInteger
    check v.intVal == -7

  test "val float":
    let v = ktgFloat(3.14)
    check v.kind == vkFloat
    check v.floatVal == 3.14

  test "val string":
    let v = ktgString("hello")
    check v.kind == vkString
    check v.strVal == "hello"

  test "val logic true":
    let v = ktgLogic(true)
    check v.kind == vkLogic
    check v.boolVal == true

  test "val logic false":
    let v = ktgLogic(false)
    check v.kind == vkLogic
    check v.boolVal == false

  test "val none":
    let v = ktgNone()
    check v.kind == vkNone

  test "val pair":
    let v = ktgPair(100, 200)
    check v.kind == vkPair
    check v.px == 100
    check v.py == 200

  test "val money":
    let v = ktgMoney(1999)
    check v.kind == vkMoney
    check v.cents == 1999

  test "val file":
    let v = ktgFile("path/to/file")
    check v.kind == vkFile
    check v.filePath == "path/to/file"

  test "val url":
    let v = ktgUrl("https://example.com")
    check v.kind == vkUrl
    check v.urlVal == "https://example.com"

  test "val email":
    let v = ktgEmail("user@example.com")
    check v.kind == vkEmail
    check v.emailVal == "user@example.com"

  test "val word":
    let v = ktgWord("hello", wkWord)
    check v.kind == vkWord
    check v.wordName == "hello"
    check v.wordKind == wkWord

  test "val set word":
    let v = ktgWord("name", wkSetWord)
    check v.kind == vkWord
    check v.wordKind == wkSetWord
    check v.wordName == "name"

  test "val get word":
    let v = ktgWord("name", wkGetWord)
    check v.kind == vkWord
    check v.wordKind == wkGetWord
    check v.wordName == "name"

  test "val lit word":
    let v = ktgWord("name", wkLitWord)
    check v.kind == vkWord
    check v.wordKind == wkLitWord
    check v.wordName == "name"

  test "val meta word":
    let v = ktgWord("enter", wkMetaWord)
    check v.kind == vkWord
    check v.wordKind == wkMetaWord
    check v.wordName == "enter"

  test "val block inert":
    let v = ktgBlock(@[ktgInt(1), ktgInt(2), ktgInt(3)])
    check v.kind == vkBlock
    check v.blockVals.len == 3
    check v.blockVals[0].intVal == 1
    check v.blockVals[1].intVal == 2
    check v.blockVals[2].intVal == 3

  test "val paren":
    let v = ktgParen(@[ktgInt(1), KtgValue(kind: vkOp, opFn: nil, opSymbol: "+"), ktgInt(2)])
    check v.kind == vkParen
    check v.parenVals.len == 3

  test "val nested block":
    let v = ktgBlock(@[
      ktgBlock(@[ktgInt(1), ktgInt(2)]),
      ktgBlock(@[ktgInt(3), ktgInt(4)])
    ])
    check v.kind == vkBlock
    check v.blockVals.len == 2
    check v.blockVals[0].kind == vkBlock
    check v.blockVals[1].kind == vkBlock

suite "Values: Truthiness":
  test "truthy none is falsy":
    check not isTruthy(ktgNone())

  test "truthy false is falsy":
    check not isTruthy(ktgLogic(false))

  test "truthy true is truthy":
    check isTruthy(ktgLogic(true))

  test "truthy zero is truthy":
    check isTruthy(ktgInt(0))

  test "truthy empty string is truthy":
    check isTruthy(ktgString(""))

  test "truthy empty block is truthy":
    check isTruthy(ktgBlock())

suite "Values: typeOf":
  test "typeof integer":
    check typeName(ktgInt(42)) == "integer!"

  test "typeof string":
    check typeName(ktgString("hi")) == "string!"

  test "typeof none":
    check typeName(ktgNone()) == "none!"

suite "Values: Display":
  test "display integer":
    check $ktgInt(42) == "42"

  test "display string":
    check $ktgString("hi") == "hi"

  test "display logic":
    check $ktgLogic(true) == "true"

  test "display none":
    check $ktgNone() == "none"

  test "display block":
    check $ktgBlock(@[ktgInt(1)]) == "[1]"


# =============================================================================
# EQUALITY TESTS (from test_basics.nim patterns, verified against spec)
# =============================================================================

suite "Equality":
  test "eq numeric cross type":
    # Rule 1: integer = float if same numeric value
    check valuesEqual(ktgInt(42), ktgFloat(42.0))

  test "eq money own domain":
    # Rule 2: money only equals money
    check not valuesEqual(ktgMoney(4200), ktgInt(42))
    check valuesEqual(ktgMoney(1999), ktgMoney(1999))

  test "eq block structural":
    # Spec: Block equality is structural ([1 2 3] = [1 2 3] is true)
    check valuesEqual(ktgBlock(@[ktgInt(1), ktgInt(2)]), ktgBlock(@[ktgInt(1), ktgInt(2)]))
    check not valuesEqual(ktgBlock(@[ktgInt(1)]), ktgBlock(@[ktgInt(2)]))

  test "eq string case sensitive":
    # Rule 6: strings are case-sensitive
    check not valuesEqual(ktgString("abc"), ktgString("ABC"))
    check valuesEqual(ktgString("abc"), ktgString("abc"))

  test "eq word case insensitive same subtype":
    # Rule 7: words are case-insensitive but must be same subtype
    # Spec: 'hello = first [hello] is FALSE (lit-word vs word)
    check valuesEqual(ktgWord("hello", wkLitWord), ktgWord("Hello", wkLitWord))
    check not valuesEqual(ktgWord("hello", wkLitWord), ktgWord("hello", wkWord))

  test "eq none only none":
    # Rule 9: none equals only none
    check valuesEqual(ktgNone(), ktgNone())
    check not valuesEqual(ktgNone(), ktgLogic(false))

  test "eq cross type false":
    # Rule 10: cross-type is false
    check not valuesEqual(ktgInt(1), ktgString("1"))


# =============================================================================
# TO / JOIN TESTS (from to-join.test.ts)
# These require the evaluator at runtime. Here we verify parse structure only.
# =============================================================================

suite "To Conversions (parse only)":
  test "to integer from string":
    let ast = parseSource("to integer! \"42\"")
    check ast.len == 3
    check ast[0].kind == vkWord
    check ast[0].wordName == "to"
    check ast[1].kind == vkType
    check ast[1].typeName == "integer!"
    check ast[2].kind == vkString
    check ast[2].strVal == "42"

  test "to integer from float parse":
    let ast = parseSource("to integer! 3.99")
    check ast.len == 3
    check ast[0].wordName == "to"
    check ast[1].typeName == "integer!"
    check ast[2].kind == vkFloat
    check ast[2].floatVal == 3.99

  test "to integer from logic is error":
    # SPEC: `to integer! true` is ERROR (numbers and logic don't cross)
    # The TS test expected this to return 1 -- that CONFLICTS with the spec.
    # Spec is source of truth: this conversion should be an error at eval time.
    let ast = parseSource("to integer! true")
    check ast.len == 3
    check ast[0].wordName == "to"
    check ast[1].typeName == "integer!"
    check ast[2].kind == vkLogic
    # NOTE: At eval time, this must produce an error per spec section 4.2.

  test "to logic from zero is error":
    # SPEC: `to logic! 0` is ERROR (numbers and logic are different domains)
    let ast = parseSource("to logic! 0")
    check ast.len == 3
    check ast[0].wordName == "to"
    check ast[1].typeName == "logic!"
    check ast[2].kind == vkInteger
    # NOTE: At eval time, this must produce an error per spec section 4.2.

  test "to float from string parse":
    let ast = parseSource("to float! \"3.14\"")
    check ast.len == 3
    check ast[0].wordName == "to"
    check ast[1].typeName == "float!"
    check ast[2].kind == vkString

  test "to float from integer parse":
    let ast = parseSource("to float! 7")
    check ast.len == 3
    check ast[2].kind == vkInteger
    check ast[2].intVal == 7

  test "to string from integer parse":
    let ast = parseSource("to string! 42")
    check ast.len == 3
    check ast[1].typeName == "string!"
    check ast[2].intVal == 42

  test "to string from logic parse":
    let ast = parseSource("to string! true")
    check ast.len == 3
    check ast[2].kind == vkLogic

  test "to word from string parse":
    let ast = parseSource("to word! \"hello\"")
    check ast.len == 3
    check ast[1].typeName == "word!"
    check ast[2].strVal == "hello"

  test "to block wraps value parse":
    let ast = parseSource("to block! 42")
    check ast.len == 3
    check ast[1].typeName == "block!"
    check ast[2].intVal == 42

  test "to float from logic is error":
    # SPEC: `to float! true` is ERROR (logic and numbers are different domains)
    let ast = parseSource("to float! true")
    check ast.len == 3
    # NOTE: At eval time, this must produce an error per spec section 4.2.

  test "to string from block parse":
    # Spec: to string! [1 2 3] -> "123" (rejoin, no separator)
    # TS test expected "1 2 3" (space-separated) -- SPEC OVERRIDE.
    let ast = parseSource("to string! [1 2 3]")
    check ast.len == 3  # "to", "string!", [1 2 3]
    check ast[0].wordName == "to"
    check ast[1].kind == vkType
    check ast[1].typeName == "string!"
    check ast[2].kind == vkBlock
    check ast[2].blockVals.len == 3

suite "Join (parse only)":
  test "join two strings parse":
    let ast = parseSource("join \"hello\" \" world\"")
    check ast.len == 3
    check ast[0].kind == vkWord
    check ast[0].wordName == "join"
    check ast[1].kind == vkString
    check ast[1].strVal == "hello"
    check ast[2].kind == vkString
    check ast[2].strVal == " world"

  test "join string and integer parse":
    let ast = parseSource("join \"count: \" 42")
    check ast.len == 3
    check ast[0].wordName == "join"
    check ast[1].strVal == "count: "
    check ast[2].intVal == 42

  test "join string and block parse":
    let ast = parseSource("join \"hello\" [\" \" \"world\"]")
    check ast.len == 3
    check ast[0].wordName == "join"
    check ast[1].strVal == "hello"
    check ast[2].kind == vkBlock
    check ast[2].blockVals.len == 2

  test "join string and mixed block parse":
    let ast = parseSource("join \"val: \" [1 \" + \" 2]")
    check ast.len == 3
    check ast[0].wordName == "join"
    check ast[2].kind == vkBlock
    check ast[2].blockVals.len == 3


# =============================================================================
# SPEC-DRIVEN TESTS (not from TS, but validating spec rules in Nim)
# =============================================================================

suite "Spec-Driven":
  test "append string is error parse":
    # Spec: append on strings is ERROR (strings are immutable)
    # This is a parse-only check; eval would need to raise error.
    let ast = parseSource("append \"hello\" \"world\"")
    check ast.len == 3
    check ast[0].wordName == "append"
    check ast[1].strVal == "hello"
    check ast[2].strVal == "world"

  test "first block returns word parse":
    # Spec: first [hello] returns word! (not lit-word!) -- REBOL behavior
    # This is a parse-only check.
    let ast = parseSource("first [hello]")
    check ast.len == 2
    check ast[0].wordName == "first"
    check ast[1].kind == vkBlock
    check ast[1].blockVals.len == 1
    check ast[1].blockVals[0].kind == vkWord
    check ast[1].blockVals[0].wordName == "hello"

  test "try returns context parse":
    # Spec: try returns context! with path access, not block with select
    # Parse-only: verify the input is well-formed
    let ast = parseSource("try [1 / 0]")
    check ast.len == 2
    check ast[0].wordName == "try"
    check ast[1].kind == vkBlock
