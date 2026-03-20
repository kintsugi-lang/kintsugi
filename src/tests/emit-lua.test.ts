import { describe, test, expect } from 'bun:test';
import { lower } from '@/compiler/lower';
import { emitLua } from '@/compiler/emit-lua';

const compile = (source: string): string => emitLua(lower(source)).code;

describe('Lua emission — basics', () => {
  test('variable assignment', () => {
    const lua = compile('x: 42');
    expect(lua).toContain('local x = 42');
  });

  test('string assignment', () => {
    const lua = compile('name: "hello"');
    expect(lua).toContain('local name = "hello"');
  });

  test('arithmetic', () => {
    const lua = compile('x: 2 + 3');
    expect(lua).toContain('local x = (2 + 3)');
  });

  test('left to right', () => {
    const lua = compile('x: 2 + 3 * 4');
    expect(lua).toContain('((2 + 3) * 4)');
  });

  test('print', () => {
    const lua = compile('print 42');
    expect(lua).toContain('print(42)');
  });

  test('print with expression', () => {
    const lua = compile('print 2 + 3');
    expect(lua).toContain('print((2 + 3))');
  });
});

describe('Lua emission — functions', () => {
  test('function declaration', () => {
    const lua = compile('add: function [a b] [a + b]');
    expect(lua).toContain('local function add(a, b)');
    expect(lua).toContain('(a + b)');
  });

  test('typed function', () => {
    const lua = compile('add: function [a [integer!] b [integer!]] [a + b]');
    // Lua ignores types — same output
    expect(lua).toContain('local function add(a, b)');
  });

  test('function with return', () => {
    const lua = compile('f: function [x] [return x]');
    expect(lua).toContain('return x');
  });
});

describe('Lua emission — control flow', () => {
  test('if', () => {
    const lua = compile('if true [print 42]');
    expect(lua).toContain('if true then');
    expect(lua).toContain('print(42)');
    expect(lua).toContain('end');
  });

  test('either becomes if/else', () => {
    const lua = compile('either true [print 1] [print 2]');
    expect(lua).toContain('if true then');
    expect(lua).toContain('print(1)');
    expect(lua).toContain('else');
    expect(lua).toContain('print(2)');
  });

  test('for range', () => {
    const lua = compile('loop [for [n] from 1 to 10 [print n]]');
    expect(lua).toContain('for n = 1, 10, 1 do');
    expect(lua).toContain('print(n)');
  });

  test('infinite loop', () => {
    const lua = compile('loop [print 1 break]');
    expect(lua).toContain('while true do');
    expect(lua).toContain('break');
  });
});

describe('Lua emission — operators', () => {
  test('comparison', () => {
    const lua = compile('x: 5 > 3');
    expect(lua).toContain('(5 > 3)');
  });

  test('not equal', () => {
    const lua = compile('x: 5 <> 3');
    expect(lua).toContain('(5 ~= 3)');
  });

  test('and/or', () => {
    const lua = compile('x: true and false');
    expect(lua).toContain('(true and false)');
  });
});

describe('Lua emission — builtins', () => {
  test('length?', () => {
    const lua = compile('print length? [1 2 3]');
    expect(lua).toContain('#');
  });

  test('uppercase', () => {
    const lua = compile('print uppercase "hello"');
    expect(lua).toContain('string.upper("hello")');
  });

  test('min/max', () => {
    const lua = compile('print min 3 7');
    expect(lua).toContain('math.min(3, 7)');
  });
});

describe('Lua emission — Tier 3 words', () => {
  test('compose lowers to block literal', () => {
    const lua = compile('x: compose [1 (2 + 3) 4]');
    expect(lua).toContain('local x = {1, (2 + 3), 4}');
  });

  test('reduce lowers to block literal', () => {
    const lua = compile('x: reduce [1 + 2 3 + 4]');
    expect(lua).toContain('{(1 + 2), (3 + 4)}');
  });

  test('all desugars to and chain', () => {
    const lua = compile('x: all [true true 42]');
    expect(lua).toContain('and');
  });

  test('any desugars to or chain', () => {
    const lua = compile('x: any [false 42]');
    expect(lua).toContain('or');
  });

  test('words-of on literal context emits string array', () => {
    const lua = compile('w: words-of context [x: 10 y: 20]');
    expect(lua).toContain('"x"');
    expect(lua).toContain('"y"');
  });
});

describe('Lua emission — conditional runtime', () => {
  test('no runtime chunk without runtime-requiring words', () => {
    const lua = compile('print 42');
    expect(lua).not.toContain('Runtime:');
  });

  test('type predicates pull in type-predicates chunk', () => {
    const lua = compile('print integer? 42');
    expect(lua).toContain('Runtime: type predicates');
    expect(lua).toContain('__type_check');
  });

  test('to pulls in to chunk', () => {
    const lua = compile('x: to integer! "42"');
    expect(lua).toContain('Runtime: type conversion');
    expect(lua).toContain('__to');
  });

  test('parse pulls in parse chunk', () => {
    const lua = compile('print parse "hello" [some alpha]');
    expect(lua).toContain('Runtime: parse engine');
    expect(lua).toContain('__parse');
  });
});

describe('Lua emission — warnings', () => {
  test('no warnings for basic code', () => {
    const result = emitLua(lower('print 42'));
    expect(result.warnings).toHaveLength(0);
  });

  test('warning emitted for type predicates', () => {
    const result = emitLua(lower('print integer? 42'));
    expect(result.warnings.length).toBeGreaterThan(0);
    expect(result.warnings[0]).toContain('type predicates');
  });

  test('warning emitted for parse', () => {
    const result = emitLua(lower('print parse "hi" [some alpha]'));
    expect(result.warnings.length).toBeGreaterThan(0);
    expect(result.warnings[0]).toContain('parse');
  });

  test('warning emitted once per chunk', () => {
    const result = emitLua(lower('print integer? 42\nprint string? "x"'));
    const typeWarnings = result.warnings.filter(w => w.includes('type predicates'));
    expect(typeWarnings).toHaveLength(1);
  });
});

describe('Lua emission — complete program', () => {
  test('factorial', () => {
    const lua = compile(`
      fact: function [n] [
        if n = 0 [return 1]
        return n * fact (n - 1)
      ]
      print fact 10
    `);
    expect(lua).toContain('local function fact(n)');
    expect(lua).toContain('if (n == 0) then');
    expect(lua).toContain('return 1');
    expect(lua).toContain('return (n * fact((n - 1)))');
    expect(lua).toContain('print(fact(10))');
  });
});
