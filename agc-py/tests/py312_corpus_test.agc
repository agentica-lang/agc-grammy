## Parse-only corpus for SUBSET.md sections 2–5 and layout in section 8:
## syntax alone, nothing is translated or run. The runnable programs are in
## `corpus_run_test.agc`.

import Engine from "../../src/engine"
import Grammar from "../../src/grammar"

# phase3_rejections: syntax alone does not enforce these semantic exclusions.
# Any, object: PY-ANY; tuple, set, bytes, complex, Final, ClassVar: PY-OUT-OF-SUBSET.
# cast(...), TYPE_CHECKING, print(..., sep/end/file=...), extra d.get args:
# PY-OUT-OF-SUBSET. Dynamic builtins (eval, exec, getattr, setattr, globals,
# locals, vars, dir): PY-DYNAMIC. `x is y`: PY-IS. `nan`/`inf`: PY-OUT-OF-SUBSET.
# __init__ packages: PY-OUT-OF-SUBSET. Float //, %, **: PY-OPERATOR.
# Mixed arithmetic: PY-OPERATOR; same-type violations: PY-TYPE-MISMATCH.
# First binding without annotation: PY-UNTYPED-NAME.

def main() -> Void
  # The test discovery worker has a smaller step budget than the run worker.
  grammar: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  if System.args() == ["--agentica-test", "run"]
    grammar = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    Test.test("bindings and augmented assignment") do
      accepts(grammar, "x: int = 2\nx = x + 1\nx += 1\nx -= 1\nx *= 2\nx /= 2\nx %= 2\npass\n")
    end,
    Test.test("annotated scalars, nested subscripts, unions and forwards") do
      accepts(
        grammar,
        "i: int = 1\ns: str = \"s\"\nf: float = 1.0\nb: bool = False\nd: dict[str, list[int]] = {\"x\": [1]}\nx: int | None = None\ny: Optional[int]\nz: \"Fwd\"\n",
      )
    end,
    Test.test("plain type aliases") do accepts(grammar, "type Count = int\ntype Counts = list[Count]\n") end,
    Test.test("defaults and keyword calls") do
      accepts(grammar, "def add(x: int, y: int = 1) -> int:\n    return x + y\nadd(2, y=3)\n")
    end,
    Test.test("bare return and explicit None return") do
      accepts(grammar, "def noop() -> None:\n    return\ndef done() -> None:\n    return None\n")
    end,
    Test.test("branch chain") do accepts(grammar, "if False:\n    pass\nelif False:\n    pass\nelse:\n    pass\n") end,
    Test.test("while with next and break") do
      accepts(grammar, "while True:\n    if False:\n        next\n    break\n")
    end,
    Test.test("list, range and string-call for loops") do
      accepts(grammar, "for x in [1, 2]:\n    pass\nfor x in range(1, 9, 2):\n    pass\nfor x in str(2):\n    pass\n")
    end,
    Test.test("single bare, named or bound handler") do
      accepts(
        grammar,
        "try:\n    int(\"x\")\nexcept:\n    pass\ntry:\n    int(\"x\")\nexcept ValueError:\n    pass\ntry:\n    int(\"x\")\nexcept ValueError as e:\n    print(e)\n",
      )
    end,
    Test.test("raising an error") do accepts(grammar, "def fail() -> None:\n    raise ValueError(\"oops\")\n") end,
    Test.test("assert with and without a message") do accepts(grammar, "assert True\nassert True, \"message\"\n") end,
    Test.test("arithmetic and powers") do
      accepts(grammar, "x: int = -2 ** 3 ** 2 + (7 // 2 - 1) * 4 % 3\ny: float = +1.0 / 2.0\n")
    end,
    Test.test("boolean, chained comparison, membership and identity") do
      accepts(
        grammar,
        "xs: list[int] = [1, 2]\nx: int | None = None\nassert not False and (1 < 2 <= 3 or 4 != 5)\nassert 1 in xs and 3 not in xs\nassert x is None or x is not None\n",
      )
    end,
    Test.test("conditional expression") do accepts(grammar, "x: int = 1 if True else 2\n") end,
    Test.test("index, slices, and attribute chains") do
      accepts(
        grammar,
        "xs: list[int] = [1, 2]\nx: int = xs[0]\nys: list[int] = xs[0:1] + xs[:1] + xs[0:] + xs[:]\nprint(os.environ[\"HOME\"].strip())\n",
      )
    end,
    Test.test("dictionary lookup and defaults") do
      accepts(grammar, "d: dict[str, int] = {\"k\": 1}\nx: Optional[int] = d.get(\"k\")\ny: int = d.get(\"k\", 0)\n")
    end,
    Test.test("conversions and builtins") do
      accepts(
        grammar,
        "print(int(\"1\"), int(1.2), float(\"1\"), float(1), str(1), bool(True), len(\"x\"))\nprint(sorted([2, 1]), sum([1]), min([1]), max([1]), abs(-1), round(1.2), chr(65), ord(\"A\"))\nprint(enumerate([1]), reversed([1]), all([True]), any([False]))\n",
      )
    end,
    Test.test("named functions passed to map and filter") do
      accepts(
        grammar,
        "def keep(x: int) -> bool:\n    return x > 0\ndef inc(x: int) -> int:\n    return x + 1\nprint(map(inc, [1]), filter(keep, [1]))\n",
      )
    end,
    Test.test("all integer bases and float formats") do
      accepts(grammar, "print(0_0, 1_000, 0x_FF, 0o_77, 0b_10)\nprint(1.0, .5, 5., 1e-2, 1.2E+3, 1_000.0_5)\n")
    end,
    Test.test("plain, raw and formatted strings with both quotes and triple quotes") do
      accepts(
        grammar,
        "print('s', \"s\", r'\\n', R\"\\t\", f'{1}', F\"{{{1}}}\")\nprint('''a\nb''', \"\"\"a\nb\"\"\", r'''a\nb''', r\"\"\"a\nb\"\"\", f'''{1}\nb''', f\"\"\"{1}\nb\"\"\")\n",
      )
    end,
    Test.test("escape forms") do accepts(grammar, "print(\"\\a\\b\\f\\v\\0\\x21\\u0041\\n\\r\\t\\\\\\'\\\"\")\n") end,
    Test.test("comment lines, blank lines and expression statements") do
      accepts(grammar, "# module comment\n\n\"docstring\"\nx: int = 1\n\n# inline below\nx + 1 # trailing comment\n")
    end,
    Test.test("all import shapes and parenthesized items") do
      accepts(
        grammar,
        "import math\nimport sys as system\nimport os, json\nimport urllib.parse\nfrom math import floor, ceil\nfrom math import (\n    sqrt, # trailing comma\n)\nprint(math.pi)\n",
      )
    end,
    Test.test("joined brackets and trailing commas") do
      accepts(
        grammar,
        "def f(\n    xs: list[\n        dict[int, int]\n    ],\n) -> int:\n    return xs[\n        0\n    ][2]\nf([1, {2: 3}])\nf([\n    {2: (\n        1 + # same expression\n\n        2\n    ),},\n],)\n",
      )
    end,
    Test.test("postfix tokens across joined lines") do
      accepts(grammar, "x: str = (\n    str\n    (1)\n    .\n    strip()\n    [0]\n)\n")
    end,
    Test.test("joined brackets in an f-string hole") do
      accepts(grammar, "print(f\"{len([\n    1,\n    2,\n])}\")\n")
    end,
    Test.test("untyped def") do rejects(grammar, "def f(x):\n    pass\n") end,
    Test.test("star args") do rejects(grammar, "def f(*x: int) -> None:\n    pass\n") end,
    Test.test("star kwargs") do rejects(grammar, "f(**x)\n") end,
    Test.test("bare star and keyword-only parameters") do
      rejects(grammar, "def f(*, x: int) -> None:\n    pass\n")
    end,
    Test.test("nested def") do rejects(grammar, "def f() -> None:\n    def g() -> None:\n        pass\n") end,
    Test.test("bare raise") do rejects(grammar, "raise\n") end,
    Test.test("raise from") do rejects(grammar, "raise E() from e\n") end,
    Test.test("multiple handlers") do
      rejects(grammar, "try:\n    pass\nexcept E:\n    pass\nexcept F:\n    pass\n")
    end,
    Test.test("finally") do rejects(grammar, "try:\n    pass\nfinally:\n    pass\n") end,
    Test.test("try else") do rejects(grammar, "try:\n    pass\nexcept:\n    pass\nelse:\n    pass\n") end,
    Test.test("for else") do rejects(grammar, "for x in xs:\n    pass\nelse:\n    pass\n") end,
    Test.test("while else") do rejects(grammar, "while True:\n    pass\nelse:\n    pass\n") end,
    Test.test("with") do rejects(grammar, "with f():\n    pass\n") end,
    Test.test("class") do rejects(grammar, "class C:\n    pass\n") end,
    Test.test("decorator") do rejects(grammar, "@f\ndef g() -> None:\n    pass\n") end,
    Test.test("lambda") do rejects(grammar, "lambda: 1\n") end,
    Test.test("global") do rejects(grammar, "global x\n") end,
    Test.test("nonlocal") do rejects(grammar, "nonlocal x\n") end,
    Test.test("del") do rejects(grammar, "del x\n") end,
    Test.test("unpacking target") do rejects(grammar, "a, b = xs\n") end,
    Test.test("starred target") do rejects(grammar, "*a, b = xs\n") end,
    Test.test("negative slice") do rejects(grammar, "xs[-1:]\n") end,
    Test.test("stepped slice") do rejects(grammar, "xs[::2]\n") end,
    Test.test("byte string") do rejects(grammar, "b\"x\"\n") end,
    Test.test("alphabetic list token") do rejects(grammar, "xs: [int] = []\n") end,
    Test.test("bare yield") do rejects(grammar, "yield\n") end,
    Test.test("yield") do rejects(grammar, "yield x\n") end,
    Test.test("async") do rejects(grammar, "async def f() -> None:\n    pass\n") end,
    Test.test("await") do rejects(grammar, "await f()\n") end,
    Test.test("comprehension") do rejects(grammar, "[x for x in xs]\n") end,
    Test.test("generator") do rejects(grammar, "f(x for x in xs)\n") end,
    Test.test("tuple literal") do rejects(grammar, "(1, 2)\n") end,
    Test.test("set literal") do rejects(grammar, "{1}\n") end,
    Test.test("complex literal") do rejects(grammar, "1j\n") end,
    Test.test("ellipsis") do rejects(grammar, "...\n") end,
    Test.test("relative import") do rejects(grammar, "from .x import y\n") end,
    Test.test("late import") do rejects(grammar, "pass\nimport x\n") end,
    Test.test("named Unicode escape") do rejects(grammar, "\"\\N{LATIN SMALL LETTER A}\"\n") end,
    Test.test("explicit continuation") do rejects(grammar, "x: int = 1 + \\\n    2\n") end,
    Test.test("unjoined expression") do rejects(grammar, "x: int = 1 +\n    2\n") end,
    Test.test("unjoined f-string hole inside a call") do rejects(grammar, "f(f\"{1 +\n    2}\")\n") end,
  ])
end

private

def accepts(grammar: Result[Grammar.Grammar], input: String) -> Result[Void]
  compiled = try grammar
  Test.ok?(Engine.run(compiled, "program", input))
end

def rejects(grammar: Result[Grammar.Grammar], input: String) -> Result[Void]
  compiled = try grammar
  Test.error?(Engine.run(compiled, "program", input))
end
