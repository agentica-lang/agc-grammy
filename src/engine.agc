## Matching a compiled grammar against text, building the parse tree.
##
## Matching never raises: it returns what it found and, when it failed, the
## furthest trouble it saw, so the error names the deepest position and the
## rules expected there (as pest does).
##
## Indentation is handled here, not by rewriting the input: a rule marked `>`
## captures the indentation of the line it starts on as the block base, and the
## `INDENT`/`SAME` builtins consume a line's indentation and compare it with
## that base. Offsets stay exact, so spans and error columns are real.

import Grammar from "grammar"
import {Expr} from "grammar"
import Tree from "tree"

## Parses `text` with the rule named `rule_name`; all of `text` must be used.
def run(grammar: Grammar.Grammar, rule_name: String, text: String) -> Result[Tree.Node]
  rule = try Grammar.rule(grammar, rule_name)
  ctx = Ctx(grammar: grammar, chars: text.split(""), base: 0)
  outcome = match(ctx, rule.body, 0)
  case outcome.found
    none -> error(failure(text, rule_name, outcome.attempt))
    some(found) ->
      return error(unconsumed(text, found.pos)) if found.pos < ctx.chars.size

      ok(Tree.Node(rule: rule_name, start: 0, stop: found.pos, children: found.nodes))
  end
end

private

# The most labels a message shows.
LABEL_LIMIT = 6

# Everything matching needs: the grammar, the input characters and the
# indentation of the block being matched (0 at the top level).
struct Ctx
  grammar: Grammar.Grammar
  chars: List[String]
  base: Int
end

# What one expression matched: where it stopped and the nodes it built.
struct Progress
  pos: Int
  nodes: List[Tree.Node]
end

# One expectation, from the author's point of view: a rule name or a terminal.
# Terminal labels inside a silent rule are noise, so they are dropped there.
struct Label
  text: String
  terminal: Bool
end

# The furthest trouble seen: where, what was expected and what was not.
struct Attempt
  pos: Int
  expected: List[Label]
  unexpected: List[Label]
end

struct Outcome
  found: Optional[Progress]
  attempt: Optional[Attempt]
end

def match(ctx: Ctx, expr: Grammar.Expr, pos: Int) -> Outcome
  case expr
    Expr.Literal(text) -> match_literal(text, ctx.chars, pos)
    Expr.Insensitive(text) -> match_insensitive(text, ctx.chars, pos)
    Expr.CharClass(negated, items) -> match_class(negated, items, ctx.chars, pos)
    Expr.AnyChar -> match_any(ctx.chars, pos)
    Expr.Builtin(name) -> match_builtin(ctx, name, pos)
    Expr.RuleRef(name) -> match_ref(ctx, name, pos)
    Expr.Seq(parts) -> match_seq(ctx, parts, pos)
    Expr.Choice(options) -> match_choice(ctx, options, pos)
    Expr.Repeat(inner, min, max) -> match_repeat(ctx, inner, min, max, pos)
    Expr.Lookahead(inner) -> match_lookahead(ctx, inner, pos)
    Expr.Negative(inner) -> match_negative(ctx, inner, pos)
  end
end

# A named rule builds a node and reports its name when it fails; a silent one
# (`_`) passes its children up and keeps only rule names, not its own terminals.
def match_ref(ctx: Ctx, name: String, pos: Int) -> Outcome
  case Grammar.find(ctx.grammar, name)
    none -> miss(pos, [name])
    some(rule) ->
      if rule.silent
        outcome = match(inner_ctx(ctx, rule, pos), rule.body, pos)
        Outcome(found: outcome.found, attempt: without_terminals(outcome.attempt))
      else
        match_rule(ctx, rule, pos)
      end
  end
end

def match_rule(ctx: Ctx, rule: Grammar.Rule, pos: Int) -> Outcome
  outcome = match(inner_ctx(ctx, rule, pos), rule.body, pos)
  case outcome.found
    none ->
      named = Attempt(pos: pos, expected: [Label(text: rule.name, terminal: false)], unexpected: [])
      Outcome(found: none, attempt: merge(outcome.attempt, some(named)))
    some(found) ->
      node = Tree.Node(rule: rule.name, start: pos, stop: found.pos, children: found.nodes)
      matched(Progress(pos: found.pos, nodes: [node]))
  end
end

# A scope rule works against the indentation of the line it starts on.
def inner_ctx(ctx: Ctx, rule: Grammar.Rule, pos: Int) -> Ctx
  return ctx if !rule.indents

  ctx.with(base: line_indent(ctx.chars, pos))
end

