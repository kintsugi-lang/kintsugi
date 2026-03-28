# Lexer Fix — Match Updated Kintsugi Spec

**Date:** 2026-03-16
**Goal:** Fix the existing tokenizer (renamed to lexer) to correctly tokenize all datatypes and syntax in the updated Kintsugi spec.

## Already working

The current tokenizer already handles:
- `^` escape character in `consumeUntil`
- EOF safety in `consumeUntil`
- Curly-brace strings (`{...}` → `STRING`)
- `#` dispatch: char literals (`#"A"`), binary (`#{hex}`), directives (`#preprocess`)
- All word/path variants (word, set-word, get-word, lit-word, paths)
- Blocks, parens, comments, whitespace
- Integers, floats, tuples, pairs, dates
- File literals (`%path/to/file`)
- Operators (`+`, `-`, `*`, `/`, `%`, `=`, `<`, `>`, `<=`, `>=`, `<>`)
- Lifecycle hooks (`@enter`)

## Changes needed

### Rename
- `tokenizer.ts` → `lexer.ts`
- Update `index.ts` import
- Rename exported functions: `tokenizeFile` → `lexFile`, `createTokenizerFromString` → `createLexerFromString`

### `types.ts` — add token types
- `TIME` — `14:30:00`, `14:30`
- `URL` — `https://example.com`, `tcp://localhost:8080`
- `EMAIL` — `user@example.com`
- `LOGIC` — `true`, `false`, `on`, `off`, `yes`, `no`

### `lexer.ts` — new token support

1. **Money:** When `$` followed by a digit, consume digits + optional `.` + digits. Emit `MONEY`. **Insertion:** New branch in the main loop, before the operator branch.

2. **Time:** In the number branch, after consuming initial digits, if next char is `:` followed by a digit, it's a time literal. Consume at minimum `NN:NN`, optionally `NN:NN:NN`. Emit `TIME`. No conflict with set-words (which start with alpha).

3. **URL:** In `consumeWordOrPath`, after consuming a word, check if the next three chars are `://` **before** checking for trailing `:` (set-word). If `://` is found, consume the scheme separator and everything after it until whitespace or a delimiter (`[`, `]`, `(`, `)`). Emit `URL`. This correctly handles `tcp://localhost:8080`.

4. **Email:** In `consumeWordOrPath`, after consuming a word, if next char is `@` followed by alpha, consume the `@` and the domain part (alpha, digits, `.`, `-`). Emit `EMAIL`. Only alpha-starting words can become emails.

5. **Word characters:** Add `~` to `isWordChar` regex: `/[a-z0-9_?!~-]/i`. Required for shape names (`user~`, `admin~`).

### Ordering in `consumeWordOrPath`

After consuming a word, checks happen in this order:
1. `://` → URL (consume rest, return URL token)
2. `@` + alpha → email (consume rest, return EMAIL token)
3. `/` → path (existing behavior)
4. `:` → set-word/set-path (existing behavior)
5. Otherwise → word (existing behavior)

### Escape sequence translation

The lexer does **not** translate escape sequences. `^/` stays as the two characters `^` and `/` in the token value. Translation to actual newlines/tabs is the evaluator's job. The lexer's role is to correctly delimit the string, not interpret its contents.

### Logic literals

`true`, `false`, `on`, `off`, `yes`, `no` emit `LOGIC` tokens. After `consumeWordOrPath` produces a word, check if the value is one of these six — if so, override the type to `LOGIC`. Add `LOGIC` to `TOKEN_TYPE` in `types.ts`.

`none` emits `NONE` (already exists in `TOKEN_TYPE`). Same approach — check after word consumption.

### Minor cleanup

- Fix `consumeUntil` call for curly-brace strings: change `consumeUntil('}')` to `consumeUntil('{', '}')` for API clarity (functionally identical but semantically correct).
- Remove f-string handling if any remnants exist.

### New file: `lexer.test.ts`
Unit tests for every token type using `bun test`. One `describe` block per token type.

### Not changing
- `STUB`, `COMMENT`, `NONE`, `FUNCTION` token types left in `types.ts` for future use.
- `-` and `%` ambiguity is a non-issue — whitespace is significant in Kintsugi.
- Flat token stream — parser handles nesting.
- Refinement paths (`loop/collect`, `try/handle`) won't trigger URL detection because paths use single `/`, not `://`.
