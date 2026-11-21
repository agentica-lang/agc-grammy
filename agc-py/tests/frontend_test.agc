## The `agc-py` frontend tests: parse → AST → scopes → diagnostics, each stage
## refusing before the next starts. The grammar is loaded once in the run
## worker and shared across the fixtures.

import Frontend from "../src/frontend"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

def analyze(compiled: Result[Grammar.Grammar], source: String) -> Result[List[Frontend.Diagnostic]]
  tree = try Frontend.parse_source(compiled.unwrap!, source)
  program = try Frontend.build(tree, source)
  ok(Frontend.resolve(program))
end

def codes(diags: List[Frontend.Diagnostic]) -> List[String] = diags.map { |diag| diag.code }

def span_text(source: String, diag: Frontend.Diagnostic) -> String = source.slice(diag.start, diag.stop - diag.start)

def check_codes(compiled: Result[Grammar.Grammar], source: String) -> Result[List[String]]
  ok(codes(try analyze(compiled, source)))
end

def check(compiled: Result[Grammar.Grammar], source: String) -> Result[Void]
  Frontend.check_source(compiled.unwrap!, "prog.py", source)
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
    Test.test("a clean program resolves with no diagnostics") do
      try Test.ok?(check(compiled, "x: int = 1\nprint(x)\n"))
      Test.ok?(check(compiled, "def add(a: int, b: int) -> int:\n    return a + b\nprint(add(1, 2))\n"))
    end,
    Test.test("shadowing a module name in a function is allowed") do
      try Test.ok?(check(compiled, "x: int = 1\ndef f(x: int) -> int:\n    return x\n"))
      Test.ok?(check(compiled, "x: int = 1\ndef f() -> None:\n    x: int = 2\n"))
    end,
    Test.test("duplicate parameters are rejected at the second name") do
      source = "def f(a: int, a: int) -> int:\n    return a\n"
      diags = try analyze(compiled, source)
      try Test.eq(diags.size, 1)
      diag = List.first(diags)
      try Test.eq(diag.code, "PY-DUPLICATE-BINDING")
      try Test.eq(span_text(source, diag), "a")
      pos = Tree.position(source, diag.start)
      try Test.eq(pos.line, 1)
      Test.eq(pos.column, 15)
    end,
    Test.test("a duplicate module binding is rejected at the second name") do
      source = "x: int = 1\nx: int = 2\n"
      try Test.eq(try check_codes(compiled, source), ["PY-DUPLICATE-BINDING"])
      diags = try analyze(compiled, source)
      diag = List.first(diags)
      try Test.eq(span_text(source, diag), "x")
      pos = Tree.position(source, diag.start)
      try Test.eq(pos.line, 2)
      Test.eq(pos.column, 1)
    end,
    Test.test("unknown names point at the use") do
      source = "x: int = y\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-NAME-UNKNOWN"])
      diag = List.first(diags)
      try Test.eq(span_text(source, diag), "y")
      pos = Tree.position(source, diag.start)
      try Test.eq(pos.line, 1)
      try Test.eq(pos.column, 10)
      Test.assert(
        Frontend.render("prog.py", source, diag).include?("prog.py:1:10 error[PY-NAME-UNKNOWN]"),
        Frontend.render("prog.py", source, diag),
      )
    end,
    Test.test("reserved words cannot be used as names") do
      source = "if = 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-RESERVED-NAME"])
      diag = List.first(diags)
      try Test.eq(span_text(source, diag), "if")
      pos = Tree.position(source, diag.start)
      try Test.eq(pos.line, 1)
      Test.eq(pos.column, 1)
    end,
    Test.test("a keyword as a def name is reserved") do
      source = "def if() -> None:\n    pass\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-RESERVED-NAME"])
      Test.eq(span_text(source, List.first(diags)), "if")
    end,
    Test.test("a keyword as a parameter is reserved") do
      source = "def f(if: int) -> int:\n    return 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-RESERVED-NAME"])
      Test.eq(span_text(source, List.first(diags)), "if")
    end,
    Test.test("a keyword as an import is reserved") do
      source = "import if\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-RESERVED-NAME"])
      Test.eq(span_text(source, List.first(diags)), "if")
    end,
    Test.test("mutual recursion resolves") do
      Test.ok?(check(compiled, "def f() -> None:\n    g()\n\ndef g() -> None:\n    f()\n"))
    end,
    Test.test("a top-level call before its def is unknown") do
      source = "print(f())\ndef f() -> int:\n    return 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-NAME-UNKNOWN"])
      Test.eq(span_text(source, List.first(diags)), "f")
    end,
    Test.test("a body use of a later-bound module variable is unknown") do
      source = "def f() -> None:\n    print(y)\n\ny: int = 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-NAME-UNKNOWN"])
      Test.eq(span_text(source, List.first(diags)), "y")
    end,
    Test.test("an unknown bare annotation is rejected") do
      source = "x: Bad = 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-ANNOTATION-UNKNOWN"])
      Test.eq(span_text(source, List.first(diags)), "Bad")
    end,
    Test.test("an unknown dotted annotation head is rejected") do
      source = "x: nosuch.X = 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-ANNOTATION-UNKNOWN"])
      Test.eq(span_text(source, List.first(diags)), "nosuch")
    end,
    Test.test("a quoted forward reference resolves clean") do
      try Test.ok?(check(compiled, "z: \"Fwd\" = 1\n"))
      try Test.ok?(check(compiled, "x: \"A\" | None = 1\n"))
      Test.ok?(check(compiled, "xs: list[\"Fwd\"] = []\n"))
    end,
    Test.test("a single-quoted forward reference resolves clean") do Test.ok?(check(compiled, "z: 'Fwd' = 1\n")) end,
    Test.test("a bare Any annotation is rejected") do
      source = "x: Any = 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-ANY"])
      Test.eq(span_text(source, List.first(diags)), "Any")
    end,
    Test.test("a typing.Any annotation is rejected") do
      source = "x: typing.Any = 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-ANY"])
      Test.eq(span_text(source, List.first(diags)), "typing.Any")
    end,
    Test.test("check_source renders every failure") do
      case check(compiled, "x = 1\ny = 2\n")
        error(e) ->
          try Test.assert(e.message.include?("prog.py:1:1"), e.message)
          try Test.assert(e.message.include?("prog.py:2:1"), e.message)
          Test.assert(e.message.include?("error[PY-UNTYPED-NAME]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an untyped def masks a generic parse error elsewhere") do
      case check(compiled, "x = = 1\ndef f(x):\n    return x\n")
        error(e) -> Test.assert(e.message.include?("error[PY-UNTYPED-DEF]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("diagnostics sort by start offset across module and body") do
      source = "def f() -> None:\n    print(y)\n\nx = 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-NAME-UNKNOWN", "PY-UNTYPED-NAME"])
      try Test.eq(span_text(source, List.first(diags)), "y")
      try Test.eq(span_text(source, List.first(diags.drop(1))), "x")
      Test.assert(List.first(diags).start < List.first(diags.drop(1)).start, "expected body diag before module diag")
    end,
    Test.test("a bare raise name stays skipped") do Test.ok?(check(compiled, "def f() -> None:\n    raise E\n")) end,
    Test.test("a raise factory call resolves its head") do
      source = "def f() -> None:\n    raise make_error(\"x\")\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-NAME-UNKNOWN"])
      Test.eq(span_text(source, List.first(diags)), "make_error")
    end,
    Test.test("an except-as name stays bound after its handler") do
      Test.ok?(
        check(
          compiled,
          "def f() -> None:\n    try:\n        x: int = 1\n    except ValueError as e:\n        print(e)\n    print(e)\n",
        ),
      )
    end,
    Test.test("a for target may rebind an existing name") do
      Test.ok?(check(compiled, "x: int = 0\nfor x in range(3):\n    print(x)\n"))
    end,
    Test.test("a multi-line untyped def stays a generic engine error") do
      case check(compiled, "def f(\n    x\n):\n    return x\n")
        error(e) -> Test.assert(!e.message.include?("PY-UNTYPED-DEF"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an untyped defaulted parameter points at just the name") do
      source = "def f(x=0) -> int:\n    return x\n"
      found = Frontend.untyped_def(source)
      case found
        some(diag) ->
          try Test.eq(diag.code, "PY-UNTYPED-DEF")
          Test.eq(span_text(source, diag), "x")
        none -> Test.assert(false, "expected a diagnostic")
      end
    end,
    Test.test("an untyped parameter matching the def name points at the parameter") do
      source = "def f(f=0) -> int:\n    return f\n"
      found = Frontend.untyped_def(source)
      case found
        some(diag) ->
          try Test.eq(diag.code, "PY-UNTYPED-DEF")
          try Test.eq(span_text(source, diag), "f")
          Test.eq(diag.start, 6)
        none -> Test.assert(false, "expected a diagnostic")
      end
    end,
    Test.test("an untyped def refuses before resolve") do
      case check(compiled, "def f(x):\n    return y\n")
        error(e) ->
          try Test.assert(e.message.include?("error[PY-UNTYPED-DEF]"), e.message)
          Test.assert(e.message.include?("prog.py:1:1"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a def without a return type is untyped") do
      case check(compiled, "def f(x: int):\n    return x\n")
        error(e) -> Test.assert(e.message.include?("error[PY-UNTYPED-DEF]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an untyped parameter points at the parameter") do
      source = "def f(x) -> int:\n    return x\n"
      found = Frontend.untyped_def(source)
      case found
        some(diag) ->
          try Test.eq(diag.code, "PY-UNTYPED-DEF")
          Test.eq(span_text(source, diag), "x")
        none -> Test.assert(false, "expected a diagnostic")
      end
    end,
    Test.test("a first binding without an annotation is untyped") do
      source = "x = 1\n"
      diags = try analyze(compiled, source)
      try Test.eq(codes(diags), ["PY-UNTYPED-NAME"])
      diag = List.first(diags)
      try Test.eq(span_text(source, diag), "x")
      pos = Tree.position(source, diag.start)
      try Test.eq(pos.line, 1)
      Test.eq(pos.column, 1)
    end,
    Test.test("a reassignment of a declared name is fine") do Test.ok?(check(compiled, "x: int = 1\nx = x + 1\n")) end,
    Test.test("a for target binds without an annotation") do
      Test.ok?(check(compiled, "for i in range(3):\n    print(i)\n"))
    end,
    Test.test("an except-as name binds in the handler") do
      source = "def f() -> None:\n    try:\n        x: int = 1\n    except ValueError as e:\n        print(e)\n"
      Test.ok?(check(compiled, source))
    end,
    Test.test("a raise class is not resolved") do
      source = "def f() -> None:\n    raise ValueError(\"bad\")\n"
      Test.ok?(check(compiled, source))
    end,
    Test.test("build keeps spans and header facts") do
      source = "def add(a: int, b: int) -> int:\n    return a + b\n"
      tree = try Frontend.parse_source(compiled.unwrap!, source)
      program = try Frontend.build(tree, source)
      try Test.eq(program.funcs.size, 1)
      try Test.eq(program.top.size, 0)
      func_def = List.first(program.funcs)
      try Test.eq(func_def.name, "add")
      try Test.eq(func_def.return_type, "int")
      try Test.eq(func_def.params.size, 2)
      try Test.eq(func_def.body.size, 1)
      Test.eq(source.slice(func_def.name_span.start, func_def.name_span.stop - func_def.name_span.start), "add")
    end,
    Test.test("render matches the Agentica diagnostic shape") do
      diag = Frontend.Diagnostic(
        code: "PY-NAME-UNKNOWN",
        message: "unknown name `y`",
        help: some("bind it first, for example `y: int = ...`"),
        start: 9,
        stop: 10,
      )

      Test.eq(
        Frontend.render("prog.py", "x: int = y\n", diag),
        "prog.py:1:10 error[PY-NAME-UNKNOWN]\nunknown name `y`\n\n1 | x: int = y\n  |          ^\n= help: bind it first, for example `y: int = ...`",
      )
    end,
  ])
end
