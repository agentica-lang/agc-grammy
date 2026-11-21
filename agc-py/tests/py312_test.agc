## Typed-subset grammar fixtures for phase 2.

import Engine from "../../src/engine"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

def parse_py(compiled: Result[Grammar.Grammar], input: String) -> Result[Tree.Node]
  Engine.run(compiled.unwrap!, "program", input)
end

def annotation_texts(tree: Tree.Node, input: String) -> List[String]
  Tree.find_all(tree, "annotation").map { |node| Tree.text(node, input) }
end

def node_texts(tree: Tree.Node, name: String, input: String) -> List[String]
  Tree.find_all(tree, name).map { |node| Tree.text(node, input) }
end

def assert_parse_error_at(compiled: Result[Grammar.Grammar], input: String, location: String) -> Result[Void]
  case parse_py(compiled, input)
    error(e) -> Test.assert(e.message.include?(location), e.message)
    ok(_) -> Test.assert(false, "expected an error")
  end
end

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  # Compile only in the run worker and share its result across the fixtures.
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  args = System.args()
  if args != ["--agentica-test", "list"] and args != ["--agentica-test", "run"]
    IO.warn("expected Agentica test worker args [--agentica-test, list|run], got #{args.inspect}")
    System.exit(1)
  end

  if args == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    Test.test("a typed def parses with its params and return") do
      tree = try parse_py(compiled, "def add(a: int, b: int) -> int:\n    return a + b\n")
      try Test.eq(Tree.find_all(tree, "def_stmt").size, 1)
      try Test.eq(Tree.find_all(tree, "param").size, 2)
      try Test.eq(
        Tree.text(Tree.first(tree, "def_stmt").unwrap!, "def add(a: int, b: int) -> int:\n    return a + b\n"),
        "def add(a: int, b: int) -> int:\n    return a + b",
      )

      Test.eq(annotation_texts(tree, "def add(a: int, b: int) -> int:\n    return a + b\n"), ["int", "int", "int"])
    end,
    Test.test("defaults and a trailing comma parse") do
      tree = try parse_py(compiled, "def f(a: int, b: str = s, c: float = 1.5,) -> int:\n    return a\n")
      try Test.eq(Tree.find_all(tree, "param").size, 3)
      Test.eq(Tree.find_all(tree, "return_stmt").size, 1)
    end,
    Test.test("keyword args parse in calls") do
      tree = try parse_py(compiled, "f(x=1, y=s)\n")
      try Test.eq(Tree.find_all(tree, "kwarg").size, 2)
      Test.eq(Tree.text(Tree.first(tree, "call").unwrap!, "f(x=1, y=s)\n"), "f(x=1, y=s)")
    end,
    Test.test("an untyped def is rejected") do Test.error?(parse_py(compiled, "def f(x):\n    return x\n")) end,
    Test.test("a def without a return type is rejected") do
      Test.error?(parse_py(compiled, "def f(x: int):\n    return x\n"))
    end,
    Test.test("star args are rejected") do
      Test.error?(parse_py(compiled, "def f(*args: int) -> int:\n    return 0\n"))
    end,
    Test.test("a nested def is rejected") do
      Test.error?(parse_py(compiled, "def f() -> None:\n    def g() -> None:\n        return\n"))
    end,
    Test.test("annotations cover subscripts, unions and forward refs") do
      input = "x: list[int] = y\ny: X | None\nz: \"Fwd\"\nw: Optional[int]\nv: dict[str, int] = d\nu: int\n"
      tree = try parse_py(compiled, input)
      try Test.eq(Tree.find_all(tree, "annotated").size, 6)
      top = Tree.find_all(tree, "annotated").map { |node|
        Tree.text(Tree.first_child(node, "annotation").unwrap!, input)
      }

      Test.eq(top, ["list[int]", "X | None", "\"Fwd\"", "Optional[int]", "dict[str, int]", "int"])
    end,
    Test.test("a bare declaration parses") do
      tree = try parse_py(compiled, "y: str\n")
      try Test.eq(annotation_texts(tree, "y: str\n"), ["str"])
      Test.eq(Tree.find_all(tree, "annotated").size, 1)
    end,
    Test.test("a type alias parses inside a def body") do
      program = "def f() -> None:\n    type Alias = int\n    pass\n"
      tree = try parse_py(compiled, program)
      Test.eq(Tree.find_all(tree, "type_alias").size, 1)
    end,
    Test.test("a ternary parses in a return") do
      tree = try parse_py(compiled, "def f(a: int) -> int:\n    return a if a else b\n")
      try Test.eq(Tree.find_all(tree, "cond_expr").size, 2)
      Test.eq(
        Tree.text(Tree.first(tree, "cond_expr").unwrap!, "def f(a: int) -> int:\n    return a if a else b\n"),
        "a if a else b",
      )
    end,
    Test.test("a bare return and a pass body parse") do
      tree = try parse_py(compiled, "def f() -> None:\n    return\ndef g() -> None:\n    pass\n")
      try Test.eq(Tree.find_all(tree, "return_stmt").size, 1)
      Test.eq(Tree.find_all(tree, "pass_stmt").size, 1)
    end,
    Test.test("if and while work in bodies") do
      program = (
        "def f(a: int) -> int:\n    x: int = 0\n    if a > 0:\n        x = a\n    while x > 10:\n        x = x - 1\n    return x\n"
      )

      tree = try parse_py(compiled, program)
      try Test.eq(Tree.find_all(tree, "if_stmt").size, 1)
      try Test.eq(Tree.find_all(tree, "while_loop").size, 1)
      Test.eq(Tree.find_all(tree, "return_stmt").size, 1)
    end,
    Test.test("a chained comparison parses as one node") do
      program = "def f(a: int, b: int, c: int) -> int:\n    if a < b < c:\n        return a\n    return b\n"
      tree = try parse_py(compiled, program)
      cond = Tree.first(Tree.first(tree, "if_stmt").unwrap!, "comparison").unwrap!

      Test.eq(Tree.text(cond, program), "a < b < c")
    end,
    Test.test("unions cover forward refs on either side") do
      input = "x: \"A\" | None\ny: int | \"Fwd\"\nz: list[\"Fwd\"]\nw: X | Y | Z\n"
      tree = try parse_py(compiled, input)
      try Test.eq(Tree.find_all(tree, "annotated").size, 4)
      top = Tree.find_all(tree, "annotated").map { |node|
        Tree.text(Tree.first_child(node, "annotation").unwrap!, input)
      }

      Test.eq(top, ["\"A\" | None", "int | \"Fwd\"", "list[\"Fwd\"]", "X | Y | Z"])
    end,
    Test.test("a dotted annotation parses") do
      tree = try parse_py(compiled, "x: a.b.C\n")
      Test.eq(annotation_texts(tree, "x: a.b.C\n"), ["a.b.C"])
    end,
    Test.test("elif and else branches parse in a body") do
      program = (
        "def f(a: int) -> int:\n    if a > 0:\n        return a\n    elif a < 0:\n        return b\n    else:\n        return c\n"
      )

      tree = try parse_py(compiled, program)
      try Test.eq(Tree.find_all(tree, "if_stmt").size, 1)
      try Test.eq(Tree.find_all(tree, "elif_branch").size, 1)
      try Test.eq(Tree.find_all(tree, "else_branch").size, 1)
      Test.eq(Tree.find_all(tree, "return_stmt").size, 3)
    end,
    Test.test("a comparison call arg is not a kwarg") do
      tree = try parse_py(compiled, "f(x == 1)\n")
      try Test.eq(Tree.find_all(tree, "kwarg").size, 0)
      Test.eq(Tree.text(Tree.first(tree, "call").unwrap!, "f(x == 1)\n"), "f(x == 1)")
    end,
    Test.test("kwargs come last in calls") do
      tree = try parse_py(compiled, "f(x, y=1)\n")
      try Test.eq(Tree.find_all(tree, "arg").size, 1)
      try Test.eq(Tree.find_all(tree, "kwarg").size, 1)
      Test.eq(Tree.text(Tree.first(tree, "call").unwrap!, "f(x, y=1)\n"), "f(x, y=1)")
    end,
    Test.test("a positional arg after a kwarg is rejected at the arg") do
      case parse_py(compiled, "f(x=1, y)\n")
        error(e) ->
          try Test.assert(e.message.include?("line 1, column 8"), e.message)
          Test.assert(e.message.include?("kwarg"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("positional args cannot resume in a mixed call") do
      Test.error?(parse_py(compiled, "f(x, y=1, z)\n"))
    end,
    Test.test("a nested ternary parses") do
      program = "def f(a: int) -> int:\n    return a if c1 else b if c2 else c3\n"
      tree = try parse_py(compiled, program)
      try Test.eq(Tree.find_all(tree, "cond_expr").size, 3)
      Test.eq(Tree.text(Tree.first(tree, "cond_expr").unwrap!, program), "a if c1 else b if c2 else c3")
    end,
    Test.test("empty calls and trailing commas parse") do
      tree = try parse_py(compiled, "f()\n")
      try Test.eq(Tree.find_all(tree, "call").size, 1)
      tree = try parse_py(compiled, "f(a,)\n")
      Test.eq(Tree.text(Tree.first(tree, "call").unwrap!, "f(a,)\n"), "f(a,)")
    end,
    Test.test("a missing trailing newline still parses") do
      tree = try parse_py(compiled, "x: int = 1")
      try Test.eq(Tree.find_all(tree, "annotated").size, 1)
      tree = try parse_py(compiled, "def f(a: int) -> int:\n    return a")
      Test.eq(Tree.find_all(tree, "return_stmt").size, 1)
    end,
    Test.test("a trailing comment may run to EOF") do
      tree = try parse_py(compiled, "x: int = 1 # c")
      Test.eq(Tree.find_all(tree, "annotated").size, 1)
    end,
    Test.test("empty and whitespace-only programs are accepted") do
      try Test.ok?(parse_py(compiled, ""))
      Test.ok?(parse_py(compiled, "   \n  \n"))
    end,
    Test.test("star-star kwargs are rejected where the arg starts") do
      case parse_py(compiled, "f(**kw)\n")
        error(e) ->
          try Test.assert(e.message.include?("line 1, column 3"), e.message)
          Test.assert(e.message.include?("kwarg"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("lists and dicts parse as literals") do
      program = "a = [1, -2, x]\nb = []\nc = {\"k\": v,}\nd = {}\n"
      tree = try parse_py(compiled, program)
      lists = node_texts(tree, "list_lit", program)
      try Test.eq(lists, ["[1, -2, x]", "[]"])
      dicts = node_texts(tree, "dict_lit", program)
      try Test.eq(dicts, ["{\"k\": v,}", "{}"])
      Test.eq(Tree.find_all(tree, "dict_entry").size, 1)
    end,
    Test.test("literals chain like names") do
      program = "e = [1, 2][0]\nf = {\"k\": 1}[\"k\"]\ng = \"sep\".join(xs)\n"
      tree = try parse_py(compiled, program)
      try Test.eq(Tree.find_all(tree, "list_lit").size, 1)
      try Test.eq(Tree.find_all(tree, "dict_lit").size, 1)
      try Test.eq(Tree.find_all(tree, "index").size, 2)
      Test.eq(node_texts(tree, "call_trailer", program), ["(xs)"])
    end,
    Test.test("calls, attributes and indexes chain in source order") do
      program = "x = f(a)[0].y[1][2]\ny = d[\"key\"]\nz = xs[-1]\nw = a.b.c\nmath.sqrt(x)\n"
      tree = try parse_py(compiled, program)
      try Test.eq(node_texts(tree, "call", program), ["f(a)", "math.sqrt(x)"])
      try Test.eq(node_texts(tree, "attr", program), ["a.b.c", "math.sqrt"])
      try Test.eq(node_texts(tree, "attr_trailer", program), [".y"])
      try Test.eq(Tree.first(tree, "attr_trailer").unwrap!.children.size, 0)
      Test.eq(node_texts(tree, "index", program), ["[0]", "[1]", "[2]", "[\"key\"]", "[-1]"])
    end,
    Test.test("nested indexes do not retry the lower expression as a slice") do
      program = "y = x" + "[x" * 10 + "]" * 10
      tree = try parse_py(compiled, program)
      Test.eq(Tree.find_all(tree, "index").size, 10)
    end,
    Test.test("slices accept optional and dynamic bounds") do
      program = "a = xs[0:2]\nb = xs[a:b]\nc = xs[a:]\nd = xs[:b]\ne = xs[:]\nf = xs[-a:b]\n"
      tree = try parse_py(compiled, program)
      try Test.eq(node_texts(tree, "index", program), ["[0:2]", "[a:b]", "[a:]", "[:b]", "[:]", "[-a:b]"])
      Test.eq(node_texts(tree, "slice", program), [":2", ":b", ":", ":b", ":", ":b"])
    end,
    Test.test("slices reject explicit negative bounds and steps") do
      try Test.error?(parse_py(compiled, "x = xs[-1:b]"))
      try Test.error?(parse_py(compiled, "x = xs[a:-1]"))
      try Test.error?(parse_py(compiled, "x = xs[:(-1)]"))
      try Test.error?(parse_py(compiled, "x = xs[::2]"))
      Test.error?(parse_py(compiled, "x = xs[a:b:c]"))
    end,
    # TODO(PY-SLICE): the grammar itself rejects stepped/literal-negative
    # slices at parse time; the frontend fallback owns the `PY-SLICE` code.
    Test.test("raw grammar still rejects stepped slices (PY-SLICE owner is frontend)") do
      Test.error?(parse_py(compiled, "x = xs[1:2:3]\n"))
    end,
    Test.test("plain, raw and escaped strings parse") do
      program = (
        "x: str = \"a\\n\\r\\t\\\\\\\"\\'\\0\\a\\b\\f\\v\\x41\\u0041\"\n" +
        "y: str = 'sq'\n" +
        "r: str = r\"a\\nb\"\n" +
        "s: str = r'c\\td'\n"
      )

      tree = try parse_py(compiled, program)
      texts = node_texts(tree, "text", program)
      Test.eq(texts, ["\"a\\n\\r\\t\\\\\\\"\\'\\0\\a\\b\\f\\v\\x41\\u0041\"", "'sq'", "r\"a\\nb\"", "r'c\\td'"])
    end,
    Test.test("f-strings interpolate holes and triple-quoted forms span lines") do
      program = "x: str = f\"hi {name}!\"\ny: str = f\"{{x}}\"\nz: str = \"\"\"a\nb\"\"\"\nw: str = '''q'''\n"
      tree = try parse_py(compiled, program)
      texts = node_texts(tree, "text", program)
      try Test.eq(texts, ["f\"hi {name}!\"", "f\"{{x}}\"", "\"\"\"a\nb\"\"\"", "'''q'''"])
      try Test.eq(Tree.find_all(tree, "hole").size, 1)
      Test.eq(Tree.text(Tree.first(tree, "hole").unwrap!, program), "{name}")
    end,
    Test.test("only triple-quoted raw strings allow backslash-newline") do
      try Test.error?(parse_py(compiled, "x = r\"a\\\nb\"\n"))
      try Test.error?(parse_py(compiled, "x = r'a\\\nb'\n"))
      program = "x = r\"\"\"a\\\nb\"\"\"\ny = r'''a\\\nb'''\n"
      tree = try parse_py(compiled, program)
      Test.eq(node_texts(tree, "text", program), ["r\"\"\"a\\\nb\"\"\"", "r'''a\\\nb'''"])
    end,
    Test.test("rejected string forms fail to parse") do
      try Test.error?(parse_py(compiled, "x: str = \"a\\N{BULLET}b\"\n"))
      try Test.error?(parse_py(compiled, "x: str = b\"hi\"\n"))
      try Test.error?(parse_py(compiled, "x: str = \"\\U0001F600\"\n"))
      try Test.error?(parse_py(compiled, "x: str = \"a\\x4g\"\n"))
      try Test.error?(parse_py(compiled, "x: str = \"a\\u123\"\n"))
      Test.error?(parse_py(compiled, "x: str = \"a\\"))
    end,
    Test.test("combined and unicode string prefixes are outside the subset") do
      try Test.error?(parse_py(compiled, "x = rf\"hi\""))
      try Test.error?(parse_py(compiled, "x = fr\"hi\""))
      try Test.error?(parse_py(compiled, "x = rF\"hi\""))
      Test.error?(parse_py(compiled, "x = u\"hi\""))
    end,
    Test.test("numbers cover bases, underscores, exponents and dot forms") do
      program = (
        "a: int = 0xFF\n" +
        "b: int = 0o17\n" +
        "c: int = 0b101\n" +
        "d: int = 1_000\n" +
        "e: float = 1e10\n" +
        "f: float = 1.5e-3\n" +
        "g: float = 1.\n" +
        "h: float = .5\n" +
        "i: int = 0xF_F\n" +
        "j: float = 1E+10\n"
      )

      tree = try parse_py(compiled, program)
      numbers = node_texts(tree, "number", program)
      Test.eq(numbers, ["0xFF", "0o17", "0b101", "1_000", "1e10", "1.5e-3", "1.", ".5", "0xF_F", "1E+10"])
    end,
    Test.test("numeric separators and leading zeroes follow the literal form") do
      program = "a = 0x_FF\nb = 0_0\nc = 0.5\nd = 0e2\n"
      tree = try parse_py(compiled, program)
      try Test.eq(node_texts(tree, "number", program), ["0x_FF", "0_0", "0.5", "0e2"])
      try Test.error?(parse_py(compiled, "x = 01"))
      try Test.error?(parse_py(compiled, "x = 00_0"))
      try Test.error?(parse_py(compiled, "x = 01.0"))
      try Test.error?(parse_py(compiled, "x = 01e2"))
      try Test.error?(parse_py(compiled, "x = 1__0"))
      Test.error?(parse_py(compiled, "x = 0b2"))
    end,
    Test.test("for loops parse lists, ranges and string calls with break and next") do
      program = "for x in [1, 2]:\n    break\nfor i in range(3):\n    next\nfor c in str(1):\n    pass\n"
      tree = try parse_py(compiled, program)
      try Test.eq(Tree.find_all(tree, "for_loop").size, 3)
      try Test.eq(Tree.find_all(tree, "list_lit").size, 1)
      try Test.eq(node_texts(tree, "call", program), ["range(3)", "str(1)"])
      try Test.eq(Tree.find_all(tree, "break_stmt").size, 1)
      try Test.eq(Tree.find_all(tree, "next_stmt").size, 1)
      Test.eq(Tree.find_all(tree, "pass_stmt").size, 1)
    end,
    Test.test("try parses exactly one bare, named or bound handler") do
      program = (
        "def f() -> None:\n    try:\n        pass\n    except:\n        pass\n    try:\n        pass\n    except E:\n        pass\n    try:\n        pass\n    except E as e:\n        pass\n"
      )

      tree = try parse_py(compiled, program)
      try Test.eq(Tree.find_all(tree, "try_stmt").size, 3)
      try Test.eq(Tree.find_all(tree, "except_handler").size, 3)
      try Test.eq(Tree.find_all(tree, "pass_stmt").size, 6)
      Test.eq(node_texts(tree, "name", program), ["f", "E", "E", "e"])
    end,
    Test.test("assert parses with and without a message") do
      program = "assert True\nassert x > 0, \"positive only\"\n"
      tree = try parse_py(compiled, program)
      try Test.eq(Tree.find_all(tree, "assert_stmt").size, 2)
      Test.eq(Tree.find_all(tree, "text").size, 1)
    end,
    Test.test("raise parses a call or a name") do
      program = "raise E(\"msg\")\nraise E\n"
      tree = try parse_py(compiled, program)
      try Test.eq(Tree.find_all(tree, "raise_stmt").size, 2)
      try Test.eq(Tree.find_all(tree, "call").size, 1)
      Test.eq(node_texts(tree, "name", program), ["E", "E"])
    end,
    Test.test("break and next cannot be call statements") do
      try Test.error?(parse_py(compiled, "break(1)"))
      Test.error?(parse_py(compiled, "next(it)"))
    end,
    Test.test("for rejects unpacking and attribute targets") do
      try assert_parse_error_at(compiled, "for a, b in xs:\n    pass\n", "line 1, column 1")
      assert_parse_error_at(compiled, "for x.y in xs:\n    pass\n", "line 1, column 1")
    end,
    Test.test("with is rejected") do
      assert_parse_error_at(compiled, "with open(p):\n    pass\n", "line 1, column 1")
    end,
    Test.test("try without a handler is rejected at EOF") do
      assert_parse_error_at(compiled, "try:\n    pass\n", "line 3, column 1")
    end,
    Test.test("loop else is rejected") do
      assert_parse_error_at(compiled, "for x in xs:\n    pass\nelse:\n    pass\n", "line 3, column 6")
    end,
    Test.test("finally without a handler is rejected") do
      assert_parse_error_at(compiled, "try:\n    pass\nfinally:\n    pass\n", "line 3, column 1")
    end,
    Test.test("finally after a handler is rejected") do
      assert_parse_error_at(compiled, "try:\n    pass\nexcept:\n    pass\nfinally:\n    pass\n", "line 5, column 9")
    end,
    Test.test("try else is rejected") do
      assert_parse_error_at(compiled, "try:\n    pass\nexcept:\n    pass\nelse:\n    pass\n", "line 5, column 6")
    end,
    Test.test("two handlers is rejected") do
      assert_parse_error_at(compiled, "try:\n    pass\nexcept E:\n    pass\nexcept F:\n    pass\n", "line 5, column 1")
    end,
    Test.test("bare raise is rejected") do assert_parse_error_at(compiled, "raise\n", "line 1, column 6") end,
    Test.test("raise from is rejected") do
      assert_parse_error_at(compiled, "raise E from cause\n", "line 1, column 9")
    end,
    Test.test("bare decorator is rejected") do
      assert_parse_error_at(compiled, "@decorate\ndef f() -> None:\n    pass\n", "line 1, column 1")
    end,
    Test.test("call decorator is rejected") do
      assert_parse_error_at(compiled, "@decorate(1)\ndef f() -> None:\n    pass\n", "line 1, column 1")
    end,
    Test.test("continue keyword is rejected") do
      assert_parse_error_at(compiled, "for x in xs:\n    continue\n", "line 2, column 5")
    end,
    Test.test("joined lines leave the next branch chain at its own indentation") do
      input = (
        "def f() -> None:\n    print(\n1, # a continued argument can start at column one\n    )\n    if True:\n        print(\n            2,\n)\n    elif False:\n        pass\n    else:\n        pass\n    print(3)\n"
      )

      tree = try parse_py(compiled, input)
      try Test.eq(
        node_texts(tree, "call", input),
        ["print(\n1, # a continued argument can start at column one\n    )", "print(\n            2,\n)", "print(3)"],
      )

      try Test.eq(Tree.find_all(tree, "elif_branch").size, 1)
      Test.eq(Tree.find_all(tree, "else_branch").size, 1)
    end,
    Test.test("match and case remain soft identifiers") do
      input = "match = 1\ncase: int = match\nx.match\nmatch(x)\n"
      tree = try parse_py(compiled, input)
      try Test.eq(node_texts(tree, "assign", input), ["match = 1"])
      try Test.eq(node_texts(tree, "attr", input), ["x.match"])
      Test.eq(node_texts(tree, "call_stmt", input), ["match(x)"])
    end,
    Test.test("match and case headers fail at the soft keyword") do
      try assert_parse_error_at(compiled, "match x:\n    case 1:\n        pass\n", "line 1, column 1")
      try assert_parse_error_at(compiled, "case ...:\n    pass\n", "line 1, column 1")
      assert_parse_error_at(compiled, "if True:\n    match x:\n        pass\n", "line 2, column 5")
    end,
    Test.test("powers bind inside unary signs and associate on the right") do
      input = "x = -2**3**-4 // 5\n"
      tree = try parse_py(compiled, input)
      outer = Tree.first(tree, "power").unwrap!
      try Test.eq(Tree.text(outer, input), "**3**-4")
      try Test.eq(node_texts(outer, "power", input), ["**-4"])
      Test.eq(node_texts(tree, "minus", input), ["-2**3**-4", "-4"])
    end,
  ])
end
