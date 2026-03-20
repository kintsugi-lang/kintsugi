import { describe, expect, test } from 'bun:test';
import { TOKEN_TYPES, TokenType } from '@types';
import { lexString as lex } from '@/helpers';

// Helper: lex a string, expect exactly one token with given type and value
function expectSingleToken(input: string, type: string, value: string) {
  const tokens = lex(input);
  expect(tokens.length).toBe(1);
  expect(tokens[0].type).toBe(type as TokenType);
  expect(tokens[0].value).toBe(value);
}

describe('integers', () => {
  test('positive integer', () => expectSingleToken('42', TOKEN_TYPES.INTEGER, '42'));
  test('negative integer', () => expectSingleToken('-7', TOKEN_TYPES.INTEGER, '-7'));
});

describe('floats', () => {
  test('basic float', () => expectSingleToken('3.14', TOKEN_TYPES.FLOAT, '3.14'));
});

describe('tuples', () => {
  test('version tuple', () => expectSingleToken('1.2.3', TOKEN_TYPES.TUPLE, '1.2.3'));
});

describe('pairs', () => {
  test('basic pair', () => expectSingleToken('100x200', TOKEN_TYPES.PAIR, '100x200'));
});

describe('dates', () => {
  test('full date', () => expectSingleToken('2026-03-15', TOKEN_TYPES.DATE, '2026-03-15'));
});

describe('strings', () => {
  test('double-quoted string', () => expectSingleToken('"hello"', TOKEN_TYPES.STRING, 'hello'));
  test('curly-brace string', () => expectSingleToken('{hello}', TOKEN_TYPES.STRING, 'hello'));
  test('string with escape', () => expectSingleToken('"line one^/line two"', TOKEN_TYPES.STRING, 'line one/line two'));
  test('curly string with escape', () => expectSingleToken('{She said ^"hello^"}', TOKEN_TYPES.STRING, 'She said "hello"'));
});

describe('chars', () => {
  test('char literal', () => expectSingleToken('#"A"', TOKEN_TYPES.CHAR, 'A'));
});

describe('binary', () => {
  test('binary literal', () => expectSingleToken('#{48656C6C6F}', TOKEN_TYPES.BINARY, '48656C6C6F'));
});

describe('files', () => {
  test('file path', () => expectSingleToken('%path/to/file.txt', TOKEN_TYPES.FILE, 'path/to/file.txt'));
  test('quoted file', () => expectSingleToken('%"path with spaces"', TOKEN_TYPES.FILE, 'path with spaces'));
});

describe('words', () => {
  test('simple word', () => expectSingleToken('print', TOKEN_TYPES.WORD, 'print'));
  test('word with hyphen', () => expectSingleToken('my-var', TOKEN_TYPES.WORD, 'my-var'));
  test('word with question mark', () => expectSingleToken('empty?', TOKEN_TYPES.WORD, 'empty?'));
  test('word with exclamation', () => expectSingleToken('integer!', TOKEN_TYPES.WORD, 'integer!'));
  test('word with tilde (shape name)', () => expectSingleToken('user~', TOKEN_TYPES.WORD, 'user~'));
});

describe('logic', () => {
  test('true', () => expectSingleToken('true', TOKEN_TYPES.LOGIC, 'true'));
  test('false', () => expectSingleToken('false', TOKEN_TYPES.LOGIC, 'false'));
  test('on is a word (resolved to logic at eval time)', () => expectSingleToken('on', TOKEN_TYPES.WORD, 'on'));
  test('off is a word', () => expectSingleToken('off', TOKEN_TYPES.WORD, 'off'));
  test('yes is a word', () => expectSingleToken('yes', TOKEN_TYPES.WORD, 'yes'));
  test('no is a word', () => expectSingleToken('no', TOKEN_TYPES.WORD, 'no'));
});

describe('none', () => {
  test('none literal', () => expectSingleToken('none', TOKEN_TYPES.NONE, 'none'));
});

describe('set-words', () => {
  test('basic set-word', () => expectSingleToken('name:', TOKEN_TYPES.SET_WORD, 'name'));
});

describe('get-words', () => {
  test('basic get-word', () => expectSingleToken(':name', TOKEN_TYPES.GET_WORD, 'name'));
});

describe('lit-words', () => {
  test('basic lit-word', () => {
    const tokens = lex("'name");
    expect(tokens[0].type).toBe(TOKEN_TYPES.LIT_WORD);
    expect(tokens[0].value).toBe('name');
  });
});

