import { AstContainer, Token } from '@types';
import { createLexerFromString } from '@/lexer';
import { parseTokens } from '@/parser';

export const lexString = (input: string): Token[] => [...createLexerFromString(input)];
export const parseString = (input: string): AstContainer => parseTokens(lexString(input));

export { Evaluator } from '@/evaluator';