def match_seq(ctx: Ctx, parts: List[Grammar.Expr], pos: Int) -> Outcome
  nodes: List[Tree.Node] = []
  attempt: Optional[Attempt] = none
  at = pos
  for part in parts
    outcome = match(ctx, part, at)
    attempt = merge(attempt, outcome.attempt)
    case outcome.found
      none -> return Outcome(found: none, attempt: attempt)
      some(found) ->
        nodes = append(nodes, found.nodes)
        at = found.pos
    end
  end

  Outcome(found: some(Progress(pos: at, nodes: nodes)), attempt: attempt)
end

def match_choice(ctx: Ctx, options: List[Grammar.Expr], pos: Int) -> Outcome
  attempt: Optional[Attempt] = none
  for option in options
    outcome = match(ctx, option, pos)
    attempt = merge(attempt, outcome.attempt)
    return Outcome(found: outcome.found, attempt: attempt) if outcome.found.some?
  end

  Outcome(found: none, attempt: attempt)
end

# Stops on no progress, so a repetition of a nullable expression terminates.
def match_repeat(ctx: Ctx, inner: Grammar.Expr, min: Int, max: Int, pos: Int) -> Outcome
  nodes: List[Tree.Node] = []
  attempt: Optional[Attempt] = none
  count = 0
  at = pos
  while max < 0 or count < max
    outcome = match(ctx, inner, at)
    attempt = merge(attempt, outcome.attempt)
    case outcome.found
      none -> break
      some(found) ->
        stuck = found.pos == at
        nodes = append(nodes, found.nodes)
        at = found.pos
        count += 1
        break if stuck
    end
  end

  if count < min
    wanted = Attempt(pos: at, expected: [Label(text: describe(inner), terminal: true)], unexpected: [])
    return Outcome(found: none, attempt: merge(attempt, some(wanted)))
  end

  Outcome(found: some(Progress(pos: at, nodes: nodes)), attempt: attempt)
end

def match_lookahead(ctx: Ctx, inner: Grammar.Expr, pos: Int) -> Outcome
  outcome = match(ctx, inner, pos)
  case outcome.found
    none -> Outcome(found: none, attempt: outcome.attempt)
    some(_) -> matched(Progress(pos: pos, nodes: []))
  end
end

def match_negative(ctx: Ctx, inner: Grammar.Expr, pos: Int) -> Outcome
  outcome = match(ctx, inner, pos)
  case outcome.found
    none -> matched(Progress(pos: pos, nodes: []))
    some(_) ->
      refused = Attempt(pos: pos, expected: [], unexpected: [Label(text: describe(inner), terminal: false)])
      Outcome(found: none, attempt: some(refused))
  end
end

# An insensitive literal compares case by case with an ASCII fold, as pest:
# U+212A KELVIN SIGN is not an ASCII `K`, so `^"k"` does not match it.
def match_insensitive(text: String, chars: List[String], pos: Int) -> Outcome
  parts = text.split("")
  for i in 0...parts.size
    at = pos + i
    return miss(at, ["^#{text.inspect}"]) if at >= chars.size or ascii_down(chars[at]) != ascii_down(parts[i])
  end

  matched(Progress(pos: pos + parts.size, nodes: []))
end

def ascii_down(c: String) -> String
  code = c.code
  return String.from_code(code + 32) if code >= 65 and code <= 90

  c
end

def match_literal(text: String, chars: List[String], pos: Int) -> Outcome
  parts = text.split("")
  for i in 0...parts.size
    at = pos + i
    return miss(at, [text.inspect]) if at >= chars.size or chars[at] != parts[i]
  end

  matched(Progress(pos: pos + parts.size, nodes: []))
end

def match_any(chars: List[String], pos: Int) -> Outcome
  return miss(pos, ["any character"]) if pos >= chars.size

  matched(Progress(pos: pos + 1, nodes: []))
end

def match_class(negated: Bool, items: List[Grammar.ClassItem], chars: List[String], pos: Int) -> Outcome
  label = class_text(negated, items)
  return miss(pos, [label]) if pos >= chars.size

  c = chars[pos]
  inside = items.any? { |item| item_holds?(item, c) }
  return miss(pos, [label]) if inside == negated

  matched(Progress(pos: pos + 1, nodes: []))
end

def item_holds?(item: Grammar.ClassItem, c: String) -> Bool
  case item
    Grammar.ClassItem.Single(ch) -> ch == c
    Grammar.ClassItem.Span(low, high) -> low.compare(c) <= 0 and c.compare(high) <= 0
  end
end

def match_builtin(ctx: Ctx, name: String, pos: Int) -> Outcome
  return matched(Progress(pos: pos, nodes: [])) if (name == "EOF" or name == "EOI") and pos >= ctx.chars.size
  return matched(Progress(pos: pos, nodes: [])) if name == "SOI" and pos == 0
  return match_indent(ctx, pos, true) if name == "INDENT"
  return match_indent(ctx, pos, false) if name == "SAME"
  return miss(pos, [builtin_label(name)]) if pos >= ctx.chars.size
  return match_newline(ctx.chars, pos) if name == "NEWLINE"

  if builtin_holds?(name, ctx.chars[pos])
    matched(Progress(pos: pos + 1, nodes: []))
  else
    miss(pos, [builtin_label(name)])
  end
