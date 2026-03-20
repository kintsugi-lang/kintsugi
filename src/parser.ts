import { AstAtom, AstContainer, AtomType, ContainerType, Token, TOKEN_TYPES } from '@types';

export class ParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ParseError';
  }
}

export function parseTokens(tokens: Token[]): AstContainer {
  const stack: AstContainer[] = [{ type: TOKEN_TYPES.BLOCK, children: [] }];

  const characterMapping = {
    [TOKEN_TYPES.BLOCK]: ['[', ']'],
    [TOKEN_TYPES.PAREN]: ['(', ')'],
  };
  
  const isStackEmpty = () => stack.length <= 1;
  const topOfStack = () => stack[stack.length - 1];

  for (const token of tokens) {
    const top = topOfStack();
    
    const containerType: ContainerType | null = (token.type === TOKEN_TYPES.BLOCK || token.type === TOKEN_TYPES.PAREN)
      ? token.type
      : null;

    if (!containerType) {
      const atom: AstAtom = { type: token.type as AtomType, value: token.value };
      top.children.push(atom);
    } else {
      const [openingCharacter, closingCharacter] = characterMapping[containerType];
      const otherContainerType = containerType === TOKEN_TYPES.BLOCK ? TOKEN_TYPES.PAREN : TOKEN_TYPES.BLOCK;
      
      if (token.value === openingCharacter) {
        stack.push({ type: token.type as ContainerType, children: [] });
      } else if (token.value === closingCharacter) {
        if (isStackEmpty()) throw new ParseError(`Unexpected ${closingCharacter}`);
        
        const frame = stack.pop()!;
        if (frame.type !== containerType) {
          throw new ParseError(`Mismatched delimiter: expected ${characterMapping[otherContainerType][1]} but got ${closingCharacter}`);
        }
        
        const node = { type: containerType, children: frame.children };
        topOfStack().children.push(node);
      }
    }
  }

  if (!isStackEmpty()) throw new ParseError(`Unclosed ${characterMapping[topOfStack().type]}`);
  return topOfStack();
}
