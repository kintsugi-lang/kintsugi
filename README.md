<img src="/assets/logo-full.svg" width="500" height="250" />

Kintsugi is a homoiconic programming language with rich built-in datatypes, preprocessing, and a number of useful facilities powered by DSLs called "dialects". Influenced by REBOL, Red, Ren-C, Common Lisp, D, Python, Kotlin, and Raku.

> [!CAUTION]
> This language is in active development. Things will change and break until this notice goes away or we hit 1.0.

```red
traffic-light-color!: @type/enum ['red | 'yellow | 'green]

TrafficLight: object [
  field/optional [state [traffic-light-color!] 'red]
  field/optional [timer [integer!] 0]

  advance: function [] [
    match self/state [
      ['red]    [self/state: 'green  self/timer: 30]
      ['green]  [self/state: 'yellow self/timer: 5]
      ['yellow] [self/state: 'red    self/timer: 45]
    ]
  ]

  display: function [] [
    rejoin ["[" (uppercase to string! self/state) "] " self/timer "s"]
  ]
]

light: make TrafficLight []
print light/display                     ; [RED] 0s
light/advance
print light/display                     ; [GREEN] 30s
light/advance
print light/display                     ; [YELLOW] 5s
light/advance
print light/display                     ; [RED] 45s
```


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

## Learn Kintsugi in Y Minutes

The language spec is a single executable file, found [here](/full-spec.ktg).
