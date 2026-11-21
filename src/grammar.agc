## Reading `.grammar` files (a pest-like PEG syntax) into rules.
##
## A rule is `name = { body }`, or `name = _{ body }` to build no node. In a
## body: `"text"`, `[a-z]`, `[^0-9]`, `.` (any char), a rule name, a builtin
## (`ANY`, `EOF`, `ASCII_DIGIT`, `ASCII_ALPHA`, `ASCII_ALNUM`, `ASCII_HEX`,
## `NEWLINE`), `~` sequence, `|` ordered choice, `*`, `+`, `?`, `!` and `&`
## lookahead, and `( )`. `#` starts a comment.

## The max of a `Repeat` that never stops, as in `*` and `+`.
UNBOUNDED = -1

## One rule: its name, whether it builds no node, and its body.
struct Rule
  name: String
  silent: Bool
  body: Expr
end

## A whole grammar: its rules, in file order.
struct Grammar
  rules: List[Rule]
end

## One character or one `a-z` span of a character class.
enum ClassItem
  Single(String)
  Span(String, String)
end

## The body of a rule, as written.
enum Expr
  Literal(String)
  CharClass(Bool, List[ClassItem])
  AnyChar
  Builtin(String)
  RuleRef(String)
  Seq(List[Expr])
  Choice(List[Expr])
  Repeat(Expr, Int, Int)
  Lookahead(Expr)
  Negative(Expr)
end

## Compiles `.grammar` text, or explains the first problem in it.
def compile(text: String) -> Result[Grammar]
  grammar = try scan(text)
  case first_problem(grammar)
    some(message) -> error(message)
    none -> ok(grammar)
  end
end

## Reads and compiles a `.grammar` file.
def load(path: String) -> Result[Grammar]
  text = try File.read_text(path)
  case compile(text)
    ok(grammar) -> ok(grammar)
    error(e) -> error("#{path}: #{e.message}")
  end
end

## The rule named `name`, or an error naming it.
def rule(grammar: Grammar, name: String) -> Result[Rule]
  case find(grammar, name)
    some(found) -> ok(found)
    none -> error("grammar: no rule named #{name}")
  end
end

## The rule named `name`, or none.
def find(grammar: Grammar, name: String) -> Optional[Rule]
  found: Optional[Rule] = none
  for candidate in grammar.rules
    break if found.some?
    if candidate.name == name
      found = some(candidate)
    end
  end

  found
end

private

BUILTIN_NAMES = Set.new(["ANY", "EOF", "ASCII_DIGIT", "ASCII_ALPHA", "ASCII_ALNUM", "ASCII_HEX", "NEWLINE"])

ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "\"": "\""}

struct ParsedExpr
  expr: Expr
  pos: Int
end

struct ParsedRule
  rule: Rule
  pos: Int
end

struct ParsedName
  name: String
  pos: Int
end

struct ParsedText
  text: String
  pos: Int
end

struct ParsedClass
  negated: Bool
  items: List[ClassItem]
  pos: Int
end

struct ParsedChar
  value: String
  pos: Int
end

# Reads every rule of the file, skipping blanks and comments.
def scan(text: String) -> Result[Grammar]
  chars = text.split("")
  rules: List[Rule] = []
  pos = 0
  while true
    pos = skip_blanks(chars, pos)
    break if pos >= chars.size
    parsed = try parse_rule(chars, pos)
    rules = rules.push(parsed.rule)
    pos = parsed.pos
  end

  ok(Grammar(rules: rules))
end

def parse_rule(chars: List[String], pos: Int) -> Result[ParsedRule]
  ident = try read_ident(chars, pos).to_result("grammar: expected a rule name at character #{pos}")
  after_name = try expect_char(chars, skip_blanks(chars, ident.pos), "=")
  at = skip_blanks(chars, after_name)
  silent = false
  if char_at(chars, at) == "_"
    silent = true
    at = skip_blanks(chars, at + 1)
  end

  body_start = try expect_char(chars, at, "{")
  body = try parse_expr(chars, body_start)
  after_body = try expect_char(chars, skip_blanks(chars, body.pos), "}")
  ok(ParsedRule(rule: Rule(name: ident.name, silent: silent, body: body.expr), pos: after_body))
end

def parse_expr(chars: List[String], pos: Int) -> Result[ParsedExpr]
  first = try parse_seq(chars, pos)
  parts: List[Expr] = [first.expr]
  at = first.pos
  while char_at(chars, skip_blanks(chars, at)) == "|"
    nxt = try parse_seq(chars, skip_blanks(chars, at) + 1)
    parts = parts.push(nxt.expr)
    at = nxt.pos
  end

  return ok(ParsedExpr(expr: parts[0], pos: at)) if parts.size == 1

  ok(ParsedExpr(expr: Expr.Choice(parts), pos: at))
