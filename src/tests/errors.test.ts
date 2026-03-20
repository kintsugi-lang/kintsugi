import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

describe('error and try', () => {
  test('try success result', () => {
    const ev = new Evaluator();
    ev.evalString('result: try [10 + 5]');
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: true });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'integer!', value: 15 });
    expect(ev.evalString("select result 'kind")).toEqual({ type: 'none!' });
    expect(ev.evalString("select result 'message")).toEqual({ type: 'none!' });
    expect(ev.evalString("select result 'data")).toEqual({ type: 'none!' });
  });

  test('try catches division by zero', () => {
    const ev = new Evaluator();
    ev.evalString('result: try [10 / 0]');
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'none!' });
  });

  test('try catches error with kind + message', () => {
    const ev = new Evaluator();
    ev.evalString("result: try [error 'test-error \"oops\" none]");
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    expect(ev.evalString("select result 'kind")).toEqual({ type: 'lit-word!', name: 'test-error' });
    expect(ev.evalString("select result 'message")).toEqual({ type: 'string!', value: 'oops' });
  });

  test('try catches error with data', () => {
    const ev = new Evaluator();
    ev.evalString("result: try [error 'bad \"msg\" [x: 1]]");
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    const data = ev.evalString("select result 'data");
    expect(data.type).toBe('block!');
  });

  test('error with kind only', () => {
    const ev = new Evaluator();
    ev.evalString("result: try [error 'fail none none]");
    expect(ev.evalString("select result 'kind")).toEqual({ type: 'lit-word!', name: 'fail' });
    expect(ev.evalString("select result 'message")).toEqual({ type: 'none!' });
  });
});

describe('try/handle', () => {
  test('handler receives error info and returns value', () => {
    const ev = new Evaluator();
    ev.evalString("handler: function [kind msg data] [42]");
    ev.evalString("result: try/handle [error 'bad \"oops\" none] :handler");
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'integer!', value: 42 });
  });

  test('handler not called on success', () => {
    const ev = new Evaluator();
    ev.evalString("handler: function [kind msg data] [99]");
    ev.evalString('result: try/handle [10 + 5] :handler');
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: true });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'integer!', value: 15 });
  });

  test('inline handler function', () => {
    const ev = new Evaluator();
    ev.evalString("result: try/handle [error 'fail \"boom\" none] function [kind msg data] [msg]");
    expect(ev.evalString("select result 'value")).toEqual({ type: 'string!', value: 'boom' });
  });
});
