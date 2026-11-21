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
  `.grammar` text: pest syntax (`"lit"`, `^"lit"`, `'a'..'z'`, `~` required,
  `{n,m}`, `//` and nested `/* */` comments) plus `[a-z]` classes and `.` as
  extensions; it also validates the grammar.
- `src/engine.agc`: the PEG matcher. It threads a
  `Ctx(grammar, chars, base, atomicity, whitespace, comment)` and returns an
  `Outcome` (found or the furthest `Attempt`); only `run` is public.
- `src/tree.agc`: `Node(rule, start, stop, children, tag)`, `Position` and the
  queries user code calls.
- `src/grammy.agc`: re-exports; add every new public name here or importers
  cannot reach it.
- `src/main.agc`: the CLI (`<grammar> <rule> [input-file]`).
- `examples/python/`: the reference user of the library (grammar in
  `grammars/python.grammar`, interpreter in `interp.agc`).

## Invariants to keep

- The start rule must consume the whole input; `Engine.run` reports the rest.
- An *unbounded* repetition stops when an iteration makes no progress, so
  nullable expressions terminate; a bounded one repeats the same empty match
  up to its maximum without matching again.
- Indentation never rewrites the input: a `>` rule sets `Ctx.base` to the
  indentation of the line it starts on, and `INDENT`/`SAME` consume the next
  non-blank line's indentation and compare it with that base. Blank lines are
  skipped; tabs count as one character.
- Silent rules (`= _{ ... }`) build no node; the start rule still gets one.
- `WHITESPACE`/`COMMENT`, when defined, are skipped between the parts of a
  sequence and between iterations of a repetition (`skip`), and once after the
  start rule. `Ctx` carries the two rules resolved once by `run`, so the hot
  path does no lookup. They are matched atomically with skipping disabled, so
  they never build nodes nor re-enter `skip`.
- Atomicity flows down: `@` (`Atomic`) drops the nodes of the rules it calls
  that do not declare their own atomicity and skips nothing, `$` (`Compound`)
  keeps the nodes, `!` (`NonAtomic`) restores normal behaviour, and a plain rule
  inherits from its caller (`effective_atomicity`). A rule still builds its own
  node unless its caller was atomic (`creates_node?`).
- `INDENT`/`SAME` accept a position already inside the leading spaces of a line
  (`match_indent`), so a skip that crossed the line break does not hide the
  indentation they measure. A line holding only spaces is blank there too, and
  `line_start` treats `\r` as a break.
- The rule stack travels in `Progress.stack` (`List[String]`, top last), so a
  failed alternative drops its pushes for free: nothing to snapshot or restore.
  `match` threads it as `match(ctx, stack, expr, pos)`; `POP`/`PEEK` match the
  stored text, `*_ALL` walk it from the top down. `POP`/`PEEK`/`DROP` fail on an
  empty stack, `*_ALL` match nothing, and `skip` runs with an empty stack
  because a skipped rule may not use it (the validator refuses one that does).
  A zero-width repetition only takes its shortcut when the stack did not move.
  An unbounded repetition is refused when it never consumes input, unless it
  only pops the stack (`drains_stack?`: `DROP*`), which always ends; an
  unbounded one that moves only the stack stops when it stops shrinking.
- A tag (`#name = term`) lands on the last node its term built, and over `*`,
  `+`, `?` or `{n,m}` on the last node of every iteration. The validator refuses a tag on an
  expression that builds no node. `run` applies the start rule's own atomicity
  through `body_ctx`, so an `@`/`$` start rule behaves like any other.
- The engine has no memoization and no left-recursion guard: a left-recursive
  grammar never terminates.
- Errors are `Result` values with lowercase messages that include the bad
  value, never exceptions.
- Matching threads an `Attempt` (position, expected and unexpected `Label`s)
  through every `match_*`; the deepest attempt wins and ties merge labels.
  Silent rules drop terminal labels (`without_terminals`), so only rule names
  and the terminals of named rules show up in a message.
- `Grammar.compile` validates before matching: reserved names, duplicates,
  a `WHITESPACE`/`COMMENT` that can never fail or that never consumes input,
  unknown refs, tags with no node to name, a stack read with nothing pushed
  anywhere, a skipped rule that uses the stack, left recursion (through
  nullable prefixes),
  non-failing and non-progressing *unbounded* repetitions, a zero-width
  repetition asking for more than `ZERO_WIDTH_LIMIT` nodes, and unreachable
  choice arms. Keep those checks cheap and tolerant of an already-broken
  grammar.
- Public code gets `##`; private code (after `private`) gets `#` only.
- `agentica.toml` sets `blank_line_after_end = true`; `make fmt` fixes spacing.

## Tests

`tests/<topic>_test.agc`: `grammar_test` (DSL parsing and validation),
`engine_test` (matching, spans, errors), `python_test` (the interpreter end to
end, which reads `grammars/python.grammar` from the working directory, so run
`agentica test` from the repo root).
