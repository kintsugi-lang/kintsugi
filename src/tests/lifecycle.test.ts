import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const evalWith = (input: string) => {
  const ev = new Evaluator();
  const result = ev.evalString(input);
  return { result, output: ev.output };
};

describe('@enter / @exit', () => {
  test('@enter runs before body', () => {
    const { output } = evalWith(`
      if true [
        @enter [print "enter"]
        print "body"
      ]
    `);
    expect(output).toEqual(['enter', 'body']);
  });

  test('@exit runs after body', () => {
    const { output } = evalWith(`
      if true [
        print "body"
        @exit [print "exit"]
      ]
    `);
    expect(output).toEqual(['body', 'exit']);
  });

  test('@enter and @exit together', () => {
    const { output } = evalWith(`
      if true [
        @enter [print "enter"]
        @exit [print "exit"]
        print "body"
      ]
    `);
    expect(output).toEqual(['enter', 'body', 'exit']);
  });

  test('@exit runs even on error', () => {
    const ev = new Evaluator();
    ev.evalString(`
      result: try [
        @enter [print "enter"]
        @exit [print "exit"]
        error 'fail "boom" none
      ]
    `);
    expect(ev.output).toEqual(['enter', 'exit']);
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
  });

  test('@exit sees bindings from body', () => {
    const { output } = evalWith(`
      if true [
        @exit [print x]
        x: 42
      ]
    `);
    expect(output).toEqual(['42']);
  });
});

