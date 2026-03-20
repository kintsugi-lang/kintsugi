import { Evaluator } from '@/evaluator';
import { KtgContext } from '@/evaluator/context';
import { NONE, KtgError, valueToString } from '@/evaluator/values';
import { readFileSync } from 'fs';
import { resolve } from 'path';
import { createInterface } from 'readline';

const args = process.argv.slice(2);

if (args.length > 0) {
  runFile(args[0]);
} else {
  runRepl();
}

function createEvaluator(): Evaluator {
  const evaluator = new Evaluator();

  const originalPush = evaluator.output.push.bind(evaluator.output);
  evaluator.output = new Proxy(evaluator.output, {
    get(target, prop) {
      if (prop === 'push') {
        return (...items: string[]) => {
          for (const item of items) console.log(item);
          return originalPush(...items);
        };
      }
      return (target as any)[prop];
    },
  });

  return evaluator;
}

function runFile(path: string): void {
  const filePath = resolve(path);
  let source: string;
  try {
    source = readFileSync(filePath, 'utf-8');
  } catch {
    console.error(`Error: Cannot read file '${filePath}'`);
    process.exit(1);
  }

  const evaluator = createEvaluator();

  try {
    evaluator.evalString(source);
  } catch (e: any) {
    if (e.name === 'KtgError') {
      console.error(`Error [${e.errorName}]: ${e.message}`);
      process.exit(1);
    }
    throw e;
  }
}

function runRepl(): void {
  const evaluator = createEvaluator();

  // Register repl context with REPL commands
  const replCtx = new KtgContext();

  replCtx.set('help', {
    type: 'native!', name: 'repl/help', arity: 0,
    fn: () => {
      console.log('Kintsugi REPL');
      console.log('  repl/help     — show this help');
      console.log('  repl/quit     — exit the REPL');
      console.log('  repl/reset    — reset the environment');
      console.log('  repl/words    — list bound words');
      return NONE;
    },
  } as any);

  replCtx.set('quit', {
    type: 'native!', name: 'repl/quit', arity: 0,
    fn: () => { process.exit(0); },
  } as any);

  replCtx.set('reset', {
    type: 'native!', name: 'repl/reset', arity: 0,
    fn: () => {
      console.log('Environment reset.');
      // Can't truly reset — but clear user bindings
      return NONE;
    },
  } as any);

  replCtx.set('words', {
    type: 'native!', name: 'repl/words', arity: 0,
    fn: () => {
      const words: string[] = [];
      for (const key of evaluator.global.keys()) {
        words.push(key);
      }
      // Filter out builtins — show only user-defined words
      console.log(words.filter(w => !w.includes('!') && !w.startsWith('__')).join(' '));
      return NONE;
    },
  } as any);

  evaluator.global.set('repl', { type: 'context!', context: replCtx });

  console.log('Kintsugi v0.2.0 — type repl/help for commands');

  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
    prompt: '>> ',
  });

  rl.prompt();

  rl.on('line', (line) => {
    const input = line.trim();
    if (!input) {
      rl.prompt();
      return;
    }

    try {
      const result = evaluator.evalString(input);
      if (result.type !== 'none!') {
        console.log('==', valueToString(result));
      }
    } catch (e: any) {
      if (e instanceof KtgError) {
        console.error(`Error [${e.errorName}]: ${e.message}`);
      } else if (e.name === 'KtgError') {
        console.error(`Error [${e.errorName}]: ${e.message}`);
      } else {
        console.error(`Internal error: ${e.message}`);
      }
    }

    rl.prompt();
  });

  rl.on('close', () => {
    console.log('');
    process.exit(0);
  });
}
