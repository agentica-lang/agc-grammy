## Phase 2a: the typed-subset grammar parses `def`, annotations and the core.

import Engine from "../../src/engine"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

def parse_py(input: String) -> Result[Tree.Node]
  grammar = try Grammar.load("agc-py/grammars/py312.grammar")
  Engine.run(grammar, "program", input)
end

def annotation_texts(tree: Tree.Node, input: String) -> List[String]
  Tree.find_all(tree, "annotation").map { |node| Tree.text(node, input) }
end

def main() -> Void
  Test.run([
    Test.test("a typed def parses with its params and return") do
      tree = try parse_py("def add(a: int, b: int) -> int:\n    return a + b\n")
      try Test.eq(Tree.find_all(tree, "def_stmt").size, 1)
      try Test.eq(Tree.find_all(tree, "param").size, 2)
      try Test.eq(
        Tree.text(Tree.first(tree, "def_stmt").unwrap!, "def add(a: int, b: int) -> int:\n    return a + b\n"),
        "def add(a: int, b: int) -> int:\n    return a + b",
      )

      Test.eq(annotation_texts(tree, "def add(a: int, b: int) -> int:\n    return a + b\n"), ["int", "int", "int"])
    end,
    Test.test("defaults and a trailing comma parse") do
      tree = try parse_py("def f(a: int, b: str = s, c: float = 1.5,) -> int:\n    return a\n")
      try Test.eq(Tree.find_all(tree, "param").size, 3)
      Test.eq(Tree.find_all(tree, "return_stmt").size, 1)
    end,
    Test.test("keyword args parse in calls") do
      tree = try parse_py("f(x=1, y=s)\n")
      try Test.eq(Tree.find_all(tree, "kwarg").size, 2)
      Test.eq(Tree.text(Tree.first(tree, "call").unwrap!, "f(x=1, y=s)\n"), "f(x=1, y=s)")
    end,
    Test.test("an untyped def is rejected") do Test.error?(parse_py("def f(x):\n    return x\n")) end,
    Test.test("a def without a return type is rejected") do
      Test.error?(parse_py("def f(x: int):\n    return x\n"))
    end,
    Test.test("star args are rejected") do Test.error?(parse_py("def f(*args: int) -> int:\n    return 0\n")) end,
    Test.test("a nested def is rejected") do
      Test.error?(parse_py("def f() -> None:\n    def g() -> None:\n        return\n"))
    end,
    Test.test("annotations cover subscripts, unions and forward refs") do
      input = "x: list[int] = y\ny: X | None\nz: \"Fwd\"\nw: Optional[int]\nv: dict[str, int] = d\nu: int\n"
      tree = try parse_py(input)
      try Test.eq(Tree.find_all(tree, "annotated").size, 6)
      top = Tree.find_all(tree, "annotated").map { |node|
        Tree.text(Tree.first_child(node, "annotation").unwrap!, input)
      }

      Test.eq(top, ["list[int]", "X | None", "\"Fwd\"", "Optional[int]", "dict[str, int]", "int"])
    end,
    Test.test("a bare declaration parses") do
      tree = try parse_py("y: str\n")
      try Test.eq(annotation_texts(tree, "y: str\n"), ["str"])
      Test.eq(Tree.find_all(tree, "annotated").size, 1)
    end,
    Test.test("a ternary parses in a return") do
      tree = try parse_py("def f(a: int) -> int:\n    return a if a else b\n")
      try Test.eq(Tree.find_all(tree, "cond_expr").size, 2)
      Test.eq(
        Tree.text(Tree.first(tree, "cond_expr").unwrap!, "def f(a: int) -> int:\n    return a if a else b\n"),
        "a if a else b",
      )
    end,
    Test.test("a bare return and a pass body parse") do
      tree = try parse_py("def f() -> None:\n    return\ndef g() -> None:\n    pass\n")
      try Test.eq(Tree.find_all(tree, "return_stmt").size, 1)
      Test.eq(Tree.find_all(tree, "pass_stmt").size, 1)
    end,
    Test.test("if and while work in bodies") do
      program = (
        "def f(a: int) -> int:\n    x: int = 0\n    if a > 0:\n        x = a\n    while x > 10:\n        x = x - 1\n    return x\n"
      )

      tree = try parse_py(program)
      try Test.eq(Tree.find_all(tree, "if_stmt").size, 1)
      try Test.eq(Tree.find_all(tree, "while_loop").size, 1)
      Test.eq(Tree.find_all(tree, "return_stmt").size, 1)
    end,
    Test.test("a chained comparison parses as one node") do
      program = "def f(a: int, b: int, c: int) -> int:\n    if a < b < c:\n        return a\n    return b\n"
      tree = try parse_py(program)
      cond = Tree.first(Tree.first(tree, "if_stmt").unwrap!, "comparison").unwrap!

      Test.eq(Tree.text(cond, program), "a < b < c")
    end,
    Test.test("unions cover forward refs on either side") do
      input = "x: \"A\" | None\ny: int | \"Fwd\"\nz: list[\"Fwd\"]\nw: X | Y | Z\n"
      tree = try parse_py(input)
      try Test.eq(Tree.find_all(tree, "annotated").size, 4)
      top = Tree.find_all(tree, "annotated").map { |node|
        Tree.text(Tree.first_child(node, "annotation").unwrap!, input)
      }

      Test.eq(top, ["\"A\" | None", "int | \"Fwd\"", "list[\"Fwd\"]", "X | Y | Z"])
    end,
    Test.test("a dotted annotation parses") do
      tree = try parse_py("x: a.b.C\n")
      Test.eq(annotation_texts(tree, "x: a.b.C\n"), ["a.b.C"])
    end,
    Test.test("elif and else branches parse in a body") do
      program = (
        "def f(a: int) -> int:\n    if a > 0:\n        return a\n    elif a < 0:\n        return b\n    else:\n        return c\n"
      )

      tree = try parse_py(program)
      try Test.eq(Tree.find_all(tree, "if_stmt").size, 1)
      try Test.eq(Tree.find_all(tree, "elif_branch").size, 1)
      try Test.eq(Tree.find_all(tree, "else_branch").size, 1)
      Test.eq(Tree.find_all(tree, "return_stmt").size, 3)
    end,
    Test.test("a comparison call arg is not a kwarg") do
      tree = try parse_py("f(x == 1)\n")
      try Test.eq(Tree.find_all(tree, "kwarg").size, 0)
      Test.eq(Tree.text(Tree.first(tree, "call").unwrap!, "f(x == 1)\n"), "f(x == 1)")
    end,
    Test.test("kwargs come last in calls") do
      tree = try parse_py("f(x, y=1)\n")
      try Test.eq(Tree.find_all(tree, "arg").size, 1)
      try Test.eq(Tree.find_all(tree, "kwarg").size, 1)
      Test.eq(Tree.text(Tree.first(tree, "call").unwrap!, "f(x, y=1)\n"), "f(x, y=1)")
    end,
    Test.test("a positional arg after a kwarg is rejected at the statement") do
      case parse_py("f(x=1, y)\n")
        error(e) ->
          try Test.assert(e.message.include?("line 1, column 1"), e.message)
          Test.assert(e.message.include?("def_stmt"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a nested ternary parses") do
      program = "def f(a: int) -> int:\n    return a if c1 else b if c2 else c3\n"
      tree = try parse_py(program)
      try Test.eq(Tree.find_all(tree, "cond_expr").size, 3)
      Test.eq(Tree.text(Tree.first(tree, "cond_expr").unwrap!, program), "a if c1 else b if c2 else c3")
    end,
    Test.test("empty calls and trailing commas parse") do
      tree = try parse_py("f()\n")
      try Test.eq(Tree.find_all(tree, "call").size, 1)
      tree = try parse_py("f(a,)\n")
      Test.eq(Tree.text(Tree.first(tree, "call").unwrap!, "f(a,)\n"), "f(a,)")
    end,
    Test.test("a missing trailing newline still parses") do
      tree = try parse_py("x: int = 1")
      try Test.eq(Tree.find_all(tree, "annotated").size, 1)
      tree = try parse_py("def f(a: int) -> int:\n    return a")
      Test.eq(Tree.find_all(tree, "return_stmt").size, 1)
    end,
    Test.test("a trailing comment may run to EOF") do
      tree = try parse_py("x: int = 1 # c")
      Test.eq(Tree.find_all(tree, "annotated").size, 1)
    end,
    Test.test("empty and whitespace-only programs are accepted") do
      try Test.ok?(parse_py(""))
      Test.ok?(parse_py("   \n  \n"))
    end,
    Test.test("star-star kwargs are rejected where the arg starts") do
      case parse_py("f(**kw)\n")
        error(e) ->
          try Test.assert(e.message.include?("line 1, column 3"), e.message)
          Test.assert(e.message.include?("kwarg"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
  ])
end
