import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

describe('#preprocess', () => {
  test('emit injects code', () => {
    const ev = new Evaluator();
    ev.evalString('#preprocess [emit [x: 42]]');
    expect(ev.evalString('x')).toEqual({ type: 'integer!', value: 42 });
  });

  test('conditional emit', () => {
    const ev = new Evaluator();
    ev.evalString(`#preprocess [
      either platform = 'script [
        emit [target: "script"]
      ] [
        emit [target: "other"]
      ]
    ]`);
    expect(ev.evalString('target')).toEqual({ type: 'string!', value: 'script' });
  });

  test('multiple emits', () => {
    const ev = new Evaluator();
    ev.evalString(`#preprocess [
      emit [a: 1]
      emit [b: 2]
    ]`);
    expect(ev.evalString('a')).toEqual({ type: 'integer!', value: 1 });
    expect(ev.evalString('b')).toEqual({ type: 'integer!', value: 2 });
  });

  test('emit with compose for code generation', () => {
    const ev = new Evaluator();
    ev.evalString(`#preprocess [
      loop [
        for [field] in [name age email] [
          emit compose [
            (to set-word! join "get-" field) function [obj] [
              select obj (to lit-word! field)
            ]
          ]
        ]
      ]
    ]`);
    ev.evalString('user: [name "Alice" age 25 email "a@b.com"]');
    expect(ev.evalString('get-name user')).toEqual({ type: 'string!', value: 'Alice' });
    expect(ev.evalString('get-age user')).toEqual({ type: 'integer!', value: 25 });
  });

  test('compile-time constants', () => {
    const ev = new Evaluator();
    ev.evalString(`#preprocess [
      emit [
        max-connections: 100
        build-date: 2026-03-15
      ]
    ]`);
    expect(ev.evalString('max-connections')).toEqual({ type: 'integer!', value: 100 });
  });
});
