# agc-py subset: the binding Python 3.12 contract

This file binds every later phase. Anything outside it is a frontend error by
definition; anything inside it must parse (phase 2), emit check-clean `.agc`
(phase 3) and run with the semantics written here (phase 4). It supersedes the
sketch in `agc-py/README.md`.

Rule zero: **every name is declared with a type, every `def` annotates every
parameter and its return.** An untyped `def`, an unannotated first binding and
`Any` are errors, not inference puzzles.

## 1. Types

| Python | Agentica | Notes |
|---|---|---|
| `int` | `Int` | 64-bit; overflow halts (Python bigints do not exist here) |
| `str` | `String` | unicode characters, as written |
| `float` | `Float` | 64-bit; `+inf`/`nan` spellings excluded |
| `bool` | `Bool` | `True`/`False` only; see §6 |
| `None` (as a return) | `Void` | `def f() -> None` returns nothing |
| `None` (as a value) | `none` | only inside `Optional[X]`; `nil` is never emitted |
| `list[T]` | `List[T]` | fixed element type |
| `dict[K, V]` | `Map[K, V]` | `K` is `str` or `int` |
| `X \| None`, `Optional[X]` | `Optional[X]` | both spellings accepted, same meaning |
| `"Fwd"` | the named type | string forward references resolve like bare names |

`tuple`, `set`, `bytes`, `complex`, `object`, `Any`, `Final`, `ClassVar`,
`cast`, `TYPE_CHECKING` are excluded (§9). `type Alias = ...` is included for
plain types only.

## 2. Names and binding

- The first binding of a name carries its annotation: `x: int = 0`.
  Rebinding keeps the type (`x = x + 1`); changing it is `PY-TYPE-MISMATCH`.
- `x += e` (and `-=`, `*=`, `/=`, `%=`) is sugar for `x = x OP e`. There is
  no `//=` or `**=` because there is no `//` or `**` operator to desugar
  from (see §3).
- No nested `def`, no `lambda`, no comprehensions, no `global`/`nonlocal`,
  no `del`. Module level plus one function level; with no function values
  in the subset there is nothing to close over.
- `pass` is a no-op. `...` (Ellipsis) is excluded.
- A keyword in name position (`if = 1`) parses as a name but is rejected at
  scope-check (`PY-RESERVED-NAME`).

## 3. Expressions

- Literals: ints (decimal/hex/oct/bin, underscores), floats (exponents),
  strings (prefixes `r`/`f`/plain, single/double/triple-quoted, escapes
  decoded), `True`/`False`/`None`. `b""` strings are excluded.
- Arithmetic is same-type only (`1 + 1.5` is `PY-TYPE-MISMATCH`; convert
  explicitly): `+ - * / %` on two `int` or two `float`. `/` on `int`
  truncates toward zero, exactly like the backend — which is why Python `/`
  on two `int`s does NOT map to `/`: it lowers to float division
  (`a / b` → `a.to_f / b.to_f`). Mixed or unknown combos are `PY-OPERATOR`.
