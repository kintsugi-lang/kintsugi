# Kintsugi

A language where blocks of data become programs. Homoiconic, dialect-driven, compiling to clean Lua for game dev. Influenced by REBOL, Red, Ren-C, Common Lisp, Lua, and Raku.

> [!CAUTION]
> This language is in active development.

```
qsort: function [blk] [
  if (size? blk) <= 1 [return blk]
  set [pivot @rest] blk
  set [lo hi] loop/partition [for [x] in rest do [x < pivot]]
  append append (qsort lo) pivot (qsort hi)
]

probe qsort [3 1 4 1 5 9 2 6 5 3]    ; [1 1 2 3 3 4 5 5 6 9]
```

## Syntax Categories

```
word      look up, maybe call
word:     bind a value
'word     the symbol itself
:word     get without calling
@word     magic happens here
[block]   data
(paren)   evaluate now
/refine   modify behavior
```

That's the whole grammar. Left-to-right evaluation, no operator precedence.

## What `@` Does

The `@` sigil means "the language is doing something structural here."

```
@type [string! | none!]           ; define a type
@type/enum ['north | 'south]      ; define an enum
@const x: 42                      ; constant
@shared score: 0                  ; write-through from inner scopes
@macro unless: function [c b [block!]] [  ; code generation
  @compose [if not (c) (b)]
]

@compose [a (1 + 2) b]            ; block templating  -> [a 3 b]
@parse "hello" [some alpha]       ; PEG parsing
@preprocess [emit [x: 42]]        ; compile-time code injection
@enter [print "start"]            ; lifecycle hook
@exit [print "cleanup"]           ; lifecycle hook
```

## Rich Types

27 built-in types. Everything JSON can express, plus:

```
42                    ; integer!
3.14                  ; float!
$19.99                ; money! (exact cents, no float drift)
100x200               ; pair! (2D coordinates)
1.2.3                 ; tuple! (versions, colors)
2026-03-15            ; date!
14:30:00              ; time!
%path/to/file         ; file!
https://example.com   ; url!
user@example.com      ; email!
'north                ; lit-word! (symbol)
[1 "two" true]        ; block! (the universal container)
```

## System Dialects

Dialects are scoped vocabularies. Words change meaning inside their block.

```
; Loop — for/in, from/to, collect, fold, partition
evens: loop/collect [for [x] from 1 to 10 when [even? x] do [x]]

; Match — pattern matching with destructuring
match value [
  [integer!] [print "a number"]
  ['north]   [print "going north"]
  default:   [print "something else"]
]

; Parse — PEG on strings and blocks
result: @parse "user@example.com" [
  name: some [alpha | digit | "."]
  "@"
  domain: some [alpha | digit | "." | "-"]
]

; Object — prototypes with typed fields
Enemy: object [
  field/required [hp [integer!]]
  field/optional [speed [float!] 1.0]
  damage: function [n] [self/hp: self/hp - n]
]
goblin: make Enemy [hp: 30]

; Attempt — resilient pipelines
result: attempt [
  source [read %config.txt]
  then [trim it]
  fallback ["default"]
]
```

## User Dialects

`capture` extracts keywords from blocks. `@macro` generates code. Together they make user-defined dialects trivial:

```
entity: function [spec [block!]] [
  parts: capture spec [@name @hp @attack @defense]
  ctx: context []
  if not none? parts/name [ctx/name: parts/name]
  if not none? parts/hp [ctx/hp: parts/hp  ctx/max-hp: parts/hp]
  ctx
]

warrior: entity [name "Warrior" hp 100 attack 15 defense 10]
print warrior/max-hp                    ; 100
```

## Compiles to Lua

Target: Lua 5.1 (LOVE2D, Playdate). Zero-dependency output. Tree-shaken prelude — only helpers you use are emitted.

```bash
bin/kintsugi -c game.ktg              # -> game.lua
bin/kintsugi -c src/                  # compile directory
bin/kintsugi -c game.ktg --dry-run    # print to stdout
```

Modules compile recursively. `import` emits `require`. `exports` emits `return {...}`.

## Quick Start

Requires [Nim](https://nim-lang.org/) 2.0+.

```bash
nimble build                          # build interpreter + compiler
nimble test                           # run all tests
bin/kintsugi                          # REPL
bin/kintsugi file.ktg                 # run a file
bin/kintsugi -e 'print 1 + 2'        # evaluate expression
bin/kintsugi -c file.ktg             # compile to Lua
```

## Learn Kintsugi

The language spec is a single executable file:

**[`examples/full-spec.ktg`](examples/full-spec.ktg)** (~1,800 lines)

It covers everything: types, functions, control flow, dialects, objects, error handling, modules, preprocessing, macros, and the compilation model. Because it's `.ktg`, it's tested — if the docs are wrong, the tests fail.

