> [!CAUTION]
> This language is in active development. Things will change and break until this notice goes away or we hit 1.0.

<br/>

<img src="/assets/logo-full.svg" width="500" height="250" />

<br/>

### (/kɪnˈtsuːɡi/, Japanese: 金継ぎ, lit. "golden joinery")
#### noun, also known as "kintsukuroi" (金繕い, "golden repair")
> 1. the Japanese art of repairing broken pottery by mending the areas of breakage with urushi lacquer dusted or mixed with powdered gold, silver, or platinum
> 2. a homoiconic programming language inspired by REBOL that compiles to LOVE- or Playdate-compatible Lua

<br/>

```red
qsort: function [blk] [
  if (length blk) <= 1 [return blk]
  set [pivot @rest] blk
  set [lo hi] loop/partition [for [x] in rest do [x < pivot]]
  append (append qsort lo pivot) qsort hi
]

unsorted: [3 1 4 1 5 9 2 6 5 3]
sorted: qsort unsorted
probe sorted                            ; 1 1 2 3 3 4 5 5 6 9
```

<br/>

## Rich Types

27 built-in types. Everything JSON can express, plus:

```red
42                    ; integer!
3.14                  ; float!
$19.99                ; money! (exact cents, no float drift)
100.5x200.5           ; pair! (2D coordinates, float64 components)
1.2.3                 ; tuple! (versions, colors)
2026-03-15            ; date!
14:30:00              ; time!
%path/to/file         ; file!
https://example.com   ; url!
user@example.com      ; email!
'north                ; lit-word! (symbol)
[1 "two" true]        ; block! (the universal container)
```

## Syntax Categories

```
word      look up, maybe call
word:     bind a value
'word     the symbol itself
:word     get without calling
@word     (reasonable) magic happens here
[block]   data
(paren)   evaluate now
/refine   modify behavior
```

That's the whole grammar. Left-to-right evaluation, no operator precedence.

## Learn Kintsugi in Y Minutes

The language spec is a single executable file, found [here](examples/full-spec.ktg).

## Installation

Requires [Nim](https://nim-lang.org/) 2.0+.

```bash
nimble build                          # build interpreter + compiler
nimble test                           # run all tests
kintsugi                              # REPL
kintsugi file.ktg                     # run a file
kintsugi -e 'print 1 + 2'             # evaluate expression
kintsugi -c file.ktg --target=<love2d|playdate>              # compile to Lua
kintsugi -c file.ktg --target=<love2d|playdate> --dry-run    # compile to Lua and print result to stdout
```
