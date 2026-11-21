## Reading `.grammar` files (a pest-like PEG syntax) into rules.
##
## A rule is `name = { body }`, with optional modifiers: `_` builds no node,
## `@` is atomic, `$` is compound-atomic, `!` is non-atomic, and `>` opens an
## indentation scope (they combine, as in `>_{`). In a body: `"text"`,
## `^"text"` (insensitive), `'a'..'z'`, `[a-z]`, `[^0-9]`, `.` (any char), a
## rule name, a builtin (`ANY`, `SOI`, `EOI`, `NEWLINE`, `INDENT`, `SAME`, the
## `ASCII_*` family), the stack (`PUSH(expr)`, `PUSH_LITERAL("text")`, `POP`,
## `POP_ALL`, `PEEK`, `PEEK_ALL`, `DROP`), `~` sequence, `|` ordered choice, `*`,
## `+`, `?`,
## `{n,m}`, `!` and `&` lookahead, and `( )`. Escapes: `\"`, `\\`, `\n`,
## `\r`, `\t`, `\0`, `\'`, `\xNN` and `\u{2-6 hex digits}`. `//` starts a
## comment and `/* */` nests.

## The max of a `Repeat` that never stops, as in `*` and `+`.
UNBOUNDED = -1

## How a rule treats the implicit whitespace around it (see `engine.agc`).
## `Plain` inherits the enclosing rule, so normal rules nest; `Atomic` (`@`)
## stops skipping and builds one token; `Compound` (`$`) stops skipping but
## keeps the inner nodes; `NonAtomic` (`!`) restores skipping and nodes.
enum Atomicity
  Plain
  Atomic
  Compound
  NonAtomic
end

## One rule: its name, whether it builds no node, its atomicity, whether it
## opens an indentation scope, and its body.
struct Rule
  name: String
  silent: Bool
  atomicity: Atomicity
  indents: Bool
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
  Insensitive(String)
  CharClass(Bool, List[ClassItem])
  AnyChar
  Builtin(String)
  RuleRef(String)
  Seq(List[Expr])
  Choice(List[Expr])
  Repeat(Expr, Int, Int)
  Lookahead(Expr)
  Negative(Expr)
  Tagged(String, Expr)
  Push(Expr)
  PushLiteral(String)
  Pop
  PopAll
  Peek
  PeekAll
  Drop
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

BUILTIN_NAMES = Set.new([
  "ANY",
  "SOI",
  "EOI",
  "EOF",
  "NEWLINE",
  "INDENT",
  "SAME",
  "ASCII_DIGIT",
  "ASCII_NONZERO_DIGIT",
  "ASCII_BIN_DIGIT",
  "ASCII_OCT_DIGIT",
  "ASCII_HEX",
  "ASCII_HEX_DIGIT",
  "ASCII_ALPHA",
  "ASCII_ALPHA_LOWER",
  "ASCII_ALPHA_UPPER",
  "ASCII_ALNUM",
  "ASCII_ALPHANUMERIC",
  "ASCII",
])

ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "\"": "\""}

# A bounded repetition of a zero-width expression may not ask for more nodes.
ZERO_WIDTH_LIMIT = 10_000

# Names a rule must not take: pest keywords and the builtin rules.
RESERVED = Set.new([
  "ANY",
  "SOI",
  "EOI",
  "EOF",
  "PUSH",
  "PUSH_LITERAL",
  "POP",
  "POP_ALL",
  "PEEK",
  "PEEK_ALL",
  "DROP",
  "NEWLINE",
  "INDENT",
  "SAME",
  "ASCII_DIGIT",
  "ASCII_NONZERO_DIGIT",
  "ASCII_BIN_DIGIT",
  "ASCII_OCT_DIGIT",
  "ASCII_HEX",
  "ASCII_HEX_DIGIT",
  "ASCII_ALPHA",
  "ASCII_ALPHA_LOWER",
  "ASCII_ALPHA_UPPER",
  "ASCII_ALNUM",
  "ASCII_ALPHANUMERIC",
  "ASCII",
])

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

struct ParsedFlags
  silent: Bool
  atomicity: Atomicity
  indents: Bool
  pos: Int
end

struct ParsedTag
  name: Optional[String]
  pos: Int
end

struct Scanned
  text: String
  pos: Int
end

struct ParsedBounds
  min: Int
  max: Int
  pos: Int
end

struct ParsedPrefixes
  ops: List[String]
  pos: Int
end

# Whether an expression pushes to the stack or reads from it.
enum StackUse
  Push
  Read
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
  flags = try read_modifiers(chars, at)
  body_start = try expect_char(chars, flags.pos, "{")
  body = try parse_expr(chars, body_start)
  after_body = try expect_char(chars, skip_blanks(chars, body.pos), "}")
  rule = Rule(
    name: ident.name,
    silent: flags.silent,
    atomicity: flags.atomicity,
    indents: flags.indents,
    body: body.expr,
  )

  ok(ParsedRule(rule: rule, pos: after_body))
end

