## Issue #24: a `def` annotated `-> Result[T]` is the explicit ripple of the
## subset. `raise` returns the error, and a call to such a def unwraps with
## `try` wherever the caller propagates (an outlined `try` body or another
## Result def), so the error lands in the handler where CPython's exception
## would. The annotation is quoted (`-> "Result[T]"`), the form CPython runs
## as written, so every case is differential: the same Python source runs
## under `python3` and the emitted program's standard output must match it.
##
## Sources stay a few lines each because `agentica test` shares one million
## steps per test (plus one) over the file's tests, the grammar load costs
## about 1.8 million of them and a translate costs roughly 0.2 million per
## source line (as of Agentica 0.35.0).
##
## TODO(agentica#1922): the many small pure tests carry the step budget of
## the translating ones, so their count is tied to it. Drop them (and split
## the file freely) once `agentica test` has a configurable step budget.

import EmitAssign from "../src/emit_assign"
import EmitCtx from "../src/emit_ctx"
import EmitExpr from "../src/emit_expr"
import Grammar from "../../src/grammar"
import Py2Agc from "../src/py2agc"

def ctx_returning(func_ret: String, in_try: Bool) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(source: "", file: "prog.py", scope: {}, func_ret: func_ret, in_try: in_try, next_temp: 0)
end

def mapped(text: String) -> String
  case EmitAssign.map_return(text, {})
    ok(spelled) -> spelled
    error(e) -> e.message
  end
end

# Checks the emitted text with the real backend, then runs it and answers
# the process output.
def check_and_run(text: String, path: String) -> Result[String]
  try File.write_text(path, text)
  proc = try Process.spawn_captured("agentica", ["check", path])
  checked = try Process.output(proc, 30000)
  try Test.assert(checked.stdout.include?("check ok"), checked.stdout + checked.stderr)

  runner = try Process.spawn_captured("agentica", [path])
  ran = try Process.output(runner, 30000)
  ok(ran.stdout)
end

# Translates `source`, runs it beside CPython's own run of the same source and
# answers the output once the two agree. Python prints `True`/`False` where
# the backend prints `true`/`false`, so the comparison ignores case.
def agree(compiled: Grammar.Grammar, source: String, tag: String) -> Result[String]
  py_path = "/tmp/agc_py2agc_resultdef_#{tag}.py"
  try File.write_text(py_path, source)
  runner = try Process.spawn_captured("python3", [py_path])
  ran = try Process.output(runner, 30000)
  text = try Py2Agc.translate(compiled, "prog.py", source)
  got = try check_and_run(text, "/tmp/agc_py2agc_resultdef_#{tag}.agc")
  try Test.eq(got.strip().downcase, ran.stdout.strip().downcase)
  ok(got)
