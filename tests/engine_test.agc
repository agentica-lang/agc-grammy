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
    Test.test("a failure names the start rule and place") do
      case parse("p = { \"a\" }", "p", "x")
        error(e) -> Test.assert(e.message.include?("expected p at line 1, column 1"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
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
