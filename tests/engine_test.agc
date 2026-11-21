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
    Test.test("a bounded repetition repeats a zero-width expression") do
      grammar_text = "p = { (&\"x\"){2} ~ \"x\" }"
      tree = try parse(grammar_text, "p", "x")
      try Test.eq(tree.stop, 1)
      Test.ok?(parse("p = { \"\"{3} ~ \"x\" }", "p", "x"))
    end,
    Test.test("a bounded zero-width repetition is not slow") do
      start = Time.monotonic_ms()
      tree = try parse("p = { \"\"{5000} ~ \"x\" }", "p", "x")
      elapsed = Time.monotonic_ms() - start
      try Test.eq(tree.stop, 1)
      Test.assert(elapsed < 1000, "5000 zero-width iterations took #{elapsed} ms")
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
    Test.test("WHITESPACE is skipped between parts") do
      tree = try parse("WHITESPACE = _{ \" \" }\np = { \"a\" ~ \"b\" }", "p", "a   b")
      try Test.eq(tree.stop, 5)
      Test.eq(Tree.text(tree, "a   b"), "a   b")
    end,
    Test.test("WHITESPACE is skipped between iterations") do
      tree = try parse("WHITESPACE = _{ \" \" }\np = { item* }\nitem = { ASCII_ALPHA }", "p", "a b c")
      try Test.eq(Tree.find_all(tree, "item").size, 3)
      Test.eq(tree.stop, 5)
    end,
    Test.test("WHITESPACE is skipped after the start rule") do
      tree = try parse("WHITESPACE = _{ \" \" }\np = { \"a\" }", "p", "a  ")
      Test.eq(tree.stop, 3)
    end,
    Test.test("COMMENT is skipped with WHITESPACE") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\nCOMMENT = _{ \"/*\" ~ (!\"*/\" ~ ANY)* ~ \"*/\" }\np = { \"a\" ~ \"b\" }"
      )

      tree = try parse(grammar_text, "p", "a /* x */ b")
      Test.eq(tree.stop, 11)
    end,
    Test.test("an atomic rule skips nothing and builds one token") do
      tree = try parse("WHITESPACE = _{ \" \" }\np = { token }\ntoken = @{ ASCII_ALPHA ~ ASCII_ALPHA }", "p", "ab")
      try Test.eq(tree.children.size, 1)
      Test.eq(tree.children[0].children.size, 0)
    end,
    Test.test("an atomic rule keeps the text inside it") do
      grammar_text = "WHITESPACE = _{ \" \" }\np = { \"a\" ~ token ~ \"z\" }\ntoken = @{ \"b\" ~ \"c\" }"
      tree = try parse(grammar_text, "p", "a bc z")
      Test.eq(Tree.text(tree.children[0], "a bc z"), "bc")
    end,
    Test.test("a compound-atomic rule keeps its children") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = { values }\nvalues = ${ value ~ \",\" ~ value }\nvalue = { ASCII_DIGIT+ }"
      )

      tree = try parse(grammar_text, "p", "1,2")
      try Test.eq(tree.children[0].rule, "values")
      Test.eq(Tree.find_all(tree, "value").size, 2)
    end,
    Test.test("a compound-atomic rule skips nothing") do
      grammar_text = "WHITESPACE = _{ \" \" }\np = { values }\nvalues = ${ \"a\" ~ \"b\" }"
      Test.error?(parse(grammar_text, "p", "a b"))
    end,
    Test.test("a non-atomic rule restores skipping inside an atomic one") do
      grammar_text = "WHITESPACE = _{ \" \" }\np = { body }\nbody = @{ inner ~ \"!\" }\ninner = !{ \"a\" ~ \"b\" }"
      tree = try parse(grammar_text, "p", "a b!")
      try Test.eq(tree.children.size, 1)
      Test.eq(Tree.find_all(tree, "inner").size, 1)
    end,
    Test.test("a non-atomic rule restores nodes inside an atomic one") do
      tree = try parse("p = { body }\nbody = @{ inner }\ninner = !{ ASCII_ALPHA+ }\n", "p", "abc")
      try Test.eq(tree.children.size, 1)
      Test.eq(Tree.children_of(tree.children[0], "inner").size, 1)
    end,
    Test.test("an atomic start rule skips nothing inside it") do
      try Test.error?(parse("WHITESPACE = _{ \" \" }\np = @{ \"a\" ~ \"b\" }", "p", "a b"))
      tree = try parse("WHITESPACE = _{ \" \" }\np = @{ \"a\" ~ \"b\" }", "p", "ab")
      try Test.eq(tree.stop, 2)
      Test.eq(tree.children.size, 0)
    end,
    Test.test("an atomic start rule drops the nodes inside it") do
      grammar_text = "WHITESPACE = _{ \" \" }\np = @{ inner }\ninner = { ASCII_ALPHA+ }"
      tree = try parse(grammar_text, "p", "abc")
      try Test.eq(tree.children.size, 0)
      Test.eq(Tree.text(tree, "abc"), "abc")
    end,
    Test.test("a compound start rule keeps its children and skips nothing") do
      grammar_text = "WHITESPACE = _{ \" \" }\np = ${ inner ~ \"!\" }\ninner = { ASCII_ALPHA+ }"
      try Test.error?(parse(grammar_text, "p", "a b!"))
      tree = try parse(grammar_text, "p", "ab!")
      try Test.eq(tree.children.size, 1)
      Test.eq(tree.stop, 3)
    end,
    Test.test("a non-atomic start rule skips whitespace") do
      tree = try parse("WHITESPACE = _{ \" \" }\np = !{ \"a\" ~ \"b\" }", "p", "a b")
      try Test.eq(tree.stop, 3)
      Test.eq(tree.children.size, 0)
    end,
    Test.test("leading whitespace is not skipped") do
      Test.error?(parse("WHITESPACE = _{ \" \" }\np = { \"a\" }", "p", " a"))
    end,
    Test.test("COMMENT works without WHITESPACE") do
      grammar_text = "COMMENT = _{ \"/*\" ~ (!\"*/\" ~ ANY)* ~ \"*/\" }\np = { \"a\" ~ \"b\" }"
      tree = try parse(grammar_text, "p", "a/*x*/b")
      Test.eq(tree.stop, 7)
    end,
    Test.test("a compound rule inside an atomic one keeps its nodes") do
      grammar_text = "p = { outer }\nouter = @{ inner ~ \"!\" }\ninner = ${ ASCII_ALPHA+ }"
      tree = try parse(grammar_text, "p", "ab!")
      try Test.eq(tree.children.size, 1)
      Test.eq(Tree.children_of(tree.children[0], "inner").size, 1)
    end,
    Test.test("a tag inside an atomic rule tags nothing") do
      grammar_text = "p = { outer }\nouter = @{ #v = inner }\ninner = { ASCII_ALPHA+ }"
      tree = try parse(grammar_text, "p", "ab")
      try Test.eq(tree.children.size, 1)
      Test.eq(Tree.tagged(tree, "v").size, 0)
    end,
    Test.test("a tag over a multi-node iteration tags its last node") do
      grammar_text = "p = { #kv = (key ~ \":\" ~ value)* }\nkey = { ASCII_ALPHA }\nvalue = { ASCII_DIGIT }"
      tree = try parse(grammar_text, "p", "a:1b:2")
      tagged = Tree.tagged(tree, "kv")
      try Test.eq(tagged.size, 2)
      try Test.eq(tagged[0].rule, "value")
      Test.eq(Tree.text(tagged[1], "a:1b:2"), "2")
    end,
    Test.test("a tag names the node its term built") do
      grammar_text = "p = { #left = digit ~ \",\" ~ #right = digit }\ndigit = { ASCII_DIGIT }"
      tree = try parse(grammar_text, "p", "1,2")
      left = Tree.first_tagged(tree, "left").unwrap!
      right = Tree.first_tagged(tree, "right").unwrap!
      try Test.eq(Tree.text(left, "1,2"), "1")
      try Test.eq(Tree.text(right, "1,2"), "2")
      Test.eq(Tree.tagged(tree, "left").size, 1)
    end,
    Test.test("a tag over a repetition names every node") do
      grammar_text = "p = { #d = digit* }\ndigit = { ASCII_DIGIT }"
      tree = try parse(grammar_text, "p", "123")
      Test.eq(Tree.tagged(tree, "d").size, 3)
    end,
    Test.test("a tag over an optional names the node when it is there") do
      grammar_text = "p = { #e = value? }\nvalue = { ASCII_DIGIT }"
      try Test.eq(Tree.tagged(try parse(grammar_text, "p", "7"), "e").size, 1)
      Test.eq(Tree.tagged(try parse(grammar_text, "p", ""), "e").size, 0)
    end,
    Test.test("a tag over + and {n,m} names every iteration") do
      grammar_text = "p = { #d = digit+ }\ndigit = { ASCII_DIGIT }"
      try Test.eq(Tree.tagged(try parse(grammar_text, "p", "123"), "d").size, 3)
      bounded = "q = { #d = digit{2,3} }\ndigit = { ASCII_DIGIT }"
      Test.eq(Tree.tagged(try parse(bounded, "q", "12"), "d").size, 2)
    end,
    Test.test("a tag keeps the deepest attempt") do
      grammar_text = "p = { #a = (b ~ c | b) ~ \"!\" }\nb = { \"b\" }\nc = { \"c\" }"
      case parse(grammar_text, "p", "b?")
        error(e) -> Test.assert(e.message.include?("\"c\""), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an indentation scope works with implicit whitespace") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ nl ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go \n   ab ")
      try Test.eq(Tree.first(tree, "item").unwrap!.start, 7)
      Test.eq(Tree.text(Tree.first(tree, "item").unwrap!, "go \n   ab "), "ab")
    end,
    Test.test("a lookahead for INDENT works with implicit whitespace") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ nl ~ &INDENT ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n  ab")
      Test.eq(Tree.text(tree.children[0], "go\n  ab"), "ab")
    end,
    Test.test("a silent alias for INDENT works with implicit whitespace") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ nl ~ block }\nblock = _{ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n  ab")
      Test.eq(Tree.text(tree.children[0], "go\n  ab"), "ab")
    end,
    Test.test("a repeated INDENT works with implicit whitespace") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ nl ~ INDENT ~ item ~ (nl ~ INDENT ~ item)* }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n  ab\n  cd")
      Test.eq(Tree.find_all(tree, "item").size, 2)
    end,
    Test.test("a WHITESPACE with newlines still feeds INDENT") do
      grammar_text = "WHITESPACE = _{ \" \" | \"\\n\" }\np = >_{ \"go\" ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }"

      tree = try parse(grammar_text, "p", "go\n  ab")
      try Test.eq(Tree.first(tree, "item").unwrap!.start, 5)
      Test.eq(Tree.text(Tree.first(tree, "item").unwrap!, "go\n  ab"), "ab")
    end,
    Test.test("a whitespace-only line does not close the block") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ nl ~ INDENT ~ item ~ (nl ~ INDENT ~ item)* }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n  ab\n    \n  cd")
      Test.eq(Tree.find_all(tree, "item").size, 2)
    end,
    Test.test("SAME works with implicit whitespace and skips blank lines") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ nl ~ INDENT ~ item ~ nl ~ SAME ~ \"end\" }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      try Test.ok?(parse(grammar_text, "p", "go\n  ab\n   \nend"))
      Test.error?(parse(grammar_text, "p", "go\n  ab\n  end"))
    end,
    Test.test("INDENT still fails mid-line with implicit whitespace") do
      grammar_text = "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ \"x\" ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }"
      Test.error?(parse(grammar_text, "p", "go x  ab"))
    end,
    Test.test("a dedent closes the block with implicit whitespace") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ nl ~ INDENT ~ item ~ (nl ~ INDENT ~ item)* ~ nl ~ \"end\" }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n  ab\nend")
      Test.eq(Tree.find_all(tree, "item").size, 1)
    end,
    Test.test("a carriage return ends a line for INDENT") do
      grammar_text = (
        "WHITESPACE = _{ \" \" }\np = >_{ \"go\" ~ nl ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\r\" }"
      )

      tree = try parse(grammar_text, "p", "go\r  ab")
      Test.eq(Tree.text(Tree.first(tree, "item").unwrap!, "go\r  ab"), "ab")
    end,
    Test.test("a skip that stops inside the indentation still measures it") do
      grammar_text = (
        "WHITESPACE = _{ \" \" ~ \" \" }\np = >_{ \"go\" ~ nl ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n   ab")
      try Test.eq(Tree.first(tree, "item").unwrap!.start, 6)
      Test.eq(Tree.text(Tree.first(tree, "item").unwrap!, "go\n   ab"), "ab")
    end,
    Test.test("CRLF ends an indented line") do
      grammar_text = (
        "p = >_{ \"go\" ~ nl ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\r\\n\" | \"\\n\" | \"\\r\" }"
      )

      tree = try parse(grammar_text, "p", "go\r\n  ab")
      Test.eq(Tree.text(Tree.first(tree, "item").unwrap!, "go\r\n  ab"), "ab")
    end,
    Test.test("SAME compares against an indented block base") do
      grammar_text = (
        "p = >_{ \"go\" ~ nl ~ INDENT ~ inner }\ninner = >_{ item ~ nl ~ SAME ~ \"end\" }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      )

      tree = try parse(grammar_text, "p", "go\n  ab\n  end")
      try Test.eq(Tree.find_all(tree, "item").size, 1)
      Test.error?(parse(grammar_text, "p", "go\n  ab\n end"))
    end,
    Test.test("an atomic indentation scope keeps the block base") do
      grammar_text = "p = >@{ \"go\" ~ nl ~ INDENT ~ item }\nitem = { ASCII_ALPHA+ }\nnl = _{ \"\\n\" }"
      tree = try parse(grammar_text, "p", "go\n  ab")
      try Test.eq(tree.children.size, 0)
      Test.eq(tree.stop, 7)
    end,
    Test.test("an untagged node has no tag") do
      tree = try parse("p = { ASCII_DIGIT }", "p", "1")
      try Test.eq(tree.tag, none)
      Test.eq(Tree.first_tagged(tree, "left"), none)
    end,
    Test.test("a pest JSON grammar parses unchanged") do
      grammar_text = "json = { SOI ~ value ~ EOI }\n"
      grammar_text += "object = { \"{\" ~ pair ~ (\",\" ~ pair)* ~ \"}\" | \"{\" ~ \"}\" }\n"
      grammar_text += "pair = { string ~ \":\" ~ value }\n"
      grammar_text += "array = { \"[\" ~ value ~ (\",\" ~ value)* ~ \"]\" | \"[\" ~ \"]\" }\n"
      grammar_text += "value = { string | number | object | array | bool | null }\n"
      grammar_text += "string = @{ \"\\\"\" ~ inner ~ \"\\\"\" }\n"
      grammar_text += "inner = @{ (!(\"\\\"\" | \"\\\\\" | '\\u{0000}'..'\\u{001F}') ~ ANY)* ~ (escape ~ inner)? }\n"
      grammar_text += (
        "escape = @{ \"\\\\\" ~ (\"\\\"\" | \"\\\\\" | \"/\" | \"b\" | \"f\" | \"n\" | \"r\" | \"t\" | unicode) }\n"
      )

      grammar_text += "unicode = @{ \"u\" ~ ASCII_HEX_DIGIT{4} }\n"
      grammar_text += "number = @{ \"-\"? ~ int ~ (\".\" ~ ASCII_DIGIT+ ~ exp? | exp)? }\n"
      grammar_text += "int = @{ \"0\" | ASCII_NONZERO_DIGIT ~ ASCII_DIGIT* }\n"
      grammar_text += "exp = @{ (\"E\" | \"e\") ~ (\"+\" | \"-\")? ~ ASCII_DIGIT+ }\n"
      grammar_text += "bool = { \"true\" | \"false\" }\n"
      grammar_text += "null = { \"null\" }\n"
      grammar_text += "WHITESPACE = _{ \" \" | \"\\t\" | \"\\r\" | \"\\n\" }"
      input = "{\"a\": [1, -2.5e3, true, null], \"b\": {\"c\": \"x\\n\"}}"
      tree = try parse(grammar_text, "json", input)
      try Test.eq(Tree.find_all(tree, "pair").size, 3)
      try Test.eq(Tree.find_all(tree, "string").size, 4)
      Test.eq(Tree.find_all(tree, "inner").size, 0)
    end,
    Test.test("grammars/json.grammar parses verbatim from pest") do
      grammar = try Grammar.load("grammars/json.grammar")
      input = "{\"a\": [1, -2.5e3, true, null], \"b\": {\"c\": \"x\\n\"}}  "
      tree = try Engine.run(grammar, "json", input)
      try Test.eq(Tree.find_all(tree, "pair").size, 3)
      try Test.eq(Tree.find_all(tree, "string").size, 4)
      try Test.eq(tree.stop, input.split("").size)
      try Test.eq(Tree.find_all(tree, "inner").size, 0)
      try JSON.parse(Tree.to_json(tree, input))
      try Test.ok?(Engine.run(grammar, "json", "{}"))
      try Test.ok?(Engine.run(grammar, "json", "[]"))
      try Test.eq(Tree.find_all(try Engine.run(grammar, "json", "{\"e\": \"A\"}"), "string").size, 2)
      try Test.eq(Tree.find_all(try Engine.run(grammar, "json", "[0, -0, 1e+10]"), "number").size, 3)
      try Test.error?(Engine.run(grammar, "json", "01"))
      Test.error?(Engine.run(grammar, "json", "tru"))
    end,
    Test.test("to_json matches the pest shape") do
      tree = try parse("p = { \"a\" ~ word }\nword = { ASCII_ALPHA+ }", "p", "ab")
      expected = "{\n"
      expected += "  \"pos\": [\n"
      expected += "    0,\n"
      expected += "    2\n"
      expected += "  ],\n"
      expected += "  \"rule\": \"p\",\n"
      expected += "  \"inner\": {\n"
      expected += "    \"pos\": [\n"
      expected += "      1,\n"
      expected += "      2\n"
      expected += "    ],\n"
      expected += "    \"pairs\": [\n"
      expected += "      {\n"
      expected += "        \"pos\": [\n"
      expected += "          1,\n"
      expected += "          2\n"
      expected += "        ],\n"
      expected += "        \"rule\": \"word\",\n"
      expected += "        \"inner\": \"b\"\n"
      expected += "      }\n"
      expected += "    ]\n"
      expected += "  }\n"
      expected += "}"
      try Test.eq(Tree.to_json(tree, "ab"), expected)
      try JSON.parse(Tree.to_json(tree, "ab"))
      Test.eq(Tree.text(tree, "ab"), "ab")
    end,
    Test.test("to_json escapes its text") do
      try Test.eq(Tree.json_string("a\"b\\c"), "\"a\\\"b\\\\c\"")
      try Test.eq(Tree.json_string("x\ny\tz"), "\"x\\ny\\tz\"")
      try Test.eq(Tree.json_string(String.from_code(1)), "\"\\u0001\"")
      try Test.eq(Tree.json_string(String.from_code(8)), "\"\\b\"")
      try Test.eq(Tree.json_string(String.from_code(12)), "\"\\f\"")
      try Test.eq(Tree.json_string("a/b"), "\"a/b\"")
      try Test.eq(Tree.json_string(""), "\"\"")
      for code in [1, 8, 12, 13, 31]
        try JSON.parse(Tree.json_string(String.from_code(code)))
      end

      try JSON.parse(Tree.json_string("a/b"))
      try JSON.parse(Tree.json_string(String.from_code(127)))
      try JSON.parse(Tree.json_string("héllo 😀"))
      leaf = Tree.Node(rule: "r", start: 0, stop: 1, children: [], tag: none)
      try JSON.parse(Tree.to_json(leaf, "é"))
      Test.eq(Tree.text(leaf, "é"), "é")
    end,
    Test.test("to_json carries the tag") do
      tree = try parse("p = { #v = digit }\ndigit = { ASCII_DIGIT }", "p", "7")
      try Test.eq(Tree.tagged(tree, "v").size, 1)
      tagged = Tree.to_json(tree, "7")
      try JSON.parse(tagged)
      try Test.eq(tagged.include?("  \"tag\": \"v\",\n"), true)
      plain = try parse("p = { ASCII_DIGIT }", "p", "7")
      Test.assert(!Tree.to_json(plain, "7").include?("\"tag\""), Tree.to_json(plain, "7"))
    end,
    Test.test("to_json positions are character offsets") do
      tree = try parse("p = { ANY }", "p", "é")
      try Test.eq(tree.stop, 1)
      try JSON.parse(Tree.to_json(tree, "é"))
      Test.assert(Tree.to_json(tree, "é").include?("0,\n    1"), Tree.to_json(tree, "é"))
    end,
    Test.test("to_json inner pos spans gapped children") do
      grammar = try Grammar.load("grammars/json.grammar")
      tree = try Engine.run(grammar, "json", "{\"a\": 1}")
      pair = Tree.first(tree, "pair").unwrap!
      inner = Tree.to_json(pair, "{\"a\": 1}")
      try JSON.parse(inner)
      try Test.eq(pair.stop - pair.start, 6)
      try Test.eq(pair.start, 1)
      try Test.eq(pair.stop, 7)
      Test.assert(inner.include?("\"pos\": [\n      1,\n      7\n    ]"), inner)
    end,
    Test.test("PUSH stores the text and POP matches it") do
      tree = try parse("p = { PUSH(word) ~ \" \" ~ POP }\nword = { ASCII_ALPHA+ }", "p", "abc abc")
      try Test.eq(tree.stop, 7)
      Test.eq(Tree.find_all(tree, "word").size, 1)
    end,
    Test.test("PUSH_LITERAL stores a fixed string") do
      tree = try parse("p = { PUSH_LITERAL(\"ab\") ~ \"cd\" ~ POP }", "p", "cdab")
      Test.eq(tree.stop, 4)
    end,
    Test.test("PEEK matches without popping") do
      tree = try parse("p = { PUSH_LITERAL(\"ab\") ~ \"|\" ~ PEEK ~ \"|\" ~ POP }", "p", "|ab|ab")
      Test.eq(tree.stop, 6)
    end,
    Test.test("POP_ALL walks the stack from its top") do
      tree = try parse("p = { PUSH_LITERAL(\"a\") ~ PUSH_LITERAL(\"b\") ~ \"-\" ~ POP_ALL }", "p", "-ba")
      try Test.eq(tree.stop, 3)
      Test.error?(parse("p = { PUSH_LITERAL(\"a\") ~ PUSH_LITERAL(\"b\") ~ \"-\" ~ POP_ALL }", "p", "-ab"))
    end,
    Test.test("PEEK_ALL matches the whole stack twice") do
      grammar_text = "p = { PUSH_LITERAL(\"a\") ~ PUSH_LITERAL(\"b\") ~ \"-\" ~ PEEK_ALL ~ PEEK_ALL }"
      tree = try parse(grammar_text, "p", "-baba")
      Test.eq(tree.stop, 5)
    end,
    Test.test("DROP pops without matching") do
      tree = try parse("p = { PUSH_LITERAL(\"<\") ~ PUSH_LITERAL(\">\") ~ DROP ~ \"x\" ~ POP }", "p", "x<")
      Test.eq(tree.stop, 2)
    end,
    Test.test("a failed alternative rolls the stack back") do
      grammar_text = "p = { (PUSH_LITERAL(\"x\") ~ \"q\")? ~ \"a\" ~ PEEK }"
      try Test.error?(parse(grammar_text, "p", "ax"))
      Test.ok?(parse("p = { PUSH_LITERAL(\"x\") ~ \"a\" ~ PEEK }", "p", "ax"))
    end,
    Test.test("a repetition rolls the stack back too") do
      grammar_text = "p = { (PUSH_LITERAL(\"x\") ~ \"q\")* ~ \"a\" ~ PEEK }"
      Test.error?(parse(grammar_text, "p", "ax"))
    end,
    Test.test("a lookahead does not leak a push") do
      grammar_text = "p = { &(PUSH_LITERAL(\"x\")) ~ \"a\" ~ PEEK }"
      Test.error?(parse(grammar_text, "p", "ax"))
    end,
    Test.test("an empty stack fails instead of crashing") do
      case parse("p = { \"a\" ~ POP }\nunused = _{ PUSH_LITERAL(\"x\") }", "p", "a")
        error(e) -> Test.assert(e.message.include?("a value on the stack"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("the stack balances nested parentheses") do
      grammar_text = (
        "p = { nested }\nnested = { \"(\" ~ PUSH_LITERAL(\")\") ~ (nested | inner)* ~ POP }\ninner = { (!(\"(\" | \")\") ~ ANY)+ }"
      )

      try Test.eq((try parse(grammar_text, "p", "((x)(y))")).stop, 8)
      Test.error?(parse(grammar_text, "p", "((a)"))
    end,
    Test.test("a zero-width bounded repetition still changes the stack") do
      tree = try parse("p = { DROP{0} ~ PUSH_LITERAL(\"x\"){2} ~ \"-\" ~ POP_ALL }", "p", "-xx")
      try Test.eq(tree.stop, 3)
      dropped = try parse("p = { PUSH_LITERAL(\"a\") ~ PUSH_LITERAL(\"b\") ~ DROP{2} }", "p", "")
      Test.eq(dropped.stop, 0)
    end,
    Test.test("POP_ALL on an empty stack matches nothing") do
      tree = try parse("p = { PUSH_LITERAL(\"a\") ~ DROP ~ POP_ALL ~ \"x\" }", "p", "x")
      Test.eq(tree.stop, 1)
    end,
    Test.test("PEEK_ALL on an empty stack matches nothing") do
      tree = try parse("p = { PUSH_LITERAL(\"a\") ~ DROP ~ PEEK_ALL ~ \"x\" }", "p", "x")
      Test.eq(tree.stop, 1)
    end,
    Test.test("a failed POP is rolled back") do
      grammar_text = "p = { PUSH_LITERAL(\"a\") ~ (POP ~ \"z\")? ~ POP }"
      tree = try parse(grammar_text, "p", "a")
      Test.eq(tree.stop, 1)
    end,
    Test.test("a partially failed POP_ALL is rolled back") do
      grammar_text = "p = { PUSH_LITERAL(\"a\") ~ PUSH_LITERAL(\"b\") ~ (POP_ALL ~ \"!\")? ~ \"-\" ~ POP_ALL }"
      tree = try parse(grammar_text, "p", "-ba")
      Test.eq(tree.stop, 3)
    end,
    Test.test("PUSH keeps the whitespace inside the span") do
      grammar_text = "WHITESPACE = _{ \" \" }\np = { PUSH(a ~ b) ~ \"|\" ~ POP }\na = { \"x\" }\nb = { \"y\" }"
      tree = try parse(grammar_text, "p", "x y|x y")
      Test.eq(tree.stop, 7)
    end,
    Test.test("PUSH of an empty match stores an empty string") do
      tree = try parse("p = { PUSH(\"x\"?) ~ \"|\" ~ PEEK_ALL ~ \"?\" }", "p", "|?")
      Test.eq(tree.stop, 2)
    end,
    Test.test("PUSH and POP handle astral characters") do
      text = String.from_code(128512)
      tree = try parse("p = { PUSH(ANY) ~ \"|\" ~ POP }", "p", "#{text}|#{text}")
      Test.eq(tree.stop, 3)
    end,
    Test.test("an unbounded repetition that only pops keeps going") do
      # The loop drains both values, so the POP that follows has nothing to match;
      # stopping after the first zero-width iteration would have accepted it.
      grammar_text = "p = { PUSH_LITERAL(\"a\") ~ PUSH_LITERAL(\"b\") ~ (DROP | \"x\")* ~ POP }"
      Test.error?(parse(grammar_text, "p", "a"))
    end,
    Test.test("a DROP repetition drains the stack") do
      tree = try parse("p = { PUSH_LITERAL(\"a\") ~ PUSH_LITERAL(\"b\") ~ DROP* ~ \"x\" }", "p", "x")
      Test.eq(tree.stop, 1)
    end,
    Test.test("a stack operation inside an atomic rule still works") do
      tree = try parse("p = { item }\nitem = @{ PUSH_LITERAL(\"ab\") ~ \"cd\" ~ POP }", "p", "cdab")
      try Test.eq(tree.children.size, 1)
      Test.eq(Tree.text(tree.children[0], "cdab"), "cdab")
    end,
    Test.test("position counts lines and columns") do
      where = Tree.position("ab\ncd\n", 4)
      try Test.eq(where.line, 2)
      try Test.eq(where.column, 2)
      Test.eq(where.line_text, "cd")
    end,
  ])
end
