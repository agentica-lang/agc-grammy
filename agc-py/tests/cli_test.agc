## The `agc-py` command line, run as a child process from the repo root:
## standard output, `-o`, failures that leave no output, and exit codes.

GOOD = "def add(x: int, y: int) -> int:\n    return x + y\nprint(add(1, 2))\n"
HUGE = "x: int = 99999999999999999999999\nprint(x)\n"
BAD = "def f(x) -> int:\n    return x\n"

struct Ran
  code: Int
  stdout: String
  stderr: String
end

def cli(args: List[String]) -> Result[Ran]
  proc = try Process.spawn_captured("agentica", ["agc-py/src/main.agc"] + args)
  out = try Process.output(proc, 60000)
  code = try Process.wait(proc, 60000)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

def run_bytecode(path: String) -> Result[Ran]
  proc = try Process.spawn_captured("agentica", ["run", "--", path])
  out = try Process.output(proc, 60000)
  code = try Process.wait(proc, 60000)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

def exists?(path: String) -> Bool
  case File.stat(path)
    ok(_) -> true
    error(_) -> false
  end
end

def main() -> Void
  Test.run([
    Test.test("without -o the program goes to standard output") do
      try File.write_text("/tmp/agc_cli_good.py", GOOD)
      ran = try cli(["/tmp/agc_cli_good.py"])
      try Test.eq(ran.code, 0)
      Test.assert(ran.stdout.include?("def add(x: Int, y: Int) -> Int"), ran.stdout)
    end,
    Test.test("-o writes the same text and leaves no temporary file") do
      try Path.remove("/tmp/agc_cli_out.agc")
      try File.write_text("/tmp/agc_cli_good.py", GOOD)
      printed = try cli(["/tmp/agc_cli_good.py"])
      ran = try cli(["/tmp/agc_cli_good.py", "-o", "/tmp/agc_cli_out.agc"])
      try Test.eq(ran.code, 0)
      try Test.eq(ran.stdout, "")
      try Test.eq(try File.read_text("/tmp/agc_cli_out.agc"), printed.stdout)
      Test.assert(!exists?("/tmp/agc_cli_out.agc.tmp"), "temporary file left behind")
    end,
    Test.test("a refusal prints its diagnostic and writes no output") do
      try Path.remove("/tmp/agc_cli_new.agc")
      try File.write_text("/tmp/agc_cli_old.agc", "kept\n")
      try File.write_text("/tmp/agc_cli_bad.py", BAD)
      fresh = try cli(["/tmp/agc_cli_bad.py", "-o", "/tmp/agc_cli_new.agc"])
      try Test.eq(fresh.code, 1)
      try Test.assert(fresh.stderr.include?("error[PY-UNTYPED-DEF]"), fresh.stderr)
      try Test.assert(!exists?("/tmp/agc_cli_new.agc"), "output created by a failure")
      try Test.assert(!exists?("/tmp/agc_cli_new.agc.tmp"), "temporary file left behind")
      old = try cli(["/tmp/agc_cli_bad.py", "-o", "/tmp/agc_cli_old.agc"])
      try Test.eq(old.code, 1)
      Test.eq(try File.read_text("/tmp/agc_cli_old.agc"), "kept\n")
    end,
    Test.test("--agcb compiles to bytecode that runs, and the same input gives the same bytes anywhere") do
      try Path.remove("/tmp/agc_cli_b1")
      try Path.remove("/tmp/agc_cli_b2")
      try Dir.mkdir("/tmp/agc_cli_b1")
      try Dir.mkdir("/tmp/agc_cli_b2")
      try File.write_text("/tmp/agc_cli_good.py", GOOD)
      first = try cli(["/tmp/agc_cli_good.py", "--agcb", "-o", "/tmp/agc_cli_b1/first.agcb"])
      second = try cli(["/tmp/agc_cli_good.py", "--agcb", "-o", "/tmp/agc_cli_b2/other.agcb"])
      try Test.eq(first.code, 0)
      try Test.eq(second.code, 0)
      try Test.eq(try File.sha256("/tmp/agc_cli_b1/first.agcb"), try File.sha256("/tmp/agc_cli_b2/other.agcb"))
      try Test.eq(try Dir.list("/tmp/agc_cli_b1"), ["first.agcb"])
      ran = try run_bytecode("/tmp/agc_cli_b1/first.agcb")
      try Test.eq(ran.code, 0)
      Test.eq(ran.stdout, "3\n")
    end,
    Test.test("a compile failure shows the diagnostic, exits 1 and leaves nothing behind") do
      try Path.remove("/tmp/agc_cli_b3")
      try Dir.mkdir("/tmp/agc_cli_b3")
      try File.write_text("/tmp/agc_cli_huge.py", HUGE)
      ran = try cli(["/tmp/agc_cli_huge.py", "--agcb", "-o", "/tmp/agc_cli_b3/huge.agcb"])
      try Test.eq(ran.code, 1)
      try Test.assert(ran.stderr.include?("error[CHECK-INT-RANGE]"), ran.stderr)
      try Test.assert(ran.stderr.include?("huge.agc:"), ran.stderr)
      Test.eq(try Dir.list("/tmp/agc_cli_b3"), [])
    end,
    Test.test("a refusal before compiling writes nothing, and --agcb without -o exits 2") do
      try File.write_text("/tmp/agc_cli_bad.py", BAD)
      refused = try cli(["/tmp/agc_cli_bad.py", "--agcb", "-o", "/tmp/agc_cli_b3/bad.agcb"])
      try Test.eq(refused.code, 1)
      try Test.assert(refused.stderr.include?("error[PY-UNTYPED-DEF]"), refused.stderr)
      try Test.eq(try Dir.list("/tmp/agc_cli_b3"), [])
      usage = try cli(["/tmp/agc_cli_good.py", "--agcb"])
      Test.eq(usage.code, 2)
    end,
    Test.test("a missing file exits 1 and a bad command line exits 2") do
      missing = try cli(["/tmp/agc_cli_missing.py"])
      try Test.eq(missing.code, 1)
      try Test.assert(missing.stderr.include?("/tmp/agc_cli_missing.py"), missing.stderr)
      usage = try cli([])
      Test.eq(usage.code, 2)
    end,
  ])
end
