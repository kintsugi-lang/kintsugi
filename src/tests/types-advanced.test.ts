import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('custom types with @type', () => {
  test('@type creates a union type', () => {
    const ev = new Evaluator();
    ev.evalString('string-or-none!: @type [string! | none!]');
    ev.evalString('greet: function [name [string-or-none!]] [either none? name ["hello stranger"] [join "hello " name]]');
    expect(ev.evalString('greet "Ray"')).toEqual({ type: 'string!', value: 'hello Ray' });
    expect(ev.evalString('greet none')).toEqual({ type: 'string!', value: 'hello stranger' });
  });

  test('@type rejects wrong type', () => {
    const ev = new Evaluator();
    ev.evalString('string-or-none!: @type [string! | none!]');
    ev.evalString('f: function [x [string-or-none!]] [x]');
    expect(() => ev.evalString('f 42')).toThrow('x expects string-or-none!, got integer!');
  });
});

describe('@type/where', () => {
  test('where adds a guard to the type', () => {
    const ev = new Evaluator();
    ev.evalString('positive!: @type/where [integer!] [it > 0]');
    ev.evalString('f: function [x [positive!]] [x * 2]');
    expect(ev.evalString('f 5')).toEqual({ type: 'integer!', value: 10 });
  });

  test('where rejects values that fail the guard', () => {
    const ev = new Evaluator();
    ev.evalString('positive!: @type/where [integer!] [it > 0]');
    ev.evalString('f: function [x [positive!]] [x * 2]');
    expect(() => ev.evalString('f -3')).toThrow('x fails where clause for positive!');
  });

  test('where rejects wrong base type', () => {
    const ev = new Evaluator();
    ev.evalString('positive!: @type/where [integer!] [it > 0]');
    ev.evalString('f: function [x [positive!]] [x * 2]');
    expect(() => ev.evalString('f "hi"')).toThrow('x expects positive!, got string!');
  });
});

describe('type matching in match', () => {
  test('match by type', () => {
    expect(eval_(`
      match 42 [
        [integer!]  ["got int"]
        [string!]   ["got string"]
        [_]         ["other"]
      ]
    `)).toEqual({ type: 'string!', value: 'got int' });
  });

  test('match string by type', () => {
    expect(eval_(`
      match "hello" [
        [integer!]  ["got int"]
        [string!]   ["got string"]
        [_]         ["other"]
      ]
    `)).toEqual({ type: 'string!', value: 'got string' });
  });

  test('match with type and capture', () => {
    expect(eval_(`
      match [42 "hello"] [
        [integer! string!]  ["typed pair"]
        [_]                 ["other"]
      ]
    `)).toEqual({ type: 'string!', value: 'typed pair' });
  });

  test('type match with custom @type', () => {
    const ev = new Evaluator();
    ev.evalString('number!: @type [integer! | float!]');
    expect(ev.evalString(`
      match 3.14 [
        [number!] ["got number"]
        [_]       ["other"]
      ]
    `)).toEqual({ type: 'string!', value: 'got number' });
  });
});

describe('typed blocks', () => {
  test('block with element type constraint', () => {
    const ev = new Evaluator();
    ev.evalString('sum: function [nums [block! integer!]] [loop/fold [for [acc n] in nums [acc + n]]]');
    expect(ev.evalString('sum [1 2 3 4]')).toEqual({ type: 'integer!', value: 10 });
  });

  test('typed block rejects wrong element types', () => {
    const ev = new Evaluator();
    ev.evalString('sum: function [nums [block! integer!]] [loop/fold [for [acc n] in nums [acc + n]]]');
    expect(() => ev.evalString('sum [1 "two" 3]')).toThrow('nums expects block! of integer!');
  });

  test('untyped block accepts anything', () => {
    const ev = new Evaluator();
    ev.evalString('f: function [data [block!]] [length? data]');
    expect(ev.evalString('f [1 "a" true]')).toEqual({ type: 'integer!', value: 3 });
  });
});
