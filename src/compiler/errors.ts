export class CompileError extends Error {
  constructor(
    public phase: 'lower' | 'emit',
    public context: string,
    message: string,
  ) {
    super(`[${phase}] ${context ? context + ': ' : ''}${message}`);
    this.name = 'CompileError';
  }
}

export function lowerError(context: string, message: string): never {
  throw new CompileError('lower', context, message);
}

export function emitError(context: string, message: string): never {
  throw new CompileError('emit', context, message);
}