# `_` builds no node, `>` opens an indentation scope (INDENT/SAME use it),
# `@ $ !` set the atomicity. Each may appear once.
def read_modifiers(chars: List[String], pos: Int) -> Result[ParsedFlags]
  silent = false
  indents = false
  atomicity = Atomicity.Plain
  at = pos
  while true
    case char_at(chars, at)
      "_" ->
        return error("grammar: two _ modifiers on one rule at character #{at}") if silent

        silent = true
        at = skip_blanks(chars, at + 1)
      ">" ->
        return error("grammar: two > modifiers on one rule at character #{at}") if indents

        indents = true
        at = skip_blanks(chars, at + 1)
      "@", "$", "!" ->
        if atomicity != Atomicity.Plain
          return error("grammar: two #{char_at(chars, at)} modifiers on one rule at character #{at}")
        end

        atomicity = modifier_atomicity(char_at(chars, at))
        at = skip_blanks(chars, at + 1)
      _ -> break
    end
  end

  ok(ParsedFlags(silent: silent, atomicity: atomicity, indents: indents, pos: at))
end

def modifier_atomicity(letter: String) -> Atomicity
  case letter
    "@" -> Atomicity.Atomic
    "$" -> Atomicity.Compound
    "!" -> Atomicity.NonAtomic
    _ -> Atomicity.Plain
  end
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
    break if seq_end?(chars, at)
    part = try parse_term(chars, at)
    parts = parts.push(part.expr)
    at = skip_blanks(chars, part.pos)
    break if seq_end?(chars, at)
    return error("grammar: expected ~ between terms at character #{at}") if char_at(chars, at) != "~"
    at = skip_blanks(chars, at + 1)
    return error("grammar: expected an expression after ~ at character #{at}") if seq_end?(chars, at)
  end

  return error("grammar: expected an expression at character #{pos}") if parts.size == 0
  return ok(ParsedExpr(expr: parts[0], pos: at)) if parts.size == 1

  ok(ParsedExpr(expr: Expr.Seq(parts), pos: at))
end

def seq_end?(chars: List[String], pos: Int) -> Bool
  c = char_at(chars, pos)
  c == "|" or c == ")" or c == "}" or c == ""
end

def parse_term(chars: List[String], pos: Int) -> Result[ParsedExpr]
  tag = try read_tag(chars, pos)
  prefixes = read_prefixes(chars, tag.pos)
  base = try parse_primary(chars, prefixes.pos)
  applied = try apply_postfix(chars, base)
  expr = wrap_prefixes(prefixes.ops, applied.expr)
  case tag.name
    none -> ok(ParsedExpr(expr: expr, pos: applied.pos))
    some(name) -> ok(ParsedExpr(expr: Expr.Tagged(name, expr), pos: applied.pos))
  end
end

# `#name = term` tags the node the term builds.
def read_tag(chars: List[String], pos: Int) -> Result[ParsedTag]
  at = skip_blanks(chars, pos)
  return ok(ParsedTag(name: none, pos: pos)) if char_at(chars, at) != "#"
  ident = try read_ident(chars, skip_blanks(chars, at + 1)).to_result(
    "grammar: expected a tag name after #, found #{char_at(chars, skip_blanks(chars, at + 1)).inspect} at character #{at}",
  )

  equals = try expect_char(chars, skip_blanks(chars, ident.pos), "=")
  ok(ParsedTag(name: some(ident.name), pos: skip_blanks(chars, equals)))
end

# Reads the `!` and `&` before a term, as pest does: they bind looser than `*`.
def read_prefixes(chars: List[String], pos: Int) -> ParsedPrefixes
  ops: List[String] = []
  at = skip_blanks(chars, pos)
  while char_at(chars, at) == "!" or char_at(chars, at) == "&"
    ops = ops.push(char_at(chars, at))
    at = skip_blanks(chars, at + 1)
  end

  ParsedPrefixes(ops: ops, pos: at)
end

# `!&e` is `!(&e)`: the last operator read wraps the innermost.
def wrap_prefixes(ops: List[String], expr: Expr) -> Expr
  result = expr
  for i in 0...ops.size
    if ops[ops.size - 1 - i] == "!"
      result = Expr.Negative(result)
    else
      result = Expr.Lookahead(result)
    end
  end

  result
end

def apply_postfix(chars: List[String], base: ParsedExpr) -> Result[ParsedExpr]
  expr = base.expr
  at = skip_blanks(chars, base.pos)
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
      "{" ->
        bounds = try read_bounds(chars, at)
        expr = Expr.Repeat(expr, bounds.min, bounds.max)
        at = skip_blanks(chars, bounds.pos)
      _ -> break
    end
  end

  ok(ParsedExpr(expr: expr, pos: at))
end

def parse_primary(chars: List[String], pos: Int) -> Result[ParsedExpr]
  at = skip_blanks(chars, pos)
  case char_at(chars, at)
    "(" -> parse_group(chars, at)
    "\"" -> parse_literal(chars, at)
    "^" -> parse_insensitive(chars, at)
    "'" -> parse_range(chars, at)
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

def parse_insensitive(chars: List[String], pos: Int) -> Result[ParsedExpr]
  at = skip_blanks(chars, pos + 1)
  return error("grammar: expected a string after ^ at character #{pos}") if char_at(chars, at) != "\""

  text = try parse_string(chars, at)
  ok(ParsedExpr(expr: Expr.Insensitive(text.text), pos: text.pos))
