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
// grammars/csv.grammar
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

A failure names the **deepest** position matching reached and the rules it
expected there, with the offending line:

```text
grammar: expected "cd" at line 1, column 3: abX
```

Labels are rule names, and literals or character classes from a named rule.
A silent rule contributes only rule names, so helper rules such as `ws` do not
add character noise.

`Grammar.compile` refuses a broken grammar before matching: a rule declared
twice, an unknown rule, a reserved name (`ANY`, `EOI`, `ASCII_DIGIT`, ...),
left recursion, a repetition of something that cannot fail
(`("")*`) or never consumes input (`(&"x")*`), and a choice arm that cannot
fail (which hides the arms after it).

## Grammar syntax

A rule is `name = { body }`, or `name = _{ body }` for a silent rule that builds
no node. Rules are separated by blanks; `//` starts a line comment and
`/* ... */` a block comment (they nest).

| In a body | Means |
|---|---|
| `"text"` | a literal (`\"`, `\\`, `\n`, `\r`, `\t`, `\0`, `\'`, `\xNN`, `\u{2-6 hex digits}`) |
| `^"text"` | the same literal, ASCII case insensitively |
| `'a'..'z'` | one character in a pest range |
| `a{n}`, `a{n,}`, `a{,n}`, `a{n,m}` | repetition bounds |
| `[a-z]`, `[^0-9]` | one character, in or out of the set; `\-` and `\]` are literal |
| `.` | any character |
| `name` | that rule; silent rules pass their children up |
| `ANY`, `SOI`, `EOI` (alias `EOF`), `NEWLINE` | builtins |
| `INDENT`, `SAME` | consume a line's indentation, compared with the `>` scope |
| `PUSH(a)`, `PUSH_LITERAL("t")` | push the text `a` matched, or the fixed string |
| `POP`, `PEEK`, `POP_ALL`, `PEEK_ALL`, `DROP` | match the stack top (or all of it) and pop it, or drop it |
| `a ~ b` | sequence (`~` is required between terms, as in pest) |
| `a \| b` | ordered choice: the first match wins, no longest match |
| `a*`, `a+`, `a?` | repetition; a repetition that matches nothing stops |
| `!a`, `&a` | negative and positive lookahead, consuming nothing |
| `#name = a` | names the last node `a` builds, or every iteration's last for `a*`, `a?`, `a+`, `a{n,m}` |
| `( ... )` | grouping |

Single-character builtins, all matching one character: `ASCII_DIGIT`,
`ASCII_NONZERO_DIGIT`, `ASCII_BIN_DIGIT`, `ASCII_OCT_DIGIT`, `ASCII_HEX_DIGIT`
(alias `ASCII_HEX`), `ASCII_ALPHA_LOWER`, `ASCII_ALPHA_UPPER`, `ASCII_ALPHA`,
`ASCII_ALPHANUMERIC` (alias `ASCII_ALNUM`), `ASCII`, `ANY`. `NEWLINE` matches
`\n`, `\r\n` or `\r`; `SOI` and `EOI` match the ends of the input.

Between `=` and `{` a rule takes modifiers: `_` builds no node, `>` opens an
indentation scope, and `@`, `$`, `!` set the atomicity. They combine (`>_{` is
both) and each may appear at most once.

## Whitespace and atomicity

Define `WHITESPACE` and/or `COMMENT` and they are matched implicitly between the
parts of a sequence, between the iterations of a repetition, and after the start
rule — exactly `WHITESPACE* ~ (COMMENT ~ WHITESPACE*)*`. They are ordinary rules,
so they are declared like any other (write them silent, `= _{ ... }`: a skip rule
is matched atomically and never builds nodes). As in pest, the compiler refuses
one that can never fail (so skipping would never move) or that never consumes
input:

```
WHITESPACE = _{ " " | "	" | NEWLINE }
COMMENT = _{ "//" ~ (!NEWLINE ~ ANY)* }
```

Atomicity says what happens inside a rule:

| Modifier | Whitespace inside | Nodes inside |
|---|---|---|
| none | skipped | built |
| `@` atomic | not skipped | dropped: the rule is one token |
| `$` compound-atomic | not skipped | built |
| `!` non-atomic | skipped | built, even inside an atomic rule |

