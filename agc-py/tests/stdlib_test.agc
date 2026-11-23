## Issue #27: the standard-library surface of `SUBSET.md` section 5. Each
## family is translated in-process, checked and run with the real backend
## beside CPython on the same source (the outputs must agree), and what the
## table does not map refuses with its own code and a help naming what is
## mapped.

import Grammar from "../../src/grammar"
import Py2Agc from "../src/py2agc"

struct Ran
  code: Int
  stdout: String
end

def run_process(command: String, args: List[String]) -> Result[Ran]
  proc = try Process.spawn_captured(command, args)
  out = try Process.output(proc, 30000)
  code = try Process.wait(proc, 30000)
  ok(Ran(code: code, stdout: out.stdout))
end

# Translates `source` as the entry file of a folder of this test, answering
# the emitted text.
def translate(compiled: Grammar.Grammar, dir: String, source: String) -> Result[String]
  try Path.remove(dir)
  try Dir.mkdir_private(dir)
  try File.write_text("#{dir}/prog.py", source)
  units = try Py2Agc.translate_modules(compiled, "#{dir}/prog.py", [])
  ok(List.last(units).text)
end

# Translates `source`, checks it with the backend, runs it and CPython on it
# and requires the same standard output and exit code. Answers the output.
def agree(compiled: Grammar.Grammar, n: Int, source: String) -> Result[String]
  dir = "/tmp/agc_std_#{System.pid()}_#{n}"
  text = try translate(compiled, dir, source)
  try File.write_text("#{dir}/prog.agc", text)
  checked = try run_process("agentica", ["check", "#{dir}/prog.agc"])
  try Test.assert(checked.stdout.include?("check ok"), checked.stdout + text)
  expected = try run_process("python3", ["#{dir}/prog.py"])
  got = try run_process("agentica", ["#{dir}/prog.agc"])
  _ = Path.remove(dir)
  try Test.eq(got.stdout, expected.stdout)
  try Test.eq(got.code, expected.code)
  ok(got.stdout)
end

