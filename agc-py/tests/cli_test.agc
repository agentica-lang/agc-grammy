## The `agc-py` command line, run as a child process from the repo root:
## standard output, `-o`, failures that leave no output, and exit codes. Each
## test works in a folder of its own that it creates and removes.

GOOD = "def add(x: int, y: int) -> int:\n    return x + y\nprint(add(1, 2))\n"
# Recursion, a loop with a rebinding, floor division and modulo of negatives,
# true division, a map and a string length, all printed.
PROGRAM = (
  "def fib(n: int) -> int:\n    if n < 2:\n        return n\n    return fib(n - 1) + fib(n - 2)\n\n\ndef total(xs: list[int]) -> int:\n    acc: int = 0\n    for x in xs:\n        acc += x\n    return acc\n\n\ncounts: dict[str, int] = {\"a\": 1, \"b\": 2}\nprint(fib(15))\nprint(total([1, -2, 3, 40]))\nprint(-7 // 2, -7 % 3, 7 / 2)\nprint(counts[\"b\"], len(\"héllo\"))\ni: int = 0\nwhile i < 3:\n    print(\"n\" + str(i))\n    i += 1\n"
)

# The frontend does not check the range of an int literal yet, so only
# `agentica compile` refuses this one (CHECK-INT-RANGE). When the translator
# learns to refuse it, pick another program that the frontend lets through.
HUGE = "x: int = 99999999999999999999999\nprint(x)\n"
BAD = "def f(x) -> int:\n    return x\n"

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

def capture(command: String, args: List[String], folder: String = ".") -> Result[Ran]
  proc = try Process.spawn_captured(command, args, Process.Options(chdir: folder))
  out = try Process.output(proc, 60000)
  code = try Process.wait(proc, 60000)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

def run_bytecode(path: String) -> Result[Ran] = capture(agentica(), ["run", "--", path])

def run_agc(path: String) -> Result[Ran] = capture(agentica(), [path])

def python(path: String) -> Result[Ran] = capture("python3", [path])

def cli(args: List[String]) -> Result[Ran] = capture(agentica(), ["agc-py/src/main.agc"] + args)

# Runs `body` in a fresh folder of this test and removes it afterwards, whatever
# the body answers.
def in_folder(n: Int, body: Fn[String, Result[Void]]) -> Result[Void]
  folder = "/tmp/agc_cli_#{System.pid()}_#{n}"
  try Path.remove(folder)
  try Dir.mkdir_private(folder)
  result = body.call(folder)
  _ = Path.remove(folder)
  result
end

