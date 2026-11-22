## The `py2agc` pipeline: `.py` → parse/build/resolve → module `.agc`.
## Emitted programs are verified against the backend in one shared fixture:
## `agentica check` (the backend refuses the dead-rewrite regression) and a
## run whose output is compared with Python's.

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
    # An update-only variable (its only read is the augmented target's own
    # implicit read) keeps its declaration and update and gains one real
    # discard read, so the backend never sees a use of a vanished name.
    Test.test("an update-only variable survives with a discard read") do
      source = "c: int = 0\nc += 1\nprint(1)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("c: Int = 0"), text)
          try Test.assert(text.include?("c = c + (1)"), text)
          try Test.assert(text.include?("_ = c"), text)
          try Test.assert(!text.include?("_ = 0\n") and !text.include?("_ = c +"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_aug_only.agc")
          Test.assert(ran.include?("1"), ran)
      end
    end,
    # A variable with a real downstream read keeps exactly that: no discard
    # read is injected on top of the update chain.
    Test.test("a downstream read stays the only real read") do
      source = "c: int = 0\nc += 1\nprint(c)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("c: Int = 0"), text)
          try Test.assert(text.include?("c = c + (1)"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_aug_real.agc")
          Test.assert(ran.include?("1"), ran)
      end
    end,
    # The same chain inside a `def`: the discard read lands in the body.
    Test.test("a def-local update-only variable gains its discard read") do
      source = "def bump() -> None:\n    x: int = 0\n    x += 1\n    return\nbump()\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("def bump() -> Void"), text)
          try Test.assert(text.include?("x = x + (1)"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_aug_def.agc")
          Test.assert(ran.empty?(), ran)
      end
    end,
    # A name only annotated has no value: a plain assignment refuses with
    # its own message (nothing to assign), an augmented one still reads.
    Test.test("assigning after a valueless annotation refuses with its own message") do
      plain = "c: int\nc = 5\nprint(c)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", plain)
        error(e) ->
          try Test.assert(e.message.include?("PY-NAME-UNKNOWN"), e.message)
          try Test.assert(e.message.include?("annotated without a value"), e.message)
          try Test.assert(e.message.include?("c = 5"), e.message)
          try Test.assert(e.message.include?("2 | c = 5"), e.message)
        ok(_) -> try Test.assert(false, "expected an error")
      end

      aug = "c: int\nc += 1\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", aug)
        error(e) ->
          try Test.assert(e.message.include?("PY-NAME-UNKNOWN"), e.message)
          Test.assert(e.message.include?("read before it is assigned"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("reserved generated names refuse spanned") do
      named = "main: int = 1\nprint(main)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", named)
        error(e) ->
          try Test.assert(e.message.include?("PY-OUT-OF-SUBSET"), e.message)
          try Test.assert(e.message.include?("reserved"), e.message)
        ok(_) -> try Test.assert(false, "expected an error")
      end

      func = "def main() -> int:\n    return 1\nprint(main())\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", func)
        error(e) ->
          try Test.assert(e.message.include?("PY-OUT-OF-SUBSET"), e.message)
          Test.assert(e.message.include?("1:5"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a defaulted parameter refuses spanned") do
      source = "def add(x: int = 1) -> int:\n    return x\nprint(add())\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) ->
          try Test.assert(e.message.include?("PY-OUT-OF-SUBSET"), e.message)
          Test.assert(e.message.include?("default value"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a type alias hoists and its variable updates") do
      source = "type Count = int\nc: Count = 1\nc += 2\nprint(c)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.start_with?("type Count = Int\n"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_alias_aug.agc")
          Test.assert(ran.include?("3"), ran)
      end
    end,
  ])
end

# Spells the `add(1, 2)` interpolation without writing it literally.
def add_call() -> String = "#" + "{add(1, 2)}"