# Translating `source` refuses, and the rendered diagnostic holds every needle.
def refuses(compiled: Grammar.Grammar, n: Int, source: String, needles: List[String]) -> Result[Void]
  dir = "/tmp/agc_std_#{System.pid()}_#{n}"
  case translate(compiled, dir, source)
    ok(_) -> error("expected a refusal for #{source}")

    error(e) ->
      _ = Path.remove(dir)
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
    Test.test("math: sqrt, floor, ceil and the constants, by module, alias and name") do
      source = "import math\nimport math as m\nfrom math import floor, pi, sqrt as root\nx: float = 2.5\n"
      source = source + "print(math.sqrt(16.0), root(2.0), m.sqrt(x + 1.5))\n"
      source = source + "print(math.floor(x * 2.0), math.ceil(-x), floor(-x), m.ceil(x))\n"
      source = source + "print(math.pi, pi, m.e, math.tau)\n"
      got = try agree(compiled.unwrap!, 1, source)
      Test.assert(got.include?("3.141592653589793"), got)
    end,
    Test.test("sys: argv and exit run like CPython, with the exit code") do
      source = "import sys\nfrom sys import exit\nprint(len(sys.argv), sys.argv[1:])\n"
      source = source + "if len(sys.argv) == 1:\n    print(\"done\")\n    exit(3)\nprint(\"unreachable\")\n"
      got = try agree(compiled.unwrap!, 2, source)
      Test.assert(got.include?("done"), got)
    end,
    Test.test("os: environ, getenv and getcwd are catchable and run like CPython") do
      source = (
        "import os\nfrom os import getcwd\ntry:\n    if os.environ[\"HOME\"] == os.getenv(\"HOME\"):\n        print(\"same\")\n"
      )

      source = (
        source +
        "except KeyError:\n    print(\"no home\")\ntry:\n    print(os.environ[\"AGC_PY_UNSET_VARIABLE\"])\n"
      )

      source = (
        source +
        "except KeyError:\n    print(\"unset\")\ntry:\n    if getcwd() == os.getcwd():\n        print(\"cwd\")\nexcept OSError:\n    print(\"no cwd\")\n"
      )

      got = try agree(compiled.unwrap!, 3, source)
      Test.assert(got.include?("unset"), got)
    end,
    Test.test("open: read, write and append whole files run like CPython") do
      path = "/tmp/agc_std_open_#{System.pid()}.txt"
      source = "try:\n    open(\"#{path}\", \"w\").write(\"one\")\n    open(\"#{path}\", \"a\").write(\" two\")\n"
      source = source + "    print(open(\"#{path}\").read())\nexcept OSError:\n    print(\"failed\")\n"
      source = source + "try:\n    print(open(\"#{path}.missing\").read())\nexcept OSError:\n    print(\"missing\")\n"
      got = try agree(compiled.unwrap!, 4, source)
      _ = Path.remove(path)
      Test.assert(got.include?("one two") and got.include?("missing"), got)
    end,
    Test.test("html and urllib.parse encode and decode like CPython, by module, alias and name") do
      source = "import html\nimport urllib.parse\nfrom urllib.parse import quote_plus as qp, unquote\n"
      source = source + "s: str = \"<a href=\\\"x\\\">'&</a> é~*/ +\"\nprint(html.escape(s))\n"
      source = source + "if html.unescape(html.escape(s)) == s:\n    print(\"round\")\n"
      source = source + "print(urllib.parse.quote(s), qp(s), urllib.parse.quote(\"a b/c\"))\n"
      source = (
        source +
        "try:\n    print(unquote(\"a%2Fb+c\"), urllib.parse.unquote_plus(\"a+b%26\"))\nexcept ValueError:\n    print(\"bad\")\n"
      )

      got = try agree(compiled.unwrap!, 14, source)
      Test.assert(got.include?("&#x27;") and got.include?("round") and got.include?("a/b+c a b&"), got)
    end,
    Test.test("time and random answer in range, and sleep waits") do
      source = (
        "import time\nimport random\nfrom random import randint\nt0: float = time.time()\nm0: float = time.monotonic()\n"
      )

      source = (
        source +
        "time.sleep(0.01)\nif time.time() > t0 and time.monotonic() >= m0 and t0 > 1000000000.0:\n    print(\"clock\")\n"
      )

      source = source + "r: int = randint(3, 3)\nif random.random() < 1.0:\n    print(r)\n"
      got = try agree(compiled.unwrap!, 15, source)
      Test.eq(got, "clock\n3\n")
    end,
    Test.test("a standard-library import whose std alias is taken refuses") do
      dir = "/tmp/agc_std_#{System.pid()}_16"
      try Path.remove(dir)
      try Dir.mkdir_private(dir)
      try File.write_text("#{dir}/uri.py", "def f(x: int) -> int:\n    return x\n")
      try File.write_text(
        "#{dir}/prog.py",
        "import uri\nfrom urllib.parse import quote\nprint(uri.f(1), quote(\"a\"))\n",
      )

      case Py2Agc.translate_modules(compiled.unwrap!, "#{dir}/prog.py", [])
        ok(_) -> error("expected a refusal")
        error(e) ->
          _ = Path.remove(dir)
          try Test.assert(e.message.include?("error[PY-OUT-OF-SUBSET]"), e.message)
          Test.assert(e.message.include?("`std/uri` becomes `Uri`"), e.message)
      end
    end,
    Test.test("a mapped module with an unmapped member and an unmapped module refuse precisely") do
      try refuses(
        compiled.unwrap!,
        17,
        "from urllib.parse import urlencode\n",
        [
          "prog.py:1:26 error[PY-IMPORT-UNKNOWN]", "`urllib.parse.urlencode`",
          "`urllib.parse` maps quote, quote_plus, unquote, unquote_plus",
        ],
      )

      refuses(
        compiled.unwrap!,
        18,
        "import json\nprint(json.dumps(1))\n",
        ["error[PY-IMPORT-UNKNOWN]", "`json.dumps`", "no member of `json` is mapped yet"],
      )
    end,
    Test.test("a member outside the table refuses with what the module maps") do
      try refuses(
        compiled.unwrap!,
        5,
        "import math\nprint(math.sin(1.0))\n",
        [
          "error[PY-IMPORT-UNKNOWN]", "`math.sin` is not in the supported standard-library surface",
          "`math` maps ceil, e, floor, pi, sqrt, tau",
        ],
      )

      refuses(
        compiled.unwrap!,
        6,
        "from os import path\n",
        ["prog.py:1:16 error[PY-IMPORT-UNKNOWN]", "`os.path`", "`os` maps environ, getcwd, getenv"],
      )
    end,
    Test.test("math.inf has no spelling") do
      refuses(compiled.unwrap!, 7, "import math\nprint(math.inf)\n", ["error[PY-IMPORT-UNKNOWN]", "`math.inf`"])
    end,
    Test.test("a module whose members are not mapped yet says so") do
      refuses(
        compiled.unwrap!,
        8,
        "import re\nprint(re.compile(\"a\"))\n",
        ["error[PY-IMPORT-UNKNOWN]", "`re.compile`", "no member of `re` is mapped yet"],
      )
    end,
    Test.test("an argument of the wrong type, a missing argument and a constant call refuse") do
      try refuses(
        compiled.unwrap!,
        9,
        "import math\nprint(math.sqrt(2))\n",
        ["error[PY-TYPE-MISMATCH]", "`math.sqrt` expects `Float`"],
      )

      refuses(
        compiled.unwrap!,
        10,
        "import sys\nsys.exit()\n",
        ["error[PY-CALL-ARITY]", "`sys.exit` is missing 1 required argument"],
      )
    end,
    Test.test("os.environ is only a key lookup, and open is only a whole-file read or write") do
      try refuses(
        compiled.unwrap!,
        11,
        "import os\nprint(os.environ)\n",
        ["error[PY-OUT-OF-SUBSET]", "only supported as `os.environ[name]`"],
      )

      try refuses(
        compiled.unwrap!,
        12,
        "f: str = \"a\"\nopen(f)\n",
        ["error[PY-OUT-OF-SUBSET]", "only supported as `open(path).read()`"],
      )

      refuses(
        compiled.unwrap!,
        13,
        "print(open(\"a\", \"x\").write(\"b\"))\n",
        ["error[PY-OUT-OF-SUBSET]", "supports mode \"r\" with `.read()`"],
      )
    end,
  ])
end
