## The `agc-py` command line: translates one typed `.py` file to `.agc`.
##
##   agentica agc-py/src/main.agc FILE.py [-I DIR]... [-o OUT.agc]
##   agentica agc-py/src/main.agc FILE.py [-I DIR]... --agcb -o OUT.agcb
##
## Without `-o` the `.agc` text goes to standard output. The whole text is
## built before anything is written, and `-o` writes temporary files beside
## the outputs and renames them into place, so a failure leaves no partial
## file and keeps an older output as it was.
##
## The local modules `FILE.py` imports are found in its folder, then in each
## `-I DIR` in order. A program with imports is one `.agc` file per module,
## so it needs `-o`: the entry module goes to OUT.agc and every imported
## module to `NAME.agc` in the folder of OUT.agc.
##
## `--agcb` compiles the emitted program with `agentica compile`
## (`$AGC_PY_AGENTICA`, else `agentica` on `PATH`) in a private folder beside
## the output. The program is named after the input (`prog.py` becomes
## `prog.agc`): the bytecode records that name, so the same input name and text
## give the same bytes wherever the output goes.
##
## A refusal, or a compile failure, prints its diagnostics to standard error
## and exits 1; a bad command line exits 2.

import Grammar from "../../src/grammar"
import OP from "std/option_parser"
import {Arg, Opt, Kind} from "std/option_parser"
import Link from "link"
import Py2Agc from "py2agc"

GRAMMAR = "grammars/py312.grammar"

struct Options
  file: String
  output: Optional[String]
  includes: List[String]
  agcb: Bool
end

# One file to write: its path and its text.
struct Out
  path: String
  text: String
end

# The `-I DIR` pairs of the command line and the words left for the parser.
struct Split
  rest: List[String]
  includes: List[String]
end

def main() -> Void
  split = split_includes(System.args())
  parsed = (
    parser()
    |> OP.parse(split.rest)
    |> OP.run!()
  )

  file = OP.string(parsed, "file")
  options = Options(
    file: file,
    output: OP.optional_string(parsed, "output"),
    includes: split.includes,
    agcb: OP.flag(parsed, "agcb"),
  )

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
    "Translates a typed Python file to Agentica. Imported modules are found beside FILE.py, then in each -I DIR (repeatable).",
    [Arg(name: "file", metavar: "FILE.py", help: "the Python file to translate")],
    [
      Opt(name: "output", short: "o", metavar: "OUT", help: "write the result here instead of standard output"),
      Opt(name: "agcb", kind: Kind.Flag, help: "compile to bytecode with `agentica compile`; needs -o"),
    ],
  )
end

# `-I DIR` and `-IDIR` are taken out before the parser sees the words (it
# keeps one value per option, and `-I` repeats); `--` ends them.
def split_includes(args: List[String]) -> Split
  rest: List[String] = []
  includes: List[String] = []
  index = 0
  while index < args.size
    word = args[index]
    if word == "--"
      rest = rest + args.drop(index)
      break
    end

    if word == "-I" and index + 1 < args.size
      includes = includes.push(args[index + 1])
      index += 2
    elsif word.start_with?("-I") and word.length > 2
      includes = includes.push(word.slice(2, word.length - 2))
      index += 1
    else
      rest = rest.push(word)
      index += 1
    end
  end

  Split(rest: rest, includes: includes)
end

def run(options: Options) -> Result[Void]
  try check_distinct(options.file, options.output)
  grammar = try Grammar.load(try grammar_path())
  units = try Py2Agc.translate_modules(grammar, options.file, options.includes)
  case options.output
    none ->
      if units.size > 1
        return error("agc-py: #{options.file} imports local modules, which need one file each: pass -o OUT.agc")
      end

      print(List.first(units).text)
      ok()

    some(path) if options.agcb -> compile_atomic(path, units)
    some(path) -> write_all(try outputs(path, units))
  end
end

# The entry module goes to `path` and every imported module to its own name
# beside it; an imported module may not land on `path` itself.
def outputs(path: String, units: List[Link.Unit]) -> Result[List[Out]]
  folder = folder_of(path)
  target = try Path.resolve(path)
  files: List[Out] = []
  for unit in units.take(units.size - 1)
    beside = "#{folder}/#{unit.name}"
    return error("agc-py: the output #{path} is the file of module #{unit.name}") if try Path.resolve(beside) == target

    files = files.push(Out(path: beside, text: unit.text))
  end

  ok(files.push(Out(path: path, text: List.last(units).text)))
end

def folder_of(path: String) -> String
  parts = path.split("/")
  return "." if parts.size <= 1
  return "/" if parts.size == 2 and parts[0].empty?

  parts.take(parts.size - 1).join("/")
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

# Every file goes to a temporary beside it first and is renamed into place
# only when all of them were written, so a failed write leaves the outputs as
# they were.
def write_all(files: List[Out]) -> Result[Void]
  for file in files
    case File.write_text(temp_name(file.path), file.text)
      ok(_) -> nil

      error(e) ->
        remove_temps(files)
        return error("agc-py: cannot write #{file.path}: #{e.message}")
    end
  end

  for file in files
    case Path.replace(temp_name(file.path), file.path)
      ok(_) -> nil

      error(e) ->
        remove_temps(files)
        return error("agc-py: cannot write #{file.path}: #{e.message}")
    end
  end

  ok()
end

def temp_name(path: String) -> String = "#{path}.#{System.pid()}.tmp"

def remove_temps(files: List[Out]) -> Void
  for file in files
    _ = Path.remove(temp_name(file.path))
  end
end

def compile_atomic(path: String, units: List[Link.Unit]) -> Result[Void]
  folder = "#{path}.#{System.pid()}.tmp"
  case Dir.mkdir_private(folder)
    error(e) -> return error("agc-py: cannot write #{path}: #{e.message}")
    ok(_) -> nil
  end

  result = compile_in(folder, units, path)
  _ = Path.remove(folder)
  result
end

# Every module is written to the private folder; the entry module (the last
# unit) is the program `agentica compile` starts from.
def compile_in(folder: String, units: List[Link.Unit], path: String) -> Result[Void]
  built = "#{folder}/out.agcb"
  for unit in units
    case File.write_text("#{folder}/#{unit.name}", unit.text)
      error(e) -> return error("agc-py: cannot write #{path}: #{e.message}")
      ok(_) -> nil
    end
  end

  name = List.last(units).name
  try agentica_compile(folder, name, built)
  case Path.replace(built, path)
    ok(_) -> ok()
    error(e) -> error("agc-py: cannot write #{path}: #{e.message}")
  end
end

# The binary that compiles: `$AGC_PY_AGENTICA` (the Makefile sets it) or
# `agentica`.
def agentica() -> String
  case System.env("AGC_PY_AGENTICA")
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

  diagnostic = out.stderr.replace("#{folder}/", "").strip()
  error(
    "agc-py: `agentica compile` refused the emitted program (exit #{code})\n#{diagnostic}\n" +
    "run without --agcb to see the emitted program",
  )
end
