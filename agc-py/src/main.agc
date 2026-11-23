## The `agc-py` command line: translates one typed `.py` file to `.agc`.
##
##   agentica agc-py/src/main.agc FILE.py [-o OUT.agc]
##   agentica agc-py/src/main.agc FILE.py --agcb -o OUT.agcb
##
## Without `-o` the `.agc` text goes to standard output. The whole text is
## built before anything is written, and `-o` writes a temporary file beside
## the output and renames it into place, so a failure leaves no partial file
## and keeps an older output as it was. `--agcb` compiles the emitted program
## with `agentica compile` (`$AGENTICA`, else `agentica` on `PATH`) in a private folder
## beside the output, where the program is named after the input
## (`prog.py` becomes `prog.agc`): the bytecode records that name, so the same
## input name and text give the same bytes wherever the output goes. A
## refusal, or a compile failure, prints its diagnostics to standard error and
## exits 1; a bad command line exits 2.

import Grammar from "../../src/grammar"
import OP from "std/option_parser"
import {Arg, Opt, Kind} from "std/option_parser"
import Py2Agc from "py2agc"

GRAMMAR = "grammars/py312.grammar"

struct Options
  file: String
  output: Optional[String]
  agcb: Bool
end

def main() -> Void
  args = System.args()
  parsed = (
    parser()
    |> OP.parse(args)
    |> OP.run!()
  )

  file = OP.string(parsed, "file")
  options = Options(file: file, output: OP.optional_string(parsed, "output"), agcb: OP.flag(parsed, "agcb"))
  if options.agcb and options.output == none
    IO.warn("agc-py: --agcb needs -o OUT.agcb\nTry 'agc-py --help' for more information")
    System.exit(2)
  end

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
    [
      Opt(name: "output", short: "o", metavar: "OUT", help: "write the result here instead of standard output"),
      Opt(name: "agcb", kind: Kind.Flag, help: "compile to bytecode with `agentica compile`; needs -o"),
    ],
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

    some(path) if options.agcb -> compile_atomic(path, program_name(options.file), text)
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

# The emitted program is named after the input, as `agentica` names it in the bytecode.
def program_name(file: String) -> String
  parts = file.split("/")
  base = parts[parts.size - 1]
  return "#{base.slice(0, base.length - 3)}.agc" if base.end_with?(".py")

  "#{base}.agc"
end

def compile_atomic(path: String, name: String, text: String) -> Result[Void]
  folder = "#{path}.#{System.pid()}.tmp"
  case Dir.mkdir_private(folder)
    error(e) -> return error("agc-py: cannot write #{path}: #{e.message}")
    ok(_) -> nil
  end

  result = compile_in(folder, name, text, path)
  _ = Path.remove(folder)
  result
end

def compile_in(folder: String, name: String, text: String, path: String) -> Result[Void]
  built = "#{folder}/out.agcb"
  case File.write_text("#{folder}/#{name}", text)
    error(e) -> return error("agc-py: cannot write #{path}: #{e.message}")
    ok(_) -> nil
  end

  try agentica_compile(folder, name, built)
  case Path.replace(built, path)
    ok(_) -> ok()
    error(e) -> error("agc-py: cannot write #{path}: #{e.message}")
  end
end

# The binary that compiles: `$AGENTICA` (as the Makefile sets it) or `agentica`.
def agentica() -> String
  case System.env("AGENTICA")
    ok(path) if !path.empty?() -> path
    _ -> "agentica"
  end
end

# `agentica compile` with its own diagnostic as the error, naming the program
# without its temporary folder; the bytecode cache is off so that nothing is
# written beside it.
def agentica_compile(folder: String, name: String, output: String) -> Result[Void]
  args = ["--no-cache", "compile", "#{folder}/#{name}", "-o", output]
  case Process.spawn_captured(agentica(), args)
    error(e) -> error("agc-py: cannot run agentica: #{e.message}")

    ok(proc) ->
      result = finish_compile(proc, folder)
      Process.close(proc)
      result
  end
end

def finish_compile(proc: Process, folder: String) -> Result[Void]
  out = try Process.output(proc, 120000)
  code = try Process.wait(proc, 120000)
  return ok() if code == 0

  error(
    "agc-py: `agentica compile` refused the emitted program (exit #{code})\n#{out.stderr.replace("#{folder}/", "")}" +
    "\nrun without --agcb to see the emitted program",
  )
end
