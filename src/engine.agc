## Matching a compiled grammar against text, building the parse tree.

import Grammar from "grammar"
import Tree from "tree"

## Parses `text` with the rule named `rule_name`; all of `text` must be used.
def run(grammar: Grammar.Grammar, rule_name: String, text: String) -> Result[Tree.Node]
  rule = try Grammar.rule(grammar, rule_name)
  chars = text.split("")
  case match(grammar, rule.body, chars, 0)
    none -> error(failure(text, rule_name, 0))
    some(found) ->
      return error(unconsumed(text, found.pos)) if found.pos < chars.size

      ok(Tree.Node(rule: rule_name, start: 0, stop: found.pos, children: found.nodes))
  end
end

private

DIGITS = Set.new("0123456789".split(""))

LETTERS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".split(""))

HEX_DIGITS = Set.new("0123456789abcdefABCDEF".split(""))

# What one expression matched: where it stopped and the nodes it built.
struct Progress
  pos: Int
  nodes: List[Tree.Node]
end

def match(grammar: Grammar.Grammar, expr: Grammar.Expr, chars: List[String], pos: Int) -> Optional[Progress]
  case expr
    Grammar.Expr.Literal(text) -> match_literal(text, chars, pos)
    Grammar.Expr.CharClass(negated, items) -> match_class(negated, items, chars, pos)
    Grammar.Expr.AnyChar -> match_any(chars, pos)
    Grammar.Expr.Builtin(name) -> match_builtin(name, chars, pos)
    Grammar.Expr.RuleRef(name) -> match_ref(grammar, name, chars, pos)
    Grammar.Expr.Seq(parts) -> match_seq(grammar, parts, chars, pos)
    Grammar.Expr.Choice(options) -> match_choice(grammar, options, chars, pos)
    Grammar.Expr.Repeat(inner, min, max) -> match_repeat(grammar, inner, min, max, chars, pos)
    Grammar.Expr.Lookahead(inner) -> match_lookahead(grammar, inner, chars, pos)
    Grammar.Expr.Negative(inner) -> match_negative(grammar, inner, chars, pos)
  end
end

# A named rule builds a node; a silent one (`_`) passes its children up.
def match_ref(grammar: Grammar.Grammar, name: String, chars: List[String], pos: Int) -> Optional[Progress]
  case Grammar.find(grammar, name)
    none -> none
    some(rule) ->
      if rule.silent
        match(grammar, rule.body, chars, pos)
      else
        match_rule(grammar, rule, chars, pos)
      end
  end
end

# Wraps the body in a node, even for a silent rule (the start rule asked for it).
def match_rule(grammar: Grammar.Grammar, rule: Grammar.Rule, chars: List[String], pos: Int) -> Optional[Progress]
  case match(grammar, rule.body, chars, pos)
    none -> none
    some(found) ->
      node = Tree.Node(rule: rule.name, start: pos, stop: found.pos, children: found.nodes)
      some(Progress(pos: found.pos, nodes: [node]))
  end
end

def match_seq(grammar: Grammar.Grammar, parts: List[Grammar.Expr], chars: List[String], pos: Int) -> Optional[Progress]
  nodes: List[Tree.Node] = []
  at = pos
  for part in parts
    case match(grammar, part, chars, at)
      none -> return none
      some(found) ->
        nodes = append(nodes, found.nodes)
        at = found.pos
    end
  end

  some(Progress(pos: at, nodes: nodes))
end

def match_choice(
  grammar: Grammar.Grammar,
  options: List[Grammar.Expr],
  chars: List[String],
  pos: Int,
) -> Optional[Progress]
  found: Optional[Progress] = none
  for option in options
    break if found.some?
    found = match(grammar, option, chars, pos)
  end

  found
end

# Stops on no progress, so a repetition of a nullable expression terminates.
def match_repeat(
  grammar: Grammar.Grammar,
  inner: Grammar.Expr,
  min: Int,
  max: Int,
  chars: List[String],
  pos: Int,
) -> Optional[Progress]
  nodes: List[Tree.Node] = []
  count = 0
  at = pos
  while max < 0 or count < max
    case match(grammar, inner, chars, at)
      none -> break
      some(found) ->
        stuck = found.pos == at
        nodes = append(nodes, found.nodes)
        at = found.pos
        count += 1
        break if stuck
    end
  end

  return none if count < min

  some(Progress(pos: at, nodes: nodes))
end

def match_lookahead(grammar: Grammar.Grammar, inner: Grammar.Expr, chars: List[String], pos: Int) -> Optional[Progress]
  case match(grammar, inner, chars, pos)
    none -> none
    some(_) -> some(Progress(pos: pos, nodes: []))
  end
end

def match_negative(grammar: Grammar.Grammar, inner: Grammar.Expr, chars: List[String], pos: Int) -> Optional[Progress]
  case match(grammar, inner, chars, pos)
    none -> some(Progress(pos: pos, nodes: []))
    some(_) -> none
  end
end

def match_literal(text: String, chars: List[String], pos: Int) -> Optional[Progress]
  parts = text.split("")
  return none if pos + parts.size > chars.size
  for i in 0...parts.size
    return none if chars[pos + i] != parts[i]
  end

  some(Progress(pos: pos + parts.size, nodes: []))
end

def match_any(chars: List[String], pos: Int) -> Optional[Progress]
  return none if pos >= chars.size

  some(Progress(pos: pos + 1, nodes: []))
end

def match_class(negated: Bool, items: List[Grammar.ClassItem], chars: List[String], pos: Int) -> Optional[Progress]
  return none if pos >= chars.size

  c = chars[pos]
  inside = items.any? { |item| item_holds?(item, c) }
  return none if inside == negated

  some(Progress(pos: pos + 1, nodes: []))
end

def item_holds?(item: Grammar.ClassItem, c: String) -> Bool
  case item
    Grammar.ClassItem.Single(ch) -> ch == c
    Grammar.ClassItem.Span(low, high) -> low.compare(c) <= 0 and c.compare(high) <= 0
  end
end

def match_builtin(name: String, chars: List[String], pos: Int) -> Optional[Progress]
  return some(Progress(pos: pos, nodes: [])) if name == "EOF" and pos >= chars.size
  return none if pos >= chars.size

  if builtin_holds?(name, chars[pos])
    some(Progress(pos: pos + 1, nodes: []))
  else
    none
  end
end

def builtin_holds?(name: String, c: String) -> Bool
  case name
    "ANY" -> true
    "NEWLINE" -> c == "\n" or c == "\r"
    "ASCII_DIGIT" -> DIGITS.include?(c)
    "ASCII_ALPHA" -> LETTERS.include?(c)
    "ASCII_ALNUM" -> DIGITS.include?(c) or LETTERS.include?(c)
    "ASCII_HEX" -> HEX_DIGITS.include?(c)
    _ -> false
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

def failure(text: String, rule_name: String, pos: Int) -> String
  where = Tree.position(text, pos)
  "grammar: expected #{rule_name} at line #{where.line}, column #{where.column}: #{where.line_text}"
end

def unconsumed(text: String, pos: Int) -> String
  where = Tree.position(text, pos)
  "grammar: unconsumed input at line #{where.line}, column #{where.column}: #{where.line_text}"
end
