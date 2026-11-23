## The runnable corpus of SUBSET.md: each `corpus/NAME.py` is a whole program
## that `agc-py` translates, and the emitted `.agc` must run with the standard
## output and exit code that python3 gives the same file. A program python3
## cannot run (`next` is a name there, `continue` a syntax error here) has its
## expected output in `corpus/NAME.expected` instead. Programs print booleans
## through `yn` and no list of strings or map: the backend prints `true` and
## `["a"]` where python3 prints `True` and `['a']`. The parse-only corpus, where
## nothing runs, is `py312_corpus_test.agc`.

NAMES = [
  "types", "literals", "arith", "control", "loops_next", "strings", "lists_maps", "functions", "results", "precedence",
]
FOLDER = "agc-py/tests/corpus"

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
  out = try Process.output(proc, 120000)
  code = try Process.wait(proc, 120000)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

# What the program must print: the golden beside it, else python3's own run.
def expected(name: String) -> Result[Ran]
  if (try Dir.list(FOLDER)).include?("#{name}.expected")
    return ok(Ran(code: 0, stdout: try File.read_text("#{FOLDER}/#{name}.expected"), stderr: ""))
  end

  capture("python3", ["#{FOLDER}/#{name}.py"])
end

def runs_like_expected(name: String) -> Result[Void]
  folder = "/tmp/agc_corpus_#{System.pid()}_#{name}"
  try Path.remove(folder)
  try Dir.mkdir_private(folder)
  result = translate_and_compare(name, folder)
  _ = Path.remove(folder)
  result
end

def translate_and_compare(name: String, folder: String) -> Result[Void]
  want = try expected(name)
  built = try capture(agentica(), ["agc-py/src/main.agc", "#{FOLDER}/#{name}.py", "-o", "#{folder}/prog.agc"])
  try Test.assert(built.code == 0, built.stderr)
  ran = try capture(agentica(), ["#{folder}/prog.agc"])
  try Test.eq(ran.stdout, want.stdout)
  Test.eq(ran.code, want.code)
end

def main() -> Void
  tests = NAMES.map { |name| Test.test("#{name} runs like its expected output") do runs_like_expected(name) end }
  Test.run(
    tests +
    [
      Test.test("every program of the folder is listed") do
        found = (try Dir.list(FOLDER))
          .select { |file| file.end_with?(".py") }
          .map { |file| file.slice(0, file.length - 3) }

        Test.eq(found.sort, NAMES.sort)
      end,
    ],
  )
end
