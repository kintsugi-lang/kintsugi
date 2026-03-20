import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';
import { compileToLua } from '@/compiler/compile';
import { execFileSync } from 'child_process';
import { writeFileSync, unlinkSync } from 'fs';

// Run a program in both the interpreter and compiled Lua,
// verify they produce the same output.
function validate(name: string, source: string) {
  test(name, () => {
    // Interpreter output
    const ev = new Evaluator();
    ev.evalString(source);
    const interpOutput = ev.output.join('\n');

    // Compiled Lua output
    const lua = compileToLua(source);
    const tmpPath = `/tmp/ktg-validate-${name.replace(/\s+/g, '-')}.lua`;
    writeFileSync(tmpPath, lua);
    let luaOutput: string;
    try {
      luaOutput = execFileSync('lua', [tmpPath], { encoding: 'utf-8' }).trimEnd();
    } finally {
      try { unlinkSync(tmpPath); } catch {}
    }

    expect(luaOutput).toBe(interpOutput);
  });
}

describe('validation — interpreter vs Lua output', () => {
  validate('arithmetic', `
    print 2 + 3
    print 10 - 4
    print 3 * 7
    print 2 + 3 * 4
    print 2 + (3 * 4)
  `);

  validate('variables', `
    x: 42
    y: x + 8
    print x
    print y
  `);

  validate('strings', `
    print join "hello" " world"
    print uppercase "hello"
    print lowercase "HELLO"
    print trim "  hi  "
  `);

  validate('function call', `
    add: function [a b] [a + b]
    print add 3 4
    print add 10 20
  `);

  validate('recursion', `
    fact: function [n] [
      if n = 0 [return 1]
      return n * fact (n - 1)
    ]
    print fact 5
    print fact 10
  `);

  validate('closures', `
    make-adder: function [n] [function [x] [x + n]]
    add5: make-adder 5
    print add5 10
    print add5 100
  `);

  validate('if either', `
    print if true [42]
    either 5 > 3 [print "yes"] [print "no"]
    either 1 > 9 [print "yes"] [print "no"]
  `);

  validate('for range', `
    loop [for [n] from 1 to 5 [print n]]
  `);

  validate('for each', `
    loop [for [item] in [10 20 30] [print item]]
  `);

  validate('context', `
    p: context [x: 10 y: 20]
    print p/x
    print p/y
    p/x: 99
    print p/x
  `);

  validate('comparison', `
    print 5 > 3
    print 5 < 3
    print 5 = 5
    print 5 <> 3
  `);

  validate('logic', `
    print not true
    print not false
    print true and true
    print true and false
  `);

  validate('min max abs', `
    print min 3 7
    print max 3 7
    print abs -42
    print negate 5
  `);

  validate('nested either', `
    sign: function [n] [
      either n > 0 [1] [
        either n < 0 [-1] [0]
      ]
    ]
    print sign 5
    print sign -3
    print sign 0
  `);

  // Tier 3 — homoiconic words in compiled code

  validate('compose literal block', `
    result: compose [1 (2 + 3) 4]
    print first result
    print second result
    print last result
  `);

  validate('reduce literal block', `
    result: reduce [1 + 2 3 + 4 5 * 2]
    print first result
    print second result
    print last result
  `);

  validate('all short-circuit', `
    print all [true true 42]
    print all [true false 42]
  `);

  validate('any short-circuit', `
    print any [false false 42]
    print any [false 10 42]
  `);

  validate('words-of context', `
    p: context [x: 10 y: 20]
    w: words-of p
    print length? w
  `);

  validate('bind is no-op', `
    data: [1 2 3]
    bind data context [x: 10]
    print first data
  `);

  validate('type predicates', `
    print integer? 42
    print string? "hello"
    print logic? true
    print block? [1 2 3]
    print integer? "nope"
  `);
});
