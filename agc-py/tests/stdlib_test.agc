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

# The binary under test: `$AGC_PY_AGENTICA` (the Makefile sets it) or `agentica`.
def agentica() -> String
  case System.env("AGC_PY_AGENTICA")
    ok(path) if !path.empty?() -> path
    _ -> "agentica"
  end
end

def run_process(command: String, args: List[String]) -> Result[Ran]
  proc = try Process.spawn_captured(command, args)
  out = try Process.output(proc, 30000)
  code = try Process.wait(proc, 30000)
  ok(Ran(code: code, stdout: out.stdout))
end

# Runs `body` in a fresh folder of this test and removes it afterwards,
# whatever the body answers.
def in_dir(n: Int, body: Fn[String, Result[Void]]) -> Result[Void]
  dir = "/tmp/agc_std_#{System.pid()}_#{n}"
  try Path.remove(dir)
  try Dir.mkdir_private(dir)
  result = body.call(dir)
  _ = Path.remove(dir)
  result
end

# Translates `source` as the entry file of `dir`, answering the emitted text.
def translate(compiled: Grammar.Grammar, dir: String, source: String) -> Result[String]
  try File.write_text("#{dir}/prog.py", source)
  units = try Py2Agc.translate_modules(compiled, "#{dir}/prog.py", [])
  ok(List.last(units).text)
end

# Translates `source`, checks it with the backend, runs it and CPython on it
# and requires the same standard output and exit code. Checks `then` on the
# output.
def agrees(compiled: Grammar.Grammar, n: Int, source: String, then: Fn[String, Result[Void]]) -> Result[Void]
  in_dir(n) do |dir|
    text = try translate(compiled, dir, source)
    try File.write_text("#{dir}/prog.agc", text)
    checked = try run_process(agentica(), ["check", "#{dir}/prog.agc"])
    try Test.assert(checked.stdout.include?("check ok"), checked.stdout + text)
    expected = try run_process("python3", ["#{dir}/prog.py"])
    got = try run_process(agentica(), ["#{dir}/prog.agc"])
    try Test.eq(got.stdout, expected.stdout)
    try Test.eq(got.code, expected.code)
    then.call(got.stdout)
  end
end

# `agrees` with nothing more to check.
def agree(compiled: Grammar.Grammar, n: Int, source: String) -> Result[Void]
  agrees(compiled, n, source) do |_| ok() end
end

# Translating `source` refuses, and the rendered diagnostic holds every needle.
def refuses(compiled: Grammar.Grammar, n: Int, source: String, needles: List[String]) -> Result[Void]
  in_dir(n) do |dir|
    case translate(compiled, dir, source)
      ok(_) -> error("expected a refusal for #{source}")

      error(e) ->
        for needle in needles
          try Test.assert(e.message.include?(needle), e.message)
        end

        ok()
    end
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
      agrees(compiled.unwrap!, 1, source) do |got| Test.assert(got.include?("3.141592653589793"), got) end
    end,
    Test.test("sys: argv and exit run like CPython, with the exit code") do
      source = "import sys\nfrom sys import exit\nprint(len(sys.argv), sys.argv[1:])\n"
      source = source + "if len(sys.argv) == 1:\n    print(\"done\")\n    exit(3)\nprint(\"unreachable\")\n"
      agrees(compiled.unwrap!, 2, source) do |got| Test.assert(got.include?("done"), got) end
    end,
    Test.test("sys.exit takes the code modulo 256 like the operating system") do
      try agree(compiled.unwrap!, 19, "import sys\nsys.exit(-1)\n")
      agree(compiled.unwrap!, 20, "import sys\nsys.exit(300)\n")
    end,
    Test.test("os: environ, getenv and getcwd answer the real values like CPython") do
      source = "import os\nfrom os import getcwd\ntry:\n    print(os.environ[\"HOME\"])\n"
      source = (
        source +
        "except KeyError:\n    print(\"no home\")\ntry:\n    print(os.environ[\"AGC_PY_UNSET_VARIABLE\"])\n"
      )

      source = (
        source +
        "except KeyError:\n    print(\"unset\")\ntry:\n    print(getcwd(), os.getcwd())\nexcept OSError:\n    print(\"no cwd\")\n"
      )

      source = (
        source +
        "if os.getenv(\"AGC_PY_UNSET_VARIABLE\") is None:\n    print(\"none\")\nif os.getenv(\"HOME\") is not None:\n    print(\"some\")\n"
      )

      agrees(compiled.unwrap!, 3, source) do |got|
        Test.assert(got.include?("unset") and got.include?("none\nsome"), got)
      end
    end,
    Test.test("os.getenv takes no default") do
      refuses(
        compiled.unwrap!,
        21,
        "import os\nprint(os.getenv(\"K\", \"d\"))\n",
        ["error[PY-CALL-ARITY]", "`os.getenv` takes 1 argument, 2 given"],
      )
    end,
    Test.test("open: read, write and append whole files run like CPython") do
      path = "/tmp/agc_std_open_#{System.pid()}.txt"
      source = "try:\n    open(\"#{path}\", \"w\").write(\"one\")\n    open(\"#{path}\", \"a\").write(\" two\")\n"
      source = source + "    print(open(\"#{path}\").read())\nexcept OSError:\n    print(\"failed\")\n"
      source = source + "try:\n    print(open(\"#{path}.missing\").read())\nexcept OSError:\n    print(\"missing\")\n"
      result = agrees(compiled.unwrap!, 4, source) do |got|
        Test.assert(got.include?("one two") and got.include?("missing"), got)
      end

      _ = Path.remove(path)
      result
    end,
    Test.test("open reads text with universal newlines like CPython") do
      path = "/tmp/agc_std_crlf_#{System.pid()}.txt"
      try File.write_text(path, "é\r\na\rb\n")
      source = (
        "try:\n    text: str = open(\"#{path}\").read()\n    print(len(text))\n    print(text)\nexcept OSError:\n    print(\"failed\")\n"
      )

      result = agrees(compiled.unwrap!, 22, source) do |got| Test.eq(got, "6\né\na\nb\n\n") end

      _ = Path.remove(path)
      result
    end,
    Test.test("the result of write has no form") do
      refuses(
        compiled.unwrap!,
        23,
        "print(open(\"/tmp/agc_never\", \"w\").write(\"x\"))\n",
        ["error[PY-OUT-OF-SUBSET]", "the result of `write`"],
      )
    end,
    Test.test("a def named open is the user's own") do
      agrees(compiled.unwrap!, 24, "def open(p: str) -> int:\n    return 7\nprint(open(\"a\"))\n") do |got|
        Test.eq(got, "7\n")
      end
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
