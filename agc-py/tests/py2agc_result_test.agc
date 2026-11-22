## Issue #24 cut regressions: `Result` values in eager expression positions
## inside an outlined `try`. Both ternary branches evaluate eagerly, so a
## branch that hoists a `Result` refuses spanned instead of converting an
## untaken arm; an f-string hole unwraps before interpolation so a failed
## conversion reaches the handler.
##
## The ternary checks parse one expression and call the emitter seam
## directly; the end-to-end tests translate and run. That mix keeps the file
## inside the shared step budget: a `translate` costs about a million steps,
## loading the grammar 1.8 million, and the budget is one million per test.

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

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  if System.args() == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    # Both branches evaluate eagerly, so a direct `Result` arm would convert
    # even when the guard picks the other one.
    Test.test("a direct Result ternary arm refuses inside try") do
      case emit_in_try(compiled.unwrap!, "int(s) if False else 0")
        error(e) ->
          try Test.assert(e.message.include?("PY-OUT-OF-SUBSET"), e.message)
          Test.assert(e.message.include?("ternary branch with a Result"), e.message)
        ok(out) -> Test.assert(false, "expected a refusal, emitted #{out.code}")
      end
    end,
    # An arm whose outer type hides the `Result` hoist (`int(s) + 1` is
    # `Int` and still appends `py_tK = try ...`) refuses the same way.
    Test.test("a nested Result ternary arm refuses inside try") do
      case emit_in_try(compiled.unwrap!, "(int(s) + 1) if False else 0")
        error(e) ->
          try Test.assert(e.message.include?("PY-OUT-OF-SUBSET"), e.message)
          Test.assert(e.message.include?("ternary branch with a Result"), e.message)
        ok(out) -> Test.assert(false, "expected a refusal, emitted #{out.code}")
      end
    end,
    Test.test("a plain ternary still emits inside try") do
      case emit_in_try(compiled.unwrap!, "1 if False else 0")
        error(e) -> Test.assert(false, "expected an emission, got #{e.message}")
        ok(out) ->
          try Test.eq(out.type, "Int")
          Test.assert(out.pre.include?("if false"), out.pre.join("\n"))
      end
    end,
    # Outside `try` nothing catches the hole's error, so interpolating the
    # `Result` (`ok(5)`) is refused instead; an `and`/`or` tail emits without
    # `try` unwrapping, so the same refusal keeps a lazy tail honest.
    Test.test("an uncaught f-string hole refuses outside try") do
      case emit_expr(compiled.unwrap!, "f\"{int(s)}\"", false)
        error(e) ->
          try Test.assert(e.message.include?("PY-TYPE-MISMATCH"), e.message)
          Test.assert(e.message.include?("f-string hole"), e.message)
        ok(out) -> Test.assert(false, "expected a refusal, emitted #{out.code}")
      end
    end,
    Test.test("a short-circuit tail cannot hide an uncaught f-string Result") do
      case emit_in_try(compiled.unwrap!, "True and (f\"{int(s)}\" == \"5\")")
        error(e) ->
          try Test.assert(e.message.include?("PY-TYPE-MISMATCH"), e.message)
          Test.assert(e.message.include?("f-string hole"), e.message)
        ok(out) -> Test.assert(false, "expected a refusal, emitted #{out.code}")
      end
    end,
    # The refusal reaches the user as a spanned diagnostic at the arm.
    Test.test("the ternary refusal renders with its span") do
      direct = "s: str = \"bad\"\ntry:\n    x: int = int(s) if False else 0\n    print(x)\nexcept:\n    print(99)\n"

      case Py2Agc.translate(compiled.unwrap!, "prog.py", direct)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-OUT-OF-SUBSET]"), e.message)
          Test.assert(e.message.include?("x: int = int(s) if False else 0"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    # Holes unwrap left to right before interpolation: the good hole prints
    # `v=5`, the bad one reaches the handler instead of printing a `Result`.
    Test.test("f-string holes inside try unwrap in order and fail caught") do
      holes = (
        "a: str = \"5\"\nb: str = \"bad\"\ntry:\n    v: str = f\"v={int(a)}\"\n" +
        "    print(v)\n    q: str = f\"{int(b)}\"\n    print(q)\nexcept:\n    print(1)\n"
      )

      case Py2Agc.translate(compiled.unwrap!, "prog.py", holes)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          first = text.index_of("py_t0 = try a.to_i").unwrap!
          second = text.index_of("py_t1 = try b.to_i").unwrap!
          try Test.assert(first < second, text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_result_fstring.agc")
          try Test.assert(ran.strip().start_with?("v=5"), ran)
          try Test.eq(ran.strip().slice(ran.strip().length - 1, 1), "1")
          Test.assert(!ran.include?("error(") and !ran.include?("ok("), ran)
      end
    end,
  ])
end
