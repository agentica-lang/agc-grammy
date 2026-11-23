## The `agc-py` command line, run as a child process from the repo root:
## standard output, `-o`, failures that leave no output, and exit codes. Each
## test works in a folder of its own that it creates and removes.

GOOD = "def add(x: int, y: int) -> int:\n    return x + y\nprint(add(1, 2))\n"
BAD = "def f(x) -> int:\n    return x\n"

struct Ran
  code: Int
  stdout: String
  stderr: String
end

# The binary under test: `$AGENTICA` (the Makefile sets it) or `agentica`.
def agentica() -> String
  case System.env("AGENTICA")
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

def cli(args: List[String]) -> Result[Ran] = capture(agentica(), ["agc-py/src/main.agc"] + args)

# Runs `body` in a fresh folder of this test and removes it afterwards, whatever
# the body answers.
def in_folder(n: Int, body: Fn[String, Result[Void]]) -> Result[Void]
  folder = "/tmp/agc_cli_#{System.pid()}_#{n}"
  try Path.remove(folder)
  try Dir.mkdir(folder)
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
