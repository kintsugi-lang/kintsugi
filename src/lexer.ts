import { Predicate, Token, TOKEN_TYPES } from '@types';

const LOGIC_WORDS = ['true', 'false'];
const OPERATOR_CHARACTERS = '+-*=<>/%|';

export function* createLexerFromString(input: string): Generator<Token, null, unknown> {
  let currentPos = 0;

  // ================ 
  
  const peek = () => input[currentPos];
  const peekNext = () => input[currentPos + 1];
  const advance = () => input[currentPos++];
  const isAtEnd = () => currentPos >= input.length;
  const isWhitespace = (char: string) => typeof char === 'string' && /\s/.test(char);
  const isDigit = (char: string) => typeof char === 'string' && /\d/.test(char);
  const isAlpha = (char: string) => typeof char === 'string' && /[a-z]/i.test(char);
  const isWordChar = (char: string) => typeof char === 'string' && /[a-z0-9_?!~-]/i.test(char);
  const isFileChar = (char: string) => typeof char === 'string' && /[a-z0-9._\/\\-]/i.test(char);
  const isUrlChar = (char: string) => typeof char === 'string' && !isWhitespace(char) && !'[]()'.includes(char);
  
  const consumeWhile = (predicate: Predicate): string => {
    let value = '';
    while (!isAtEnd() && predicate(peek())) value += advance();
    return value;
  };
  
  const consumeUntil = (openingCharacter: string, closingCharacter?: string): string => {
    if (!closingCharacter) closingCharacter = openingCharacter;

    let value = '';
    advance();
    while (!isAtEnd() && peek() !== closingCharacter) {
      // REBOL-style escape character...
      if (peek() === '^') advance();
      value += advance();
    }
    advance();
    return value;
  };

  const consumeAllComponents = (delimiter: string, predicate: Predicate, numberOfIterations?: number): string => {
    let value = '';
    while (peek() === delimiter && (numberOfIterations === undefined || numberOfIterations-- > 0)) {
      value += advance();
      value += consumeWhile(predicate);
    }
    return value;
  }

  const consumeWordOrPath = (prefix?: "'" | ':'): Token => {
    let value = consumeWhile(isWordChar);

    // URL: scheme://rest
    if (peek() === ':' && peekNext() === '/') {
      // Check for :// — need to peek two ahead
      const savedPos = currentPos;
      advance(); // :
      if (peek() === '/' && peekNext() === '/') {
        value += ':';
        value += advance(); // first /
        value += advance(); // second /
        value += consumeWhile(isUrlChar);
        return { type: TOKEN_TYPES.URL, value };
      }
      // Not a URL — backtrack
      currentPos = savedPos;
    }

    // Email: word@domain or word.word@domain
    if (peek() === '@' || (peek() === '.' && !isDigit(peekNext()))) {
      // Speculatively consume dot-separated segments looking for @
      const savedPos = currentPos;
      let extra = '';
      while (peek() === '.' && isWordChar(peekNext())) {
        extra += advance(); // .
        extra += consumeWhile(isWordChar);
      }
      if (peek() === '@' && isAlpha(peekNext())) {
        value += extra;
        value += advance(); // @
        const isDomainChar = (char: string) => typeof char === 'string' && /[a-z0-9._-]/i.test(char);
        value += consumeWhile(isDomainChar);
        return { type: TOKEN_TYPES.EMAIL, value };
      }
      // Not an email — backtrack
      currentPos = savedPos;
    }

    let isWordOrPath = peek() === '/' ? 'PATH' : 'WORD';

    // If this is a path, consume all path components...
    if (isWordOrPath === 'PATH') value += consumeAllComponents('/', isWordChar);

    if (peek() === ':') {
      advance();
      return {
        type: TOKEN_TYPES[`SET_${isWordOrPath}`],
        value
      };
    }

    let type = TOKEN_TYPES[isWordOrPath];
    if (prefix === ':') type = TOKEN_TYPES[`GET_${isWordOrPath}`];
    if (prefix === "'") type = TOKEN_TYPES[`LIT_${isWordOrPath}`];

    // Logic and none literals (only for plain words, not get/lit/paths)
    if (!prefix && isWordOrPath === 'WORD') {
      if (LOGIC_WORDS.includes(value)) type = TOKEN_TYPES.LOGIC;
      if (value === 'none') type = TOKEN_TYPES.NONE;
    }

    return { type, value };
  }
  
  // ================ 

  // While we're not at the end...
  while (!isAtEnd()) {
    const currentChar = peek();

    // Whitespace 
    if (isWhitespace(currentChar)) {
      advance();
      continue;
    }

    // Comments
    if (currentChar === ';') {
      while (!isAtEnd() && peek() !== '\n') advance();
      continue;
    }

    // Blocks
    if (currentChar === '[' || currentChar === ']') {
      advance();
      yield { type: TOKEN_TYPES.BLOCK, value: currentChar };
      continue;
    }

    // Parens
    if (currentChar === '(' || currentChar === ')') {
      advance();
      yield { type: TOKEN_TYPES.PAREN, value: currentChar };
      continue;
    }

    // Lifecycle
    if (currentChar === '@') {
      advance();
      const { value } = consumeWordOrPath();
      yield { type: TOKEN_TYPES.LIFECYCLE, value };
      continue;
    }

    if (currentChar === '#') {
      advance();

      const token: Token = { type: TOKEN_TYPES.STUB, value: '' };

      if (peek() === '[') {
        // #[expr] — inline preprocess
        token.type = TOKEN_TYPES.DIRECTIVE;
        token.value = 'inline';
      } else if (isAlpha(peek())) {
        token.type = TOKEN_TYPES.DIRECTIVE;
        token.value = consumeWhile(isAlpha);
      } else if (peek() === '"') {
        token.type = TOKEN_TYPES.CHAR;
        token.value = consumeUntil('"');
      } else if (peek() === '{') {
        token.type = TOKEN_TYPES.BINARY;
        token.value = consumeUntil('}');
      }

      yield token;
      continue;
    }

    // Words and paths
    if (currentChar === "'" || currentChar === ':') {
      advance(); // skip prefix
      yield consumeWordOrPath(currentChar);
      continue;
    }

    if (isAlpha(currentChar) || currentChar === '_') {
      yield consumeWordOrPath();
      continue;
    }

    // Strings
    if (currentChar === '"' || currentChar === '{') {
      const value = currentChar === '{' ? consumeUntil('}') : consumeUntil('"');
      yield { type: TOKEN_TYPES.STRING, value };
      continue;
    }

    // Numbers, floats, tuples...
    if (isDigit(currentChar) || (currentChar === '-' && isDigit(peekNext()))) {
      let value = '';
      if (currentChar === '-') value += advance();
      value += consumeWhile(isDigit);

      // Time: 14:30 or 14:30:00
      if (peek() === ':' && isDigit(peekNext())) {
        value += consumeAllComponents(':', isDigit, 2);
        yield { type: TOKEN_TYPES.TIME, value };
        continue;
      }

      if (peek() === 'x' && isDigit(peekNext())) {
        value += consumeAllComponents('x', isDigit, 1);
        yield { type: TOKEN_TYPES.PAIR, value };
        continue;
      }

      if (peek() === '-' && isDigit(peekNext())) {
        value += consumeAllComponents('-', isDigit, 2);
        yield { type: TOKEN_TYPES.DATE, value };
        continue;
      }
 
      const components = consumeAllComponents('.', isDigit);
      if (!components) {
        yield { type: TOKEN_TYPES.INTEGER, value };
      } else {
        value += components;
        const dotCount = (components.match(/\./g) || []).length;
        yield { type: dotCount === 1 ? TOKEN_TYPES.FLOAT : TOKEN_TYPES.TUPLE, value };
      }
      continue;
    }

    // file references: %filename.ktg
    if (currentChar === '%' && (isFileChar(peekNext()) || peekNext() === '"')) {
      advance();

      let value = peek() === '"'
        ? consumeUntil('"')
        : consumeWhile(isFileChar);
      
      yield { type: TOKEN_TYPES.FILE, value };
      continue;
    }

    // Money: $19.99
    if (currentChar === '$' && isDigit(peekNext())) {
      advance(); // skip $
      let value = consumeWhile(isDigit);
      if (peek() === '.' && isDigit(peekNext())) {
        value += advance(); // the dot
        value += consumeWhile(isDigit);
      }
      yield { type: TOKEN_TYPES.MONEY, value };
      continue;
    }

    if (OPERATOR_CHARACTERS.includes(currentChar)) {
      let value = advance();

      if (value === '<' && peek() === '=') value += advance();
      if (value === '>' && peek() === '=') value += advance();
      if (value === '<' && peek() === '>') value += advance();
      
      yield { type: TOKEN_TYPES.OPERATOR, value };
      continue;
    }
    
    // Fallback for anything we didn't catch
    advance();
  }
  return null;
}
