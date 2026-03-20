import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('to word types', () => {
  test('to word! from string', () => {
    expect(eval_('to word! "hello"')).toEqual({ type: 'word!', name: 'hello' });
  });

  test('to set-word! from string', () => {
    expect(eval_('to set-word! "x"')).toEqual({ type: 'set-word!', name: 'x' });
  });

  test('to lit-word! from string', () => {
    expect(eval_('to lit-word! "name"')).toEqual({ type: 'lit-word!', name: 'name' });
  });

  test('to get-word! from string', () => {
    expect(eval_('to get-word! "print"')).toEqual({ type: 'get-word!', name: 'print' });
  });

  test('to block! from string', () => {
    const result = eval_('to block! "hello"');
    expect(result.type).toBe('block!');
    if (result.type === 'block!') {
      expect(result.values).toEqual([{ type: 'string!', value: 'hello' }]);
    }
  });
});

describe('bind', () => {
  test('bind words in block to context', () => {
    const ev = new Evaluator();
    ev.evalString('point: context [x: 10 y: 20]');
    ev.evalString('code: [x + y]');
    ev.evalString('bind code point');
    expect(ev.evalString('do code')).toEqual({ type: 'integer!', value: 30 });
  });

  test('bind mutates the block in place', () => {
    const ev = new Evaluator();
    ev.evalString('env: context [a: 99]');
    ev.evalString('blk: [a]');
    ev.evalString('bind blk env');
    expect(ev.evalString('do blk')).toEqual({ type: 'integer!', value: 99 });
  });

  test('bind does not affect words not in context', () => {
    const ev = new Evaluator();
    ev.evalString('env: context [x: 5]');
    ev.evalString('y: 10');
    ev.evalString('code: [x + y]');
    ev.evalString('bind code env');
    expect(ev.evalString('do code')).toEqual({ type: 'integer!', value: 15 });
  });

  test('bind works with nested blocks', () => {
    const ev = new Evaluator();
    ev.evalString('env: context [n: 42]');
    ev.evalString('code: [if true [n]]');
    ev.evalString('bind code env');
    expect(ev.evalString('do code')).toEqual({ type: 'integer!', value: 42 });
  });

  test('bind returns the block', () => {
    const ev = new Evaluator();
    ev.evalString('env: context [x: 7]');
    expect(ev.evalString('do bind [x] env')).toEqual({ type: 'integer!', value: 7 });
  });
});

describe('words-of', () => {
  test('returns words in a context', () => {
    const ev = new Evaluator();
    ev.evalString('env: context [x: 10 y: 20]');
    const result = ev.evalString('words-of env');
    expect(result.type).toBe('block!');
    if (result.type === 'block!') {
      expect(result.values).toHaveLength(2);
      const names = result.values.map((v: any) => v.name).sort();
      expect(names).toEqual(['x', 'y']);
    }
  });
});

describe('homoiconic code generation', () => {
  test('compose + to set-word! builds runnable code', () => {
    const ev = new Evaluator();
    ev.evalString('field: "greeting"');
    ev.evalString('code: compose [(to set-word! field) "hello world"]');
    ev.evalString('do code');
    expect(ev.evalString('greeting')).toEqual({ type: 'string!', value: 'hello world' });
  });

  test('generate a function dynamically', () => {
    const ev = new Evaluator();
    ev.evalString('name: "double"');
    ev.evalString('code: compose [(to set-word! name) function [x] [x * 2]]');
    ev.evalString('do code');
    expect(ev.evalString('double 21')).toEqual({ type: 'integer!', value: 42 });
  });

  test('bind + do for scoped code execution', () => {
    const ev = new Evaluator();
    ev.evalString('math: context [pi: 3.14 tau: 6.28]');
    ev.evalString('code: [pi + tau]');
    ev.evalString('bind code math');
    expect(ev.evalString('do code')).toEqual({ type: 'float!', value: 9.42 });
  });
});
