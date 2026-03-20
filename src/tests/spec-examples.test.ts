import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

describe('spec examples', () => {
  test('quicksort', () => {
    const ev = new Evaluator();
    ev.evalString(`
      qsort: function [blk] [
        if (length? blk) <= 1 [return blk]
        pivot: first blk
        rest: copy blk
        remove rest 1
        set [lo hi] loop/partition [for [x] in rest [x < pivot]]
        result: qsort lo
        append result pivot
        loop [for [x] in qsort hi [append result x]]
        result
      ]
    `);
    ev.evalString('unsorted: [3 1 4 1 5 9 2 6 5 3]');
    ev.evalString('sorted: qsort unsorted');
    const sorted = ev.evalString('sorted');
    expect(sorted.type).toBe('block!');
    if (sorted.type === 'block!') {
      expect(sorted.values.map((v: any) => v.value)).toEqual([1, 1, 2, 3, 3, 4, 5, 5, 6, 9]);
    }
  });

  test('fibonacci', () => {
    const ev = new Evaluator();
    ev.evalString(`
      fib: function [n] [
        seq: [0 1]
        loop [
          from 1 to (n - 2)
          [
            a: pick seq ((length? seq) - 1)
            b: last seq
            append seq (a + b)
          ]
        ]
        seq
      ]
    `);
    const result = ev.evalString('fib 10');
    expect(result.type).toBe('block!');
    if (result.type === 'block!') {
      expect(result.values.map((v: any) => v.value)).toEqual([0, 1, 1, 2, 3, 5, 8, 13, 21, 34]);
    }
  });

  test('fizzbuzz', () => {
    const ev = new Evaluator();
    ev.evalString(`
      loop [
        for [n] from 1 to 20 [
          either (n % 15) = 0 [print "FizzBuzz"] [
            either (n % 3) = 0 [print "Fizz"] [
              either (n % 5) = 0 [print "Buzz"] [
                print n
              ]
            ]
          ]
        ]
      ]
    `);
    expect(ev.output).toEqual([
      '1', '2', 'Fizz', '4', 'Buzz', 'Fizz', '7', '8', 'Fizz', 'Buzz',
      '11', 'Fizz', '13', '14', 'FizzBuzz', '16', '17', 'Fizz', '19', 'Buzz',
    ]);
  });

  test('factorial with loop', () => {
    const ev = new Evaluator();
    ev.evalString(`
      n: 1
      factorial: 1
      loop [
        if n > 5 [break]
        factorial: factorial * n
        n: n + 1
      ]
    `);
    expect(ev.evalString('factorial')).toEqual({ type: 'integer!', value: 120 });
  });

  test('structural type validation with is?', () => {
    const ev = new Evaluator();
    ev.evalString("user!: @type ['name string! 'age integer!]");
    expect(ev.evalString('is? user! [name "Alice" age 25]')).toEqual({ type: 'logic!', value: true });
    expect(ev.evalString('is? user! [name "Alice"]')).toEqual({ type: 'logic!', value: false });
    expect(ev.evalString('is? user! [name 42 age 25]')).toEqual({ type: 'logic!', value: false });
  });

  test('code generation with preprocess', () => {
    const ev = new Evaluator();
    ev.evalString(`
      #preprocess [
        loop [
          for [field] in [name age] [
            emit compose [
              (to set-word! join "get-" field) function [obj] [
                select obj (to lit-word! field)
              ]
            ]
          ]
        ]
      ]
    `);
    ev.evalString('user: [name "Alice" age 25]');
    expect(ev.evalString('get-name user')).toEqual({ type: 'string!', value: 'Alice' });
    expect(ev.evalString('get-age user')).toEqual({ type: 'integer!', value: 25 });
  });

  test('error handling with try', () => {
    const ev = new Evaluator();
    ev.evalString(`
      safe-divide: function [x y] [
        if y = 0 [error 'division-by-zero "cannot divide by zero" none]
        x / y
      ]
    `);
    ev.evalString("result: try [safe-divide 10 0]");
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    expect(ev.evalString("select result 'kind")).toEqual({ type: 'lit-word!', name: 'division-by-zero' });
    ev.evalString("result: try [safe-divide 10 2]");
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: true });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'float!', value: 5 });
  });

  test('closures and higher-order functions', () => {
    const ev = new Evaluator();
    ev.evalString(`
      make-adder: function [n] [function [x] [x + n]]
      add5: make-adder 5
      add10: make-adder 10
    `);
    expect(ev.evalString('add5 3')).toEqual({ type: 'integer!', value: 8 });
    expect(ev.evalString('add10 3')).toEqual({ type: 'integer!', value: 13 });
    expect(ev.evalString('apply :add5 [100]')).toEqual({ type: 'integer!', value: 105 });
  });

  test('loop/collect with filter', () => {
    const ev = new Evaluator();
    const result = ev.evalString(`
      loop/collect [
        for [n] from 1 to 20
        when [even? n]
        [n * n]
      ]
    `);
    expect(result.type).toBe('block!');
    if (result.type === 'block!') {
      expect(result.values.map((v: any) => v.value)).toEqual([4, 16, 36, 64, 100, 144, 196, 256, 324, 400]);
    }
  });

  test('bind + do for scoped evaluation', () => {
    const ev = new Evaluator();
    ev.evalString(`
      math: context [pi: 3.14 tau: 6.28]
      formula: [pi + tau]
      bind formula math
    `);
    expect(ev.evalString('do formula')).toEqual({ type: 'float!', value: 9.42 });
  });
});
