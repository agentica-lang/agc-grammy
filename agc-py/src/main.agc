## The `agc-py` command line: translates one typed `.py` file to `.agc`.
##
##   agentica agc-py/src/main.agc FILE.py [-o OUT.agc]
##
## Without `-o` the `.agc` text goes to standard output. The whole text is
## built before anything is written, and `-o` writes a temporary file beside
## the output and renames it into place, so a failure leaves no partial file
## and keeps an older output as it was. A refusal prints its diagnostics to
## standard error and exits 1; a bad command line exits 2.

import Grammar from "../../src/grammar"
import OP from "std/option_parser"
import {Arg, Opt} from "std/option_parser"
import Py2Agc from "py2agc"

GRAMMAR = "grammars/py312.grammar"

struct Options
  file: String
  output: Optional[String]
end

def main() -> Void
  args = System.args()
  parsed = (
    parser()
    |> OP.parse(args)
    |> OP.run!()
  )

  file = OP.string(parsed, "file")
  options = Options(file: file, output: OP.optional_string(parsed, "output"))
  case run(options)
    ok(_) -> System.exit(0)

    error(e) ->
      IO.warn(e.message)
      System.exit(1)
  end
end

private

def parser() -> OP.Parser
  OP.new(
    "agc-py",
    "Translates a typed Python file to Agentica.",
    [Arg(name: "file", metavar: "FILE.py", help: "the Python file to translate")],
    [Opt(name: "output", short: "o", metavar: "OUT.agc", help: "write the result here instead of standard output")],
  )
end

def run(options: Options) -> Result[Void]
  try check_distinct(options.file, options.output)
  grammar = try Grammar.load(try grammar_path())
  source = try read_source(options.file)
  text = try Py2Agc.translate(grammar, options.file, source)
  case options.output
    none ->
      print(text)
      ok()

    some(path) -> write_atomic(path, text)
  end
end

def read_source(file: String) -> Result[String]
  case File.read_text(file)
    ok(source) -> ok(source)
    error(e) -> error("agc-py: cannot read #{file}: #{e.message}")
  end
end

# The grammar lives beside this file, so the command works from any folder and
# through a link.
def grammar_path() -> Result[String]
  real = try Path.real(System.program_name())
  parts = real.split("/")
  ok("#{parts.take(parts.size - 1).join("/")}/../#{GRAMMAR}")
end

def check_distinct(file: String, output: Optional[String]) -> Result[Void]
  case output
    none -> ok()

    some(path) ->
      return error("agc-py: the output #{path} is the input file") if try Path.resolve(path) == try Path.resolve(file)

      ok()
  end
end

def write_atomic(path: String, text: String) -> Result[Void]
  temp = "#{path}.#{System.pid()}.tmp"
  case File.write_text(temp, text)
    error(e) ->
      _ = Path.remove(temp)
      return error("agc-py: cannot write #{path}: #{e.message}")

    ok(_) -> nil
  end

  case Path.replace(temp, path)
    ok(_) -> ok()

    error(e) ->
      _ = Path.remove(temp)
      error("agc-py: cannot write #{path}: #{e.message}")
  end
end