- `//` on `int` lowers to a `floor_div` helper (truncating `/` corrected by
  one when the remainder is nonzero and the signs differ — verified:
  `-7 // 2 == -4` while the backend's `/` gives `-3`). `//` on `float` is
  `PY-OPERATOR`. `**` is `int` base with `int` exponent, lowered to `a.pow(b)` (probed:
  `2.pow(10) == 1024`; negative exponents and overflow halt). A statically
  negative exponent is `PY-OPERATOR`; a dynamic one halts at run time where
  Python would return a float — documented divergence, same family as
  overflow. Anything else is `PY-OPERATOR`. `%` is `int`-only with Python signs, lowered to a
  `pymod` helper (`-7 % 2 == 1` while the backend gives `-1`); float `%` is
  `PY-OPERATOR`.
- `+` concatenates two `str` (or two same-typed lists); `s * n` repeats a
  string (`n: int`, that order only). `[1, 2] * 2` and `3 * "ab"` are
  `PY-OPERATOR`.
- Comparisons `== !=` on anything; ordering `< <= > >=` on two numbers, or
  on two strings via `a.compare(b) < 0` (probed). Chained comparisons
  evaluate each operand once (temp + `and`).
- `and`/`or` short-circuit over `bool`; `not x` needs `bool`.
- Conditional expression `a if c else b`: the backend `if` is
  statement-only, so it lowers to a temp plus a statement `if`/`else`.
- Slices `xs[a:b]`: static negative bounds or a step are `PY-SLICE`; dynamic
  bounds clamp to `[0, len]` at run time (`a > b` and out-of-range `b` give
  empty, they never halt). Lowered to a `slice` helper over `take`/`drop`.
- `x in xs` / `x not in xs`: `List` via `include?`, `String` via
  `include?`, `Map` keys via `key?`. Unpacking (`a, b = ...`, `a, b = b, a`)
  is excluded with the tuple it would need.
- Calls are positional or keyword (`f(x=1)` works — probed), no `*args`,
  no `**kwargs`. Subscripting `xs[i]`, `d[k]`; out-of-range or a missing key
  halts like the backend, it is not a catchable error — use `d.get(k)`,
  which is included and yields `Optional[V]` (`none` when absent, probed);
  `d.get(k, default)` maps to the 3-arg `Map.get` (probed).
- Conversions and builtins, each with its lowering:
  `int(s)` → `s.to_i` (catchable `Result`, like `ValueError`),
  `int(f)` → `f.to_i`, `float(s)` → `s.to_f`, `float(n)` → `n.to_f`
  (`float("inf")`/`float("nan")` are catchable conversion errors in the
  backend, unlike Python — same `Result` family, documented divergence),
  `str(x)` → interpolation, `int`/`float` of the wrong kind →
  `PY-TYPE-MISMATCH`. `bool(x)` accepts `Bool` only, else `PY-TYPE-MISMATCH`
  (there is no truthiness to convert from, §6). `len()` → `size`/`length`.
  `range(a)` / `range(a, b)` map to ranges; 3-arg `range(a, b, step)`
  desugars to a `while`. `print(a, b, ...)` joins with single spaces via
  interpolation (one backend arg); `sep=`/`end=`/`file=` kwargs are
  `PY-OUT-OF-SUBSET`.
- `x is None` / `x is not None` only (→ `.none?()` checks); any other `is`
  is `PY-IS`.
- `x in xs` / `x not in xs` over `List`/`String` and `Map` keys (→
  `include?`/`key?`).
- `None` outside `Optional`: an unannotated `x = None` is `PY-UNTYPED-NAME`,
  `x: int = None` is `PY-TYPE-MISMATCH`, and an explicit `return None` is
  allowed only under `-> None`.

## 4. Statements

- Expression statements, assignment, `pass` (emits `nil`, so a body never
  ends up empty), `assert c` / `assert c, msg` with `c: bool` and `msg: str`
  (failure emits `IO.warn(msg)` then `System.exit(1)`; it is not catchable).
- `if`/`elif`/`else`, `while`, `for x in ...` over `List` and `Range`.
  String iteration desugars through `split("")` (Unicode scalar values,
  and `Bytes` is not an iteration source). No `for`/`while` `else`.
  `break` is included; the spelling is `next` for continue (the backend has
  no `continue` — verified by probe). Top-level statements in file order
  form the `main` body; top-level bindings are `main`-locals.
- `return` (a value only under a non-`Void` return; bare `return` only under
  `-> None`; anything else is `PY-TYPE-MISMATCH`). `raise E("msg")`
  lowers to `return error("msg")` — message only, the class is not modeled —
  so any function that can raise returns `Result[T]` and every caller
  handles it; the ripple is explicit, not inferred.
- `try`/`except` with exactly one handler (bare, `except E` or
  `except E as e`; the class is accepted syntactically but ignored, since
  classes are not modeled — `e`, when bound, is the message `String`).
  The body is outlined into a `-> Result[T]` helper; `return`, `break` and
  `next` inside a `try` body are `PY-TRY-CONTROL`. Catchable means exactly
  the `error(...)` values of `Result`-returning calls (`to_i`, helpers that
  `return error(...)`); halts (out-of-range, overflow, failed assert) are
  never catchable. No `finally`, no `try`/`else`, no `raise ... from`, no
  bare `raise`.
- `def` with full annotations, defaults allowed and re-evaluated per call
  (values are immutable, so sharing is unobservable — `def f(x: list = [])`
  is fine), keyword calls allowed. One file is one module (§5).

## 5. Imports and modules

- `import x`, `import x as y`, `import x, y`, `from x import a, b`
  (parenthesized lists allowed). Imports come first in the file; anything
  after the first non-import statement is `PY-IMPORT-POSITION`. One file is
  one module; the module name is the file stem, which must be a valid
  identifier (else `PY-IMPORT-UNKNOWN`).
- Search path: the file's folder first, then an explicit list (CLI flag in
  phase 4). Circular imports are `PY-IMPORT-CYCLE`, carrying every import
  span of the cycle. Relative imports, packages (`__init__`), and
  `TYPE_CHECKING`-gated imports are excluded.
- Unknown modules/names are `PY-IMPORT-UNKNOWN` / `PY-NAME-UNKNOWN` at the
  importing span.
