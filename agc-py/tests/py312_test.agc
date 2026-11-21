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
      try Test.eq(Tree.find_all(tree, "arg").size, 2)
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
  ])
end
