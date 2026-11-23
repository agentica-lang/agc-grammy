## Linked-module emission (issue #26): one `.agc` file per module in dependency
## order, the import forms and their aliases, what a call through an import
## checks, and what refuses (and in which file). Every fixture is a real
## multi-file program in a temporary folder, translated in-process; the
## command line and the run against python3 are in `link_cli_test.agc`.

import Grammar from "../../src/grammar"
import Link from "../src/link"
import Py2Agc from "../src/py2agc"

LIB = "def inc(x: int, step: int) -> int:\n    return x + step\n\n\ndef twice(x: int) -> int:\n    return x * 2\n"
MID = "from lib import twice\n\n\ndef quad(step: int, x: int) -> int:\n    return twice(x) + step\n"
SAME = "def f(x: int) -> int:\n    return x\n"

# Writes `files` (name to text) in a fresh folder of this test, translates its
# `prog.py` and removes the folder.
def translate(compiled: Grammar.Grammar, n: Int, files: Map[String, String]) -> Result[List[Link.Unit]]
  dir = "/tmp/agc_link_#{System.pid()}_#{n}"
  try Path.remove(dir)
  try Dir.mkdir_private(dir)
  for name in files.keys()
    try File.write_text("#{dir}/#{name}.py", files.get(name, ""))
  end

  result = Py2Agc.translate_modules(compiled, "#{dir}/prog.py", [])
  _ = Path.remove(dir)
  result
end

# Translating refuses, and the rendered diagnostic holds every needle.
def refuses(compiled: Grammar.Grammar, n: Int, files: Map[String, String], needles: List[String]) -> Result[Void]
  case translate(compiled, n, files)
    ok(_) -> error("expected a refusal")

    error(e) ->
      for needle in needles
        try Test.assert(e.message.include?(needle), e.message)
      end

      ok()
  end
end

def main() -> Void
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  if System.args() == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    Test.test("every import form links to an import of the sibling file, in dependency order") do
      prog = "import lib\nimport lib as l2\nimport mid\nfrom lib import twice as dbl, inc\nfrom mid import quad\n"
      prog = prog + "print(lib.inc(1, 2), l2.twice(3), dbl(4), inc(5, 6), quad(step=7, x=8))\n"
      units = try translate(compiled.unwrap!, 1, {"prog": prog, "lib": LIB, "mid": MID})
      try Test.eq(units.map { |unit| unit.name }, ["lib.agc", "mid.agc", "prog.agc"])
      text = units[2].text
      try Test.assert(
        text.start_with?("import Lib from \"lib\"\nimport L2 from \"lib\"\nimport {twice as dbl, inc}"),
        text,
      )

      try Test.assert(text.include?("import {quad} from \"mid\"") and !text.include?("import Mid"), text)
      try Test.assert(text.include?("Lib.inc(1, 2)") and text.include?("L2.twice(3)"), text)
      try Test.assert(units[1].text.include?("import {twice} from \"lib\"\n"), units[1].text)
      try Test.assert(!units[0].text.include?("def main"), units[0].text)
      Test.assert(text.include?("def main() -> Void"), text)
    end,
    Test.test("a call through an import checks arity like a local call") do
      refuses(
        compiled.unwrap!,
        3,
        {"prog": "from lib import inc\nprint(inc(1))\n", "lib": LIB},
        ["prog.py:2:1 error[PY-CALL-ARITY]", "`inc` is missing 1 required argument (`step`)"],
      )
    end,
    Test.test("a default is not lowered across modules") do
      refuses(
        compiled.unwrap!,
        4,
        {"prog": "import lib\nprint(lib.f(1))\n", "lib": "def f(x: int, y: int = 1) -> int:\n    return x + y\n"},
        ["error[PY-CALL-ARITY]", "`lib.f` is missing 1 required argument (`y`)", "defaults do not cross modules"],
      )
    end,
    Test.test("an argument of the wrong type refuses") do
      refuses(
        compiled.unwrap!,
        5,
        {"prog": "import lib\nprint(lib.twice(\"a\"))\n", "lib": LIB},
        ["error[PY-TYPE-MISMATCH]"],
      )
    end,
    Test.test("a member the module does not have refuses") do
      refuses(
        compiled.unwrap!,
        6,
        {"prog": "import lib\nprint(lib.nope(1))\n", "lib": LIB},
        ["error[PY-NAME-UNKNOWN]", "does not define a function `nope`"],
      )
    end,
    Test.test("a member and a module are not values") do
      try refuses(
        compiled.unwrap!,
        7,
        {"prog": "import lib\nx: int = lib.twice\n", "lib": LIB},
        ["`lib.twice` is not a value"],
      )

      refuses(compiled.unwrap!, 8, {"prog": "import lib\nprint(lib)\n", "lib": LIB}, ["module `lib` is not a value"])
    end,
    Test.test("an import whose alias Agentica reserves refuses") do
      refuses(
        compiled.unwrap!,
        17,
        {"prog": "import time\nprint(time.f(1))\n", "time": SAME},
        ["prog.py:1:8 error[PY-OUT-OF-SUBSET]", "becomes `Time`", "a type name Agentica reserves"],
      )
    end,
    Test.test("an import whose alias is a type alias of the file refuses") do
      refuses(
        compiled.unwrap!,
        18,
        {"prog": "import point\ntype Point = int\nprint(point.f(1))\n", "point": SAME},
        ["error[PY-OUT-OF-SUBSET]", "becomes `Point`", "type alias of this file"],
      )
    end,
    Test.test("two imports with the same alias refuse") do
      refuses(
        compiled.unwrap!,
        19,
        {"prog": "import lib\nimport lib as Lib\nprint(lib.twice(1), Lib.twice(2))\n", "lib": LIB},
        ["prog.py:2:15 error[PY-OUT-OF-SUBSET]", "another import of this file already uses"],
      )
    end,
    Test.test("a function renamed to an uppercase name refuses") do
      refuses(
        compiled.unwrap!,
        20,
        {"prog": "from lib import twice as Dbl\nprint(Dbl(1))\n", "lib": LIB},
        ["prog.py:1:26 error[PY-OUT-OF-SUBSET]", "must start with a lowercase letter"],
      )
    end,
    Test.test("a type alias cannot be imported") do
      refuses(
        compiled.unwrap!,
        9,
        {"prog": "from lib import Names\n", "lib": "type Names = list[str]\n"},
        ["prog.py:1:17 error[PY-OUT-OF-SUBSET]", "type aliases do not cross modules"],
      )
    end,
    Test.test("a name a module only imports cannot be imported through it") do
      refuses(
        compiled.unwrap!,
        10,
        {"prog": "from mid import twice\n", "lib": LIB, "mid": MID},
        ["prog.py:1:17 error[PY-NAME-UNKNOWN]", "module `mid` has no function `twice`"],
      )
    end,
    Test.test("an imported module holds only defs and aliases") do
      refuses(
        compiled.unwrap!,
        11,
        {"prog": "import lib\nprint(1)\n", "lib": "count: int = 3\n"},
        ["lib.py:1:1 error[PY-OUT-OF-SUBSET]", "may only declare"],
      )
    end,
    Test.test("an import cycle and an unknown module refuse before emission") do
      try refuses(compiled.unwrap!, 14, {"prog": "import lib\n", "lib": "import prog\n"}, ["error[PY-IMPORT-CYCLE]"])
      refuses(compiled.unwrap!, 15, {"prog": "import nope\n"}, ["error[PY-IMPORT-UNKNOWN]"])
    end,
  ])
end