- Stdlib surface (closed, each mapped in phase 3). Covered with what the
  backend and its std give today, nothing else:
  - builtins: `print` (-> `puts`, space-joined), `len` (-> `size`/`length`),
    `range` (-> `Range`, 3-arg form desugars), `str`/`int`/`float`/`bool`
    conversions, `sorted` (-> `List.sort`), `sum`/`min`/`max` (->
    `List.sum`/`min`/`max`), `abs` (-> `.abs`), `round` (-> `.round`,
    `Float` only — probed: `Int` has no `round`, an `int` needs no rounding),
    `chr`/`ord` (-> `String.from_code`/`.code`), `enumerate` (desugars to an
    index counter), `reversed` (-> `List.reverse`), `all`/`any` (->
    `List.all?`/`any?`), `map`/`filter` over named functions (->
    `List.map`/`select`).
  - `math`: `sqrt` (-> `Math.sqrt`), `floor`/`ceil` (-> the `Float` methods
    `x.floor()`/`x.ceil()`). The backend has no `Math.pi`/`tau` constants
    (probed: `CHECK-UNKNOWN-NAME`), so `math.pi`/`math.e`/`math.tau` lower to
    the `Float` literals `3.141592653589793`/`2.718281828459045`/
    `6.283185307179586`; `math.inf` has no spelling and is excluded
    (`PY-OUT-OF-SUBSET`).
  - `sys`: `argv` (-> `System.args()`), `exit` (-> `System.exit`), stdio via
    `IO` (`stdin` -> `IO.gets`, `stderr` via `IO.warn`).
  - `os`: `environ[name]` key lookup only (-> `System.env(name)`, which
    returns a catchable `Result`; `os.getenv(name)` lowers the same way).
    Iteration, `len` and `in` over `environ` are unmapped
    (`PY-OUT-OF-SUBSET`), `os.getcwd()` (-> `Path.cwd()`),
    `open(path)` read-only (-> `File.read_text`), `open(p, "w")` (->
    `File.write_text`), `open(p, "a")` (-> `File.append_text`, each a
    catchable `Result`); other modes are `PY-OUT-OF-SUBSET`. The rest of `os`
    is `PY-IMPORT-UNKNOWN`.
  - `json` (-> `JSON.parse`/`JSON.encode`), `re` (-> `std/regex`, RE2 subset),
    `toml` (-> `std/toml`), `datetime` (-> `std/utc`, partial:
    instants/formatting only, no arithmetic/`timedelta`/`strptime`),
    `urllib.parse` (->
    `std/uri`), `http.client` (-> `std/http`), `html` escaping (-> `std/html`),
    `mimetypes` (-> `std/mime`), `cookies` (-> `std/cookie`), `argparse` (->
    `std/option_parser`), `logging` (-> `std/logger`), `time` (-> `Time`),
    `random` (-> `Random`; secrets need `OpenSSL.Random`, excluded v0),
    `hashlib` (-> `OpenSSL.Digest`, partial), `pathlib` (-> `File`
    operations, partial), `string` methods: `strip`, `split`, `join`,
    `replace`, `upcase`, `downcase`, `start_with?`, `end_with?`, `include?`.
  - Excluded v0 (each a `PY-IMPORT-UNKNOWN`): `socket`, `threading`,
    `multiprocessing`, `asyncio`, `subprocess`, `sqlite3`, `csv`,
    `decimal`, `statistics` (beyond `List` helpers), `itertools`,
    `functools`, `collections`, `dataclasses`, `unittest`, `pdb`.
  Anything else from the stdlib is `PY-IMPORT-UNKNOWN`.

Backend mismatches to remember (phase 4 lowers exactly this): `List.min`/
`max` return `Optional` (Python raises on `[]`); `List.sort` is `Int`/`Float`/
`String` only; `"sep".join(xs)` flips to `xs.join(sep)`; bare `sys.exit()`
needs an explicit code (`System.exit` takes one argument, probed).

## 6. Truthiness

There is none. Conditions (`if`, `while`, `assert`, `not`, `and`/`or`
operands, the ternary guard) must be `bool`; anything else is
`PY-COND-NOT-BOOL`. No truthy lists, no truthy `None`, no custom `__bool__`
(there are no classes to define it on).

## 7. Mutation and aliasing

All values are immutable, so there is no observable aliasing; "mutation"
is rebinding:

- `xs.append(x)` and friends do not exist: `PY-MUTATION` names the
  rebinding (`xs = xs.push(x)`).
- Function arguments are passed by value as the backend passes them; there
  are no `out` parameters and no observable aliasing to reason about.

## 8. Lexical rules

