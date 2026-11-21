## Reading `.grammar` text: rules, bodies and validation.

import Grammar from "../src/grammar"
import {ClassItem, Expr, UNBOUNDED} from "../src/grammar"

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
    Test.test("an unsupported modifier fails") do
      case Grammar.compile("a = @{ \"x\" }")
        error(e) -> Test.assert(e.message.include?("not supported yet"), e.message)
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