end

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  if System.args() == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    Test.test("Result[T] maps to the backend's fallible signature") do
      try Test.eq(mapped("Result[int]"), "Result[Int]")
      Test.eq(mapped("Result[list[int]]"), "Result[List[Int]]")
    end,
    Test.test("a quoted Result annotation maps the same") do
      try Test.eq(mapped("\"Result[int]\""), "Result[Int]")
      Test.eq(mapped("\"Result[None]\""), "Result[Void]")
    end,
    Test.test("Result[None] maps to Result[Void]") do Test.eq(mapped("Result[None]"), "Result[Void]") end,
    Test.test("a plain return annotation maps as before") do Test.eq(mapped("int"), "Int") end,
    Test.test("a Result parameter annotation refuses") do
      case EmitAssign.map_annotation("Result[int]", {})
        error(e) -> Test.assert(e.message.include?("PY-OUT-OF-SUBSET"), e.message)
        ok(text) -> Test.assert(false, "expected a refusal, mapped #{text}")
      end
    end,
    Test.test("Result[str] maps like its payload") do Test.eq(mapped("Result[str]"), "Result[String]") end,
    Test.test("a nested Result refuses") do
      Test.assert(mapped("Result[Result[int]]").include?("PY-OUT-OF-SUBSET"), mapped("Result[Result[int]]"))
    end,
    Test.test("a Result def propagates, the top level does not") do
      try Test.assert(EmitCtx.propagates?(ctx_returning("Result[Int]", false)), "a Result def propagates")
      try Test.assert(EmitCtx.propagates?(ctx_returning("Result[Void]", true)), "a try body propagates")
      try Test.assert(!EmitCtx.propagates?(ctx_returning("", false)), "the top level does not")
      Test.assert(!EmitCtx.propagates?(ctx_returning("Int", false)), "a plain def does not")
    end,
    Test.test("unwrap_whole reads a Result as its value and leaves other types") do
      wrapped = EmitExpr.unwrap_whole(EmitExpr.Out(code: "f(s)", type: "Result[Bool]", pre: ["py_t0 = s"]))
      try Test.eq(wrapped.code, "(try f(s))")
      try Test.eq(wrapped.type, "Bool")
      try Test.eq(wrapped.pre, ["py_t0 = s"])
      plain = EmitExpr.unwrap_whole(EmitExpr.Out(code: "n", type: "Int", pre: []))
      try Test.eq(plain.code, "n")
      Test.eq(plain.type, "Int")
    end,
    Test.test("raise reaches the caller's handler through two Result defs") do
      source = (
        "def p(s: str) -> \"Result[int]\":\n    if s == \"\":\n        raise ValueError(\"empty\")\n    return int(s)\n" +
        "def t(s: str) -> \"Result[int]\":\n    return p(s) * 2\n" +
        "try:\n    print(t(\"21\"))\n    print(t(\"\"))\nexcept ValueError as e:\n    print(\"caught\", e)\n"
      )

      got = try agree(compiled.unwrap!, source, "raise")
      Test.assert(got.strip() == "42\ncaught empty", got)
    end,
    Test.test("a conversion error propagates the same way") do
      source = (
        "def p(s: str) -> \"Result[int]\":\n    return int(s) + 1\n" +
        "try:\n    print(p(\"4\"))\n    print(p(\"z\"))\nexcept:\n    print(\"bad\")\n"
      )

      got = try agree(compiled.unwrap!, source, "convert")
      Test.assert(got.strip() == "5\nbad", got)
    end,
    Test.test("a call unwraps in a binding, a statement and a loop header") do
      source = (
        "def g(s: str) -> \"Result[list[int]]\":\n    return [int(s), 2]\n" +
        "def u(s: str) -> \"Result[int]\":\n    n: int = 0\n    g(s)\n    for x in g(s):\n        n += x\n    return n\n" +
        "try:\n    print(u(\"3\"))\n    print(u(\"q\"))\nexcept:\n    print(\"bad\")\n"
      )

      got = try agree(compiled.unwrap!, source, "forms")
      Test.assert(got.strip() == "5\nbad", got)
    end,
    Test.test("a Result return passes through and Result[None] ends in success") do
      source = (
        "def a(s: str) -> \"Result[int]\":\n    return int(s)\n" +
        "def b(s: str) -> \"Result[int]\":\n    return a(s)\n" +
        "def c(s: str) -> \"Result[None]\":\n    if s == \"\":\n        return\n    print(b(s))\n" +
        "try:\n    c(\"\")\n    c(\"4\")\n    c(\"z\")\n    print(\"unreached\")\nexcept:\n    print(\"err\")\n"
      )

      got = try agree(compiled.unwrap!, source, "pass")
      Test.assert(got.strip() == "4\nerr", got)
    end,
    Test.test("a Result bool guard unwraps in an if and a while") do
      source = (
        "def lim(s: str) -> \"Result[bool]\":\n    return int(s) > 2\n" +
        "def run(s: str) -> \"Result[None]\":\n    n: int = 0\n    while lim(s):\n        n += 1\n" +
        "        if n > 1:\n            break\n    if lim(s):\n        print(n)\n" +
        "try:\n    run(\"3\")\n    run(\"x\")\nexcept:\n    print(\"bad\")\n"
      )

      got = try agree(compiled.unwrap!, source, "guard")
      Test.assert(got.strip() == "2\nbad", got)
    end,
    Test.test("a handler inside a Result def returns or re-raises") do
      source = (
        "def w(s: str) -> \"Result[int]\":\n    try:\n        print(int(s))\n    except ValueError as e:\n" +
        "        if s == \"q\":\n            raise ValueError(\"wrapped\")\n        return -1\n    return 7\n" +
        "try:\n    print(w(\"5\"))\n    print(w(\"x\"))\n    print(w(\"q\"))\n" +
        "except ValueError as e:\n    print(\"top\", e)\n"
      )

      got = try agree(compiled.unwrap!, source, "handler")
      Test.assert(got.strip() == "5\n7\n-1\ntop wrapped", got)
    end,
    Test.test("an uncaught Result call refuses outside a propagating context") do
      source = "def p(s: str) -> \"Result[int]\":\n    return int(s)\nprint(p(\"1\"))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(e.message.include?("PY-TYPE-MISMATCH"), e.message)
        ok(text) -> Test.assert(false, "expected a refusal, emitted #{text}")
      end
    end,
    # `return g()` with a `None` call runs it and succeeds.
    Test.test("returning a None call under Result[None] runs it then succeeds") do
      source = (
        "def g() -> None:\n    print(\"g\")\n" +
        "def h() -> \"Result[None]\":\n    return g()\n" +
        "try:\n    h()\n    print(\"done\")\nexcept:\n    print(\"err\")\n"
      )

      got = try agree(compiled.unwrap!, source, "voidreturn")
      Test.assert(got.strip() == "g\ndone", got)
    end,
    # An `if`/`else` that returns in every arm closes a Result[None] def: no
    # `ok()` follows it.
    Test.test("a Result[None] def ending in an if with returns in every arm") do
      source = (
        "def k(s: str) -> \"Result[None]\":\n    if s == \"\":\n        return\n    else:\n        print(s)\n        return\n" +
        "try:\n    k(\"\")\n    k(\"a\")\nexcept:\n    print(\"err\")\n"
      )

      got = try agree(compiled.unwrap!, source, "ifends")
      Test.assert(got.strip() == "a", got)
    end,
  ])
end
