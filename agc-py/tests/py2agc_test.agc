## The `py2agc` pipeline: `.py` → parse/build/resolve → module `.agc`.
## Emitted programs are verified against the backend in one shared fixture:
## `agentica check` (the backend refuses the dead-rewrite regression) and a
## run whose output is compared with Python's. Loop-target reassignment and
## annotation mapping keep their backend probes here: the immutable loop
## variable and the bare `List`/`Map` spellings are both backend refusals,
## so a regression shows up as a failed check, not a silent wrong type.

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
    # The call ABI lowers a defaulted parameter at every call site, so the
    # old refusal is now a working default.
    Test.test("a defaulted parameter lowers at the call site") do
      source = "def add(x: int = 1) -> int:\n    return x\nprint(add())\nprint(add(4))\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("def add(x: Int) -> Int"), text)
          try Test.assert(text.include?("#" + "{add(1)}"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_default.agc")
          Test.assert(ran.include?("1\n4"), ran)
      end
    end,
    # A bare def name is not a value: the old emission let `print(greet)`
    # through as `puts("#{greet}")`, which the backend refuses ("functions
    # are not values", probed CHECK-UNKNOWN-NAME), so the value occurrence
    # refuses spanned. Calls, a parameter shadowing the name and the
    # `map`/`filter` function slot keep working.
    Test.test("a bare def value refuses spanned at the occurrence") do
      # (source, rendered source line of the refusal) pairs: top level, an
      # f-string hole and a def-body return.
      sources: List[String] = [
        "def greet() -> int:\n    return 1\nprint(greet)\n",
        "def greet() -> int:\n    return 1\nprint(f\"{greet}\")\n",
        "def greet() -> int:\n    return 1\ndef f() -> int:\n    return greet\n",
      ]

      lines: List[String] = ["3 | print(greet)", "print(f\"{greet}\")", "4 |     return greet"]
      i = 0
      for source in sources
        case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
          error(e) ->
            try Test.assert(e.message.include?("error[PY-OUT-OF-SUBSET]"), e.message)
            try Test.assert(e.message.include?("function `greet` is not a value"), e.message)
            try Test.assert(e.message.include?("= help: call it, for example `greet(...)`"), e.message)
            try Test.assert(e.message.include?(List.first(lines.drop(i))), e.message)
          ok(_) -> try Test.assert(false, "expected an error at case #{i}")
        end

        i += 1
      end

      ok()
    end,
    Test.test("a def call, a parameter shadow and map/filter still check and run") do
      source = (
        "def greet() -> int:\n    return 1\ndef f(greet: int) -> int:\n    return greet\n" +
        "def inc(x: int) -> int:\n    return x + 1\nxs: list[int] = [1, 2]\n" +
        "print(f(greet()))\nprint(sum(map(inc, xs)))\n"
      )

      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("def f(greet: Int) -> Int"), text)
          try Test.assert(text.include?("xs.map { |py_x0| inc(py_x0) }"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_def_value.agc")
          try Test.assert(ran.include?("1"), ran)
          Test.assert(ran.include?("5"), ran)
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
    # A fresh `for` target reassigned in the body lowers through a fresh
    # iterator: the direct header would assign the backend's immutable loop
    # variable (probed CHECK-IMMUTABLE-ASSIGNMENT on the parent emission),
    # while the iterator shape checks and runs with Python's values.
    Test.test("a reassigned fresh for target checks and runs") do
      source = "def bump() -> None:\n    for x in [1, 2, 3]:\n        x += 1\n        print(x)\nbump()\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("for py_t0 in [1, 2, 3]"), text)
          try Test.assert(text.include?("  x = py_t0\n"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_for_reassign.agc")
          try Test.assert(ran.include?("2"), ran)
          try Test.assert(ran.include?("3"), ran)
          Test.assert(ran.include?("4"), ran)
      end
    end,
    # Reassignment nested in an `if` counts too, and the per-iteration
    # binding resets: the second iteration sees the element, not 9.
    Test.test("a nested reassignment of a fresh for target runs like Python") do
      source = "def f() -> None:\n    for x in [1, 2]:\n        if x == 1:\n            x = 9\n        print(x)\nf()\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          ran = try check_and_run(text, "/tmp/agc_py2agc_for_nested.agc")
          try Test.assert(ran.include?("9"), ran)
          Test.assert(ran.include?("2"), ran)
      end
    end,
    # A nested loop binding the same name rebinds the outer target through
    # its own header, exactly as Python rebinds it.
    Test.test("a nested for rebinding the fresh target rebinds the outer one") do
      source = (
        "def f() -> None:\n    for x in [1, 2]:\n        for x in [10, 20]:\n            print(x)\n        print(x)\nf()\n"
      )

      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          ran = try check_and_run(text, "/tmp/agc_py2agc_for_inner.agc")
          try Test.assert(ran.include?("10"), ran)
          try Test.assert(ran.include?("20"), ran)
          # 10, 20, 20, 10, 20, 20: six prints, two of them the outer read.
          Test.eq(ran.split("\n").size, 7)
      end
    end,
    # Bare `list`/`dict` map to no backend type: every annotation site
    # refuses spanned with a parameterized example, and a parameterized
    # form still emits and runs.
    Test.test("bare list and dict annotations refuse spanned end to end") do
      param = "def f(xs: list) -> int:\n    return 0\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", param)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-ANNOTATION-UNKNOWN]"), e.message)
          try Test.assert(e.message.include?("needs one parameter"), e.message)
          try Test.assert(e.message.include?("write `list[T]`, for example `list[int]`"), e.message)
        ok(_) -> try Test.assert(false, "expected an error")
      end

      ret = "def f() -> dict:\n    return {}\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", ret)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-ANNOTATION-UNKNOWN]"), e.message)
          try Test.assert(e.message.include?("needs two parameters"), e.message)
        ok(_) -> try Test.assert(false, "expected an error")
      end

      binding = "d: dict = {}\nprint(d)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", binding)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-ANNOTATION-UNKNOWN]"), e.message)
          try Test.assert(e.message.include?("1:4"), e.message)
        ok(_) -> try Test.assert(false, "expected an error")
      end

      alias = "type Bunch = list\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", alias)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-ANNOTATION-UNKNOWN]"), e.message)
          try Test.assert(e.message.include?("needs one parameter"), e.message)
        ok(_) -> try Test.assert(false, "expected an error")
      end

      nested = "xss: list[list] = []\nprint(xss)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", nested)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-ANNOTATION-UNKNOWN]"), e.message)
          Test.assert(e.message.include?("needs one parameter"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    # Issue #24 cut: a `Result`-returning call inside a strict compound
    # inside an outlined `try` hoists to `try` in order (single evaluation);
    # the caught error reaches the handler, the uncaught shape refuses.
    Test.test("a Result call in a compound inside try checks and runs caught") do
      good = "try:\n    x: int = int(\"5\") + 1\n    print(x)\nexcept:\n    print(0)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", good)
        error(e) -> try Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("py_t0 = try"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_result_compound_ok.agc")
          try Test.assert(ran.include?("6"), ran)
      end

      bad = "try:\n    x: int = int(\"bad\") + 1\n    print(x)\nexcept:\n    print(0)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", bad)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          ran = try check_and_run(text, "/tmp/agc_py2agc_result_compound_err.agc")
          Test.assert(ran.include?("0"), ran)
      end
    end,
    Test.test("uncaught, lazy and assert Result shapes refuse spanned") do
      uncaught = "x: int = int(\"5\") + 1\nprint(x)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", uncaught)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-TYPE-MISMATCH]"), e.message)
          try Test.assert(e.message.include?("1 | x: int"), e.message)
        ok(_) -> try Test.assert(false, "expected an error")
      end

      lazy = "try:\n    x: bool = False and int(\"bad\") == 5\n    print(x)\nexcept:\n    print(True)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", lazy)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-TYPE-MISMATCH]"), e.message)
          try Test.assert(e.message.include?("Result[Int]"), e.message)
        ok(_) -> try Test.assert(false, "expected an error")
      end

      cond = "try:\n    assert int(\"5\") == 5\n    print(1)\nexcept:\n    print(0)\n"
      case Py2Agc.translate(compiled.unwrap!, "prog.py", cond)
        error(e) ->
          try Test.assert(e.message.include?("error[PY-TYPE-MISMATCH]"), e.message)
          Test.assert(e.message.include?("Result[Int]"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("parameterized list and dict annotations still check and run") do
      source = (
        "def total(xs: list[int]) -> int:\n    acc: int = 0\n    for x in xs:\n        acc += x\n    return acc\nd: dict[str, int] = {\"a\": 7}\nprint(total([1, -2, 3]))\nprint(d[\"a\"])\n"
      )

      case Py2Agc.translate(compiled.unwrap!, "prog.py", source)
        error(e) -> Test.assert(false, "expected a program, got #{e.message}")
        ok(text) ->
          try Test.assert(text.include?("def total(xs: List[Int]) -> Int"), text)
          try Test.assert(text.include?("d: Map[String, Int]"), text)
          ran = try check_and_run(text, "/tmp/agc_py2agc_parameterized.agc")
          try Test.assert(ran.include?("2"), ran)
          Test.assert(ran.include?("7"), ran)
      end
    end,
  ])
end

# Spells the `add(1, 2)` interpolation without writing it literally.
def add_call() -> String = "#" + "{add(1, 2)}"
