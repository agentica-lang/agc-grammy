## Linked-module emission through the command line (issue #26): one `.agc`
## file per module, the import forms and their aliases, `-I`, what a call
## through an import checks, and what refuses (and in which file). Each test
## runs the command as a child process (the runner's step budget is too small
## for several translations in one file) in a folder of its own.

LIB = "def inc(x: int, step: int) -> int:\n    return x + step\n\n\ndef twice(x: int) -> int:\n    return x * 2\n"
MID = "from lib import twice\n\n\ndef quad(step: int, x: int) -> int:\n    return twice(x) + step\n"
SAME = "def f(x: int) -> int:\n    return x\n"

struct Ran
  code: Int
  stdout: String
  stderr: String
end

# The binary under test: `$AGC_PY_AGENTICA` (the Makefile sets it) or
# `agentica`.
def agentica() -> String
  case System.env("AGC_PY_AGENTICA")
    ok(path) if !path.empty?() -> path
    _ -> "agentica"
  end
end

def capture(command: String, args: List[String]) -> Result[Ran]
  proc = try Process.spawn_captured(command, args)
  out = try Process.output(proc, 60000)
  code = try Process.wait(proc, 60000)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

def cli(args: List[String]) -> Result[Ran] = capture(agentica(), ["agc-py/src/main.agc"] + args)

# Runs `body` in a fresh folder of this test and removes it afterwards, whatever
# the body answers.
def in_folder(n: Int, body: Fn[String, Result[Void]]) -> Result[Void]
  folder = "/tmp/agc_link_#{System.pid()}_#{n}"
  try Path.remove(folder)
  try Dir.mkdir_private(folder)
  result = body.call(folder)
  _ = Path.remove(folder)
  result
end

def write_files(dir: String, files: Map[String, String]) -> Result[Void]
  for name in files.keys()
    try File.write_text("#{dir}/#{name}.py", files.get(name, ""))
  end

  ok()
end

# Translating `prog.py` (with `files` beside it) refuses: exit 1, nothing
# written, and the diagnostic holds every needle.
def refuses(n: Int, files: Map[String, String], needles: List[String]) -> Result[Void]
  in_folder(n) do |dir|
    try write_files(dir, files)
    ran = try cli(["#{dir}/prog.py", "-o", "#{dir}/out.agc"])
    try Test.eq(ran.code, 1)
    try Test.eq(try Dir.list(dir), Map.keys(files).sort.map { |name| "#{name}.py" })
    for needle in needles
      try Test.assert(ran.stderr.include?(needle), ran.stderr)
    end

    ok()
  end
end

