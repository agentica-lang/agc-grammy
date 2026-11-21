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
| atomic `@` | yes | missing | later |
| compound atomic `$` | yes | missing | later |
| non-atomic `!` | yes | missing | later |
| implicit `WHITESPACE` / `COMMENT` skipping | yes | missing | later (with atomicity) |
| node tags `#tag = expr` | yes (extra) | missing | later |
| string literal `"text"` | yes | yes | — |
| insensitive literal `^"text"` | yes | missing | now |
| range `'a'..'z'` | yes | missing (classes instead) | now, as an alias |
| class `[a-z]`, `[^0-9]` | no | yes (extension) | keep |
| `.` any char | no (`ANY`) | yes (extension) | keep |
| sequence `~` | required | optional | keep |
| ordered choice `\|` | yes | yes | — |
| `*`, `+`, `?` | yes | yes | — |
| bounds `{n}`, `{n,}`, `{,n}`, `{n,m}` | yes | missing | now |
| `&`, `!` lookahead | yes | yes | — |
| grouping `( )` | yes | yes | — |
| left recursion | static error | static error | done |
| indentation blocks | none (users pre-process or use the stack) | `>` scope with `INDENT`/`SAME` (extension) | done |
| `//` line and `/* */` nested comments | yes | only `#` | now (`#` stays) |
| doc comments `///`, `//!` | yes | missing | later |
| escapes `\" \\ \n \r \t` | yes | yes | — |
| escapes `\0 \' \xNN \u{NNNN}` | yes | missing | now |
| `PUSH`, `PUSH_LITERAL`, `POP`, `POP_ALL`, `DROP` | yes | missing | later |
| `PEEK`, `PEEK[a..b]`, `PEEK_ALL` | yes | missing | later |
| `ANY` | yes | yes | — |
| `SOI` | yes | missing | now |
| `EOI` | yes | as `EOF` | now (rename, keep `EOF`) |
| `NEWLINE` (`\n`, `\r\n`, `\r`) | yes | `\n`, `\r` | now (add `\r\n`) |
| `ASCII_DIGIT` | yes | yes | — |
| `ASCII_NONZERO_DIGIT`, `ASCII_BIN_DIGIT`, `ASCII_OCT_DIGIT` | yes | missing | now |
| `ASCII_ALPHA_LOWER`, `ASCII_ALPHA_UPPER`, `ASCII` | yes | missing | now |
| `ASCII_ALPHANUMERIC` | yes | as `ASCII_ALNUM` | now (rename, keep alias) |
| `ASCII_HEX_DIGIT` | yes | as `ASCII_HEX` | now (rename, keep alias) |
| Unicode properties `\p{L}`, `\p{Emoji}` | yes (tables) | missing | no (tables; revisit on demand) |
| grammar file extension | `.pest` | `.grammar` | accept both |

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
| `WHITESPACE`/`COMMENT` must fail and progress | yes | n/a | later (with implicit skipping) |
| tags on silent rules | yes | n/a | later |
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
| `WHITESPACE`/`COMMENT` run between tokens | yes | no |
| indentation-aware matching (`INDENT`, `SAME`) | no | yes (extension) |
| atomic rules stop whitespace skipping and child nodes | yes | no |
| stack mutation with rollback on a failed alternative | yes | no |
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
| node tags | `Pair::as_node_tag`, `find_tagged` | missing | later |
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

### Milestone 1 — trustworthy (cheap, high value) — DONE (1 and 2)

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
3. **Syntax fill-ins** — the pest builtin names (`EOI`, `SOI`, the whole
   `ASCII_*` family) and `NEWLINE` with `\r\n` are done. Still missing, and
   next: repetition bounds `{n,m}`, `^"literal"`, escapes `\0 \' \xNN \u{...}`,
   `//` and `/* */` comments, `'a'..'z'` ranges, `~` required, and the `@`/`$`/`!`
   modifiers (they parse today and report "not supported yet").

### Milestone 2 — real grammars

4. **Atomicity and implicit whitespace.** `@`, `$`, `!` plus `WHITESPACE` and
   `COMMENT` skipping, including the rule that atomic rules stop skipping. This
   is what makes pest grammars short; without it, ported grammars need `ws`
   everywhere. Needs a matching context (atomic flag, skip flag) and two new
   validator rules.
5. **Node tags** `#tag = expr` plus tag queries on the tree.

### Milestone 3 — power and speed

6. **Stack operations** `PUSH`/`PUSH_LITERAL`/`POP`/`POP_ALL`/`PEEK`/`PEEK_ALL`/
   `DROP`, with rollback when an alternative fails. Threading an immutable stack
   through the matcher fits the language, but it is the largest change here.
7. **Performance**: compile literals to character lists (no `split` per match),
   a line index for positions, and memoization. Then benchmark against
   `grammars/json.pest` on a large document.
8. **Ecosystem**: port `json.pest` unchanged as a test of parity, add
   `Pairs::to_json`-style output, and write grammy's own `.grammar` parser as a
   `.grammar` (self-hosting).

## 8. Decisions

1. **Syntax: pest is the base, with two documented extensions.** Any `.pest`
   body parses: `"text"`, `^"text"`, `'a'..'z'`, `ANY`, `~`, `|`, `* + ?`,
   `{n,m}`, `& !`, `( )`, `_ @ $ !` modifiers and `//`/`/* */` comments. The
   extensions are `[a-z]`/`[^...]` classes and `.` for `ANY`; pest has no `[` in
   a body, so they never conflict. `#` comments go away (they would collide
   with node tags `#tag = expr`). `~` becomes required. These are the item 3
   syntax fill-ins, still open.
2. **Builtin names: pest names, old ones as aliases (done).** `EOI` and `EOF`,
   `ASCII_ALPHANUMERIC` and `ASCII_ALNUM`, `ASCII_HEX_DIGIT` and `ASCII_HEX`
   all work; the grammar validator reserves every one of them.
3. **Order: errors and validation first (done), then the syntax fill-ins, then
   atomicity with implicit whitespace.**
4. **Indentation is ours, and it lives in the engine.** `>` rules capture the
   line's indentation as the block base; `INDENT`/`SAME` consume and compare.
   No input rewriting, so spans and error columns stay exact. pest has no
   equivalent, so this stays an extension outside the pest syntax surface.
