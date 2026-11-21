# agc-py roadmap: Python (typed subset) to `.agcb`, by phases

Goal: a compiler for a Python 3.12 subset with mandatory typing, built on
grammy, emitting typed `.agc` so `agentica compile` produces the `.agcb`.
Pipeline: `.py` → (grammy) → `.agc` → (agentica) → `.agcb`. No phase emits
bytecode by hand; `agentica check` on the emitted code is the type checker.

A phase is done when its exit criteria hold on `master` with `make ci` green.
Phases break into PR-sized deliverables below; a phase ships as one PR or a
short stack. Each deliverable states its tests.

## Phase 0 — package and repo (this PR)

Goal: `agc-py/` exists as a package-in-waiting without breaking grammy.

- PR 0a (this one): `agc-py/README.md` (goal, pipeline, subset sketch,
  bytecode pointers), `agc-py/roadmap.md` (this file), `agc-py/src/py2agc.agc`
  (pipeline skeleton), `agc-py/tests/` (3 tests), Makefile/README/AGENTS.md
  wiring.

Exit: `make ci` green, 185 grammy tests + the scaffold tests.

Note (repo shape): one manifest covers `src/`, `tests/` and `agc-py/` by
release discipline, not tool requirement (a `ref` pin or `path` dep would also
work): we defer the workspace split until the first `grammy-*` prefixed tag.
That split means moving `src/`, `tests/`, `grammars/`, `examples/` under
`grammy/` with its own manifest, a workspace-root manifest carrying the
repository URL, and rewriting relative imports to `pkg/grammy/...`.

Grammy-side work is ordered by who needs it: each phase below lists its
`grammy:` dependencies first, so engine improvements land right before the
`agc-py` PRs that require them — never speculatively. Anything unlisted stays
as is until a phase asks for it.

## Phase 1 — subset spec, binding (1 PR)

Goal: the one-page contract everything else implements. No code.

- PR 1a: `agc-py/SUBSET.md` — closed include list (typed `def`/`return`,
  annotated names, `if`/`while`/`for`, `try/except`, expressions), the type
  table Python→Agentica, semantic rules where the languages differ (rebinding
  vs `xs = xs.push(x)`, closures, int overflow, `None`/`nil`, truthiness,
  `is` vs `==`, exceptions as `Result`), lexical edge cases (string prefixes,
  triple-quoted, escapes, number forms, implicit joining vs indentation,
  `match`/`case` soft keywords, `with`/f-strings in or out), and the closed
  exclusion list (each exclusion is a frontend error with a span).

Exit: `SUBSET.md` merged; it supersedes the README sketch, and anything
outside it is an error by definition. Later phases cite it per construct.

grammy: none. If the spec needs a syntax probe (e.g. soft-keyword shaping),
it goes in as a throwaway fixture, not a merged change.

## Phase 2 — grammar of the typed subset (4 PRs)

Goal: grammy parses every in-subset program to a tree. Grammar lives next to
`grammars/python.grammar` (e.g. `grammars/py312.grammar`); `python.grammar`
and the interpreter keep passing untouched.

- PR 2a (functions): typed `def` with params/return, annotated assignments,
  annotation syntax (subscripts `list[int]`, `X | None`, string forward refs).
  Tests: one `.py` fixture per form, parsed to a tree with the expected nodes.
- PR 2b (data): list/dict literals, subscripting, slicing, complete strings
  (prefixes, triple-quoted, escapes decoded) and numbers (hex/oct/bin,
  underscores, exponents). Tests: fixtures + decoded values.
- PR 2c (control): `for`, `try/except`, `with` (or rejection with a span if
  phase 1 excluded it), decorators rejected with a span. Tests: fixtures.
- PR 2d (layout): implicit line joining inside `()/[]/{}` composed with
  `INDENT`/`SAME`, `match`/`case` soft keywords. Tests: full corpus green,
  invalid programs fail with the deepest span.

Exit: the corpus parses; invalid programs fail with spans; zero regressions
in grammy's suite.

grammy (only if phase 2 measures it): precompiled literals when fixture files
parse too slowly to iterate on, and a line index for `Tree.position` when
diagnostic tests on large fixtures get slow. Both are pure speedups with no
semantic change, so they can land inside the 2a–2d stack without disturbing
it.

## Phase 3 — AST, scopes, codegen to `.agc` (4 PRs)

Goal: `py2agc` turns the tree into typed `.agc`. No type checker of our own:
untyped code never reaches emission, and emitted code carries full annotations
so `agentica check` enforces the rest.

- PR 3a (AST + scopes): AST nodes over `Grammy.Node` with `start`/`stop`,
  name resolution and scopes, structured diagnostics (span + line/column +
  line text) reusing grammy's error shape. Tests: scopes resolve/shadow/reject
  as specified; diagnostics print the offending line.
- PR 3b (expressions): literals, operators with the true-division rule,
  calls, subscripting, builtin mapping (`print`→`puts`, `len`, `range`).
  Tests: each emitted form passes `agentica check` in the test itself.
- PR 3c (statements): assignment (incl. the `push`-style rebinding rule),
  `if`/`while`/`for`, `return`, `try/except`→`Result`. Tests: control flow
  fixtures whose emitted `.agc` checks clean.
- PR 3d (functions + modules): typed `def` emission, call ABI, one module =
  one file to start. Tests: corpus-wide — every phase-2 fixture emits `.agc`
  that checks clean.

Exit: every corpus program emits `.agc` that passes `agentica check` and runs
with the reference semantics from `SUBSET.md`.

grammy: structured error payloads if diagnostics need more than a string —
today a failed `Engine.run` yields one message; multi-error reporting or
machine-readable spans (rule + `start`/`stop` + labels as data, not text)
belong here, driven by 3a's diagnostic tests. No recovery machinery until a
test demands it.

## Phase 4 — CLI, corpus and pipeline (2 PRs)

Goal: `.py` in, `.agcb` out, reproducibly.

- PR 4a (CLI): `py2agc file.py [-o out.agc | --agcb]` driving parse → emit →
  `agentica compile`; end-to-end tests (`.py` → run `.agcb`, compare
  behaviour against the spec).
- PR 4b (docs + corpus): user guide (subset + errors), the mapping table as
  reference, `to_json` dumps of trees/AST in tests for diffing, corpus
  expansion to every spec example.

Exit: a typed sample compiles to `.agcb` and runs; `make ci` covers CLI and
corpus; a deviations list (Python-vs-Agentica semantics) lives next to
`parity.md`.

grammy: `to_json` forest form (today only a single pair) for tooling dumps and
test diffs; `PEEK[a..b]` only if the subset's grammar wants it (unlikely —
it is a pest-extra, not a Python need).

## Phase 5 — performance and native (3 PRs, only on measurement)

Goal: the parser keeps up with real files; native only if the numbers say so.

- PR 5a (bench): a benchmark harness (to be added, e.g. `make bench`) over
  multi-thousand-line `.py` files, with the recorded baseline in the repo.
- PR 5b (engine): the grammy-side optimizations not already taken in phase
  2 — precompiled literals, a line index, memoization — each measured against
  the baseline. Whatever phase 2 already took is not redone here.
- PR 5c (native, conditional): a native backend (`native-gen` + `pest_vm`)
  behind a flag, same `.grammar`, the suite run against both engines with
  `to_json` diffs. Only if 5b misses the target.

Exit: benchmark recorded; no native module without a failing number first.
