## Issue #24 regressions: `Result` values in strict and lazy expression
## positions inside an outlined `try`. A directly `Result[T]`-typed operand
## unwraps inline as `(try ...)`, so it evaluates once, in source order, and
## Python's laziness survives: `g() + int(h())` runs `g` first, a chained
## comparison never runs its tail once a link is false, and an `and`/`or`
## tail or the untaken ternary arm stays unevaluated. The end-to-end cases
## are differential: the same Python source runs under `python3` and the
## emitted program's standard output must match it. The rest check the
## emitter seam, where a fragment costs a parse instead of a translation.
##
## `agentica test` shares one million steps per test (plus one) over the
## file's tests. As of Agentica 0.35.0, loading the grammar costs about 1.8
## million of them, one small `translate` about 1.2 million and one
## expression parse about 0.4 million. The file translates in four tests and
## each of the rest parses one fragment.

import EmitExpr from "../src/emit_expr"
import Engine from "../../src/engine"
import Grammar from "../../src/grammar"
import Py2Agc from "../src/py2agc"
import Tree from "../../src/tree"

# The value node of a one-expression program (`py_tmp = <expr>`).
def parse_expr(compiled: Grammar.Grammar, expr: String) -> Result[Tree.Node]
  source = "py_tmp = #{expr}\n"
  tree = try Engine.run(compiled, "program", source)
  assigns = Tree.find_all(tree, "assign")
  return error("no assign in #{expr}") if assigns.empty?

  ok(List.last(List.first(assigns).children))
end

# Emits `expr` as the expression lane does, inside or outside a `try` body.
def emit_expr(compiled: Grammar.Grammar, expr: String, in_try: Bool) -> Result[EmitExpr.Out]
  node = try parse_expr(compiled, expr)
  EmitExpr.emit_with(node, "py_tmp = #{expr}\n", {"s": "String"}, {}, in_try)
end

# `emit_expr` inside the outlined `try` helper.
def emit_in_try(compiled: Grammar.Grammar, expr: String) -> Result[EmitExpr.Out] = emit_expr(compiled, expr, true)

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

# Translates `source` and runs it beside CPython's own run of the same
# source, answering the backend's output once the two agree. Python prints
# `True` and `False` where the backend prints `true`/`false`, so the
# comparison ignores case; every fixture prints lowercase text otherwise.
def agree(compiled: Grammar.Grammar, source: String, tag: String) -> Result[String]
  py_path = "/tmp/agc_py2agc_diff_#{tag}.py"
  try File.write_text(py_path, source)
  runner = try Process.spawn_captured("python3", [py_path])
  ran = try Process.output(runner, 30000)
  text = try translate_text(compiled, source)
  got = try check_and_run(text, "/tmp/agc_py2agc_diff_#{tag}.agc")
  try Test.eq(got.strip().downcase, ran.stdout.strip().downcase)
  ok(got)
end

# Spells `#{code}` without writing it in a literal (the compiler reads `"#{"`
# as the start of an interpolation).
def interp(code: String) -> String = "#" + "{" + code + "}"

# The emitted program for `source`.
def translate_text(compiled: Grammar.Grammar, source: String) -> Result[String]
  Py2Agc.translate(compiled, "prog.py", source)
