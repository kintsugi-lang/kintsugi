import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('parameter type checking', () => {
  test('accepts correct type', () => {
    expect(eval_('add: function [a [integer!] b [integer!]] [a + b] add 3 4'))
      .toEqual({ type: 'integer!', value: 7 });
  });

  test('rejects wrong type', () => {
    expect(() => eval_('add: function [a [integer!] b [integer!]] [a + b] add "hi" 4'))
      .toThrow('a expects integer!, got string!');
  });

  test('rejects wrong type on second param', () => {
    expect(() => eval_('add: function [a [integer!] b [integer!]] [a + b] add 3 "hi"'))
      .toThrow('b expects integer!, got string!');
  });
});

describe('built-in type union checking', () => {
  test('number! accepts integer', () => {
    expect(eval_('double: function [x [number!]] [x * 2] double 5'))
      .toEqual({ type: 'integer!', value: 10 });
  });

  test('number! accepts float', () => {
    expect(eval_('double: function [x [number!]] [x * 2] double 2.5'))
      .toEqual({ type: 'float!', value: 5 });
  });

  test('number! rejects string', () => {
    expect(() => eval_('double: function [x [number!]] [x * 2] double "hi"'))
      .toThrow('x expects number!, got string!');
  });
});

describe('return type checking', () => {
  test('accepts correct return type', () => {
    expect(eval_('f: function [return: [integer!]] [42] f'))
      .toEqual({ type: 'integer!', value: 42 });
  });

  test('rejects wrong return type', () => {
    expect(() => eval_('f: function [return: [integer!]] ["oops"] f'))
      .toThrow('return expects integer!, got string!');
  });

  test('checks early return type', () => {
    expect(() => eval_('f: function [x [integer!] return: [integer!]] [return "bad"] f 1'))
      .toThrow('return expects integer!, got string!');
  });
});

describe('no constraint means any type', () => {
  test('untyped params accept anything', () => {
    expect(eval_('id: function [x] [x] id 42')).toEqual({ type: 'integer!', value: 42 });
    expect(eval_('id: function [x] [x] id "hi"')).toEqual({ type: 'string!', value: 'hi' });
  });
});

describe('refinement param type checking', () => {
  test('checks refinement param types', () => {
    const ev = new Evaluator();
    ev.evalString('greet: function [name [string!] /loud /times count [integer!]] [name]');
    expect(ev.evalString('greet "Ray"')).toEqual({ type: 'string!', value: 'Ray' });
    expect(() => ev.evalString('greet 42')).toThrow('name expects string!, got integer!');
  });
});

describe('structural types as constraints', () => {
  test('accepts matching block', () => {
    const ev = new Evaluator();
    ev.evalString("point!: @type ['x integer! 'y integer!]");
    ev.evalString('get-x: function [p [point!]] [select p \'x]');
    expect(ev.evalString('get-x [x 10 y 20]')).toEqual({ type: 'integer!', value: 10 });
  });

  test('rejects non-matching block', () => {
    const ev = new Evaluator();
    ev.evalString("point!: @type ['x integer! 'y integer!]");
    ev.evalString('get-x: function [p [point!]] [select p \'x]');
    expect(() => ev.evalString('get-x [name "Alice"]')).toThrow('p expects point!, got block!');
  });

  test('rejects non-block value', () => {
    const ev = new Evaluator();
    ev.evalString("point!: @type ['x integer! 'y integer!]");
    ev.evalString('get-x: function [p [point!]] [select p \'x]');
    expect(() => ev.evalString('get-x 42')).toThrow('p expects point!, got integer!');
  });

  test('structural types compose', () => {
    const ev = new Evaluator();
    ev.evalString("base!: @type ['name string! 'age integer!]");
    ev.evalString('check: function [data [base!]] [select data \'name]');
    expect(ev.evalString('check [name "Alice" age 25]')).toEqual({ type: 'string!', value: 'Alice' });
  });
});
