# pest parity

Where `grammy` stands against [pest](https://pest.rs) and what is worth closing.

Reference: `pest-parser/pest` at commit `7e14252` (2026-11-13), read from a
throwaway clone. Sources used: `meta/src/grammar.pest` (the meta-grammar, i.e.
the official syntax), `meta/src/validator.rs`, `pest/src/lib.rs` (special and
builtin rules), `pest/src/parser_state.rs`, `pest/src/error.rs`,
`pest/src/{span,position,stack}.rs`, `pest/src/iterators/*`, `derive/src/lib.rs`,
`generator/src/generator.rs`, `vm/src/lib.rs`.

Legend: **have** = works today, **partial** = narrower or different,
**missing** = not implemented. Decision: **now** = next milestone, **later** =
worth having, **no** = deliberately out of scope.

## 1. Grammar language

| Feature | pest | grammy | Decision |
|---|---|---|---|
| `name = { body }` rules | yes | yes | — |
| silent rule `_` | yes | yes | — |
| atomic `@` | yes | yes | done |
| compound atomic `$` | yes | yes | done |
| non-atomic `!` | yes | yes | done |
| implicit `WHITESPACE` / `COMMENT` skipping | yes | yes | done |
| node tags `#tag = expr` | yes (extra) | yes | done, tags with no node are refused |
| string literal `"text"` | yes | yes | — |
| insensitive literal `^"text"` | yes | yes | done |
| range `'a'..'z'` | yes | yes (parsed as a one-span class) | done |
| class `[a-z]`, `[^0-9]` | no | yes (extension) | keep |
| `.` any char | no (`ANY`) | yes (extension) | keep |
| sequence `~` | required | required | done |
| ordered choice `\|` | yes | yes | — |
| `*`, `+`, `?` | yes | yes | — |
| bounds `{n}`, `{n,}`, `{,n}`, `{n,m}` | yes | yes | done |
| `&`, `!` lookahead | yes | yes | — |
| grouping `( )` | yes | yes | — |
| left recursion | static error | static error | done |
| indentation blocks | none (users pre-process or use the stack) | `>` scope with `INDENT`/`SAME` (extension) | done |
| `//` line and `/* */` nested comments | yes | yes (`#` removed) | done |
| doc comments `///`, `//!` | yes | missing | later |
| escapes `\" \\ \n \r \t` | yes | yes | — |
| escapes `\0 \' \xNN \u{NNNN}` | yes | yes | done |
| `PUSH`, `PUSH_LITERAL`, `POP`, `POP_ALL`, `DROP` | yes | yes | done |
| `PEEK`, `PEEK_ALL` | yes | yes | done |
| `PEEK[a..b]` stack slices | yes (grammar-extras) | missing | later |
| `ANY` | yes | yes | — |
| `SOI` | yes | yes | done |
| `EOI` | yes | yes (alias `EOF`) | done |
| `NEWLINE` (`\n`, `\r\n`, `\r`) | yes | yes | done |
| `ASCII_DIGIT` | yes | yes | — |
| `ASCII_NONZERO_DIGIT`, `ASCII_BIN_DIGIT`, `ASCII_OCT_DIGIT` | yes | yes | done |
| `ASCII_ALPHA_LOWER`, `ASCII_ALPHA_UPPER`, `ASCII` | yes | yes | done |
| `ASCII_ALPHANUMERIC` | yes | yes (alias `ASCII_ALNUM`) | done |
| `ASCII_HEX_DIGIT` | yes | yes (alias `ASCII_HEX`) | done |
| Unicode properties `\p{L}`, `\p{Emoji}` | yes (tables) | missing | no (tables; revisit on demand) |
| grammar file extension | `.pest` | `.grammar` | accept both |

Known deviation: an unknown escape (`\d`) keeps its character instead of
being refused as pest does; the `\x`/`\u` forms are strict.

Naming note: `ANY`/`EOF`/`ASCII_ALNUM`/`ASCII_HEX` are our own names; pest parity
means `ANY`/`EOI`/`ASCII_ALPHANUMERIC`/`ASCII_HEX_DIGIT`, with our old names kept
as aliases so existing grammars keep working.

## 2. Grammar validation

| Check | pest | grammy | Decision |
|---|---|---|---|
| duplicate rule names | yes | yes | — |
| unknown rule references | yes | yes | — |
| pest keyword used as a rule name | yes | yes | done |
| left recursion | yes, reported at compile time | yes | done |
| expression that cannot fail inside a repetition (`("")*`) | yes | yes | done |
| non-progressing expression inside a repetition (`&""*`) | yes | yes | done |
| unreachable choice arm (a non-failing arm before others) | yes | yes | done |
| `WHITESPACE`/`COMMENT` must not fail and must progress | yes | yes | done |
| tags on silent rules | yes | yes (also on literals and builtins) | done |
| stack-only loops | yes | n/a | later |
| Rust keyword rule names | deprecated | n/a | no |

Our engine already *behaves* safely on a zero-width repetition (it breaks
instead of spinning); pest instead refuses the grammar. Refusing is better: the
author almost always wrote something else.

## 3. Engine semantics

| Behaviour | pest | grammy |
|---|---|---|
| ordered choice, first match wins | yes | yes |
| greedy repetition, no give-back (`"a"* ~ "a"` fails) | yes | yes |
| named rules build nodes, silent rules do not | yes | yes |
| the start rule must consume the whole input (`EOI`) | yes | yes |
| `WHITESPACE`/`COMMENT` run between tokens | yes | yes |
| indentation-aware matching (`INDENT`, `SAME`) | no | yes (extension) |
| atomic rules stop whitespace skipping and child nodes | yes | yes (`$`/`!` children keep theirs, as in pest) |
| stack mutation with rollback on a failed alternative | yes | yes (the stack rides on the matched value) |
| `PUSH`/`PUSH_LITERAL`/`POP`/`POP_ALL`/`PEEK`/`PEEK_ALL`/`DROP` | yes | yes |
| `PEEK[a..b]` stack slices | yes (grammar-extras) | no |
| compile-time check that a `POP` is protected by a `PUSH` | yes (call graph) | partial (whole grammar) |
| left recursion through a stack read | analysed | refused (reads count as nullable, so the check is conservative) |
| `DROP*` / a repetition that only shrinks the stack | allowed | allowed (drains, then stops) |
| stack use inside `WHITESPACE`/`COMMENT` | shares the parse stack | refused (skipping stays side-effect free) |
| furthest failure with positives/negatives | yes | yes (deepest attempt, labels, line/column) |
| custom errors, `renamed_rules` | yes | no |
| call limit, error detail knob | yes | no (the VM's `--max-steps` is the only bound) |
| right-to-left matching (`MatchDir`) | yes | no |
| input is `&str`, rules are `char`-based | yes | chars are 1-character `String`s |

## 4. Runtime API

pest ships `Pair`/`Pairs`/`Tokens`/`FlatPairs` over a compile-time `Rule` enum;
grammy ships `Node(rule, start, stop, children)` with rule names as strings.

| API | pest | grammy | Decision |
|---|---|---|---|
| tree node | `Pair` | `Node` | — |
| children iterator | `Pairs::into_inner` | `Node.children`, `children_of` | — |
| node text | `Pair::as_str` | `Tree.text(node, input)` | — |
| span | `Span::{start,end}`, `Pair::as_span` | `Node.start/stop` | — |
| line/column | `Pos::line_col`, `Pair::line_col`, `Position::line_of` | `Tree.position(input, offset)` | later (add a line index; today O(n) per call) |
| flattened traversal | `Pairs::flatten` | `Tree.find_all` | — |
| all tokens of a rule | `Pair::tokens`, `Pairs::tokens` | `Tree.find_all` / `children_of` | — |
| JSON dump of the tree | `Pairs::to_json` | CLI renders text | later |
| node tags | `Pair::as_node_tag`, `find_tagged` | `Node.tag`, `Tree.tagged`/`first_tagged` | done |
| parse entry point | `Pest::parse(Rule, input)` | `Engine.run(grammar, rule, input)` | — |
| grammar compiled ahead of time | `#[derive(Parser)]` | `Grammar.load` at run time | no (see §6) |
| typed stack | `pest::Stack` | missing | later |
| precedence helpers | `PrattParser`, `PrecClimber` | missing | no |

## 5. Tooling and ecosystem

| Item | pest | grammy | Decision |
|---|---|---|---|
| runtime grammar interpretation | `pest_vm::Vm` | this is our model | — |
| code generation | `pest_derive` proc macro | none | no (§6) |
| optimizer (rule inlining, skipping) | `pest_generator` | none | later (perf) |
| ready-made grammars | json, toml, sql, http | python subset | later (port `json.pest`) |
| self-hosting grammar | `bootstrap/` | none | later (good stress test) |
| debugger | `pest_debugger` | none | no |
| fuzzing, benchmarks, resource limits | yes | none | later |

## 6. Out of scope, and why

| Not doing | Why |
|---|---|
| proc macro / generated `Rule` enum | Agentica has no macros. Loading a grammar at run time and querying nodes by rule name is the equivalent; a `grammy gen` that writes typed `.agc` helpers could come later, but the tree API already covers the use case. |
| Unicode property tables (`\p{...}`) | They are megabytes of generated data in pest; as `.agc` source they would dominate the repo. A generated optional module later, if a real grammar needs it. |
| Indentation-sensitive blocks | We have this and pest does not (`>` scope plus `INDENT`/`SAME`, no input rewriting). It is an extension, not a parity item; keep it outside the pest syntax surface. |
| `MatchDir`, `PrecClimber`, `PrattParser`, `miette`, debugger | Rust-ecosystem conveniences with no Agentica analogue; precedence belongs in user code over the tree. |
| Rust keyword validation | Rust-specific. |

## 7. What to do, in order

### Milestone 1 — trustworthy (cheap, high value) — DONE (1, 2 and 3)

1. **Furthest-failure errors** — done: matching threads an `Outcome` with the
   deepest `Attempt` (labels for rule names, literals and classes; silent rules
   drop terminal labels) and the message carries line, column and the line.
   Pest-style `positives`/`negatives` and `renamed_rules` are not done.

   Original brief: **Furthest-failure errors.** Thread a failure record (position, expected
   rules, what was negated) through matching and report the deepest one with
   line, column and the offending line. Today every error says "line 1,
   column 1", which makes real grammars undebuggable. Touches every `match_*`
   signature, but mechanically.
2. **Validator parity for hangs** — done: left recursion (through nullable
   prefixes and mutual recursion), non-failing and non-progressing repetitions,
   reserved (pest keyword/builtin) rule names, and unreachable choice arms.
3. **Syntax fill-ins** — done: repetition bounds `{n,m}`, `^"literal"`,
   escapes `\0 \' \xNN \u{...}`, `//` and nested `/* */` comments,
   `'a'..'z'` ranges as one-span classes, required `~`, and the full pest
   builtin set.

### Milestone 2 — real grammars

4. **Atomicity and implicit whitespace** — done: `@` (atomic), `$`
   (compound-atomic) and `!` (non-atomic) set `Ctx.atomicity`, which cascades
   into called rules; a plain rule inherits it, `!` restores it. `WHITESPACE`
   and `COMMENT` are skipped between sequence parts and repetition iterations
   and once after the start rule, as `WHITESPACE* ~ (COMMENT ~ WHITESPACE*)*`;
   atomic rules skip nothing and `@` drops the nodes of the rules it calls that
   do not declare their own atomicity (`$` and `!` keep theirs, as pest does).
   The validator refuses a skipped rule that can never fail or that never
   consumes input, as pest's `validate_whitespace_comment` does.
   Deviation: a skip rule is matched atomically, so it never builds nodes even
   when it is not declared silent; pest inserts those nodes into the tree.
   Also: `INDENT`/`SAME` are ours and accept a position inside the leading
   spaces of a line, so implicit skipping cannot hide the indentation they
   measure (pest has no equivalent).
5. **Node tags** — done: `#name = term` parses to `Expr.Tagged`, `Node.tag`
   carries it, `Tree.tagged`/`first_tagged` query it. A tag names the last node
   its term built, and over `*` or `?` the last node of every iteration, which
   is what pest's `tag_node` does after each iteration. Deviations: `+` and
   `{n,m}` tag every iteration too, where pest falls through to the default arm
   and tags only the final node of the whole repetition (a pest inconsistency we
   do not copy); and a tag on an expression that builds no node is a compile
   error, where pest writes the tag onto the last pair already queued (a
   preceding sibling) or no-ops inside a lookahead. The validator follows a
   silent rule into its body, so tagging a silent wrapper is allowed. A tag
   inside an atomic rule names nothing in grammy, since `@` builds no inner
   nodes.

### Milestone 3 — power and speed

6. **Stack operations** — done: `PUSH(expr)` and `PUSH_LITERAL("text")` push,
   `POP`/`PEEK` match the top, `POP_ALL`/`PEEK_ALL` walk the stack from its top
   down, `DROP` pops without matching. The stack lives in `Progress`, so a
   failed alternative rolls it back for free. Deviations: `PEEK[a..b]` slices
   (pest grammar-extras) are not implemented, and the "a `POP` must be
   protected by a `PUSH`" check is per grammar instead of per rule reachability,
   so an empty stack fails the parse where pest refuses the grammar.
7. **Performance**: compile literals to character lists (no `split` per match),
   a line index for positions, and memoization. Then benchmark against
   `grammars/json.pest` on a large document.
8. **Ecosystem**: port `json.pest` unchanged as a test of parity, add
   `Pairs::to_json`-style output, and write grammy's own `.grammar` parser as a
   `.grammar` (self-hosting).

## 8. Decisions

1. **Syntax: pest is the base, with two documented extensions (done).** A
   `.pest` body parses: `"text"`, `^"text"`, `'a'..'z'`, `ANY`, `~`, `|`,
   `* + ?`, `{n,m}`, `& !`, `( )` and `//`/`/* */` comments. The extensions are
   `[a-z]`/`[^...]` classes and `.` for `ANY`; pest has no `[` in a body, so
   they never conflict. `#` comments are gone (they collided with the future
   node tags `#tag = expr`) and `~` is required. The `_ @ $ !` modifiers all
   work, at most one of `_ @ $ !` per rule.
2. **Builtin names: pest names, old ones as aliases (done).** `EOI` and `EOF`,
   `ASCII_ALPHANUMERIC` and `ASCII_ALNUM`, `ASCII_HEX_DIGIT` and `ASCII_HEX`
   all work; the grammar validator reserves every one of them.
3. **Order: errors and validation first (done), then the syntax fill-ins, then
   atomicity with implicit whitespace.**
4. **Indentation is ours, and it lives in the engine.** `>` rules capture the
   line's indentation as the block base; `INDENT`/`SAME` consume and compare.
   No input rewriting, so spans and error columns stay exact. pest has no
   equivalent, so this stays an extension outside the pest syntax surface.