A plain rule inherits the atomicity of its caller, which is how `@` swallows
everything it calls that does not declare its own atomicity. `!` restores normal
behaviour inside it.

A repetition without a bound stops on the first iteration that makes no
progress. Left recursion is not supported (it will not terminate).

## The stack

Grammars can remember text and match it again later — pest's stack, used for
balanced constructs without left recursion:

```
nested = { "(" ~ PUSH_LITERAL(")") ~ (nested | inner)* ~ POP }
inner  = { (!("(" | ")") ~ ANY)+ }
```

`nested` accepts `((a)(b))`: each `(` stores the `)` that must close it, and `POP`
only matches when that `)` is really there. `PUSH(e)` works the same way when the
closing text is what `e` matched (`PUSH(ASCII_DIGIT+) ~ " #" ~ POP`).

`PUSH(a)` stores the text `a` covered, `PUSH_LITERAL("t")` stores a fixed
string, `POP` matches the top and pops it, `PEEK` matches it without popping,
`POP_ALL`/`PEEK_ALL` walk the whole stack from its top down, and `DROP` pops
without matching. The stack is part of the matched value, so a failed
alternative (or a repetition that stops, or a lookahead) leaves it untouched.
`POP`, `PEEK` and `DROP` on an empty stack fail the match; `POP_ALL` and
`PEEK_ALL` on an empty stack match nothing, as in pest. The compiler refuses a
grammar that reads the stack without ever pushing to it, and a `WHITESPACE` or
`COMMENT` that uses it — skipping stays side-effect free.

## Indentation

Blocks are matched without rewriting the input, so spans and error columns stay
real. A rule marked `>` records the indentation of the line it starts on as the
block base; `INDENT` then consumes the indentation of the next non-blank line
when it is deeper than the base, and `SAME` when it is equal:

```
if_stmt = { "if" ~ ws ~ expr ~ ":" ~ suite ~ elif_branch* }
elif_branch = { eol ~ SAME ~ "elif" ~ ws ~ expr ~ ":" ~ suite }
suite = >_{ eol ~ INDENT ~ statement ~ (eol ~ INDENT ~ statement)* }
```

A block ends by itself: the repetition fails on the first line that is not
deeper, and the enclosing scope continues from that line. Tabs count as one
character each, and blank lines are skipped by `INDENT`/`SAME`, so they never
close a block.

`INDENT` and `SAME` also accept a position that is already inside the leading
spaces of a line, so implicit whitespace (even one that matches newlines) does
not hide the indentation they measure: the skip may reach the content of the
next line and `INDENT` still sees the indentation it left behind.

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
Grammy.tagged(node, tag) -> List[Node]              # depth first, by tag
Grammy.first_tagged(node, tag) -> Optional[Node]
Grammy.position(input, offset) -> Position          # line, column, line_text
Grammy.to_json(node, input) -> String              # the tree as JSON, pest `Pair::to_json` style
Grammy.json_string(value) -> String                # a string as a JSON string literal
```

```text
agentica src/main.agc <grammar> <rule> [input-file]         # prints the tree, one node per line
agentica src/main.agc <grammar> <rule> [input-file] --json  # prints the tree as JSON
```

`Grammar`, `Rule`, `Expr`, `ClassItem`, `Atomicity`, `UNBOUNDED`, `Node` and
`Position` are re-exported types.

## The Python subset

`grammars/python.grammar` plus `examples/python/interp.agc` is a working
interpreter: numbers, text, `True`/`False`, names, `print(...)`,
`+ - * /`, comparisons, `and`/`or`/`not`, parentheses, assignment,
`if`/`elif`/`else` and `while`.

Blocks are real Python indentation, nested as deep as you like:

```python
if total > 20:
    if i == 5:
        print("counted")
    print("twenty")
else:
    print("small")
```

```bash
make example
# or
agentica examples/python/main.agc examples/python/sample.py
```

Escapes inside text are not decoded yet, and there are no functions, lists,
dicts, `//` or `for`. `Interp.run` reads `grammars/python.grammar` relative to the
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

- a tag must name something that builds a node (pest drops such a tag silently)
- no `PEEK[a..b]` stack slices
- no packrat memoization; left recursion is refused by the compiler
- nodes keep no span information other than start/stop offsets
- the Python example has no functions, lists, dicts or `//`
