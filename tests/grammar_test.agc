## Reading `.grammar` text: rules, bodies and validation.

import Grammar from "../src/grammar"
import {Atomicity, ClassItem, Expr, UNBOUNDED} from "../src/grammar"

def main() -> Void
  Test.run([
    Test.test("a named rule with a builtin") do
      grammar = try Grammar.compile("digit = { ASCII_DIGIT }")
      try Test.eq(grammar.rules.size, 1)
      rule = grammar.rules[0]
      try Test.eq(rule.name, "digit")
      try Test.eq(rule.silent, false)
      Test.eq(rule.body, Expr.Builtin("ASCII_DIGIT"))
    end,
    Test.test("a silent rule") do
      grammar = try Grammar.compile("ws = _{ \" \" }")
      try Test.eq(grammar.rules[0].silent, true)
      Test.eq(grammar.rules[0].body, Expr.Literal(" "))
    end,
    Test.test("a choice of sequences") do
      sequence = Expr.Seq([Expr.Literal("y"), Expr.Literal("z")])
      grammar = try Grammar.compile("a = { \"x\" | \"y\" ~ \"z\" }")
      Test.eq(grammar.rules[0].body, Expr.Choice([Expr.Literal("x"), sequence]))
    end,
    Test.test("repetition counts") do
      grammar = try Grammar.compile("a = { \"x\"* ~ \"y\"+ ~ \"z\"? }")
      x = Expr.Literal("x")
      y = Expr.Literal("y")
      z = Expr.Literal("z")
      expected = Expr.Seq([Expr.Repeat(x, 0, UNBOUNDED), Expr.Repeat(y, 1, UNBOUNDED), Expr.Repeat(z, 0, 1)])
      Test.eq(grammar.rules[0].body, expected)
    end,
    Test.test("a character class span") do
      grammar = try Grammar.compile("a = { [a-z] }")
      Test.eq(grammar.rules[0].body, Expr.CharClass(false, [ClassItem.Span("a", "z")]))
    end,
    Test.test("a negated character class with escapes") do
      grammar = try Grammar.compile("a = { [^\"\\\\] }")
      Test.eq(grammar.rules[0].body, Expr.CharClass(true, [ClassItem.Single("\""), ClassItem.Single("\\")]))
    end,
    Test.test("lookahead") do
      grammar = try Grammar.compile("a = { !\"x\" ~ &\"y\" ~ ANY }")
      inner = Expr.Literal("y")
      expected = Expr.Seq([Expr.Negative(Expr.Literal("x")), Expr.Lookahead(inner), Expr.Builtin("ANY")])
      Test.eq(grammar.rules[0].body, expected)
    end,
    Test.test("any character") do
      grammar = try Grammar.compile("a = { . }")
      Test.eq(grammar.rules[0].body, Expr.AnyChar)
    end,
    Test.test("escapes in a literal") do
      grammar = try Grammar.compile("a = { \"a\\\"b\\n\" }")
      Test.eq(grammar.rules[0].body, Expr.Literal("a\"b\n"))
    end,
    Test.test("line and block comments are skipped") do
      grammar = try Grammar.compile("// a grammar\n/* nested /* x */ y */\n\na = { \"x\" }\n\nb = { a ~ \"y\" }\n")
      try Test.eq(grammar.rules.size, 2)
      Test.eq(grammar.rules[1].body, Expr.Seq([Expr.RuleRef("a"), Expr.Literal("y")]))
    end,
    Test.test("a missing ~ fails") do
      case Grammar.compile("b = { \"x\" \"y\" }")
        error(e) -> Test.assert(e.message.include?("expected ~"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("repetition bounds") do
      grammar = try Grammar.compile("a = { \"x\"{3} ~ \"y\"{2,} ~ \"z\"{,4} ~ \"w\"{1,2} }")
      expected = Expr.Seq([
        Expr.Repeat(Expr.Literal("x"), 3, 3),
        Expr.Repeat(Expr.Literal("y"), 2, UNBOUNDED),
        Expr.Repeat(Expr.Literal("z"), 0, 4),
        Expr.Repeat(Expr.Literal("w"), 1, 2),
      ])

      Test.eq(grammar.rules[0].body, expected)
    end,
    Test.test("a minimum above the maximum fails") do
      case Grammar.compile("a = { \"x\"{3,2} }")
        error(e) -> Test.assert(e.message.include?("above the maximum"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an insensitive literal") do
      grammar = try Grammar.compile("a = { ^\"true\" }")
      Test.eq(grammar.rules[0].body, Expr.Insensitive("true"))
    end,
    Test.test("a pest range is a class span") do
      grammar = try Grammar.compile("a = { 'a'..'z' }")
      Test.eq(grammar.rules[0].body, Expr.CharClass(false, [ClassItem.Span("a", "z")]))
    end,
    Test.test("escapes in literals") do
      grammar = try Grammar.compile("a = { \"\\x41\" ~ \"\\u{1F600}\" ~ \"\\0\" ~ \"\\'\" }")
      expected = Expr.Seq([
        Expr.Literal("A"),
        Expr.Literal(String.from_code(128512)),
        Expr.Literal(String.from_code(0)),
        Expr.Literal("'"),
      ])

      Test.eq(grammar.rules[0].body, expected)
    end,
    Test.test("modifiers combine") do
      grammar = try Grammar.compile("a = >_{ \"x\" }")
      rule = grammar.rules[0]
      try Test.eq(rule.indents, true)
      Test.eq(rule.silent, true)
    end,
    Test.test("the stack builtins are read") do
      grammar = try Grammar.compile("a = { PUSH(ASCII_DIGIT+) ~ POP }")
      try Test.eq(
        grammar.rules[0].body,
        Expr.Seq([Expr.Push(Expr.Repeat(Expr.Builtin("ASCII_DIGIT"), 1, UNBOUNDED)), Expr.Pop]),
      )

      literal = try Grammar.compile("b = { PUSH_LITERAL(\"x\") ~ PEEK ~ DROP }")
      try Test.eq(literal.rules[0].body, Expr.Seq([Expr.PushLiteral("x"), Expr.Peek, Expr.Drop]))
      all = try Grammar.compile("c = { PUSH_LITERAL(\"x\") ~ POP_ALL ~ PEEK_ALL }")
      Test.eq(all.rules[0].body, Expr.Seq([Expr.PushLiteral("x"), Expr.PopAll, Expr.PeekAll]))
    end,
    Test.test("PUSH without parentheses fails") do
      case Grammar.compile("a = { PUSH }")
        error(e) -> Test.assert(e.message.include?("PUSH needs an expression in parentheses"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("PUSH_LITERAL needs a string") do
      case Grammar.compile("a = { PUSH_LITERAL(x) }")
        error(e) -> Test.assert(e.message.include?("PUSH_LITERAL needs a string"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("reading the stack without pushing anything fails") do
      case Grammar.compile("a = { POP }")
        error(e) -> Test.assert(e.message.include?("reads the stack but nothing pushes"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a skipped rule cannot use the stack") do
      case Grammar.compile("WHITESPACE = _{ POP }\np = { PUSH_LITERAL(\"x\") ~ \"a\" }")
        error(e) -> Test.assert(e.message.include?("cannot use the stack"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("PUSH does not hide left recursion") do
      case Grammar.compile("a = { PUSH(a) }")
        error(e) -> Test.assert(e.message.include?("left recursive"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a skipped rule cannot reach the stack through a helper") do
      grammar_text = (
        "WHITESPACE = _{ ws }\nws = _{ \" \" ~ POP }\np = { \"a\" ~ \"b\" }\nunused = _{ PUSH_LITERAL(\"x\") }"
      )

      case Grammar.compile(grammar_text)
        error(e) -> Test.assert(e.message.include?("cannot use the stack"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("left recursion behind a stack read is refused") do
      # POP_ALL matches zero-width on an empty stack, where a parse starts.
      grammar_text = "p = { POP_ALL ~ p }\nignore = _{ PUSH_LITERAL(\"x\") }"
      case Grammar.compile(grammar_text)
        error(e) -> Test.assert(e.message.include?("left recursive"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a DROP repetition is allowed") do
      grammar = try Grammar.compile("a = { PUSH_LITERAL(\"x\") ~ DROP* }")
      Test.eq(grammar.rules.size, 1)
    end,
    Test.test("a bound does not become an excuse to build nodes") do
      grammar_text = "p = { PUSH_LITERAL(\"x\") ~ (SOI | DROP){0,50000} }"
      case Grammar.compile(grammar_text)
        error(e) -> Test.assert(e.message.include?("more than 10000 times"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a PUSH_LITERAL repetition is still refused") do
      case Grammar.compile("a = { PUSH_LITERAL(\"x\")* }")
        error(e) ->
          Test.assert(e.message.include?("never consumes input") or e.message.include?("cannot fail"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a tag over PUSH has nothing to tag") do
      case Grammar.compile("p = { #a = PUSH(ANY) }")
        error(e) -> Test.assert(e.message.include?("has no node to tag"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("the atomic modifiers are read") do
      atomic = try Grammar.compile("a = @{ \"x\" }")
      compound = try Grammar.compile("b = ${ \"x\" }")
      non_atomic = try Grammar.compile("c = !{ \"x\" }")
      try Test.eq(atomic.rules[0].atomicity, Atomicity.Atomic)
      try Test.eq(compound.rules[0].atomicity, Atomicity.Compound)
      try Test.eq(non_atomic.rules[0].atomicity, Atomicity.NonAtomic)
      Test.eq((try Grammar.compile("d = { \"x\" }")).rules[0].atomicity, Atomicity.Plain)
    end,
    Test.test("two of the same modifier fails") do
      case Grammar.compile("a = @@{ \"x\" }")
        error(e) -> Test.assert(e.message.include?("two @ modifiers on one rule"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("the atomic modifiers combine with > and _") do
      grammar = try Grammar.compile("a = >_@{ \"x\" }")
      rule = grammar.rules[0]
      try Test.eq(rule.indents, true)
      try Test.eq(rule.silent, true)
      Test.eq(rule.atomicity, Atomicity.Atomic)
    end,
    Test.test("two atomic modifiers fail") do
      case Grammar.compile("a = @${ \"x\" }")
        error(e) -> Test.assert(e.message.include?("two $ modifiers on one rule"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a repeated silent modifier fails") do
      case Grammar.compile("a = __{ \"x\" }")
        error(e) -> Test.assert(e.message.include?("two _ modifiers on one rule"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a tag wraps the term it names") do
      grammar = try Grammar.compile("a = { #key = word }\nword = { ASCII_ALPHA }")
      Test.eq(grammar.rules[0].body, Expr.Tagged("key", Expr.RuleRef("word")))
    end,
    Test.test("a tag without a node fails") do
      case Grammar.compile("a = { #n = \"x\" }")
        error(e) -> Test.assert(e.message.include?("has no node to tag"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a tag on a silent wrapper is allowed") do
      grammar = try Grammar.compile("p = { #a = list }\nlist = _{ item* }\nitem = { ASCII_DIGIT }")
      Test.eq(grammar.rules[0].body, Expr.Tagged("a", Expr.RuleRef("list")))
    end,
    Test.test("a silent rule that reaches itself does not hang the tag check") do
      case Grammar.compile("p = { #a = loop }\nloop = _{ loop? ~ \"x\" }")
        error(e) ->
          Test.assert(e.message.include?("left recursive") or e.message.include?("has no node to tag"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a tag on a silent rule fails") do
      case Grammar.compile("a = { #k = ws }\nws = _{ \" \"* }")
        error(e) -> Test.assert(e.message.include?("has no node to tag"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a tag name is required") do
      case Grammar.compile("a = { # = \"x\" }")
        error(e) -> Test.assert(e.message.include?("expected a tag name"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("WHITESPACE and COMMENT are rule names") do
      grammar = try Grammar.compile("WHITESPACE = _{ \" \" }\nCOMMENT = _{ \"#\" ~ ANY* }")
      Test.eq(grammar.rules.size, 2)
    end,
    Test.test("a WHITESPACE that cannot fail is refused") do
      case Grammar.compile("WHITESPACE = _{ \"\" }")
        error(e) -> Test.assert(e.message.include?("must be able to fail"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a WHITESPACE that never consumes input is refused") do
      case Grammar.compile("WHITESPACE = _{ &\" \" }")
        error(e) -> Test.assert(e.message.include?("must consume input"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a trailing ~ fails") do
      case Grammar.compile("a = { \"x\" ~ }")
        error(e) -> Test.assert(e.message.include?("expected an expression after ~"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a caret without a string fails") do
      case Grammar.compile("a = { ^x }")
        error(e) -> Test.assert(e.message.include?("expected a string after ^"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a malformed \\x escape fails") do
      case Grammar.compile("a = { \"\\xZZ\" }")
        error(e) -> Test.assert(e.message.include?("two hex digits"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a malformed \\u escape fails") do
      short = Grammar.compile("a = { \"\\u{9}\" }")
      surrogate = Grammar.compile("a = { \"\\u{D800}\" }")
      above = Grammar.compile("a = { \"\\u{110000}\" }")
      try Test.assert(short.message.include?("two to six hex digits"), short.message)
      try Test.assert(surrogate.message.include?("is not a character code"), surrogate.message)
      Test.assert(above.message.include?("is not a character code"), above.message)
    end,
    Test.test("a descending range fails") do
      case Grammar.compile("a = { 'z'..'a' }")
        error(e) -> Test.assert(e.message.include?("descending"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an unterminated block comment fails") do
      case Grammar.compile("a = { /* x }")
        error(e) -> Test.assert(e.message.include?("expected an expression"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an exact zero bound") do
      grammar = try Grammar.compile("a = { \"x\"{0} }")
      Test.eq(grammar.rules[0].body, Expr.Repeat(Expr.Literal("x"), 0, 0))
    end,
    Test.test("blanks inside a bound") do
      grammar = try Grammar.compile("a = { \"x\"{ 2 , 3 } }")
      Test.eq(grammar.rules[0].body, Expr.Repeat(Expr.Literal("x"), 2, 3))
    end,
    Test.test("a bound too large for Int fails") do
      case Grammar.compile("a = { \"x\"{99999999999999999999} }")
        error(e) -> Test.assert(e.message.include?("too large"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a bounded repetition of a non-consuming expression compiles") do
      Test.ok?(Grammar.compile("a = { (&\"x\"){2} }"))
    end,
    Test.test("a blank after the caret is allowed") do
      grammar = try Grammar.compile("a = { ^ \"abc\" }")
      Test.eq(grammar.rules[0].body, Expr.Insensitive("abc"))
    end,
    Test.test("a comment inside a body is skipped") do
      grammar = try Grammar.compile("a = { \"x\" ~ /* c */ \"y\" ~ // tail\n \"z\" }")
      Test.eq(grammar.rules[0].body, Expr.Seq([Expr.Literal("x"), Expr.Literal("y"), Expr.Literal("z")]))
    end,
    Test.test("a huge bound on a zero-width expression fails") do
      case Grammar.compile("a = { (&\"x\"){20000} }")
        error(e) -> Test.assert(e.message.include?("zero-width"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("unicode properties are refused") do
      case Grammar.compile("a = { \"\\p{L}\" }")
        error(e) -> Test.assert(e.message.include?("unicode properties"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an unterminated character literal names the character") do
      case Grammar.compile("a = { 'x }")
        error(e) -> Test.assert(e.message.include?("unterminated character"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a rule declared twice fails") do
      case Grammar.compile("a = { \"x\" }\na = { \"y\" }")
        error(e) -> Test.assert(e.message.include?("declared twice"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an unknown reference fails") do
      case Grammar.compile("a = { b }")
        error(e) -> Test.assert(e.message.include?("unknown rule b"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an unterminated string fails") do
      case Grammar.compile("a = { \"x }")
        error(e) -> Test.assert(e.message.include?("unterminated string"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("left recursion fails") do
      case Grammar.compile("a = { a ~ \"x\" }")
        error(e) -> Test.assert(e.message.include?("left recursive"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("indirect left recursion fails") do
      case Grammar.compile("a = { b }\nb = { a }")
        error(e) -> Test.assert(e.message.include?("left recursive"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("left recursion hides behind a nullable rule") do
      case Grammar.compile("a = { ws ~ a }\nws = _{ \" \"* }")
        error(e) -> Test.assert(e.message.include?("left recursive"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("right recursion is fine") do Test.ok?(Grammar.compile("item = { \"x\" ~ item? }")) end,
    Test.test("repeating an expression that cannot fail fails") do
      case Grammar.compile("a = { (\"\")* }")
        error(e) -> Test.assert(e.message.include?("cannot fail"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("repeating a lookahead fails") do
      case Grammar.compile("a = { (&\"x\")* }")
        error(e) -> Test.assert(e.message.include?("never consumes input"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a reserved rule name fails") do
      case Grammar.compile("ANY = { \"x\" }")
        error(e) -> Test.assert(e.message.include?("reserved rule name"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a choice arm that cannot fail fails") do
      case Grammar.compile("a = { \"\" | \"x\" }")
        error(e) -> Test.assert(e.message.include?("arms after it are unreachable"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
  ])
end
