# AGENTS.md

`grammy` is a pest-like PEG parser generator for Agentica: a grammar in a
`.grammar` file, the code that uses it in ordinary `.agc` files.

## Read first

- `agentica-programming` skill: language rules, builtins, diagnostics.
- `agentica-code-guidelines` skill: style of `.agc` files.
- `README.md`: the grammar DSL and the public API.

## Commands

```bash
make check       # agentica check src examples tests
make fmt         # format in place (CI runs fmt --check)
make lint        # style suggestions, must stay clean
make test        # agentica test tests
make ci          # all of the above
make example     # run the Python subset on examples/python/sample.py
```

`agentica test` with no path only searches `test/` and `specs/`; this repo keeps
its tests in `tests/`, so always pass the folder.

## Layout and boundaries

- `src/grammar.agc`: `Rule`, `Grammar`, `Expr`, `ClassItem` and the parser for
  `.grammar` text, including the duplicate/unknown-rule validation.
- `src/engine.agc`: the PEG matcher. It threads a `Ctx(grammar, chars, base)`
  and returns an `Outcome` (found or the furthest `Attempt`); only `run` is
  public.
- `src/tree.agc`: `Node(rule, start, stop, children)`, `Position` and the
  queries user code calls.
- `src/grammy.agc`: re-exports; add every new public name here or importers
  cannot reach it.
- `src/main.agc`: the CLI (`<grammar> <rule> [input-file]`).
- `examples/python/`: the reference user of the library (grammar in
  `grammars/python.grammar`, interpreter in `interp.agc`).

## Invariants to keep

- The start rule must consume the whole input; `Engine.run` reports the rest.
- A repetition stops when an iteration makes no progress, so nullable
  expressions terminate.
- Indentation never rewrites the input: a `>` rule sets `Ctx.base` to the
  indentation of the line it starts on, and `INDENT`/`SAME` consume the next
  non-blank line's indentation and compare it with that base. Blank lines are
  skipped; tabs count as one character.
- Silent rules (`= _{ ... }`) build no node; the start rule still gets one.
- The engine has no memoization and no left-recursion guard: a left-recursive
  grammar never terminates.
- Errors are `Result` values with lowercase messages that include the bad
  value, never exceptions.
- Matching threads an `Attempt` (position, expected and unexpected `Label`s)
  through every `match_*`; the deepest attempt wins and ties merge labels.
  Silent rules drop terminal labels (`without_terminals`), so only rule names
  and the terminals of named rules show up in a message.
- `Grammar.compile` validates before matching: reserved names, duplicates,
  unknown refs, left recursion (through nullable prefixes), non-failing and
  non-progressing repetitions, and unreachable choice arms. Keep those checks
  cheap and tolerant of an already-broken grammar.
- Public code gets `##`; private code (after `private`) gets `#` only.
- `agentica.toml` sets `blank_line_after_end = true`; `make fmt` fixes spacing.

## Tests

`tests/<topic>_test.agc`: `grammar_test` (DSL parsing and validation),
`engine_test` (matching, spans, errors), `python_test` (the interpreter end to
end, which reads `grammars/python.grammar` from the working directory, so run
`agentica test` from the repo root).