- Comments `#` to end of line; blank lines never close a block.
- Implicit line joining inside `()/[]/{}` (newlines do not end the statement
  and do not disturb indentation); explicit `\` continuation is excluded —
  use brackets.
- Indentation is significant (`INDENT`/`SAME` in grammy terms); tabs count as
  one character each and must not be mixed with spaces on the same block
  level (`PY-INDENT`).
- Strings decode at the frontend to plain characters, then emit with only
  the escapes the backend lexer accepts — `\"`, `\\`, `\n`, `\r`, `\t`
  — and every other character raw in the UTF-8 source, including `'` (verified:
  `\0`, `\xNN`, `\u{...}` and even `\'` are all `LEX-INVALID-ESCAPE`,
  while raw non-ASCII, raw `'` and even a raw NUL byte lex fine). So the
  frontend decodes the whole Python set (`\a \b \f \v \0 \xNN \uNNNN`,
  `\n \r \t \' \"`) and re-encodes minimally; `\N{...}` is excluded (no
  Unicode tables in the frontend). `r"..."` disables escapes; `f"..."`
  interpolates subset expressions with `{{`/`}}` for literal braces.
  Triple-quoted strings are plain strings, not heredocs.

## 9. Excluded, each a frontend error with its own code

Classes, decorators, `yield`/`async`/`await`, `with`, `match`, `lambda`,
comprehensions, generator expressions, `global`/`nonlocal`, `del`, starred
assignment, tuple unpacking, `*args`/`**kwargs`, bare `*`, keyword-only
markers, `tuple`/`set`/`bytes`/`complex`, `Any`, `Final`, `ClassVar`,
`cast`, `TYPE_CHECKING`, `print` kwargs (`sep=`/`end=`/`file=`),
`eval`/`exec`/`getattr`/`setattr`/`globals`/`locals`/`vars`/`dir` (the
dynamic family: `PY-DYNAMIC`), `is` outside `None`, `finally`,
`try`/`else`, loop `else`, `raise from`, bare `raise`, `b""`, `...`,
relative imports, `__init__` packages, `\N{...}` escapes, `nan`/`inf`
spellings, float `//`/`%`/`**`, mixed `int`/`float` arithmetic without an
explicit conversion.

## 10. Error catalog (stable `PY*` codes)

Every code carries file/line/column, the offending span, an explanation and a
`= help:` when the fix is known (agc-py diagnostics principle). When several
codes could apply, the most specific one wins: `PY-MUTATION` over unknown-name,
`PY-IS` over out-of-subset, `PY-SLICE` over out-of-subset, `PY-DYNAMIC` over
out-of-subset, `PY-COND-NOT-BOOL` over `PY-TYPE-MISMATCH`, and an unknown name
inside an annotation is `PY-ANNOTATION-UNKNOWN`, not `PY-NAME-UNKNOWN`.

| Code | Meaning | Span |
|---|---|---|
| `PY-UNTYPED-DEF` | `def` without full annotations | the `def` header |
| `PY-UNTYPED-NAME` | first binding without annotation | the name |
| `PY-ANY` | `Any` (or `object` as an escape hatch) | the annotation |
| `PY-ANNOTATION-UNKNOWN` | unknown name in an annotation | the name |
| `PY-TYPE-MISMATCH` | literal/expression against its annotation | the value |
| `PY-COND-NOT-BOOL` | non-`bool` condition | the condition |
| `PY-MUTATION` | in-place mutating call (`append`, ...) | the call |
| `PY-DYNAMIC` | `eval`/`exec`/`getattr`/… | the call |
| `PY-IS` | `is` outside `None` | the operator |
| `PY-SLICE` | negative/stepped slice | the slice |
| `PY-IMPORT-CYCLE` | circular import | both import spans |
| `PY-IMPORT-UNKNOWN` | unknown module or stdlib member | the import |
| `PY-NAME-UNKNOWN` | unknown name | the name |
| `PY-RESERVED-NAME` | keyword used as a name | the name |
| `PY-OUT-OF-SUBSET` | anything else from §9 (the list is complete), naming it | the construct |
| `PY-OPERATOR` | operand combination the backend has no operator for | the operator |
| `PY-TRY-CONTROL` | `return`/`break`/`next` inside a `try` body | the statement |
| `PY-IMPORT-POSITION` | import after the first non-import statement | the import |
| `PY-INDENT` | mixed tabs/spaces on one level | the line |

## 11. Worked example

```python
def total(xs: list[int]) -> int:
    acc: int = 0
    for x in xs:
        if x > 0:
            acc = acc + x
    return acc

print(total([1, -2, 3]))
```

emits (shape, not text) a typed `.agc` program: `def total(xs: List[Int]) -> Int`
with `acc: Int = 0`, the loop over `xs`, the `bool` guard, `return acc`, and a
`main` printing `total([1, -2, 3])` — which `agentica check` accepts and
`agentica compile` lowers like hand-written code.
