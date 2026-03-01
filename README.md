# Kintsugi

A homoiconic, dynamically-typed programming language with rich built-in datatypes, compile-time evaluation, and extensible DSLs called "dialects". Influenced by REBOL, Red, Ren-C, Common Lisp, D, and Raku.

```
Kintsugi [
  name: 'hello
  date: 2026-02-26
  file: %hello.ktg
  version: 0.1.0
]

greet: function [name [string!]] [
  print "Hello, " + name
]

greet "world"
```

Code is data. Data is code. Everything is a block.

> **Warning:** Kintsugi is in very early development. Nothing works yet.
