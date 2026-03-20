import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('attempt — basic pipeline', () => {
  test('source sets initial value', () => {
    expect(eval_(`
      attempt [
        source [42]
      ]
    `)).toEqual({ type: 'integer!', value: 42 });
  });

  test('then chains with it', () => {
    expect(eval_(`
      attempt [
        source [10]
        then   [it + 5]
      ]
    `)).toEqual({ type: 'integer!', value: 15 });
  });

  test('multiple then steps', () => {
    expect(eval_(`
      attempt [
        source ["  Hello  "]
        then   [trim it]
        then   [lowercase it]
      ]
    `)).toEqual({ type: 'string!', value: 'hello' });
  });
});

describe('attempt — when guard', () => {
  test('when passes if truthy', () => {
    expect(eval_(`
      attempt [
        source ["hello"]
        when   [not empty? it]
        then   [uppercase it]
      ]
    `)).toEqual({ type: 'string!', value: 'HELLO' });
  });

  test('when short-circuits to none if falsy', () => {
    expect(eval_(`
      attempt [
        source [""]
        when   [not empty? it]
        then   [uppercase it]
      ]
    `)).toEqual({ type: 'none!' });
  });
});

describe('attempt — error handling', () => {
  test('on catches specific error kind', () => {
    expect(eval_(`
      attempt [
        source [error 'bad "oops" none]
        on 'bad [42]
      ]
    `)).toEqual({ type: 'integer!', value: 42 });
  });

  test('on does not catch wrong kind', () => {
    expect(eval_(`
      attempt [
        source [error 'bad "oops" none]
        on 'other [42]
        fallback [99]
      ]
    `)).toEqual({ type: 'integer!', value: 99 });
  });

  test('fallback when no handler matches', () => {
    expect(eval_(`
      attempt [
        source [error 'fail "boom" none]
        fallback [0]
      ]
    `)).toEqual({ type: 'integer!', value: 0 });
  });

  test('error in then step is caught', () => {
    expect(eval_(`
      attempt [
        source [10]
        then   [it / 0]
        on 'math [0]
      ]
    `)).toEqual({ type: 'integer!', value: 0 });
  });
});

describe('attempt — retries', () => {
  test('retries source on error', () => {
    const ev = new Evaluator();
    ev.evalString('count: 0');
    const result = ev.evalString(`
      attempt [
        source [
          count: count + 1
          if count < 3 [error 'fail "not yet" none]
          count
        ]
        retries 5
      ]
    `);
    expect(result).toEqual({ type: 'integer!', value: 3 });
  });

  test('retries exhausted hits fallback', () => {
    expect(eval_(`
      attempt [
        source [error 'fail "always" none]
        retries 2
        fallback [0]
      ]
    `)).toEqual({ type: 'integer!', value: 0 });
  });
});

describe('attempt — reusable pipeline (no source)', () => {
  test('returns a function when no source', () => {
    const ev = new Evaluator();
    ev.evalString(`
      clean: attempt [
        when [not empty? it]
        then [trim it]
        then [lowercase it]
      ]
    `);
    expect(ev.evalString('clean "  HELLO  "')).toEqual({ type: 'string!', value: 'hello' });
    expect(ev.evalString('clean ""')).toEqual({ type: 'none!' });
  });
});