end

# A pest range, `'a'..'z'`, is one character span: the same thing as a class.
def parse_range(chars: List[String], pos: Int) -> Result[ParsedExpr]
  low = try parse_char_literal(chars, pos)
  after_low = skip_blanks(chars, low.pos)
  if !starts_with?(chars, after_low, "..")
    return error("grammar: expected .. after #{low.value.inspect} at character #{after_low}")
  end

  high = try parse_char_literal(chars, skip_blanks(chars, after_low + 2))
  if low.value.compare(high.value) > 0
    return error("grammar: the range #{low.value.inspect}..#{high.value.inspect} is descending at character #{pos}")
  end

  items = [ClassItem.Span(low.value, high.value)]
  ok(ParsedExpr(expr: Expr.CharClass(false, items), pos: high.pos))
end

def parse_char_literal(chars: List[String], pos: Int) -> Result[ParsedChar]
  return error("grammar: expected a character at character #{pos}") if char_at(chars, pos) != "'"
  return error("grammar: unterminated character at character #{pos}") if char_at(chars, pos + 1) == ""

  inner = try read_class_char(chars, pos + 1)
  return error("grammar: unterminated character at character #{pos}") if char_at(chars, inner.pos) != "'"

  ok(ParsedChar(value: inner.value, pos: inner.pos + 1))
end

def read_bounds(chars: List[String], pos: Int) -> Result[ParsedBounds]
  first = read_number(chars, skip_blanks(chars, pos + 1))
  at = skip_blanks(chars, first.pos)
  if char_at(chars, at) == "}"
    return error("grammar: a repetition bound needs a number at character #{pos}") if first.text.empty?

    exact = try bound_count(first.text, 0, pos)
    return ok(ParsedBounds(min: exact, max: exact, pos: at + 1))
  end

  return error("grammar: expected , or } in a repetition bound at character #{at}") if char_at(chars, at) != ","

  second = read_number(chars, skip_blanks(chars, at + 1))
  close = try expect_char(chars, skip_blanks(chars, second.pos), "}")
  if first.text.empty? and second.text.empty?
    return error("grammar: a repetition bound needs a number at character #{pos}")
  end

  low = try bound_count(first.text, 0, pos)
  high = try bound_count(second.text, UNBOUNDED, pos)
  return error("grammar: the repetition minimum #{low} is above the maximum #{high}") if high >= 0 and low > high

  ok(ParsedBounds(min: low, max: high, pos: close))
end

def read_number(chars: List[String], pos: Int) -> Scanned
  at = pos
  text = ""
  while at < chars.size and is_digit?(chars[at])
    text = "#{text}#{chars[at]}"
    at += 1
  end

  Scanned(text: text, pos: at)
end

def is_digit?(c: String) -> Bool = c.length == 1 and "0123456789".include?(c)

def bound_count(text: String, missing: Int, pos: Int) -> Result[Int]
  return ok(missing) if text.empty?

  case text.to_i
    ok(count) -> ok(count)
    error(_) -> error("grammar: the repetition bound #{text} is too large at character #{pos}")
  end
end

def parse_class_expr(chars: List[String], pos: Int) -> Result[ParsedExpr]
  klass = try parse_class(chars, pos)
  ok(ParsedExpr(expr: Expr.CharClass(klass.negated, klass.items), pos: klass.pos))
end

def parse_name(chars: List[String], pos: Int) -> Result[ParsedExpr]
  ident = try read_ident(chars, pos).to_result("grammar: expected an expression at character #{pos}")
  at = skip_blanks(chars, ident.pos)
  case ident.name
    "PUSH" -> parse_push(chars, at)
    "PUSH_LITERAL" -> parse_push_literal(chars, at)
    "POP" -> ok(ParsedExpr(expr: Expr.Pop, pos: ident.pos))
    "POP_ALL" -> ok(ParsedExpr(expr: Expr.PopAll, pos: ident.pos))
    "PEEK" -> ok(ParsedExpr(expr: Expr.Peek, pos: ident.pos))
    "PEEK_ALL" -> ok(ParsedExpr(expr: Expr.PeekAll, pos: ident.pos))
    "DROP" -> ok(ParsedExpr(expr: Expr.Drop, pos: ident.pos))
    _ ->
      if BUILTIN_NAMES.include?(ident.name)
        ok(ParsedExpr(expr: Expr.Builtin(ident.name), pos: ident.pos))
      else
        ok(ParsedExpr(expr: Expr.RuleRef(ident.name), pos: ident.pos))
      end
  end
end

# `PUSH(expr)` pushes the text the expression matched.
def parse_push(chars: List[String], pos: Int) -> Result[ParsedExpr]
  if char_at(chars, pos) != "("
    return error(
      "grammar: PUSH needs an expression in parentheses, found #{char_at(chars, pos).inspect} at character #{pos}",
    )
  end

  inner = try parse_expr(chars, pos + 1)
  after = try expect_char(chars, skip_blanks(chars, inner.pos), ")")
  ok(ParsedExpr(expr: Expr.Push(inner.expr), pos: after))
end