end

def parse_seq(chars: List[String], pos: Int) -> Result[ParsedExpr]
  parts: List[Expr] = []
  at = skip_blanks(chars, pos)
  while true
    c = char_at(chars, at)
    break if c == "|" or c == ")" or c == "}" or c == ""
    part = try parse_postfix(chars, at)
    parts = parts.push(part.expr)
    at = skip_tilde(chars, part.pos)
  end

  return error("grammar: expected an expression at character #{pos}") if parts.size == 0
  return ok(ParsedExpr(expr: parts[0], pos: at)) if parts.size == 1

  ok(ParsedExpr(expr: Expr.Seq(parts), pos: at))
end

def parse_postfix(chars: List[String], pos: Int) -> Result[ParsedExpr]
  prefix = try parse_prefix(chars, pos)
  expr = prefix.expr
  at = skip_blanks(chars, prefix.pos)
  while true
    case char_at(chars, at)
      "*" ->
        expr = Expr.Repeat(expr, 0, UNBOUNDED)
        at = skip_blanks(chars, at + 1)
      "+" ->
        expr = Expr.Repeat(expr, 1, UNBOUNDED)
        at = skip_blanks(chars, at + 1)
      "?" ->
        expr = Expr.Repeat(expr, 0, 1)
        at = skip_blanks(chars, at + 1)
      _ -> break
    end
  end

  ok(ParsedExpr(expr: expr, pos: at))
end

def parse_prefix(chars: List[String], pos: Int) -> Result[ParsedExpr]
  at = skip_blanks(chars, pos)
  case char_at(chars, at)
    "!" ->
      inner = try parse_prefix(chars, at + 1)
      ok(ParsedExpr(expr: Expr.Negative(inner.expr), pos: inner.pos))
    "&" ->
      inner = try parse_prefix(chars, at + 1)
      ok(ParsedExpr(expr: Expr.Lookahead(inner.expr), pos: inner.pos))
    _ -> parse_primary(chars, at)
  end
end

def parse_primary(chars: List[String], pos: Int) -> Result[ParsedExpr]
  at = skip_blanks(chars, pos)
  case char_at(chars, at)
    "(" -> parse_group(chars, at)
    "\"" -> parse_literal(chars, at)
    "[" -> parse_class_expr(chars, at)
    "." -> ok(ParsedExpr(expr: Expr.AnyChar, pos: at + 1))
    _ -> parse_name(chars, at)
  end
end

def parse_group(chars: List[String], pos: Int) -> Result[ParsedExpr]
  inner = try parse_expr(chars, pos + 1)
  after = try expect_char(chars, skip_blanks(chars, inner.pos), ")")
  ok(ParsedExpr(expr: inner.expr, pos: after))
end

def parse_literal(chars: List[String], pos: Int) -> Result[ParsedExpr]
  text = try parse_string(chars, pos)
  ok(ParsedExpr(expr: Expr.Literal(text.text), pos: text.pos))
end

def parse_class_expr(chars: List[String], pos: Int) -> Result[ParsedExpr]
  klass = try parse_class(chars, pos)
  ok(ParsedExpr(expr: Expr.CharClass(klass.negated, klass.items), pos: klass.pos))
end

def parse_name(chars: List[String], pos: Int) -> Result[ParsedExpr]
  ident = try read_ident(chars, pos).to_result("grammar: expected an expression at character #{pos}")
  if BUILTIN_NAMES.include?(ident.name)
    ok(ParsedExpr(expr: Expr.Builtin(ident.name), pos: ident.pos))
  else
    ok(ParsedExpr(expr: Expr.RuleRef(ident.name), pos: ident.pos))
  end
end

def parse_string(chars: List[String], pos: Int) -> Result[ParsedText]
  at = pos + 1
  text = ""
  while char_at(chars, at) != "\"" and char_at(chars, at) != ""
    case read_escape(chars, at)
      some(esc) ->
        text = "#{text}#{esc.value}"
        at = esc.pos
      none ->
        text = "#{text}#{char_at(chars, at)}"
        at += 1
    end
  end

  return error("grammar: unterminated string at character #{pos}") if char_at(chars, at) == ""

  ok(ParsedText(text: text, pos: at + 1))
end