def main() -> Void
  Test.run([
    Test.test("without -o the program goes to standard output") do
      in_folder(1) do |dir|
        try File.write_text("#{dir}/good.py", GOOD)
        ran = try cli(["#{dir}/good.py"])
        try Test.eq(ran.code, 0)
        Test.assert(ran.stdout.include?("def add(x: Int, y: Int) -> Int"), ran.stdout)
      end
    end,
    Test.test("-o writes the same text and leaves no temporary file") do
      in_folder(2) do |dir|
        try File.write_text("#{dir}/good.py", GOOD)
        printed = try cli(["#{dir}/good.py"])
        ran = try cli(["#{dir}/good.py", "-o", "#{dir}/out.agc"])
        try Test.eq(ran.code, 0)
        try Test.eq(ran.stdout, "")
        try Test.eq(try File.read_text("#{dir}/out.agc"), printed.stdout)
        Test.eq(try Dir.list(dir), ["good.py", "out.agc"])
      end
    end,
    Test.test("a refusal prints its diagnostic and writes no output") do
      in_folder(3) do |dir|
        try File.write_text("#{dir}/old.agc", "kept\n")
        try File.write_text("#{dir}/bad.py", BAD)
        fresh = try cli(["#{dir}/bad.py", "-o", "#{dir}/new.agc"])
        try Test.eq(fresh.code, 1)
        try Test.assert(fresh.stderr.include?("error[PY-UNTYPED-DEF]"), fresh.stderr)
        old = try cli(["#{dir}/bad.py", "-o", "#{dir}/old.agc"])
        try Test.eq(old.code, 1)
        try Test.eq(try File.read_text("#{dir}/old.agc"), "kept\n")
        Test.eq(try Dir.list(dir), ["bad.py", "old.agc"])
      end
    end,
    Test.test("the output may not be the input file") do
      in_folder(4) do |dir|
        try File.write_text("#{dir}/good.py", GOOD)
        ran = try cli(["#{dir}/good.py", "-o", "#{dir}/./good.py"])
        try Test.eq(ran.code, 1)
        try Test.assert(ran.stderr.include?("is the input file"), ran.stderr)
        Test.eq(try File.read_text("#{dir}/good.py"), GOOD)
      end
    end,
    Test.test("it runs from any folder, by an absolute path or a bare file name") do
      in_folder(5) do |dir|
        try File.write_text("#{dir}/good.py", GOOD)
        main = try Path.resolve("agc-py/src/main.agc")
        ran = try capture(agentica(), [main, "good.py", "-o", "out.agc"], dir)
        try Test.eq(ran.code, 0)
        try Test.eq(try Dir.list(dir), ["good.py", "out.agc"])
        bare = try capture(agentica(), ["main.agc", "#{dir}/good.py", "-o", "#{dir}/bare.agc"], "agc-py/src")
        try Test.eq(bare.code, 0)
        Test.eq(try File.read_text("#{dir}/bare.agc"), try File.read_text("#{dir}/out.agc"))
      end
    end,
    Test.test("--agcb compiles to bytecode that runs, and the same input gives the same bytes anywhere") do
      in_folder(7) do |dir|
        try Dir.mkdir("#{dir}/a")
        try Dir.mkdir("#{dir}/b")
        try File.write_text("#{dir}/good.py", GOOD)
        first = try cli(["#{dir}/good.py", "--agcb", "-o", "#{dir}/a/first.agcb"])
        second = try cli(["#{dir}/good.py", "--agcb", "-o", "#{dir}/b/other.agcb"])
        try Test.eq(first.code, 0)
        try Test.eq(second.code, 0)
        try Test.eq(try File.sha256("#{dir}/a/first.agcb"), try File.sha256("#{dir}/b/other.agcb"))
        try Test.eq(try Dir.list("#{dir}/a"), ["first.agcb"])
        ran = try run_bytecode("#{dir}/a/first.agcb")
        try Test.eq(ran.code, 0)
        Test.eq(ran.stdout, "3\n")
      end
    end,
    Test.test("a compile failure shows the diagnostic, exits 1 and leaves nothing behind") do
      in_folder(8) do |dir|
        try File.write_text("#{dir}/huge.py", HUGE)
        ran = try cli(["#{dir}/huge.py", "--agcb", "-o", "#{dir}/huge.agcb"])
        try Test.eq(ran.code, 1)
        try Test.assert(ran.stderr.include?("error[CHECK-INT-RANGE]"), ran.stderr)
        try Test.assert(ran.stderr.include?("huge.agc:"), ran.stderr)
        try Test.assert(ran.stderr.include?("run without --agcb"), ran.stderr)
        Test.eq(try Dir.list(dir), ["huge.py"])
      end
    end,
    Test.test("a refusal before compiling writes nothing, and --agcb without -o exits 2") do
      in_folder(9) do |dir|
        try File.write_text("#{dir}/bad.py", BAD)
        refused = try cli(["#{dir}/bad.py", "--agcb", "-o", "#{dir}/bad.agcb"])
        try Test.eq(refused.code, 1)
        try Test.assert(refused.stderr.include?("error[PY-UNTYPED-DEF]"), refused.stderr)
        try Test.eq(try Dir.list(dir), ["bad.py"])
        usage = try cli(["#{dir}/bad.py", "--agcb"])
        Test.eq(usage.code, 2)
      end
    end,
    Test.test(".py to .agc to .agcb runs like python3 on both routes") do
      in_folder(10) do |dir|
        try File.write_text("#{dir}/prog.py", PROGRAM)
        expected = try python("#{dir}/prog.py")
        agc = try cli(["#{dir}/prog.py", "-o", "#{dir}/prog.agc"])
        agcb = try cli(["#{dir}/prog.py", "--agcb", "-o", "#{dir}/prog.agcb"])
        try Test.eq(agc.code, 0)
        try Test.eq(agcb.code, 0)
        try Test.assert(expected.stdout.include?("610"), expected.stdout)
        from_agc = try run_agc("#{dir}/prog.agc")
        from_agcb = try run_bytecode("#{dir}/prog.agcb")
        try Test.eq(from_agc.stdout, expected.stdout)
        try Test.eq(from_agc.code, expected.code)
        try Test.eq(from_agcb.stdout, expected.stdout)
        Test.eq(from_agcb.code, expected.code)
      end
    end,
    Test.test("a missing file exits 1 and a bad command line exits 2") do
      in_folder(6) do |dir|
        missing = try cli(["#{dir}/missing.py"])
        try Test.eq(missing.code, 1)
        try Test.assert(missing.stderr.include?("#{dir}/missing.py"), missing.stderr)
        usage = try cli([])
        Test.eq(usage.code, 2)
      end
    end,
  ])
end