# `PUSH_LITERAL("text")` pushes a fixed string.
def parse_push_literal(chars: List[String], pos: Int) -> Result[ParsedExpr]
  if char_at(chars, pos) != "("
    return error(
      "grammar: PUSH_LITERAL needs a string in parentheses, found #{char_at(chars, pos).inspect} at character #{pos}",
    )
  end

  at = skip_blanks(chars, pos + 1)
  if char_at(chars, at) != "\""
    return error(
      "grammar: PUSH_LITERAL needs a string in parentheses, found #{char_at(chars, at).inspect} at character #{at}",
    )
  end

  literal = try parse_literal(chars, at)
  after = try expect_char(chars, skip_blanks(chars, literal.pos), ")")
  case literal.expr
    Expr.Literal(text) -> ok(ParsedExpr(expr: Expr.PushLiteral(text), pos: after))
    _ -> error("grammar: PUSH_LITERAL needs a string in parentheses at character #{pos}")
  end
end

def parse_string(chars: List[String], pos: Int) -> Result[ParsedText]
  at = pos + 1
  text = ""
  while char_at(chars, at) != "\"" and char_at(chars, at) != ""
    escaped = try read_escape(chars, at)
    case escaped
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

  escaped = try read_escape(chars, pos)
  case escaped
    some(esc) -> ok(ParsedChar(value: esc.value, pos: esc.pos))
    none -> error("grammar: dangling \\ at character #{pos}")
  end
end

# Reads an escape at `pos`; `ok(none)` means "not an escape, copy the character".
def read_escape(chars: List[String], pos: Int) -> Result[Optional[ParsedChar]]
  return ok(none) if char_at(chars, pos) != "\\"

  code = char_at(chars, pos + 1)
  return error("grammar: dangling \\ at character #{pos}") if code == ""
  return ok(some(ParsedChar(value: String.from_code(0), pos: pos + 2))) if code == "0"
  if code == "p" or code == "P"
    return error("grammar: unicode properties (\\p{...}) are not supported at character #{pos}")
  end

  return read_code_escape(chars, pos) if code == "x" or code == "u"

  # Known deviation: pest refuses an unknown escape, we keep the character
  # (`\d` is `d`). Tracked in parity.md; the escapable set is closed here.
  ok(some(ParsedChar(value: Map.get(ESCAPES, code, code), pos: pos + 2)))
end

def read_code_escape(chars: List[String], pos: Int) -> Result[Optional[ParsedChar]]
  return read_hex_escape(chars, pos) if char_at(chars, pos + 1) == "x"

  read_brace_escape(chars, pos)
end

def read_hex_escape(chars: List[String], pos: Int) -> Result[Optional[ParsedChar]]
  high = hex_value(char_at(chars, pos + 2))
  low = hex_value(char_at(chars, pos + 3))
  if high.none? or low.none?
    found = "#{char_at(chars, pos + 2)}#{char_at(chars, pos + 3)}"
    return error("grammar: \\x needs two hex digits at character #{pos}, found #{found.inspect}")
  end

  # Both sides are hex digits, so the conversions cannot fail.
  code = high.unwrap! * 16 + low.unwrap!
  ok(some(ParsedChar(value: String.from_code(code), pos: pos + 4)))
end

def read_brace_escape(chars: List[String], pos: Int) -> Result[Optional[ParsedChar]]
  if char_at(chars, pos + 2) != "{"
    return error("grammar: \\u needs two to six hex digits in braces at character #{pos}")
  end

  digits = read_hex_run(chars, pos + 3, 6)
  return error("grammar: \\u needs two to six hex digits in braces at character #{pos}") if digits.text.size < 2

  if char_at(chars, digits.pos) != "}"
    return error("grammar: expected } after a \\u escape at character #{digits.pos}")
  end

  # Every character is a hex digit, so the conversion cannot fail.
  code = hex_number(digits.text)
  if code > 1114111 or (code >= 55296 and code <= 57343)
    return error("grammar: unicode escape #{digits.text} is not a character code at character #{pos}")
  end

  ok(some(ParsedChar(value: String.from_code(code), pos: digits.pos + 1)))
end

def read_hex_run(chars: List[String], pos: Int, max: Int) -> Scanned
  at = pos
  text = ""
  while at < chars.size and text.size < max and hex_value(chars[at]).some?
    text = "#{text}#{chars[at]}"
    at += 1
  end

  Scanned(text: text, pos: at)
end

def hex_value(c: String) -> Optional[Int]
  return none if c.length != 1

  code = c.code
  return some(code - 48) if code >= 48 and code <= 57
  return some(code - 87) if code >= 97 and code <= 102
  return some(code - 55) if code >= 65 and code <= 70

  none
end

def hex_number(text: String) -> Int = text.split("").reduce(0) do |total, ch| total * 16 + hex_value(ch).unwrap! end

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
  looping = true
  while looping
    after = skip_one(chars, at)
    if after == at
      looping = false
    else
      at = after
    end
  end

  at
end

# Skips one blank, a `//` comment or a `/* */` comment; returns `pos` otherwise.
def skip_one(chars: List[String], pos: Int) -> Int
  return pos if pos >= chars.size

  c = chars[pos]
  return pos + 1 if c == " " or c == "\t" or c == "\r" or c == "\n"
  return skip_line(chars, pos) if starts_with?(chars, pos, "//")
  return skip_block(chars, pos) if starts_with?(chars, pos, "/*")

  pos
