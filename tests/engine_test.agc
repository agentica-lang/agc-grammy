## Matching grammars against text: ordered choice, repetition and spans.

import Engine from "../src/engine"
import Grammar from "../src/grammar"
import Tree from "../src/tree"

def parse(grammar_text: String, rule: String, input: String) -> Result[Tree.Node]
  grammar = try Grammar.compile(grammar_text)
  Engine.run(grammar, rule, input)
end

def main() -> Void
  Test.run([
    Test.test("a literal sequence covers the text") do
      tree = try parse("p = { \"ab\" ~ \"c\" }", "p", "abc")
      try Test.eq(tree.rule, "p")
      try Test.eq(tree.stop, 3)
      Test.eq(Tree.text(tree, "abc"), "abc")
    end,
    Test.test("a named rule inside builds a child node") do
      tree = try parse("p = { word ~ \"!\" }\nword = { ASCII_ALPHA+ }", "p", "hi!")
      try Test.eq(tree.children.size, 1)
      child = tree.children[0]
      try Test.eq(child.rule, "word")
      Test.eq(Tree.text(child, "hi!"), "hi")
    end,
    Test.test("a silent rule builds no node") do
      tree = try parse("p = { \"a\" ~ ws ~ \"b\" }\nws = _{ \" \"* }", "p", "a b")
      Test.eq(tree.children.size, 0)
    end,
    Test.test("choice is ordered") do
      try Test.error?(parse("p = { \"a\" | \"ab\" }", "p", "ab"))
      Test.ok?(parse("p = { \"ab\" | \"a\" }", "p", "ab"))
    end,
    Test.test("repetition stops on no progress") do
      tree = try parse("p = { \"a\"* ~ \"b\" }", "p", "b")
      try Test.eq(tree.stop, 1)
      Test.eq(tree.children.size, 0)
    end,
    Test.test("a character class and its negation") do
      try Test.ok?(parse("p = { [a-z]+ }", "p", "abc"))
      try Test.ok?(parse("p = { [^0-9]+ }", "p", "abc"))
      Test.error?(parse("p = { [^0-9]+ }", "p", "ab1"))
    end,
    Test.test("lookahead consumes nothing") do
      tree = try parse("p = { &\"ab\" ~ ANY ~ ANY }", "p", "ab")
      try Test.eq(tree.stop, 2)
      try Test.ok?(parse("p = { !\"b\" ~ ANY }", "p", "a"))
      Test.error?(parse("p = { !\"b\" ~ ANY }", "p", "b"))
    end,
    Test.test("EOF matches only at the end") do
      try Test.ok?(parse("p = { ANY ~ EOF }", "p", "a"))
      Test.error?(parse("p = { ANY ~ EOF }", "p", "ab"))
    end,
    Test.test("leftover input is an error") do
      case parse("p = { \"a\" }", "p", "ab")
        error(e) -> Test.assert(e.message.include?("unconsumed input"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a failure names the deepest position") do
      case parse("p = { \"ab\" ~ \"cd\" }", "p", "abX")
        error(e) ->
          try Test.assert(e.message.include?("column 3"), e.message)
          Test.assert(e.message.include?("expected \"cd\""), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a choice lists the rules it tried") do
      case parse("p = { \"a\" | \"b\" }", "p", "c")
        error(e) ->
          try Test.assert(e.message.include?("\"a\""), e.message)
          Test.assert(e.message.include?("\"b\""), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a negative lookahead reports what it refused") do
      case parse("p = { !\"x\" ~ ANY }", "p", "x")
        error(e) -> Test.assert(e.message.include?("unexpected \"x\""), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a silent rule adds no terminal noise") do
      case parse("p = { \"a\" ~ ws ~ \"b\" }\nws = _{ \" \"* }", "p", "aX")
        error(e) ->
          try Test.assert(e.message.include?("expected \"b\""), e.message)
          Test.assert(!e.message.include?("expected \" \""), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("the ASCII builtins") do
      try Test.ok?(parse("p = { ASCII_ALPHA_LOWER+ }", "p", "abc"))
      try Test.ok?(parse("p = { ASCII_ALPHA_UPPER+ }", "p", "ABC"))
      try Test.ok?(parse("p = { ASCII_BIN_DIGIT+ }", "p", "0101"))
      try Test.ok?(parse("p = { ASCII_OCT_DIGIT+ }", "p", "01234567"))
      try Test.ok?(parse("p = { ASCII_NONZERO_DIGIT+ }", "p", "123"))
      try Test.ok?(parse("p = { ASCII_HEX_DIGIT+ }", "p", "0aF"))
      try Test.ok?(parse("p = { ASCII_ALPHANUMERIC+ }", "p", "a1B"))
      try Test.ok?(parse("p = { ASCII+ }", "p", "~"))
      Test.error?(parse("p = { ASCII }", "p", "é"))
    end,
    Test.test("SOI and EOI mark the ends") do
      try Test.ok?(parse("p = { SOI ~ ANY ~ EOI }", "p", "a"))
      try Test.ok?(parse("p = { ANY ~ ANY ~ EOI }", "p", "ba"))
      Test.error?(parse("p = { SOI ~ ANY }", "p", "ba"))
    end,
    Test.test("NEWLINE accepts CRLF and CR") do
      tree = try parse("p = { NEWLINE }", "p", "\r\n")
      try Test.eq(tree.stop, 2)
      try Test.ok?(parse("p = { NEWLINE }", "p", "\n"))
      Test.ok?(parse("p = { NEWLINE }", "p", "\r"))
    end,
    Test.test("INDENT consumes a deeper line and INDENT stops on dedent") do
      grammar_text = (
        "p = >_{ \"go\" ~ nl ~ INDENT ~ item ~ (nl ~ INDENT ~ item)* ~ nl? }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n  a\n  b\n")
      try Test.eq(Tree.find_all(tree, "item").size, 2)
      try Test.eq(Tree.first(tree, "item").unwrap!.start, 5)
      Test.eq(Tree.find_all(tree, "item")[1].stop, 10)
    end,
    Test.test("INDENT skips blank lines") do
      grammar_text = (
        "p = >_{ \"go\" ~ nl ~ INDENT ~ item ~ (nl ~ INDENT ~ item)* }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n  a\n\n  b")
      Test.eq(Tree.find_all(tree, "item").size, 2)
    end,
    Test.test("tabs count as indentation") do
      grammar_text = "p = >_{ \"go\" ~ nl ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      Test.ok?(parse(grammar_text, "p", "go\n\ta"))
    end,
    Test.test("SAME wants the block indentation") do
      grammar_text = (
        "p = >_{ \"go\" ~ nl ~ INDENT ~ item ~ nl ~ SAME ~ \"end\" }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      try Test.ok?(parse(grammar_text, "p", "go\n  a\nend"))
      case parse(grammar_text, "p", "go\n  a\n  end")
        error(e) -> Test.assert(e.message.include?("a line at this indentation"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a missing block names the indentation") do
      grammar_text = "p = >_{ \"go\" ~ nl ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      case parse(grammar_text, "p", "go\na")
        error(e) -> Test.assert(e.message.include?("an indented line"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an insensitive literal ignores case") do
      try Test.ok?(parse("p = { ^\"abc\" }", "p", "AbC"))
      Test.error?(parse("p = { ^\"abc\" }", "p", "abd"))
    end,
    Test.test("repetition bounds") do
      try Test.ok?(parse("p = { \"a\"{2} }", "p", "aa"))
      try Test.error?(parse("p = { \"a\"{2} }", "p", "a"))
      try Test.ok?(parse("p = { \"a\"{2,3} ~ EOI }", "p", "aaa"))
      Test.error?(parse("p = { \"a\"{2,3} ~ EOI }", "p", "aaaa"))
    end,
    Test.test("a pest range matches one character") do
      tree = try parse("p = { 'a'..'z'+ ~ EOI }", "p", "abc")
      try Test.eq(tree.stop, 3)
      Test.error?(parse("p = { 'a'..'z'+ }", "p", "ab1"))
    end,
    Test.test("a bounded repetition at match time") do
      try Test.ok?(parse("p = { \"a\"{,2} ~ EOI }", "p", "a"))
      try Test.ok?(parse("p = { \"a\"{,2} ~ EOI }", "p", "aa"))
      try Test.error?(parse("p = { \"a\"{,2} ~ EOI }", "p", "aaa"))
      Test.ok?(parse("p = { \"a\"{0} ~ \"b\" }", "p", "b"))
    end,
    Test.test("escapes inside a character class") do
      tree = try parse("p = { [\\x41-\\x43]+ }", "p", "ABC")
      Test.eq(Tree.text(tree, "ABC"), "ABC")
    end,
    Test.test("a comment inside a body is skipped") do Test.ok?(parse("p = { \"a\" ~ /* c */ \"b\" }", "p", "ab")) end,
    Test.test("an insensitive literal folds ASCII only") do
      try Test.ok?(parse("p = { ^\"k\" }", "p", "K"))
      Test.error?(parse("p = { ^\"k\" }", "p", String.from_code(8490)))
    end,
    Test.test("tree queries") do
      grammar_text = "p = { item* }\nitem = { ASCII_DIGIT }"
      tree = try parse(grammar_text, "p", "123")
      try Test.eq(Tree.find_all(tree, "item").size, 3)
      try Test.eq(Tree.children_of(tree, "item").size, 3)
      try Test.eq(Tree.first(tree, "item").unwrap!.start, 0)
      try Test.eq(Tree.first_child(tree, "item").unwrap!.start, 0)
      try Test.eq(Tree.last_child(tree).unwrap!.start, 2)
      Test.eq(Tree.find_all(tree, "none").size, 0)
    end,
    Test.test("position counts lines and columns") do
      where = Tree.position("ab\ncd\n", 4)
      try Test.eq(where.line, 2)
      try Test.eq(where.column, 2)
      Test.eq(where.line_text, "cd")
    end,
  ])
end