describe('paths', () => {
  test('basic path', () => expectSingleToken('obj/field', TOKEN_TYPES.PATH, 'obj/field'));
  test('multi-segment path', () => expectSingleToken('a/b/c', TOKEN_TYPES.PATH, 'a/b/c'));
});

describe('set-paths', () => {
  test('basic set-path', () => expectSingleToken('obj/field:', TOKEN_TYPES.SET_PATH, 'obj/field'));
});

describe('blocks', () => {
  test('open block', () => expectSingleToken('[', TOKEN_TYPES.BLOCK, '['));
  test('close block', () => expectSingleToken(']', TOKEN_TYPES.BLOCK, ']'));
});

describe('parens', () => {
  test('open paren', () => expectSingleToken('(', TOKEN_TYPES.PAREN, '('));
  test('close paren', () => expectSingleToken(')', TOKEN_TYPES.PAREN, ')'));
});

describe('operators', () => {
  test('plus', () => expectSingleToken('+', TOKEN_TYPES.OPERATOR, '+'));
  test('minus as operator', () => {
    const tokens = lex('x - 1');
    expect(tokens[1].type).toBe(TOKEN_TYPES.OPERATOR);
    expect(tokens[1].value).toBe('-');
  });
  test('less-equal', () => expectSingleToken('<=', TOKEN_TYPES.OPERATOR, '<='));
  test('greater-equal', () => expectSingleToken('>=', TOKEN_TYPES.OPERATOR, '>='));
  test('not-equal', () => expectSingleToken('<>', TOKEN_TYPES.OPERATOR, '<>'));
});

describe('directives', () => {
  test('preprocess', () => expectSingleToken('#preprocess', TOKEN_TYPES.DIRECTIVE, 'preprocess'));
});

describe('lifecycle', () => {
  test('enter hook', () => expectSingleToken('@enter', TOKEN_TYPES.LIFECYCLE, 'enter'));
  test('exit hook', () => expectSingleToken('@exit', TOKEN_TYPES.LIFECYCLE, 'exit'));
});

describe('urls', () => {
  test('https url', () => expectSingleToken('https://example.com', TOKEN_TYPES.URL, 'https://example.com'));
  test('tcp url with port', () => expectSingleToken('tcp://localhost:8080', TOKEN_TYPES.URL, 'tcp://localhost:8080'));
  test('url with path', () => expectSingleToken('https://example.com/api/users', TOKEN_TYPES.URL, 'https://example.com/api/users'));
});

describe('emails', () => {
  test('basic email', () => expectSingleToken('user@example.com', TOKEN_TYPES.EMAIL, 'user@example.com'));
  test('email with dots and hyphens', () => expectSingleToken('first.last@my-domain.org', TOKEN_TYPES.EMAIL, 'first.last@my-domain.org'));
});

describe('money', () => {
  test('whole dollars', () => expectSingleToken('$19', TOKEN_TYPES.MONEY, '19'));
  test('dollars and cents', () => expectSingleToken('$19.99', TOKEN_TYPES.MONEY, '19.99'));
});

describe('time', () => {
  test('hours and minutes', () => expectSingleToken('14:30', TOKEN_TYPES.TIME, '14:30'));
  test('hours minutes seconds', () => expectSingleToken('14:30:00', TOKEN_TYPES.TIME, '14:30:00'));
});

describe('comments', () => {
  test('comment is skipped', () => {
    const tokens = lex('; this is a comment');
    expect(tokens.length).toBe(0);
  });
  test('comment after code', () => {
    const tokens = lex('42 ; a number');
    expect(tokens.length).toBe(1);
    expect(tokens[0].type).toBe(TOKEN_TYPES.INTEGER);
  });
});

describe('integration', () => {
  test('tokenizes script-spec.ktg without errors', async () => {
    const file = Bun.file('./examples/script-spec.ktg');
    const contents = await file.text();
    const tokens = lex(contents);
    expect(tokens.length).toBeGreaterThan(0);
  });

  test('script-spec.ktg produces no STUB tokens', async () => {
    const file = Bun.file('./examples/script-spec.ktg');
    const contents = await file.text();
    const tokens = lex(contents);
    const stubs = tokens.filter(t => t.type === TOKEN_TYPES.STUB);
    expect(stubs).toEqual([]);
  });
});