end

def skip_line(chars: List[String], pos: Int) -> Int
  at = pos
  while at < chars.size and chars[at] != "\n"
    at += 1
  end

  at
end

# Block comments nest, as in pest. An unterminated one stops at its own start,
# so the parser reports the stray `/` instead of swallowing the file.
def skip_block(chars: List[String], pos: Int) -> Int
  at = pos + 2
  level = 1
  while at < chars.size and level > 0
    if starts_with?(chars, at, "/*")
      level += 1
      at += 2
    elsif starts_with?(chars, at, "*/")
      level -= 1
      at += 2
    else
      at += 1
    end
  end

  return pos if level > 0

  at
end

def starts_with?(chars: List[String], pos: Int, text: String) -> Bool
  parts = text.split("")
  return false if pos + parts.size > chars.size
  for i in 0...parts.size
    return false if chars[pos + i] != parts[i]
  end

  true
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

# The first problem in the grammar, if any.
def first_problem(grammar: Grammar) -> Optional[String]
  rules = grammar.rules
  cheap = first_of([
    reserved_problem(rules),
    duplicate_problem(rules),
    unknown_ref_problem(rules),
    tag_problem(rules),
    stack_problem(rules),
  ])

  return cheap if cheap.some?

  always = always_rules(rules)
  still = still_rules(rules)
  first_of([
    whitespace_problem(rules, always, still),
    recursion_problem(rules),
    repetition_problem(rules, always, still),
    choice_problem(rules, always),
  ])
end

def first_of(problems: List[Optional[String]]) -> Optional[String]
  found: Optional[String] = none
  for problem in problems
    break if found.some?
    if problem.some?
      found = problem
    end
  end

  found
end

def reserved_problem(rules: List[Rule]) -> Optional[String]
  for candidate in rules
    return some("grammar: #{candidate.name} is a reserved rule name") if RESERVED.include?(candidate.name)
  end

  none
end

def duplicate_problem(rules: List[Rule]) -> Optional[String]
  known: Set[String] = Set.new([])
  for candidate in rules
    return some("grammar: rule #{candidate.name} is declared twice") if known.include?(candidate.name)
    known = known.add(candidate.name)
  end

  none
end

# `WHITESPACE` and `COMMENT` are repeated while they match, so a body that cannot
# fail (it matches the empty string) or that never consumes input makes skipping
# meaningless. pest refuses both, and so do we.
def whitespace_problem(rules: List[Rule], always: Set[String], still: Set[String]) -> Optional[String]
  pushes = stack_use_rules(rules, StackUse.Push)
  reads = stack_use_rules(rules, StackUse.Read)
  for candidate in rules
    next if candidate.name != "WHITESPACE" and candidate.name != "COMMENT"
    # A helper rule reached from here may use the stack too, so this reads the
    # fixpoint sets rather than the body alone.
    if pushes.include?(candidate.name) or reads.include?(candidate.name)
      return some("grammar: #{candidate.name} is skipped, so it cannot use the stack")
    end

    if always_with?(candidate.body, always)
      return some("grammar: #{candidate.name} is skipped, so it must be able to fail")
    end

    if still_with?(candidate.body, still)
      return some("grammar: #{candidate.name} is skipped, so it must consume input")
    end
  end

  none
end

def unknown_ref_problem(rules: List[Rule]) -> Optional[String]
  known = name_set(rules)
  for candidate in rules
    problem = unknown_ref(candidate.name, candidate.body, known)
    return problem if problem.some?
  end

  none
end

def name_set(rules: List[Rule]) -> Set[String]
  names: Set[String] = Set.new([])
  for candidate in rules
    names = names.add(candidate.name)
  end

  names
end

def unknown_ref(owner: String, expr: Expr, known: Set[String]) -> Optional[String]
  case expr
    Expr.RuleRef(name) -> ref_problem(owner, name, known)
    Expr.Seq(parts) -> nested_unknown(owner, parts, known)
    Expr.Choice(parts) -> nested_unknown(owner, parts, known)
    Expr.Repeat(inner, _, _) -> unknown_ref(owner, inner, known)
    Expr.Lookahead(inner) -> unknown_ref(owner, inner, known)
    Expr.Negative(inner) -> unknown_ref(owner, inner, known)
    Expr.Tagged(_, inner) -> unknown_ref(owner, inner, known)
    Expr.Push(inner) -> unknown_ref(owner, inner, known)
    _ -> none
  end
end

def nested_unknown(owner: String, parts: List[Expr], known: Set[String]) -> Optional[String]
  found: Optional[String] = none
  for part in parts
    break if found.some?
    found = unknown_ref(owner, part, known)
  end

  found
end

# A stack operation with nothing pushed would only ever fail. pest walks the call
# graph per rule; we keep the cheap whole-grammar version and let the parse fail
# on an empty stack at run time.
def stack_problem(rules: List[Rule]) -> Optional[String]
  return none if !stack_use_rules(rules, StackUse.Push).empty?

  reading = stack_use_rules(rules, StackUse.Read)
  for candidate in rules
    if reading.include?(candidate.name)
      return some("grammar: rule #{candidate.name} reads the stack but nothing pushes to it")
    end
  end

  none