def parse_class(chars: List[String], pos: Int) -> Result[ParsedClass]
  at = pos + 1
  negated = false
  if char_at(chars, at) == "^"
    negated = true
    at += 1
  end

  items: List[ClassItem] = []
  while char_at(chars, at) != "]" and char_at(chars, at) != ""
    low = try read_class_char(chars, at)
    at = low.pos
    if char_at(chars, at) == "-" and char_at(chars, at + 1) != "]"
      high = try read_class_char(chars, at + 1)
      items = items.push(ClassItem.Span(low.value, high.value))
      at = high.pos
    else
      items = items.push(ClassItem.Single(low.value))
    end
  end

  return error("grammar: unterminated character class at character #{pos}") if char_at(chars, at) == ""

  ok(ParsedClass(negated: negated, items: items, pos: at + 1))
end

def read_class_char(chars: List[String], pos: Int) -> Result[ParsedChar]
  c = char_at(chars, pos)
  return error("grammar: unterminated character class at character #{pos}") if c == ""
  return ok(ParsedChar(value: c, pos: pos + 1)) if c != "\\"

  esc = try read_escape(chars, pos).to_result("grammar: dangling \\ at character #{pos}")
  ok(ParsedChar(value: esc.value, pos: esc.pos))
end

def read_escape(chars: List[String], pos: Int) -> Optional[ParsedChar]
  return none if char_at(chars, pos) != "\\"

  code = char_at(chars, pos + 1)
  return none if code == ""

  some(ParsedChar(value: Map.get(ESCAPES, code, code), pos: pos + 2))
end

def read_ident(chars: List[String], pos: Int) -> Optional[ParsedName]
  at = pos
  name = ""
  while at < chars.size and ident_char?(chars[at])
    name = "#{name}#{chars[at]}"
    at += 1
  end

  return none if name == ""

  some(ParsedName(name: name, pos: at))
end

def ident_char?(c: String) -> Bool = is_letter?(c) or (c.length == 1 and "0123456789_".include?(c))

def is_letter?(c: String) -> Bool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_".include?(c)

def skip_blanks(chars: List[String], pos: Int) -> Int
  at = pos
  while at < chars.size
    c = chars[at]
    if c == " " or c == "\t" or c == "\r" or c == "\n"
      at += 1
    elsif c == "#"
      at = skip_line(chars, at)
    else
      break
    end
  end

  at
end

def skip_line(chars: List[String], pos: Int) -> Int
  at = pos
  while at < chars.size and chars[at] != "\n"
    at += 1
  end

  at
end

def skip_tilde(chars: List[String], pos: Int) -> Int
  at = skip_blanks(chars, pos)
  return at if char_at(chars, at) != "~"

  skip_blanks(chars, at + 1)
end

def expect_char(chars: List[String], pos: Int, ch: String) -> Result[Int]
  found = char_at(chars, pos)
  return error("grammar: expected #{ch} at character #{pos}, found #{found.inspect}") if found != ch

  ok(pos + 1)
end

def char_at(chars: List[String], pos: Int) -> String
  return "" if pos < 0 or pos >= chars.size

  chars[pos]
end

# The first duplicate rule name or unknown reference, if any.
def first_problem(grammar: Grammar) -> Optional[String]
  known: Set[String] = Set.new([])
  found: Optional[String] = none
  for candidate in grammar.rules
    if known.include?(candidate.name)
      found = some("grammar: rule #{candidate.name} is declared twice")
    else
      known = known.add(candidate.name)
    end

    break if found.some?
  end

  case found
    some(message) -> some(message)
    none -> first_unknown_ref(grammar.rules, known)
  end
end

def first_unknown_ref(rules: List[Rule], known: Set[String]) -> Optional[String]
  found: Optional[String] = none
  for candidate in rules
    break if found.some?
    found = unknown_ref(candidate.name, candidate.body, known)
  end

  found
end

def unknown_ref(owner: String, expr: Expr, known: Set[String]) -> Optional[String]
  case expr
    Expr.RuleRef(name) -> ref_problem(owner, name, known)
    Expr.Seq(parts) -> parts_problem(owner, parts, known)
    Expr.Choice(parts) -> parts_problem(owner, parts, known)
    Expr.Repeat(inner, _, _) -> unknown_ref(owner, inner, known)
    Expr.Lookahead(inner) -> unknown_ref(owner, inner, known)
    Expr.Negative(inner) -> unknown_ref(owner, inner, known)
    _ -> none
  end
end

def parts_problem(owner: String, parts: List[Expr], known: Set[String]) -> Optional[String]
  found: Optional[String] = none
  for part in parts
    break if found.some?
    found = unknown_ref(owner, part, known)
  end

  found
end

def ref_problem(owner: String, name: String, known: Set[String]) -> Optional[String]
  return none if known.include?(name)

  some("grammar: rule #{owner} refers to unknown rule #{name}")
end
