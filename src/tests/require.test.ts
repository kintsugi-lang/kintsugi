import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import { Evaluator } from '@/evaluator';
import { rmSync, mkdirSync, writeFileSync } from 'fs';

const TEST_DIR = '/tmp/kintsugi-require-test';

beforeAll(() => {
  mkdirSync(TEST_DIR, { recursive: true });

  // Simple module — no header
  writeFileSync(`${TEST_DIR}/simple.ktg`, `
    add: function [a b] [a + b]
    mul: function [a b] [a * b]
  `);

  // Module with header
  writeFileSync(`${TEST_DIR}/math.ktg`, `
    Kintsugi [
      name: 'math
      version: 1.0.0
    ]
    add: function [a b] [a + b]
    _helper: function [x] [x * x]
    clamp: function [val lo hi] [min hi max lo val]
  `);

  // Module with exports (private by default)
  writeFileSync(`${TEST_DIR}/restricted.ktg`, `
    Kintsugi [
      name: 'restricted
      exports: [greet]
    ]
    _internal: "secret"
    greet: function [name] [join "Hello, " name]
  `);

  // Module with dependency
  writeFileSync(`${TEST_DIR}/consumer.ktg`, `
    Kintsugi [
      name: 'consumer
      modules: [%${TEST_DIR}/simple.ktg]
    ]
    double-add: function [a b] [simple/add a b * 2]
  `);

  // Circular dependency
  writeFileSync(`${TEST_DIR}/a.ktg`, `
    Kintsugi [name: 'a modules: [%${TEST_DIR}/b.ktg]]
    val: 1
  `);
  writeFileSync(`${TEST_DIR}/b.ktg`, `
    Kintsugi [name: 'b modules: [%${TEST_DIR}/a.ktg]]
    val: 2
  `);
});

afterAll(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

describe('require — basic', () => {
  test('require loads a simple module', () => {
    const ev = new Evaluator();
    ev.evalString(`math: require %${TEST_DIR}/simple.ktg`);
    expect(ev.evalString('math/add 3 4')).toEqual({ type: 'integer!', value: 7 });
    expect(ev.evalString('math/mul 3 4')).toEqual({ type: 'integer!', value: 12 });
  });

  test('require returns context!', () => {
    const ev = new Evaluator();
    ev.evalString(`m: require %${TEST_DIR}/simple.ktg`);
    expect(ev.evalString('context? m')).toEqual({ type: 'logic!', value: true });
  });
});

describe('require — headers', () => {
  test('header is consumed, not in returned context', () => {
    const ev = new Evaluator();
    ev.evalString(`m: require %${TEST_DIR}/math.ktg`);
    expect(ev.evalString('m/add 3 4')).toEqual({ type: 'integer!', value: 7 });
  });

  test('require/header returns header block', () => {
    const ev = new Evaluator();
    ev.evalString(`h: require/header %${TEST_DIR}/math.ktg`);
    expect(ev.evalString("select h 'name")).toEqual({ type: 'lit-word!', name: 'math' });
  });

  test('require/header returns none for headerless file', () => {
    const ev = new Evaluator();
    expect(ev.evalString(`require/header %${TEST_DIR}/simple.ktg`)).toEqual({ type: 'none!' });
  });
});

describe('require — exports filtering', () => {
  test('without exports, everything is public', () => {
    const ev = new Evaluator();
    ev.evalString(`m: require %${TEST_DIR}/math.ktg`);
    expect(ev.evalString('m/add 3 4')).toEqual({ type: 'integer!', value: 7 });
    expect(ev.evalString('m/_helper 5')).toEqual({ type: 'integer!', value: 25 });
  });

  test('with exports, only listed words are visible', () => {
    const ev = new Evaluator();
    ev.evalString(`m: require %${TEST_DIR}/restricted.ktg`);
    expect(ev.evalString('m/greet "Ray"')).toEqual({ type: 'string!', value: 'Hello, Ray' });
    // _internal should not be accessible
    expect(ev.evalString('m/_internal')).toEqual({ type: 'none!' });
  });
});

describe('require — circular dependency', () => {
  test('throws on circular require', () => {
    const ev = new Evaluator();
    expect(() => ev.evalString(`require %${TEST_DIR}/a.ktg`)).toThrow('Circular dependency');
  });
});

describe('require — caching', () => {
  test('same path returns same context', () => {
    const ev = new Evaluator();
    ev.evalString(`a: require %${TEST_DIR}/simple.ktg`);
    ev.evalString(`b: require %${TEST_DIR}/simple.ktg`);
    // Both should work
    expect(ev.evalString('a/add 1 2')).toEqual({ type: 'integer!', value: 3 });
    expect(ev.evalString('b/add 1 2')).toEqual({ type: 'integer!', value: 3 });
  });
});