def main() -> Void
  Test.run([
    Test.test("every import form links to the sibling file and runs like python3, from .agc and from .agcb") do
      in_folder(1) do |dir|
        try Dir.mkdir("#{dir}/app")
        try Dir.mkdir("#{dir}/one")
        try Dir.mkdir("#{dir}/two")
        try Dir.mkdir("#{dir}/out")
        prog = "import lib\nimport lib as l2\nimport mid\nimport util\nfrom lib import twice as dbl, inc\n"
        prog = prog + "from mid import quad\nprint(lib.inc(1, 2), l2.twice(3), dbl(4), inc(5, 6), quad(step=7, x=8))\n"
        prog = prog + "print(util.f(9))\n"
        try write_files("#{dir}/app", {"prog": prog})
        try write_files("#{dir}/one", {"lib": LIB, "mid": MID})
        try write_files("#{dir}/two", {"util": SAME})
        args = ["#{dir}/app/prog.py", "-I", "#{dir}/one", "-I#{dir}/two"]
        agc = try cli(args + ["-o", "#{dir}/out/prog.agc"])
        try Test.eq(agc.code, 0)
        try Test.eq(try Dir.list("#{dir}/out"), ["lib.agc", "mid.agc", "prog.agc", "util.agc"])
        text = try File.read_text("#{dir}/out/prog.agc")
        try Test.assert(text.start_with?("import Lib from \"lib\"\nimport L2 from \"lib\"\n"), text)
        try Test.assert(text.include?("import {twice as dbl, inc} from \"lib\"\nimport {quad} from \"mid\""), text)
        try Test.assert(!text.include?("import Mid"), text)
        try Test.assert(!(try File.read_text("#{dir}/out/lib.agc")).include?("def main"), "a module has no main")
        agcb = try cli(args + ["--agcb", "-o", "#{dir}/prog.agcb"])
        try Test.eq(agcb.code, 0)
        expected = try capture("env", ["PYTHONPATH=#{dir}/one:#{dir}/two", "python3", "#{dir}/app/prog.py"])
        try Test.eq(expected.stdout, "3 6 8 11 23\n9\n")
        from_agc = try capture(agentica(), ["#{dir}/out/prog.agc"])
        from_agcb = try capture(agentica(), ["run", "--", "#{dir}/prog.agcb"])
        try Test.eq(from_agc.stdout, expected.stdout)
        Test.eq(from_agcb.stdout, expected.stdout)
      end
    end,
    Test.test("a program with imports needs -o, and an output that is a module's file is refused") do
      in_folder(2) do |dir|
        try write_files(dir, {"prog": "import lib\nprint(lib.twice(2))\n", "lib": LIB})
        printed = try cli(["#{dir}/prog.py"])
        try Test.eq(printed.code, 1)
        try Test.eq(printed.stdout, "")
        try Test.assert(printed.stderr.include?("pass -o OUT.agc"), printed.stderr)
        clash = try cli(["#{dir}/prog.py", "-o", "#{dir}/lib.agc"])
        try Test.eq(clash.code, 1)
        try Test.assert(clash.stderr.include?("module lib.agc"), clash.stderr)
        Test.eq(try Dir.list(dir), ["lib.py", "prog.py"])
      end
    end,
    Test.test("a call through an import checks arity like a local call") do
      refuses(
        3,
        {"prog": "from lib import inc\nprint(inc(1))\n", "lib": LIB},
        ["prog.py:2:1 error[PY-CALL-ARITY]", "`inc` is missing 1 required argument (`step`)"],
      )
    end,
    Test.test("a default is not lowered across modules") do
      refuses(
        4,
        {"prog": "import lib\nprint(lib.f(1))\n", "lib": "def f(x: int, y: int = 1) -> int:\n    return x + y\n"},
        ["error[PY-CALL-ARITY]", "`lib.f` is missing 1 required argument (`y`)"],
      )
    end,
    Test.test("an argument of the wrong type refuses") do
      refuses(5, {"prog": "import lib\nprint(lib.twice(\"a\"))\n", "lib": LIB}, ["error[PY-TYPE-MISMATCH]"])
    end,
    Test.test("a member the module does not have refuses") do
      refuses(
        6,
        {"prog": "import lib\nprint(lib.nope(1))\n", "lib": LIB},
        ["error[PY-NAME-UNKNOWN]", "does not define a function `nope`"],
      )
    end,
    Test.test("a member and a module are not values") do
      try refuses(7, {"prog": "import lib\nx: int = lib.twice\n", "lib": LIB}, ["`lib.twice` is not a value"])
      refuses(8, {"prog": "import lib\nprint(lib)\n", "lib": LIB}, ["module `lib` is not a value"])
    end,
    Test.test("a type alias cannot be imported") do
      refuses(
        9,
        {"prog": "from lib import Names\n", "lib": "type Names = list[str]\n"},
        ["prog.py:1:17 error[PY-OUT-OF-SUBSET]", "type aliases do not cross modules"],
      )
    end,
    Test.test("a name a module only imports cannot be imported through it") do
      refuses(
        10,
        {"prog": "from mid import twice\n", "lib": LIB, "mid": MID},
        ["prog.py:1:17 error[PY-NAME-UNKNOWN]", "module `mid` has no function `twice`"],
      )
    end,
    Test.test("an imported module holds only defs and aliases") do
      refuses(
        11,
        {"prog": "import lib\nprint(1)\n", "lib": "count: int = 3\n"},
        ["lib.py:1:1 error[PY-OUT-OF-SUBSET]", "may only declare"],
      )
    end,
    Test.test("a standard-library import refuses until it is mapped") do
      refuses(
        12,
        {"prog": "import math\nprint(1)\n"},
        ["prog.py:1:8 error[PY-OUT-OF-SUBSET]", "`math` is a standard-library module"],
      )
    end,
    Test.test("a refusal in a deeper module is rendered against that module's file and writes nothing") do
      refuses(
        13,
        {
          "prog": "import mid\nprint(mid.g(1))\n", "lib": SAME,
          "mid": "import lib\n\n\ndef g(x: int) -> int:\n    return lib.f(\"a\")\n",
        },
        ["mid.py:5:", "error[PY-TYPE-MISMATCH]"],
      )
    end,
    Test.test("an import cycle and an unknown module refuse before emission") do
      try refuses(14, {"prog": "import lib\n", "lib": "import prog\n"}, ["error[PY-IMPORT-CYCLE]"])
      refuses(15, {"prog": "import nope\n"}, ["error[PY-IMPORT-UNKNOWN]"])
    end,
  ])
end