end

# The rules that use the stack one way or the other, following rule references
# (a fixpoint, as `always_rules`/`still_rules` are).
def stack_use_rules(rules: List[Rule], use: StackUse) -> Set[String]
  known: Set[String] = Set.new([])
  changed = true
  while changed
    changed = false
    for candidate in rules
      if !known.include?(candidate.name) and uses_stack?(candidate.body, use, known)
        known = known.add(candidate.name)
        changed = true
      end
    end
  end

  known
end

def uses_stack?(expr: Expr, use: StackUse, names: Set[String]) -> Bool
  case expr
    Expr.Push(inner) ->
      return true if use == StackUse.Push

      uses_stack?(inner, use, names)
    Expr.PushLiteral(_) -> use == StackUse.Push
    Expr.Pop -> use == StackUse.Read
    Expr.PopAll -> use == StackUse.Read
    Expr.Peek -> use == StackUse.Read
    Expr.PeekAll -> use == StackUse.Read
    Expr.Drop -> use == StackUse.Read
    Expr.RuleRef(name) -> names.include?(name)
    Expr.Seq(parts) -> parts.any? { |part| uses_stack?(part, use, names) }
    Expr.Choice(options) -> options.any? { |option| uses_stack?(option, use, names) }
    Expr.Repeat(inner, _, _) -> uses_stack?(inner, use, names)
    Expr.Lookahead(inner) -> uses_stack?(inner, use, names)
    Expr.Negative(inner) -> uses_stack?(inner, use, names)
    Expr.Tagged(_, inner) -> uses_stack?(inner, use, names)
    _ -> false
  end
end

# A tag lands on the last node its term builds, so the term must build one.
def tag_problem(rules: List[Rule]) -> Optional[String]
  for candidate in rules
    problem = tag_in(candidate.name, candidate.body, rules)
    return problem if problem.some?
  end

  none
end

def tag_in(owner: String, expr: Expr, rules: List[Rule]) -> Optional[String]
  case expr
    Expr.Tagged(name, inner) ->
      if !builds_node?(inner, rules, Set.new([]))
        return some("grammar: the tag ##{name} in rule #{owner} has no node to tag")
      end

      tag_in(owner, inner, rules)
    Expr.Seq(parts) -> nested_tag(owner, parts, rules)
    Expr.Choice(options) -> nested_tag(owner, options, rules)
    Expr.Repeat(inner, _, _) -> tag_in(owner, inner, rules)
    Expr.Lookahead(inner) -> tag_in(owner, inner, rules)
    Expr.Negative(inner) -> tag_in(owner, inner, rules)
    Expr.Push(inner) -> tag_in(owner, inner, rules)
    _ -> none
  end
end

def nested_tag(owner: String, parts: List[Expr], rules: List[Rule]) -> Optional[String]
  found: Optional[String] = none
  for part in parts
    break if found.some?
    found = tag_in(owner, part, rules)
  end

  found
end

# Whether the expression can build a node at all. A silent rule builds none of
# its own, but passes its children up, so it is followed into its body; `seen`
# stops a silent rule that reaches itself.
def builds_node?(expr: Expr, rules: List[Rule], seen: Set[String]) -> Bool
  case expr
    Expr.RuleRef(name) -> ref_builds_node?(name, rules, seen)
    Expr.Seq(parts) -> parts.any? { |part| builds_node?(part, rules, seen) }
    Expr.Choice(options) -> options.any? { |option| builds_node?(option, rules, seen) }
    Expr.Repeat(inner, _, _) -> builds_node?(inner, rules, seen)
    Expr.Tagged(_, inner) -> builds_node?(inner, rules, seen)
    Expr.Push(inner) -> builds_node?(inner, rules, seen)
    _ -> false
  end
end

def ref_builds_node?(name: String, rules: List[Rule], seen: Set[String]) -> Bool
  return false if seen.include?(name)
  case body_of(rules, name)
    none -> false
    some(candidate) -> !candidate.silent or builds_node?(candidate.body, rules, seen.add(name))
  end
end

def body_of(rules: List[Rule], name: String) -> Optional[Rule]
  found: Optional[Rule] = none
  for candidate in rules
    if candidate.name == name
      found = some(candidate)
      break
    end
  end

  found
end

def ref_problem(owner: String, name: String, known: Set[String]) -> Optional[String]
  return none if known.include?(name)

  some("grammar: rule #{owner} refers to unknown rule #{name}")
end

# Reports a rule that reaches itself without consuming input.
def recursion_problem(rules: List[Rule]) -> Optional[String]
  nullable = nullable_rules(rules)
  edges: Map[String, Set[String]] = {}
  for candidate in rules
    edges = edges.put(candidate.name, left_refs(candidate.body, nullable))
  end

  for candidate in rules
    if left_reachable(candidate.name, edges).include?(candidate.name)
      return some("grammar: rule #{candidate.name} is left recursive")
    end
  end

  none
end