end

# Consumes the indentation of the next non-blank line and compares it with the
# block base: `INDENT` wants deeper, `SAME` wants equal. Blank and
# whitespace-only lines are skipped, as Python does.
# The indentation label is not terminal: a silent `suite` must keep it.
def indent_miss(pos: Int, deeper: Bool) -> Outcome
  label = Label(text: indent_label(deeper), terminal: false)
  Outcome(found: none, attempt: some(Attempt(pos: pos, expected: [label], unexpected: [])))
end

def indent_label(deeper: Bool) -> String
  return "an indented line" if deeper

  "a line at this indentation"
end

def indent_holds?(deeper: Bool, level: Int, base: Int) -> Bool
  return level > base if deeper

  level == base
end

def match_indent(ctx: Ctx, pos: Int, deeper: Bool) -> Outcome
  return indent_miss(pos, deeper) if !at_line_start?(ctx.chars, pos)

  start = skip_blank_lines(ctx.chars, pos)
  after = skip_spaces(ctx.chars, start)
  level = after - start
  return indent_miss(start, deeper) if !indent_holds?(deeper, level, ctx.base)

  matched(Progress(pos: after, nodes: []))
end

# pest's NEWLINE is `\n`, `\r\n` or `\r`.
def match_newline(chars: List[String], pos: Int) -> Outcome
  return matched(Progress(pos: pos + 1, nodes: [])) if chars[pos] == "\n"
  return miss(pos, ["NEWLINE"]) if chars[pos] != "\r"
  return matched(Progress(pos: pos + 2, nodes: [])) if pos + 1 < chars.size and chars[pos + 1] == "\n"

  matched(Progress(pos: pos + 1, nodes: []))
end

# A single character, by its code point; the callers pass one character.
def builtin_holds?(name: String, c: String) -> Bool
  code = c.code
  case name
    "ANY" -> true
    "ASCII_DIGIT" -> between?(code, 48, 57)
    "ASCII_NONZERO_DIGIT" -> between?(code, 49, 57)
    "ASCII_BIN_DIGIT" -> code == 48 or code == 49
    "ASCII_OCT_DIGIT" -> between?(code, 48, 55)
    "ASCII_HEX" -> hex_code?(code)
    "ASCII_HEX_DIGIT" -> hex_code?(code)
    "ASCII_ALPHA" -> alpha_code?(code)
    "ASCII_ALPHA_LOWER" -> between?(code, 97, 122)
    "ASCII_ALPHA_UPPER" -> between?(code, 65, 90)
    "ASCII_ALNUM" -> alpha_code?(code) or between?(code, 48, 57)
    "ASCII_ALPHANUMERIC" -> alpha_code?(code) or between?(code, 48, 57)
    "ASCII" -> code <= 127
    _ -> false
  end
end

def hex_code?(code: Int) -> Bool = between?(code, 48, 57) or between?(code, 65, 70) or between?(code, 97, 102)

def alpha_code?(code: Int) -> Bool = between?(code, 65, 90) or between?(code, 97, 122)

def between?(code: Int, low: Int, high: Int) -> Bool = code >= low and code <= high

def at_line_start?(chars: List[String], pos: Int) -> Bool
  return true if pos == 0
  return true if chars[pos - 1] == "\n"

  chars[pos - 1] == "\r"
end

def skip_spaces(chars: List[String], pos: Int) -> Int
  at = pos
  while at < chars.size and (chars[at] == " " or chars[at] == "\t")
    at += 1
  end

  at
end

# Skips lines that hold only spaces and tabs, plus their newline.
def skip_blank_lines(chars: List[String], pos: Int) -> Int
  at = pos
  looping = true
  while looping
    after_spaces = skip_spaces(chars, at)
    if after_spaces >= chars.size
      looping = false
    elsif chars[after_spaces] == "\n"
      at = after_spaces + 1
    elsif chars[after_spaces] == "\r"
      at = after_spaces + 1
      if at < chars.size and chars[at] == "\n"
        at += 1
      end
    else
      looping = false
    end
  end

  at
end

# The indentation of the line that holds `pos`: its leading spaces and tabs.
def line_indent(chars: List[String], pos: Int) -> Int
  start = line_start(chars, pos)
  skip_spaces(chars, start) - start
end

def line_start(chars: List[String], pos: Int) -> Int
  at = pos.clamp(0, chars.size)
  while at > 0 and chars[at - 1] != "\n"
    at -= 1
  end

  at
end

def matched(progress: Progress) -> Outcome = Outcome(found: some(progress), attempt: none)

