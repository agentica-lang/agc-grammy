# agc-py

A Python 3.12 subset with mandatory typing, compiled to Agentica bytecode
(`.agcb`) through grammy: `agc-py` parses `.py` with a `.grammar`, emits typed
`.agc`, and `agentica compile` produces the `.agcb`. The pipeline is
`.py` → `.agc` → `.agcb`; bytecode is never emitted by hand.

```text
.py (typed subset) --agc-py--> .agc --agentica compile--> .agcb
```

`agentica check` on the emitted `.agc` is the type checker: every `def` needs
annotations, every name needs a declared type, and anything untyped is a
frontend error before anything is emitted. See `roadmap.md` for the phases.

## Layout

```text
agc-py/README.md        this file: goal, pipeline and subset sketch
agc-py/roadmap.md      the work in phases, with exit criteria
agc-py/src/py2agc.agc  the translator (today: the pipeline skeleton)
agc-py/tests/          Agentica unit tests (run from the repo root)
```

grammy stays the only parser: `agc-py` will import it by relative path,
exactly as `tests/` and `examples/python/` do. No workspace split yet by
release discipline (not a tool requirement: a `ref` pin or `path` dep would
also work): we defer it until we cut the first `grammy-*` prefixed tag. That
split means moving `src/`, `tests/`, `grammars/`, `examples/` under `grammy/`
with its own manifest, a workspace-root manifest carrying the repository URL,
and rewriting relative imports to `pkg/grammy/...`; see roadmap phase 0.

## Subset sketch (phase 1 writes the binding version)

Only typed code compiles; the table is the whole contract:

| Python (subset) | Agentica |
|---|---|
| `def f(x: int) -> int` | `def f(x: Int) -> Int` |
| `x: int = 0` | `x: Int = 0` |
| `str`, `float`, `bool`, `None` | `String`, `Float`, `Bool`, `none` |
| `list[int]`, `dict[str, int]`, `X \| None` | `List[Int]`, `Map[String, Int]`, `Optional[X]` (`none` is the empty case) |
| `print`, `len`, `range` | `puts`, `List.size`, `Range` |

Out on purpose: classes, decorators, `yield`, `async`, `eval`/`getattr`,
in-place mutation (`list.append`), untyped `def`. Phase 1 also settles `with`,
`match`/`case` and f-strings. Each exclusion is a frontend error with a span,
not silently different behaviour. This sketch is non-binding; `agc-py/SUBSET.md`
from phase 1 supersedes it.

## Bytecode reference (sibling checkout, not a dependency)

The bytecode itself lives in `../agentica` (the Agentica implementation, next
to this repo), distilled here from commit `e31975ee9`: IR and lowering rules in
`docs/vm/03-ir-and-bytecode.md`, the writer in `compiler/bytecode/`, per-form
rules in `compiler/lower/`. What the
emitter must respect, distilled:

- Slots are per-function registers (`params, captures, locals, temporaries`);
  temporaries follow a stack discipline, so calls want their arguments in the
  highest live slots.
- Every statement and expression is a `step` with its span; loops charge per
  iteration, so generated code pays `--max-steps` like hand-written code.
- A call in direct `return` position is a `tail-call`; anything else is a
  `call`. Builtin calls (including higher-order `List` functions) are always
  `call-builtin`, never tail calls — so is `return 1 + f(n)` or
  `return try f(...)`.
- Assignment to an existing local lowers into a temporary, then usually a
  `move` (elided when the producing instruction can write the local directly).
- Literals over 255 elements are chunked by `agentica compile`, and deep
  nesting has a `BYTECODE-LIMIT`. The subset keeps literals small; larger ones
  stay correct because the backend chunks them.

`agc-py` never targets this layer directly: it emits `.agc` and lets
`agentica compile` lower it. The notes stay so codegen choices (flat
temporaries, tail positions, small literals) match what the backend rewards.
