## The call ABI (issue #23) against the real backend: keyword arguments
## evaluate left to right in source order even when the call spells them
## out of parameter order, recursion reaches its own signature, and the
## invalid call shapes refuse with their `PY-*` codes. Sources stay short
## and each test translates its own program, because `agentica test`
## shares a step budget of one million steps per test (plus one) over the
## file's tests and the grammar load costs close to two million of them.

import Grammar from "../../src/grammar"
import Py2Agc from "../src/py2agc"

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
    Test.test("keyword arguments evaluate in source order and reorder") do
      # `tag` prints its argument before returning it, so the run output is
      # the evaluation order: `b`'s value first (source order), then `a`'s,
      # and the call still adds them in parameter order.
      source = (
        "def tag(v: int) -> int:\n    print(v)\n    return v\ndef add(a: int, b: int) -> int:\n" +
        "    return a + b\nprint(add(b=tag(20), a=tag(10)))\n"
      )

      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("py_t0 = tag(20)"), text)
          try Test.assert(text.include?("py_t1 = tag(10)"), text)
          try Test.assert(text.include?("add(py_t1, py_t0)"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_kw_order.agc")
          Test.eq(ran, "20\n10\n30\n")
      end
    end,
    Test.test("plain positional calls to defs still run") do
      source = "def add(a: int, b: int) -> int:\n    return a + b\nprint(add(2, 3))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("add(2, 3)"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_plain_call.agc")
          Test.eq(ran, "5\n")
      end
    end,
    Test.test("a caller's variable survives beside a defaulted call") do
      source = "def g(a: int, b: int = a * 2) -> int:\n    return a + b\na: int = 100\nprint(g(3) + a)\n"

      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          # `g(3)` lowers to `g(py_t0, py_t0 * 2)` with `py_t0 = 3`, and the
          # trailing `a` still reads the caller's 100: 9 + 100.
          ran = try check_and_run(text, "/tmp/agc_py2agc_caller_survives.agc")
          Test.eq(ran, "109\n")
      end
    end,
    Test.test("recursion reaches its own signature") do
      source = "def r(n: int) -> int:\n    if n <= 0:\n        return 0\n    return n + r(n - 1)\nprint(r(5))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          ran = try check_and_run(text, "/tmp/agc_py2agc_recursion.agc")
          Test.eq(ran, "15\n")
      end
    end,
    Test.test("a keyword fills a defaulted parameter and runs") do
      source = "def sub(a: int, b: int = 2) -> int:\n    return a - b\nprint(sub(b=9, a=10))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          # The keyword values hoist to source-ordered temps and the call
          # spells them in parameter order: a's 10 evaluates after b's 9.
          try Test.assert(text.include?("py_t0 = 9"), text)
          try Test.assert(text.include?("py_t1 = 10"), text)
          try Test.assert(text.include?("sub(py_t1, py_t0)"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_kw_default.agc")
          Test.eq(ran, "1\n")
      end
    end,
    Test.test("an unknown keyword refuses with its code") do
      source = "def add(a: int, b: int) -> int:\n    return a + b\nprint(add(z=1))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-KWARG-UNKNOWN]"), e.message)
          Test.assert(e.message.include?("has no parameter `z`"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a repeated keyword refuses with its code") do
      source = "def add(a: int, b: int) -> int:\n    return a + b\nprint(add(a=1, a=2))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(e.message.include?("error[PY-KWARG-DUPLICATE]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a missing required argument refuses with its code") do
      source = "def add(a: int, b: int) -> int:\n    return a + b\nprint(add(1))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(e.message.include?("error[PY-CALL-ARITY]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a keyword call missing a required positional refuses") do
      source = "def sub(a: int, b: int = 2) -> int:\n    return a - b\nprint(sub(b=9))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(e.message.include?("error[PY-CALL-ARITY]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("too many positional arguments refuse with their code") do
      source = "def add(a: int, b: int) -> int:\n    return a + b\nprint(add(1, 2, 3))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(e.message.include?("error[PY-CALL-ARITY]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an optional map wraps a bare empty") do
      source = "def g(m: dict[str, int] | None) -> int:\n    return 2\nprint(g({}))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("g(some({}))"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_opt_map.agc")
          Test.eq(ran, "2\n")
      end
    end,
    Test.test("a void keyword into an optional runs and passes none") do
      source = "def v() -> None:\n    print(1)\ndef h(x: int | None) -> int:\n" + "    return 1\nprint(h(x=v()))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("v()"), text)
          try Test.assert(text.include?("h(none)"), text)
          try Test.assert(!text.include?("py_t0 = v()"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_kw_void.agc")
          Test.eq(ran, "1\n1\n")
      end
    end,
  ])
end