end

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  if System.args() == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    # The two bugs this slice fixes. `int(h())` used to hoist to a temp line
    # before the sum (so `g()` ran after `h()`), and a chained comparison
    # used to hoist its tail with the middle operand (so `int("bad")` ran
    # even once `5 < 1` had already decided). Both are three operands with a
    # middle call, which must evaluate exactly once.
    Test.test("source order and chained laziness match CPython") do
      source = (
        "def g() -> int:\n    print(\"g\")\n    return 1\n\n" +
        "def h() -> str:\n    print(\"h\")\n    return \"41\"\n\n" +
        "try:\n    v: int = g() + int(h())\n    print(v)\n" +
        "    w: bool = 5 < g() < int(\"bad\")\n    print(w)\nexcept:\n    print(0)\n"
      )

      got = try agree(compiled.unwrap!, source, "order")
      Test.assert(got.strip() == "g\nh\n42\ng\nfalse", got)
    end,
    # Only the selected ternary arm runs: the `then` arm unwraps when it is
    # picked, and the `else` arm holding a bad conversion never runs when it
    # is not (the lowering seeds no temp with it).
    Test.test("both ternary arms stay lazy like CPython") do
      source = (
        "on: bool = True\ntry:\n    a: int = int(\"5\") if on else 0\n" +
        "    b: int = 0 if on else int(\"bad\")\n    print(f\"{a}{b}\")\nexcept:\n    print(\"caught\")\n"
      )

      got = try agree(compiled.unwrap!, source, "ternary")
      Test.assert(got.strip() == "50", got)
    end,
    # A hole and an augmented assignment are both value bindings; CPython
    # answers `5-6` and then raises on the conversion, which the handler
    # catches, exactly like the emitted program.
    Test.test("a hole and an augmented assignment match CPython") do
      source = (
        "a: str = \"5\"\ntry:\n    x: int = 1\n    x += int(a)\n" +
        "    print(f\"{int(a)}-{x}\")\n    y: int = int(\"bad\")\n    print(y)\nexcept:\n    print(1)\n"
      )

      got = try agree(compiled.unwrap!, source, "holes")
      Test.assert(got.strip() == "5-6\n1", got)
    end,
    # Every strict position keeps the unwrap in place: one test per position
    # keeps each inside the file's shared step budget, and the emitted text
    # is the whole assertion (a parse, not a translation, per case).
    Test.test("a sum operand unwraps inline inside try") do
      sum = try emit_in_try(compiled.unwrap!, "int(s) + 1")
      try Test.eq(sum.code, "(try s.to_i) + 1")
      try Test.eq(sum.type, "Int")
      Test.assert(sum.pre.empty?, sum.pre.join("\n"))
    end,
    Test.test("a compare operand unwraps inline inside try") do
      cmp = try emit_in_try(compiled.unwrap!, "int(s) == 5")
      try Test.eq(cmp.code, "(try s.to_i) == 5")
      Test.assert(cmp.pre.empty?, cmp.pre.join("\n"))
    end,
    Test.test("a list element unwraps inline inside try") do
      xs = try emit_in_try(compiled.unwrap!, "[int(s), 2]")
      try Test.eq(xs.code, "[(try s.to_i), 2]")
      Test.assert(xs.pre.empty?, xs.pre.join("\n"))
    end,
    Test.test("a dict value unwraps inline inside try") do
      d = try emit_in_try(compiled.unwrap!, "{\"k\": int(s)}")
      try Test.eq(d.code, "{\"k\": (try s.to_i)}")
      Test.assert(d.pre.empty?, d.pre.join("\n"))
    end,
    # A later hole that needs a temp line (a chained comparison's middle)
    # hoists every earlier inline call in front of it, so the calls run in
    # hole order like CPython.
    Test.test("f-string holes run in hole order when a later hole hoists") do
      source = (
        "def tag(n: int) -> int:\n    print(n)\n    return n\n\n" +
        "def g() -> int:\n    print(\"g\")\n    return 1\n\n" +
        "s: str = f\"{g()}{1 < tag(20) < 30}\"\nprint(s)\n"
      )

      got = try agree(compiled.unwrap!, source, "holeorder")
      Test.assert(got.strip() == "g\n20\n1true", got)
    end,
    # Two holes in one f-string unwrap inline, in hole order, with no temp
    # line that could reorder them.
    Test.test("f-string holes unwrap inline in hole order") do
      holes = try emit_in_try(compiled.unwrap!, "f\"{int(s)}-{int(s)}\"")
      want = "\"" + interp("(try s.to_i)") + "-" + interp("(try s.to_i)") + "\""
      try Test.eq(holes.code, want)
      Test.assert(holes.pre.empty?, holes.pre.join("\n"))
    end,
    # A lazy tail keeps the unwrap inside its own text: no temp line runs it
    # early, and the operand still unwraps where it sits.
    Test.test("a lazy and or tail unwraps inline") do
      tail = try emit_in_try(compiled.unwrap!, "True and int(s) > 0")
      try Test.eq(tail.code, "true and (try s.to_i) > 0")
      Test.assert(tail.pre.empty?, tail.pre.join("\n"))
    end,
    # `print` interpolates its argument, so the unwrap lives in the hole.
    Test.test("print interpolates an inline unwrap inside try") do
      printed = try emit_in_try(compiled.unwrap!, "print(int(s))")
      try Test.eq(printed.code, "puts(\"" + interp("(try s.to_i)") + "\")")
      Test.assert(printed.pre.empty?, printed.pre.join("\n"))
    end,
    # The ternary keeps one temp per arm inside a `case` value, so each arm
    # runs only when the guard selects it and a `Result` arm is no longer a
    # refusal.
    Test.test("the ternary lowers to a case value with lazy arms") do
      arm = try emit_in_try(compiled.unwrap!, "int(s) if True else 0")
      try Test.eq(arm.code, "py_t0")
      try Test.eq(arm.type, "Int")
      Test.eq(arm.pre, ["py_t0 = case true", "  true ->", "    (try s.to_i)", "  _ ->", "    0", "end"])
    end,
    # Outside `try` the compound refuses: nothing would catch the operand's
    # error, and `Result + Int` has no backend form.
    Test.test("an uncaught compound refuses outside try") do
      case emit_expr(compiled.unwrap!, "int(s) + 1", false)
        error(e) ->
          try Test.assert(e.message.include?("PY-TYPE-MISMATCH"), e.message)
          Test.assert(e.message.include?("found Result[Int] and Int"), e.message)
        ok(out) -> Test.assert(false, "expected a refusal, emitted #{out.code}")
      end
    end,
    # Outside `try` nothing catches the hole's error, so interpolating the
    # `Result` (`ok(5)`) is refused instead.
    Test.test("an uncaught f-string hole refuses outside try") do
      case emit_expr(compiled.unwrap!, "f\"{int(s)}\"", false)
        error(e) ->
          try Test.assert(e.message.include?("PY-TYPE-MISMATCH"), e.message)
          Test.assert(e.message.include?("f-string hole"), e.message)
        ok(out) -> Test.assert(false, "expected a refusal, emitted #{out.code}")
      end
    end,
    # A comparison has no backend form on a `Result`, so outside `try` it
    # refuses at the link instead of folding to the constant `false`.
    Test.test("an uncaught comparison operand refuses outside try") do
      case emit_expr(compiled.unwrap!, "int(s) == 5", false)
        error(e) ->
          try Test.assert(e.message.include?("PY-TYPE-MISMATCH"), e.message)
          Test.assert(e.message.include?("`try`/`except`"), e.message)
        ok(out) -> Test.assert(false, "expected a refusal, emitted #{out.code}")
      end
    end,
    # `print` and `str` interpolate too, so outside `try` they refuse the
    # same uncaught `Result` an f-string hole does.
    Test.test("print refuses an uncaught Result argument") do
      case emit_expr(compiled.unwrap!, "print(int(s))", false)
        error(e) ->
          try Test.assert(e.message.include?("PY-TYPE-MISMATCH"), e.message)
          Test.assert(e.message.include?("`print` argument"), e.message)
        ok(out) -> Test.assert(false, "expected a refusal, emitted #{out.code}")
      end
    end,
  ])
end
