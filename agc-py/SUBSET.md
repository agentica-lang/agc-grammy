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
- `x += e` (and `-=`, `*=`, `//=`, `%=`, `**=`) is sugar for `x = x OP e`.
- No nested `def`, no `global`/`nonlocal`, no `del`. Module level plus one
  function level; closures read outer names but never assign them (the backend
  cannot, so the subset does not pretend otherwise).
- `pass` is a no-op. `...` (Ellipsis) is excluded.

## 3. Expressions

- Literals: ints (decimal/hex/oct/bin, underscores), floats (exponents),
  strings (prefixes `r`/`f`/plain, single/double/triple-quoted, escapes
  decoded), `True`/`False`/`None`. `b""` strings are excluded.
- Operators with the usual precedence: `+ - * / // % **` (`/` on `int` is
  truncating, as the backend; `**` on `int` only), unary `-`/`not`,
  comparisons (`== != < <= > >=`), chained comparisons (evaluated once per
  operand, desugared with `and`).
- `and`/`or` short-circuit over `bool`; `not x` needs `bool`.
- Conditional expression `a if c else b` (lowers to the backend `if`
  expression, which was probed to work).
- Slices `xs[a:b]` with `0 <= a <= b`, no step, no negative bounds
  (negative or stepped slices are `PY-SLICE`).
- Calls are positional or keyword (`f(x=1)` works — probed), no `*args`,
  no `**kwargs`. Subscripting `xs[i]`, `d[k]`; out-of-range halts like the
  backend, it is not a Python `IndexError` you can catch (see `try` below).
- Conversions and builtins: `int()`, `float()`, `str()`, `bool()`, `len()`,
  `range()` (1–3 args), `print(...)` (space-joined, one line).
- `x is None` / `x is not None` only; any other `is` is `PY-IS`.

## 4. Statements

- Expression statements, assignment, `assert c` / `assert c, msg` (failure
  halts with the message, it is not catchable).
- `if`/`elif`/`else`, `while`, `for x in ...` over `List`, `Range` and
  `String` (one-character strings). No `for`/`while` `else`. `break` is
  included; the spelling is `next` for continue (the backend has no
  `continue` — verified by probe).
- `return` (bare `return` only under `-> None`), `raise E("msg")` (message
  only, the class is not modeled).
- `try`/`except` (bare, `except E`, `except E as e`, several handlers in
  order) mapping onto `Result`: the `try` block is the fallible call, each
  handler is an `error` arm. No `finally`, no `else`, no `raise ... from`.
- `def` with full annotations, defaults allowed (`def f(x: int = 3)` —
  probed), keyword calls allowed. One file is one module (§5).

## 5. Imports and modules

- `import x`, `import x as y`, `from x import a, b` (top of file). One file is
  one module; the module name is the file stem.
- Search path: the file's folder first, then an explicit list (CLI flag in
  phase 4). Circular imports are `PY-IMPORT-CYCLE` with both spans.
- Unknown modules/names are `PY-IMPORT-UNKNOWN` / `PY-NAME-UNKNOWN` at the
  importing span.
- Stdlib surface (closed, each mapped in phase 3): `math.sqrt`, `math.floor`,
  `math.ceil`, `sys.argv` (→ `System.args`), string methods used through
  calls stay method calls (`s.strip()`, `s.split(",")`, ...). Anything else
  from the stdlib is `PY-IMPORT-UNKNOWN`.

## 6. Truthiness

There is none. Conditions (`if`, `while`, `assert`, `not`, `and`/`or`
operands, the ternary guard) must be `bool`; anything else is
`PY-COND-NOT-BOOL`. No truthy lists, no truthy `None`, no custom `__bool__`
(there are no classes to define it on).

## 7. Mutation and aliasing

Values are immutable; "mutation" is rebinding:

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

## 9. Excluded, each a frontend error with its own code

Classes, decorators, `yield`/`async`/`await`, `with`, `match`, `lambda`,
comprehensions, generator expressions, `global`/`nonlocal`, `del`, starred
assignment, `*args`/`**kwargs`, keyword-only markers, `tuple`/`set`/`bytes`/
`complex`, `Any`, `Final`, `print(..., file=)`, `eval`/`exec`/`getattr`/
`setattr`/`globals`/`locals`/`vars`/`dir` (the dynamic family:
`PY-DYNAMIC`), `is` outside `None`, negative/stepped slices, `finally`,
`try`/`else`, loop `else`, `raise from`, `b""`, `...`.

## 10. Error catalog (stable `PY*` codes)

Every code carries file/line/column, the offending span, an explanation and a
`= help:` when the fix is known (agc-py diagnostics principle).

| Code | Meaning | Span |
|---|---|---|
| `PY-UNTYPED-DEF` | `def` without full annotations | the `def` line |
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
| `PY-OUT-OF-SUBSET` | anything else from §9, naming it | the construct |
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
