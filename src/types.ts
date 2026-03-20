// Utility Types

export type ValueOf<T> = T[keyof T];
export type Prettify<T> = { [K in keyof T]: T[K] } & {};
export type RequiredProp<T, P extends keyof T> = Prettify<Omit<T, P> & Required<Pick<T, P>>>;
export type OptionalProp<T, P extends keyof T> = Prettify<Omit<T, P> & Partial<Pick<T, P>>>;
export type ReadonlyProp<T, P extends keyof T> = Prettify<Omit<T, P> & Readonly<Pick<T, P>>>;
export type MutableProp<T, P extends keyof T> = Prettify<Omit<T, P> & { -readonly [K in P]: T[K] }>;

// Lexer

export const CONTAINER_TYPES = {
  BLOCK: 'Block',
  PAREN: 'Paren',
} as const;

export const ATOM_TYPES = {
  STUB: 'Stub',
  COMMENT: 'Comment',
  DIRECTIVE: 'Directive',
  META_WORD: 'MetaWord',
  WORD: 'Word',
  GET_WORD: 'GetWord',
  SET_WORD: 'SetWord',
  LIT_WORD: 'LitWord',
  PATH: 'Path',
  GET_PATH: 'GetPath',
  SET_PATH: 'SetPath',
  LIT_PATH: 'LitPath',
  NONE: 'None',
  OPERATOR: 'Operator',
  FUNCTION: 'Function',
  STRING: 'String',
  INTEGER: 'Integer',
  FLOAT: 'Float',
  TUPLE: 'Tuple',
  PAIR: 'Pair',
  DATE: 'Date',
  MONEY: 'Money',
  CHAR: 'Char',
  FILE: 'File',
  TIME: 'Time',
  URL: 'Url',
  EMAIL: 'Email',
  LOGIC: 'Logic',
} as const;

export const TOKEN_TYPES = { ...CONTAINER_TYPES, ...ATOM_TYPES } as const;

export type ContainerType = ValueOf<typeof CONTAINER_TYPES>;
export type AtomType = ValueOf<typeof ATOM_TYPES>;
export type TokenType = Prettify<ContainerType | AtomType>;

export type Token = { type: TokenType, value: string };
export type Predicate = (...args: any[]) => boolean;

// Parser

export type AstContainer = { type: ContainerType; children: AstNode[] };
export type AstAtom = { type: AtomType, value: string };
export type AstNode = AstAtom | AstContainer;

