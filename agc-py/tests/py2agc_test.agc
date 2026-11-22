## The `py2agc` pipeline: `.py` → parse/build/resolve → module `.agc`.

import Grammar from "../../src/grammar"
import Py2Agc from "../src/py2agc"

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  if System.args() == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    Test.test("the pipeline has a version") do Test.eq(Py2Agc.version(), "0.0.0") end,
    Test.test("an empty program is refused") do
      case Py2Agc.translate(compiled.unwrap!, "prog.py", "")
        error(e) -> Test.assert(e.message.include?("nothing to translate"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a typed program translates to a standalone entry point") do
      source = "def add(x: int, y: int) -> int:\n    return x + y\nprint(add(1, 2))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("def add(x: Int, y: Int) -> Int"), text)
          try Test.assert(text.include?("def main() -> Void"), text)
          Test.assert(text.include?("puts(\"#{add_call()}\""), text)
      end
    end,
    Test.test("a frontend problem renders as its diagnostic") do
      source = "def f(x) -> int:\n    return x\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(e.message.include?("error[PY-UNTYPED-DEF]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an emit refusal renders with its span and code") do
      source = "x: int = 1\ndef f() -> int:\n    return x\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(e.message.include?("error[PY-OUT-OF-SUBSET]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
  ])
end

# Spells the `add(1, 2)` interpolation without writing it literally.
def add_call() -> String = "#" + "{add(1, 2)}"
