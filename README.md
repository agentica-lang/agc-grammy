# grammy

A pest-like PEG parser generator for [Agentica](https://www.agentica-lang.com/):
the grammar lives in a `.grammar` file, the code that uses it lives in ordinary
`.agc` files.

```ruby
# src/grammy.agc is the library; a user file imports it by relative path
import Grammy from "../../src/grammy"

grammar = try Grammy.load("grammars/python.grammar")
tree = try Grammy.run(grammar, "program", source)
puts(Grammy.text(tree, source))
```

The tree is a plain `Grammy.Node(rule, start, stop, children)`, so user code
queries it by rule name exactly as pest code queries `Rule`.

## Layout

```
agentica.toml            name, minimum Agentica version, [style]
grammars/python.grammar  a grammar: a Python subset
src/grammar.agc          the AST and the `.grammar` parser
src/engine.agc           the PEG matcher that builds the tree
src/tree.agc             Node, Position and tree queries
src/grammy.agc           the public facade (re-exports)
src/main.agc             CLI: run a rule and print the tree
examples/python/         interp.agc (the code that uses the grammar), main.agc, sample.py
tests/                   Agentica unit tests
```

## Quickstart

Write a grammar:

```
# grammars/csv.grammar
row = { cell ~ ("," ~ cell)* }
cell = { [^,\n]* }
file = _{ row ~ "\n"* ~ (row ~ "\n"*)* }
```

Use it:

```ruby
import Grammy from "../../src/grammy"

def rows(source: String) -> Result[List[Grammy.Node]]
  grammar = try Grammy.load("grammars/csv.grammar")
  tree = try Grammy.run(grammar, "file", source)
  ok(Grammy.find_all(tree, "row"))
end
```

Run it from the command line:

```bash
agentica src/main.agc grammars/csv.grammar file data.csv   # prints the tree
agentica src/main.agc grammars/csv.grammar file           # reads stdin
```

The start rule must consume the whole input; leftover text is an error that
names the line and column.

## Grammar syntax

A rule is `name = { body }`, or `name = _{ body }` for a silent rule that builds
no node. Rules are separated by blanks; `#` starts a comment.

| In a body | Means |
|---|---|
| `"text"` | a literal (`\"`, `\\`, `\n`, `\r`, `\t`) |
| `[a-z]`, `[^0-9]` | one character, in or out of the set; `\-` and `\]` are literal |
| `.` | any character |
| `name` | that rule; silent rules pass their children up |
| `ANY`, `EOF`, `ASCII_DIGIT`, `ASCII_ALPHA`, `ASCII_ALNUM`, `ASCII_HEX`, `NEWLINE` | builtins |
| `a ~ b` | sequence (`~` may be left out between terms) |
| `a \| b` | ordered choice: the first match wins, no longest match |
| `a*`, `a+`, `a?` | repetition; a repetition that matches nothing stops |
| `!a`, `&a` | negative and positive lookahead, consuming nothing |
| `( ... )` | grouping |

There is no implicit whitespace skipping: write `ws` into the grammar, or use a
silent rule. Left recursion is not supported (it will not terminate).

## API

```text
Grammy.load(path: String) -> Result[Grammar]        # read and compile a file
Grammy.compile(text: String) -> Result[Grammar]     # compile grammar text
Grammy.run(grammar, rule: String, text) -> Result[Node]
Grammy.rule(grammar, name) / Grammy.find(grammar, name)
Grammy.text(node, input) -> String                  # what the node covered
Grammy.snippet(node, input) -> String               # the same, clipped for a message
Grammy.children_of(node, name) -> List[Node]        # direct children
Grammy.first_child(node, name) / Grammy.last_child(node) -> Optional[Node]
Grammy.first(node, name) -> Optional[Node]          # depth first
Grammy.find_all(node, name) -> List[Node]           # depth first
Grammy.position(input, offset) -> Position          # line, column, line_text
```

`Grammar`, `Rule`, `Expr`, `ClassItem`, `UNBOUNDED`, `Node` and `Position` are
re-exported types.

## The Python subset

`grammars/python.grammar` plus `examples/python/interp.agc` is a working
interpreter: numbers, text, `True`/`False`, names, `print(...)`,
`+ - * /`, comparisons, `and`/`or`/`not`, parentheses, assignment,
`if`/`elif`/`else` and `while`.

A suite is one statement, or several joined by `;`, so no indentation handling
is needed:

```python
while i < 5: total = total + i * 2; i = i + 1
```

```bash
make example
# or
agentica examples/python/main.agc examples/python/sample.py
```

Escapes inside text are not decoded yet, and there are no functions, lists,
dicts or `//`. `Interp.run` reads `grammars/python.grammar` relative to the
working directory.

## Development

```bash
make check       # agentica check src examples tests
make fmt         # agentica fmt, in place
make fmt-check   # fails when a file is not formatted
make lint        # style suggestions
make test        # agentica test tests
make ci          # check + fmt-check + lint + test
```

`agentica test` with no path only looks in `test/` and `specs/`, so the tests
live in `tests/` and are run as `agentica test tests`.

## Not there yet

- error messages report the start position, not the furthest failure
- no implicit whitespace, no `^"case insensitive"` literals
- no packrat memoization and no left recursion
- nodes keep no span information other than start/stop offsets
- the Python example has no functions, lists, dicts or `//`
