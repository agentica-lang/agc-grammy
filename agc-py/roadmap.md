# agc-py roadmap: Python (typed subset) to `.agcb`, by phases

Goal: a compiler for a Python 3.12 subset with mandatory typing, built on
grammy, emitting typed `.agc` so `agentica compile` produces the `.agcb`.
Pipeline: `.py` → (grammy) → `.agc` → (agentica) → `.agcb`. No phase emits
bytecode by hand; `agentica check` on the emitted code is the type checker.

A phase is done when its exit criteria hold on `master` with `make ci` green.
Each phase is one PR (or a short stack), reviewed like the grammy milestones.

## Phase 0 — package and repo (this PR)

Goal: `agc-py/` exists as a package-in-waiting without breaking grammy.

- `agc-py/README.md` (goal, pipeline, subset sketch, bytecode pointers),
  `agc-py/src/py2agc.agc` (the pipeline skeleton), `agc-py/tests/` wired into
  the root `Makefile` (`check`, `fmt`, `lint`, `test` cover it).
- Root `README.md`/`AGENTS.md` layout lists `agc-py/`.

Exit: `make ci` green, 185 grammy tests + the scaffold tests.

Out: any grammar or codegen work; the workspace split below.

Note (repo shape): one manifest covers `src/`, `tests/` and `agc-py/` because a
package manifest forbids relative imports leaving its folder, and grammy has no
version tag yet for a `git` dependency. The split into workspace members
(`grammy/` + `agc-py/`, `[workspace]` at the root) happens with the first tag;
until then `agc-py` imports grammy by relative path like `tests/` does.

## Phase 1 — subset spec (binding)

Goal: the one-page contract everything else implements.

- Closed lists: what compiles (typed `def`/`return`, annotated names,
  `if`/`while`/`for`, `try/except`, expressions, f-strings or `format`),
  what is a frontend error (classes, decorators, `yield`, `async`,
  `eval`/`getattr`, in-place mutation, untyped `def`).
- The type table Python→Agentica (`int`/`str`/`float`/`bool`/`None`,
  `list[T]`/`dict[K, V]`/`X | None`, forward refs) and the semantic rules
  where the languages differ: rebinding vs `xs = xs.push(x)`, closures (blocks
  cannot assign outer variables), int overflow (halt vs bigint), `None` vs
  `nil`, truthiness, `is` vs `==`, exceptions as `Result`.
- Lexical edge cases: string prefixes, triple-quoted, escapes, number forms,
  implicit line joining inside brackets vs `INDENT`/`SAME`, `match`/`case` as
  soft keywords.

Exit: `agc-py/SUBSET.md` merged; every later phase cites it, and anything
outside it is an error by definition.

## Phase 2 — grammar of the typed subset

Goal: grammy parses every in-subset program to a tree.

- New grammar (e.g. `grammars/py312.grammar`, kept next to
  `grammars/python.grammar`): typed `def`, annotations incl. subscripts and
  `X | None`, `return`, lists/dicts/slicing, `for`/`try`/`with`,
  complete strings and numbers, decorators rejected with a span, implicit
  joining inside `()/[]/{}` composed with indentation.
- Fixture corpus: one `.py` per construct, parsed in `agc-py/tests/`.

Exit: the corpus parses; invalid programs fail with the deepest span;
`grammars/python.grammar` and the interpreter keep passing untouched.

## Phase 3 — AST, scopes, codegen to `.agc`

Goal: `py2agc` turns the tree into typed `.agc`.

- AST over `Grammy.Node` with `start`/`stop` on every node; name resolution and
  scopes; the emitter (`py2agc.agc` grows here) with one mapping per subset
  construct; structured diagnostics (span + line/column + line text) reusing
  grammy's error shape.
- No type checker of our own: untyped code never reaches emission, and the
  emitted `.agc` carries full annotations so `agentica check` enforces the
  rest. `py2agc` output must itself pass `agentica check` in tests.

Exit: for each corpus program, the emitted `.agc` checks clean and runs the
same as the reference semantics in the spec.

## Phase 4 — CLI, corpus and pipeline

Goal: `.py` in, `.agcb` out, reproducibly.

- CLI (`py2agc file.py [-o out.agc | --agcb]`) driving parse → emit →
  `agentica compile`; end-to-end tests (`.py` → run `.agcb`, compare
  behaviour); `to_json` dumps of trees/AST in tests for diffing.
- Docs: user guide (subset + errors), the mapping table as reference.

Exit: a typed sample compiles to `.agcb` and runs; `make ci` covers CLI and
corpus; `parity.md`-style deviations list for Python-vs-Agentica semantics.

## Phase 5 — performance and native (only on measurement)

Goal: the parser keeps up with real files; native only if the numbers say so.

- Benchmark with multi-thousand-line `.py` files; grammy-side fixes first
  (precompiled literals, line index, memoization — the standing milestone 3).
- `Tree.to_json` forest form for tooling dumps.
- A native backend (`native-gen` + `pest_vm`, same `.grammar`, suite run
  against both engines with `to_json` diffs) only if phase-5 numbers miss the
  target after the pure-AGCB speedups.

Exit: benchmark in the repo (`make bench` or equivalent) with a recorded
baseline; no native module without a failing number first.