# The rules a body can call before it consumes any input.
def left_refs(expr: Expr, nullable: Set[String]) -> Set[String]
  case expr
    Expr.RuleRef(name) -> Set.new([name])
    Expr.Seq(parts) -> seq_left_refs(parts, nullable)
    Expr.Choice(options) -> union_all(options.map { |option| left_refs(option, nullable) })
    Expr.Repeat(inner, _, _) -> left_refs(inner, nullable)
    Expr.Lookahead(inner) -> left_refs(inner, nullable)
    Expr.Negative(inner) -> left_refs(inner, nullable)
    Expr.Tagged(_, inner) -> left_refs(inner, nullable)
    Expr.Push(inner) -> left_refs(inner, nullable)
    _ -> Set.new([])
  end
end

def seq_left_refs(parts: List[Expr], nullable: Set[String]) -> Set[String]
  refs: Set[String] = Set.new([])
  for part in parts
    refs = refs.union(left_refs(part, nullable))
    break if !nullable_with?(part, nullable)
  end

  refs
end

def union_all(sets: List[Set[String]]) -> Set[String]
  total: Set[String] = Set.new([])
  for items in sets
    total = total.union(items)
  end

  total
end

# Every rule reachable from `start` without consuming input.
def left_reachable(start: String, edges: Map[String, Set[String]]) -> Set[String]
  pending: List[String] = [start]
  seen: Set[String] = Set.new([])
  while !pending.empty?
    name = pending.last
    pending = pending.take(pending.size - 1)
    for ref in Map.get(edges, name, Set.new([])).to_a
      if !seen.include?(ref)
        seen = seen.add(ref)
        pending = pending.push(ref)
      end
    end
  end

  seen
end

# Reports a repetition of an expression that cannot end.
def repetition_problem(rules: List[Rule], always: Set[String], still: Set[String]) -> Optional[String]
  for candidate in rules
    problem = repeat_in(candidate.name, candidate.body, always, still)
    return problem if problem.some?
  end

  none
end

def repeat_in(owner: String, expr: Expr, always: Set[String], still: Set[String]) -> Optional[String]
  case expr
    Expr.Repeat(inner, _, max) -> repeat_problem(owner, inner, max, always, still)
    Expr.Seq(parts) -> nested_repeat(owner, parts, always, still)
    Expr.Choice(options) -> nested_repeat(owner, options, always, still)
    Expr.Lookahead(inner) -> repeat_in(owner, inner, always, still)
    Expr.Negative(inner) -> repeat_in(owner, inner, always, still)
    Expr.Tagged(_, inner) -> repeat_in(owner, inner, always, still)
    Expr.Push(inner) -> repeat_in(owner, inner, always, still)
    _ -> none
  end
end

# Only an unbounded repetition can run forever; a bounded one terminates. A
# zero-width expression may repeat a few times, but a huge bound is refused
# instead of building that many identical nodes.
def repeat_problem(owner: String, inner: Expr, max: Int, always: Set[String], still: Set[String]) -> Optional[String]
  if max < 0
    return some("grammar: rule #{owner} repeats an expression that cannot fail") if always_with?(inner, always)
    # A `DROP` loop consumes no input but shrinks the stack, so it always ends.
    if still_with?(inner, still) and !drains_stack?(inner)
      return some("grammar: rule #{owner} repeats an expression that never consumes input")
    end
  elsif still_with?(inner, still) and max > ZERO_WIDTH_LIMIT
    return some("grammar: rule #{owner} repeats a zero-width expression more than #{ZERO_WIDTH_LIMIT} times")
  end

  repeat_in(owner, inner, always, still)
end

# Whether the expression only pops the stack, so an endless repetition of it
# still ends: `DROP*`, `(DROP ~ DROP)*`.
def drains_stack?(expr: Expr) -> Bool
  case expr
    Expr.Drop -> true
    Expr.Seq(parts) -> parts.all? { |part| drains_stack?(part) }
    Expr.Choice(options) -> options.all? { |option| drains_stack?(option) }
    Expr.Repeat(inner, _, _) -> drains_stack?(inner)
    Expr.Tagged(_, inner) -> drains_stack?(inner)
    _ -> false
  end
end

def nested_repeat(owner: String, parts: List[Expr], always: Set[String], still: Set[String]) -> Optional[String]
  found: Optional[String] = none
  for part in parts
    break if found.some?
    found = repeat_in(owner, part, always, still)
  end

  found
end

# Reports a choice arm that cannot fail, which hides the arms after it.
def choice_problem(rules: List[Rule], always: Set[String]) -> Optional[String]
  for candidate in rules
    problem = choice_in(candidate.name, candidate.body, always)
    return problem if problem.some?
  end

  none
end

def choice_in(owner: String, expr: Expr, always: Set[String]) -> Optional[String]
  case expr
    Expr.Choice(options) -> arms_problem(owner, options, always)
    Expr.Seq(parts) -> nested_choice(owner, parts, always)
    Expr.Repeat(inner, _, _) -> choice_in(owner, inner, always)
    Expr.Lookahead(inner) -> choice_in(owner, inner, always)
    Expr.Negative(inner) -> choice_in(owner, inner, always)
    Expr.Tagged(_, inner) -> choice_in(owner, inner, always)
    Expr.Push(inner) -> choice_in(owner, inner, always)
    _ -> none
  end
