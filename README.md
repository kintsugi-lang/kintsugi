<img src="/assets/logo-full.svg" width="500" height="250" />

> [!CAUTION]
> This language is in active development. Things will change and break until this notice goes away or we hit 1.0.

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

The language spec is a single executable file, found [here](examples/full-spec.ktg).
