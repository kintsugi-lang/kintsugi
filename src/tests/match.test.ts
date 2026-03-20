import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

const evalWith = (input: string) => {
  const ev = new Evaluator();
  const result = ev.evalString(input);
  return { result, output: ev.output };
};

describe('match — literal matching', () => {
  test('matches exact block', () => {
    const { output } = evalWith(`
      match [1 2 3] [
        [1 2 3] [print "got it"]
        [_]     [print "nope"]
      ]
    `);
    expect(output).toEqual(['got it']);
  });

  test('wildcard matches anything', () => {
    const { output } = evalWith(`
      match [5 6 7] [
        [1 2 3] [print "nope"]
        [_]     [print "catch-all"]
      ]
    `);
    expect(output).toEqual(['catch-all']);
  });

  test('partial wildcard', () => {
    const { output } = evalWith(`
      match [1 99 3] [
        [1 _ 3] [print "matched"]
        [_]     [print "nope"]
      ]
    `);
    expect(output).toEqual(['matched']);
  });

  test('default when nothing matches', () => {
    const { output } = evalWith(`
      match [9 9 9] [
        [1 2 3] [print "nope"]
        default: [print "default"]
      ]
    `);
    expect(output).toEqual(['default']);
  });

  test('returns body result', () => {
    expect(eval_(`
      match [1] [
        [1] [42]
        [_] [0]
      ]
    `)).toEqual({ type: 'integer!', value: 42 });
  });

  test('returns none when nothing matches and no default', () => {
    expect(eval_(`
      match [99] [
        [1] [42]
      ]
    `)).toEqual({ type: 'none!' });
  });
});

describe('match — destructuring', () => {
  test('bare words capture values', () => {
    const ev = new Evaluator();
    const result = ev.evalString(`
      match [10 20] [
        [x y] [x + y]
      ]
    `);
    expect(result).toEqual({ type: 'integer!', value: 30 });
  });

  test('mixed literals and captures', () => {
    const ev = new Evaluator();
    const result = ev.evalString(`
      match [0 42] [
        [0 0]   ["origin"]
        [x 0]   ["x-axis"]
        [0 y]   [rejoin ["y-axis at " y]]
        [x y]   ["both"]
      ]
    `);
    expect(result).toEqual({ type: 'string!', value: 'y-axis at 42' });
  });
});

describe('match — single value', () => {
  test('match wraps non-block in single-element block', () => {
    expect(eval_(`
      match 42 [
        [42] ["found"]
        [_]  ["nope"]
      ]
    `)).toEqual({ type: 'string!', value: 'found' });
  });

  test('capture single value', () => {
    expect(eval_(`
      match 99 [
        [x] [x + 1]
      ]
    `)).toEqual({ type: 'integer!', value: 100 });
  });
});

describe('match — lit-word matching', () => {
  test('lit-word matches word value', () => {
    expect(eval_(`
      match 'division-by-zero [
        ['division-by-zero] ["math error"]
        ['unreachable]      ["network error"]
        [_]                 ["unknown"]
      ]
    `)).toEqual({ type: 'string!', value: 'math error' });
  });
});

describe('match — paren evaluation', () => {
  test('paren evaluates and matches result', () => {
    expect(eval_(`
      expected: 42
      match 42 [
        [(expected)] ["got expected"]
        [_]          ["nope"]
      ]
    `)).toEqual({ type: 'string!', value: 'got expected' });
  });

  test('paren expression evaluation', () => {
    expect(eval_(`
      x: 9
      match 10 [
        [(x + 1)] ["matched x+1"]
        [_]       ["nope"]
      ]
    `)).toEqual({ type: 'string!', value: 'matched x+1' });
  });
});

describe('match — guards', () => {
  test('when clause filters matches', () => {
    expect(eval_(`
      match 15 [
        [n] when [n < 13]  ["child"]
        [n] when [n < 20]  ["teenager"]
        [n] when [n < 65]  ["adult"]
        [_]                ["senior"]
      ]
    `)).toEqual({ type: 'string!', value: 'teenager' });
  });

  test('guard fails, tries next pattern', () => {
    expect(eval_(`
      match 70 [
        [n] when [n < 13]  ["child"]
        [n] when [n < 65]  ["adult"]
        [_]                ["senior"]
      ]
    `)).toEqual({ type: 'string!', value: 'senior' });
  });
});

describe('match — string matching', () => {
  test('match on string value', () => {
    expect(eval_(`
      match "hello" [
        ["hello"] ["greeting"]
        ["bye"]   ["farewell"]
        [_]       ["unknown"]
      ]
    `)).toEqual({ type: 'string!', value: 'greeting' });
  });
});
