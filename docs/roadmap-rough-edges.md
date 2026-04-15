# Rough Edges Roadmap

An honest audit of the rough edges in Kintsugi as of 2026-04-15, triaged by ROI. The XS and S items are fixed. The items below were triaged as M or larger and deferred until a trigger condition justifies the work.

## Philosophy

The rule for when to touch these: **do not guess at features**. Each item has a "revisit when X" trigger. If X has not happened, the absence of this work is not a bug — it is the language staying small while it proves itself.

Premature XL work on a pre-1.0 language with zero external users is the single most common way for a principled design to accumulate machinery that was never load-bearing. The items below are specifically the ones where the cost is real and the payoff is gated on having users or having hit a wall.

---

## 1. Type annotations enforced (M + L)

**What**: Field-type annotations like `pos [pair!] 0x0` in `object [...]` declarations, and parameter types in `function` specs, are parsed but not enforced at assignment or call time. Writing a float to `pos.x` after declaring it `pair!` does not error. The compiler's emitter has its own ad-hoc type-tracking tables (`objectFields`, `varTypes`, `varSeqTypes`, `contextVars`, `funcReturnTypes` in `src/emit/lua.nim`) that duplicate what an enforced type system would already know.

**Split**:
- **1a (M, ~1 week)**: Interpreter-side field-type validation in set-word/set-path on objects and contexts with declared field specs. Validate template parameter types at expansion. Leave the compiler alone.
- **1b (L, 2-3 weeks)**: Consolidate the emitter's five tracking tables into one type environment. Touches every emit handler in a 4300-line file. High blast radius for existing cross-mode tests.

**Revisit when**: someone writes a 500+ line game in Kintsugi and refactors a field name. If silently-wrong type drift bites them, 1a becomes urgent. 1b can wait until 1a's field type errors are being worked around by developers who then complain that the emitter doesn't know the types either.

**Do not**: start with 1b. The emitter refactor without 1a first is mechanical churn. The enforcement has to come before the consolidation.

## 5. Hygienic templates with call-site context (XL)

**What**: `@template` is pure textual substitution at expansion time. The template body cannot inspect what is in scope at the call site, what fields an enclosing entity has declared, or what other templates are visible. Lisp-style macros can; `@template` cannot. The escape hatch today is `@preprocess [emit [...]]`, which is heavier than it should be for the cases where a template just wants to know "is `field-x` declared on this entity?"

**Size**: XL. This is essentially adding a hygienic macro system on top of the current substitution model. 1500-2500 LOC of redesign, plus months of iteration to stabilize edge cases.

**Revisit when**: a real Kintsugi program has two or more user-written templates that needed to inspect the call site and could not. Until that happens, `@preprocess [emit [...]]` is the documented escape hatch and is sufficient for code generation.

**Do not**: prematurely redesign `@template` around an anticipated feature. The current design is small enough to replace wholesale when the replacement is justified.

## 8. Tooling (M / L / XL)

**What**: Kintsugi has an Emacs mode (in a sibling repo) and nothing else. No tree-sitter grammar, no formatter, no linter, no LSP, no debugger. For a language this idiosyncratic (set-word/get-word/lit-word/meta-word with kebab-case), the lack of editor tooling is the single biggest adoption ceiling.

**Split**:
- **8a Tree-sitter grammar (M, ~2 weeks)**: 800-1500 lines of `grammar.js`. The hardest part is the contextual word-kind parsing (`name:` vs `'name` vs `:name` vs `@name`). Done well, it gives syntax highlighting in VS Code, Helix, Neovim, GitHub, and 20 other editors for free.
- **8b Formatter (M, ~1 month)**: `pretty.nim` already does most of the work for evaluator output. Repurposing it for source code needs comment preservation (the hard part) and a style-config layer. ~1500 LOC.
- **8c LSP (XL, months)**: Realistic minimum is hover + go-to-def + diagnostics. ~5000 LOC.

**Revisit when**:
- **8a**: as soon as anyone other than the author is going to write Kintsugi. It is the highest-ROI item on this entire list.
- **8b**: when source-code formatting matters — i.e. when there are multiple committers or when PR reviews waste cycles on whitespace.
- **8c**: only after 8a exists. LSP without syntax highlighting is solving the wrong problem first.

**Do not**: start with 8c. The ROI curve is backwards from what it looks like: the grammar is small and cheap and unlocks every editor; the LSP is big and expensive and only helps one editor.

## 9. Library story (M / L / XXL)

**What**: No namespacing, no version pinning, no conflict resolution, no package manager. `import` exists but is file-scoped and splices exports inline. For a solo game-dev language this is not a problem. For anyone else, there is no path to share code.

**Split**:
- **9a Namespaces (M, ~1 week)**: Change `import` to wrap exports in a context by default. Access via `imports/mod/fn` instead of bare `fn`. Fallback to inline-splice via a refinement for current call sites. ~400 LOC + cross-mode tests.
- **9b Version pinning (L, ~1 month)**: Version declarations in import statements, lockfile format, resolver. Touches parse, preprocess, and the file loader.
- **9c Package manager (XXL, months)**: Registry, fetcher, caching. Months of work for a real one.

**Revisit when**:
- **9a**: when two files in the same project have a name collision that requires one of them to rename an export. That is the first concrete sign that the flat namespace is load-bearing.
- **9b**: not until there are external users and at least one incompatible library upgrade has broken someone.
- **9c**: not until there is a library ecosystem. This is months of work for a registry nobody yet wants to publish to.

**Do not**: build a package manager before there is anything to package. The correct order is namespaces -> versions -> registry, and each step waits for the previous one to feel constrained.

## 10. Error messages (M) — done 2026-04-15

Shipped: `line`, `path`, and `pathSeg` fields on `KtgError`; `evalBlock` wraps each evaluation in a try/except that stamps line from the value being evaluated (propagates automatically to nested raises); `navigatePath` and the set-path code attach path context to any error raised during traversal; new `src/core/errors.nim` with `formatError(source, err)` that renders kind + msg, path context ("in path: x/pos/z (at /pos)"), source line preview, and a caret pointing at the path word. Wired into the REPL, `-e`, file runner, and compiler runner. Covered by `tests/test_error_formatting.nim` (20 tests, 1482 total).

---

## What does not appear on this list

Several things came up during the audit and were decided *not* to be rough edges:

- **The `@` sigil family**: "`@` means look this up" is a one-bit signal, and the reference table in the design-bible is the right shape. The perceived overgrowth was an outside critique that did not survive contact with the actual mental model.
- **Interpreter/compiler split**: there is a real tax from maintaining two code paths and a cross-mode test battery. The fix (shared IR, or compiling the interpreter from the emitter's output, or similar) is a 3-month project whose justification only shows up after a lot of silent drift. Until a cross-mode divergence bites at the semantic level rather than the syntactic level, the current tax is paid via tests and is visible.
- **Object/context split**: confusing on first read but correct by design. The small UX fix (type returning the instance's object name, and a better error message) shipped. The underlying model stays.
- **`@parse` interpreter-only**: surfaced as "invisible" in the audit. Fixed by making *all* interpret-only natives raise clean compile errors with specific hints.

These items are not in the roadmap because they do not need to be. Leaving them out is a positive statement, not an oversight.