def miss(pos: Int, expected: List[String]) -> Outcome
  labels = expected.map { |text| Label(text: text, terminal: true) }
  Outcome(found: none, attempt: some(Attempt(pos: pos, expected: labels, unexpected: [])))
end

# Keeps the deeper attempt; at the same position it merges the labels.
def merge(left: Optional[Attempt], right: Optional[Attempt]) -> Optional[Attempt]
  case left
    none -> right
    some(a) -> merge_into(a, right)
  end
end

def merge_into(left: Attempt, right: Optional[Attempt]) -> Optional[Attempt]
  case right
    none -> some(left)
    some(b) -> deepest(left, b)
  end
end

def deepest(left: Attempt, right: Attempt) -> Optional[Attempt]
  return some(right) if right.pos > left.pos
  return some(left) if left.pos > right.pos

  some(
    Attempt(
      pos: left.pos,
      expected: limit(left.expected + right.expected),
      unexpected: limit(left.unexpected + right.unexpected),
    ),
  )
end

# Keeps a message short: at most LABEL_LIMIT labels, without repeats.
def limit(labels: List[Label]) -> List[Label]
  kept: List[Label] = []
  for label in labels
    break if kept.size >= LABEL_LIMIT
    if (!kept.any? { |seen| seen.text == label.text })
      kept = kept.push(label)
    end
  end

  kept
end

# A silent rule reports the rules it reached, not the characters it tried.
def without_terminals(attempt: Optional[Attempt]) -> Optional[Attempt]
  case attempt
    none -> none
    some(found) ->
      expected = found.expected.select { |label| !label.terminal }
      unexpected = found.unexpected.select { |label| !label.terminal }
      return none if expected.empty? and unexpected.empty?

      some(Attempt(pos: found.pos, expected: expected, unexpected: unexpected))
  end
end

def describe(expr: Grammar.Expr) -> String
  case expr
    Expr.Literal(text) -> text.inspect
    Expr.Insensitive(text) -> "^#{text.inspect}"
    Expr.CharClass(negated, items) -> class_text(negated, items)
    Expr.AnyChar -> "any character"
    Expr.Builtin(name) -> builtin_label(name)
    Expr.RuleRef(name) -> name
    Expr.Repeat(inner, _, _) -> describe(inner)
    Expr.Lookahead(inner) -> describe(inner)
    Expr.Negative(inner) -> describe(inner)
    Expr.Seq(_) -> "a sequence"
    Expr.Choice(_) -> "one of several alternatives"
  end
end

def class_text(negated: Bool, items: List[Grammar.ClassItem]) -> String
  body = items.map { |item| class_item_text(item) }.join("")
  if negated
    "[^#{body}]"
  else
    "[#{body}]"
  end
end

def class_item_text(item: Grammar.ClassItem) -> String
  case item
    Grammar.ClassItem.Single(ch) -> ch
    Grammar.ClassItem.Span(low, high) -> "#{low}-#{high}"
  end
end

def builtin_label(name: String) -> String
  if name == "EOF" or name == "EOI"
    "end of input"
  elsif name == "SOI"
    "start of input"
  elsif name == "INDENT"
    "an indented line"
  elsif name == "SAME"
    "a line at this indentation"
  else
    name
  end
end

# Adds each node, so a long repetition stays linear (`+` copies both lists).
def append(nodes: List[Tree.Node], extra: List[Tree.Node]) -> List[Tree.Node]
  result = nodes
  for node in extra
    result = result.push(node)
  end

  result
end

def failure(text: String, rule_name: String, attempt: Optional[Attempt]) -> String
  case attempt
    none -> at_point(text, 0, "expected #{rule_name}")
    some(found) -> at_point(text, found.pos, trouble(found, rule_name))
  end
end

def trouble(attempt: Attempt, rule_name: String) -> String
  head = expected_head(attempt, rule_name)
  return head if attempt.unexpected.empty?

  "#{head}; unexpected #{join_labels(attempt.unexpected)}"
end

def expected_head(attempt: Attempt, rule_name: String) -> String
  return "expected #{rule_name}" if attempt.expected.empty?

  "expected #{join_labels(attempt.expected)}"
end

def join_labels(labels: List[Label]) -> String
  unique = limit(labels)
  texts = unique.map { |label| label.text }
  return texts[0] if texts.size == 1

  "#{texts.take(texts.size - 1).join(", ")} or #{texts[texts.size - 1]}"
end

def at_point(text: String, pos: Int, message: String) -> String
  where = Tree.position(text, pos)
  "grammar: #{message} at line #{where.line}, column #{where.column}: #{where.line_text}"
end

def unconsumed(text: String, pos: Int) -> String
  where = Tree.position(text, pos)
  "grammar: unconsumed input at line #{where.line}, column #{where.column}: #{where.line_text}"
end