end

def nested_choice(owner: String, parts: List[Expr], always: Set[String]) -> Optional[String]
  found: Optional[String] = none
  for part in parts
    break if found.some?
    found = choice_in(owner, part, always)
  end

  found
end

def arms_problem(owner: String, options: List[Expr], always: Set[String]) -> Optional[String]
  problem = some("grammar: rule #{owner} has a choice arm that cannot fail; the arms after it are unreachable")
  for option in options.take(options.size - 1)
    return problem if always_with?(option, always)
  end

  none
end

# Rules that can match without consuming input (computed to a fixpoint).
def nullable_rules(rules: List[Rule]) -> Set[String]
  known: Set[String] = Set.new([])
  changed = true
  while changed
    changed = false
    for candidate in rules
      if !known.include?(candidate.name) and nullable_with?(candidate.body, known)
        known = known.add(candidate.name)
        changed = true
      end
    end
  end

  known
end

def nullable_with?(expr: Expr, names: Set[String]) -> Bool
  case expr
    Expr.Literal(text) -> text.empty?
    Expr.Insensitive(text) -> text.empty?
    Expr.CharClass(_, _) -> false
    Expr.AnyChar -> false
    Expr.Builtin(name) -> name == "EOF" or name == "EOI" or name == "SOI"
    Expr.RuleRef(name) -> names.include?(name)
    Expr.Seq(parts) -> parts.all? { |part| nullable_with?(part, names) }
    Expr.Choice(options) -> options.any? { |option| nullable_with?(option, names) }
    Expr.Repeat(inner, min, _) -> min == 0 or nullable_with?(inner, names)
    Expr.Lookahead(inner) -> nullable_with?(inner, names)
    Expr.Negative(_) -> true
    Expr.Tagged(_, inner) -> nullable_with?(inner, names)
    Expr.Push(inner) -> nullable_with?(inner, names)
    Expr.PushLiteral(_) -> true
    Expr.Drop -> true
    # A stack read can match without consuming input (`POP_ALL`/`PEEK_ALL` do on
    # an empty stack, where a parse starts), so left recursion behind one is
    # caught rather than hanging.
    Expr.Pop -> true
    Expr.PopAll -> true
    Expr.Peek -> true
    Expr.PeekAll -> true
  end
end

# Rules that cannot fail (computed to a fixpoint).
def always_rules(rules: List[Rule]) -> Set[String]
  known: Set[String] = Set.new([])
  changed = true
  while changed
    changed = false
    for candidate in rules
      if !known.include?(candidate.name) and always_with?(candidate.body, known)
        known = known.add(candidate.name)
        changed = true
      end
    end
  end

  known
end

def always_with?(expr: Expr, names: Set[String]) -> Bool
  case expr
    Expr.Literal(text) -> text.empty?
    Expr.Insensitive(text) -> text.empty?
    Expr.CharClass(_, _) -> false
    Expr.AnyChar -> false
    Expr.Builtin(_) -> false
    Expr.RuleRef(name) -> names.include?(name)
    Expr.Seq(parts) -> parts.all? { |part| always_with?(part, names) }
    Expr.Choice(options) -> options.any? { |option| always_with?(option, names) }
    Expr.Repeat(inner, min, _) -> min == 0 or always_with?(inner, names)
    Expr.Lookahead(inner) -> always_with?(inner, names)
    Expr.Negative(_) -> false
    Expr.Tagged(_, inner) -> always_with?(inner, names)
    Expr.Push(inner) -> always_with?(inner, names)
    Expr.PushLiteral(_) -> true
    Expr.Pop -> false
    Expr.PopAll -> false
    Expr.Peek -> false
    Expr.PeekAll -> false
    Expr.Drop -> false
  end
end

# Rules that never consume input when they match (computed to a fixpoint).
def still_rules(rules: List[Rule]) -> Set[String]
  known: Set[String] = Set.new([])
  changed = true
  while changed
    changed = false
    for candidate in rules
      if !known.include?(candidate.name) and still_with?(candidate.body, known)
        known = known.add(candidate.name)
        changed = true
      end
    end
  end

  known
end

def still_with?(expr: Expr, names: Set[String]) -> Bool
  case expr
    Expr.Literal(text) -> text.empty?
    Expr.Insensitive(text) -> text.empty?
    Expr.CharClass(_, _) -> false
    Expr.AnyChar -> false
    Expr.Builtin(name) -> name == "EOF" or name == "EOI" or name == "SOI"
    Expr.RuleRef(name) -> names.include?(name)
    Expr.Seq(parts) -> parts.all? { |part| still_with?(part, names) }
    Expr.Choice(options) -> options.all? { |option| still_with?(option, names) }
    Expr.Repeat(inner, _, _) -> still_with?(inner, names)
    Expr.Lookahead(_) -> true
    Expr.Negative(_) -> true
    Expr.Tagged(_, inner) -> still_with?(inner, names)
    Expr.Push(inner) -> still_with?(inner, names)
    Expr.PushLiteral(_) -> true
    Expr.Drop -> true
    Expr.Pop -> false
    Expr.PopAll -> false
    Expr.Peek -> false
    Expr.PeekAll -> false
  end
end
