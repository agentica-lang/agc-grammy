## Local module resolution (issue #25): the entry folder, the explicit search
## path and the stdlib table; dependency-ordered graphs; and the
## `PY-IMPORT-UNKNOWN` / `PY-NAME-UNKNOWN` / `PY-IMPORT-CYCLE` refusals with
## their spans. Every fixture is a real multi-file program written to a
## temporary directory, so the loader reads files exactly as phase 4 will.

import Grammar from "../../src/grammar"
import Modules from "../src/modules"

def reset(dir: String) -> Result[Void]
  try Path.remove(dir)
  Dir.mkdir(dir)
end

def write_fixture(dir: String, name: String, text: String) -> Result[String]
  path = dir + "/" + name
  try File.write_text(path, text)
  ok(path)
end

def edge_text(edge: Modules.ImportEdge) -> String
  case edge.source
    Modules.ModuleSource.Local(name) -> "local:" + name
    Modules.ModuleSource.Stdlib(name) -> "stdlib:" + name
  end
end

def module_names(graph: Modules.ModuleGraph) -> List[String] = graph.modules.map { |module| module.name }

def error_text(grammar: Grammar.Grammar, file: String) -> Result[String]
  case Modules.resolve(grammar, file, [])
    error(e) -> ok(e.message)
    ok(_) -> error("expected a refusal for #{file}")
  end
end

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  if System.args() == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    Test.test("resolves a local module from the entry folder in dependency order") do
      dir = "/tmp/agc_py_modules_folder"
      try reset(dir)
      try write_fixture(dir, "a.py", "from b import inc\nprint(inc(1))\n")
      try write_fixture(dir, "b.py", "def inc(x: int) -> int:\n    return x + 1\n")

      graph = try Modules.resolve(compiled.unwrap!, dir + "/a.py", [])
      try Test.eq(graph.root, "a")
      try Test.eq(module_names(graph), ["b", "a"])
      try Test.eq(List.first(graph.modules).program.funcs.map { |func| func.name }, ["inc"])
      entry = List.last(graph.modules)
      try Test.eq(entry.imports.map { |edge| edge_text(edge) }, ["local:b"])
      Test.eq(entry.path, dir + "/a.py")
    end,
    Test.test("the entry folder shadows the search path and the standard library") do
      base = "/tmp/agc_py_modules_order"
      try reset(base)
      dir = base + "/entry"
      search = base + "/search"
      try Dir.mkdir(dir)
      try Dir.mkdir(search)
      try write_fixture(dir, "a.py", "import b\nimport math\n")
      try write_fixture(dir, "b.py", "def entry_only() -> int:\n    return 1\n")
      try write_fixture(search, "b.py", "def search_only() -> int:\n    return 2\n")
      try write_fixture(search, "math.py", "def local_math() -> int:\n    return 3\n")

      graph = try Modules.resolve(compiled.unwrap!, dir + "/a.py", [search])
      try Test.eq(module_names(graph), ["b", "math", "a"])
      try Test.eq(List.first(graph.modules).program.funcs.map { |func| func.name }, ["entry_only"])
      try Test.eq(List.first(graph.modules.drop(1)).path, search + "/math.py")
      Test.eq(List.last(graph.modules).imports.map { |edge| edge_text(edge) }, ["local:b", "local:math"])
    end,
    Test.test("the search path is tried in order and the standard library last") do
      base = "/tmp/agc_py_modules_search"
      try reset(base)
      dir = base + "/entry"
      first = base + "/one"
      second = base + "/two"
      try Dir.mkdir(dir)
      try Dir.mkdir(first)
      try Dir.mkdir(second)
      try write_fixture(dir, "a.py", "import shared\nimport sys\n")
      try write_fixture(first, "shared.py", "def from_one() -> int:\n    return 1\n")
      try write_fixture(second, "shared.py", "def from_two() -> int:\n    return 2\n")

      graph = try Modules.resolve(compiled.unwrap!, dir + "/a.py", [first, second])
      version = List.first(graph.modules)
      try Test.eq(version.program.funcs.map { |func| func.name }, ["from_one"])
      Test.eq(List.last(graph.modules).imports.map { |edge| edge_text(edge) }, ["local:shared", "stdlib:sys"])
    end,
    Test.test("a dotted module path resolves only as a supported stdlib module") do
      dir = "/tmp/agc_py_modules_dotted"
      try reset(dir)
      try write_fixture(dir, "a.py", "import urllib.parse\n")
      try write_fixture(dir, "b.py", "import foo.bar\n")

      graph = try Modules.resolve(compiled.unwrap!, dir + "/a.py", [])
      try Test.eq(List.first(graph.modules).imports.map { |edge| edge_text(edge) }, ["stdlib:urllib.parse"])

      message = try error_text(compiled.unwrap!, dir + "/b.py")
      try Test.assert(message.include?("error[PY-IMPORT-UNKNOWN]"), message)
      Test.assert(message.include?("unknown module `foo.bar`"), message)
    end,
    Test.test("an unknown module refuses at the module path") do
      dir = "/tmp/agc_py_modules_unknown"
      try reset(dir)
      try write_fixture(dir, "a.py", "import nope\n")

      message = try error_text(compiled.unwrap!, dir + "/a.py")
      try Test.assert(message.include?("a.py:1:8 error[PY-IMPORT-UNKNOWN]"), message)
      try Test.assert(message.include?("unknown module `nope`"), message)
      try Test.assert(message.include?("1 | import nope"), message)
      Test.assert(message.include?("  |        ^^^^"), message)
    end,
    Test.test("an unknown imported name refuses at the name and lists the module's names") do
      dir = "/tmp/agc_py_modules_member"
      try reset(dir)
      try write_fixture(dir, "a.py", "from b import f, nope\n")
      try write_fixture(dir, "b.py", "def f(x: int) -> int:\n    return x\n")

      message = try error_text(compiled.unwrap!, dir + "/a.py")
      try Test.assert(message.include?("a.py:1:18 error[PY-NAME-UNKNOWN]"), message)
      try Test.assert(message.include?("module `b` does not define `nope`"), message)
      try Test.assert(message.include?("1 | from b import f, nope"), message)
      Test.assert(message.include?("  |                  ^^^^"), message)
    end,
    Test.test("an imported name is checked against what the local module declares") do
      dir = "/tmp/agc_py_modules_exports"
      try reset(dir)
      try write_fixture(dir, "a.py", "from b import count, helper\nprint(count)\n")
      try write_fixture(dir, "b.py", "count: int = 1\ndef helper() -> int:\n    return count\n")

      _ = try Modules.resolve(compiled.unwrap!, dir + "/a.py", [])
      try write_fixture(dir, "c.py", "from b import missing\n")
      message = try error_text(compiled.unwrap!, dir + "/c.py")
      try Test.assert(message.include?("does not define `missing`"), message)
      Test.assert(message.include?("the module defines: helper, count"), message)
    end,
    Test.test("an aliased imported name binds the alias and checks the member") do
      dir = "/tmp/agc_py_modules_alias"
      try reset(dir)
      try write_fixture(dir, "a.py", "from b import inc as bump\nprint(bump(1))\n")
      try write_fixture(dir, "b.py", "def inc(x: int) -> int:\n    return x + 1\n")

      graph = try Modules.resolve(compiled.unwrap!, dir + "/a.py", [])
      try Test.eq(List.last(graph.modules).imports.map { |edge| edge_text(edge) }, ["local:b"])
      Test.eq(List.first(graph.modules).program.funcs.map { |func| func.name }, ["inc"])
    end,
    Test.test("a cycle reports every import span of the cycle") do
      dir = "/tmp/agc_py_modules_cycle"
      try reset(dir)
      try write_fixture(dir, "a.py", "import b\n")
      try write_fixture(dir, "b.py", "from a import thing\n")

      message = try error_text(compiled.unwrap!, dir + "/a.py")
      try Test.eq(message.split("error[PY-IMPORT-CYCLE]").size - 1, 2)
      try Test.assert(message.include?("a.py:1:1 error[PY-IMPORT-CYCLE]"), message)
      try Test.assert(message.include?("b.py:1:1 error[PY-IMPORT-CYCLE]"), message)
      try Test.assert(message.include?("circular import: a -> b -> a"), message)
      Test.assert(message.include?("1 | import b") and message.include?("1 | from a import thing"), message)
    end,
    Test.test("a self import is a cycle of one module") do
      dir = "/tmp/agc_py_modules_self"
      try reset(dir)
      try write_fixture(dir, "a.py", "import a\n")

      message = try error_text(compiled.unwrap!, dir + "/a.py")
      try Test.eq(message.split("error[PY-IMPORT-CYCLE]").size - 1, 1)
      Test.assert(message.include?("circular import: a -> a"), message)
    end,
    Test.test("a module is parsed once however many modules import it") do
      dir = "/tmp/agc_py_modules_shared"
      try reset(dir)
      try write_fixture(dir, "a.py", "import b, c\n")
      try write_fixture(dir, "c.py", "import b\n")
      try write_fixture(dir, "b.py", "def shared() -> int:\n    return 1\n")

      graph = try Modules.resolve(compiled.unwrap!, dir + "/a.py", [])
      try Test.eq(module_names(graph), ["b", "c", "a"])
      try Test.eq(graph.modules.size, 3)
      Test.eq(List.last(graph.modules).imports.map { |edge| edge_text(edge) }, ["local:b", "local:c"])
    end,
    Test.test("the entry stem is the module name and must be an identifier") do
      dir = "/tmp/agc_py_modules_stem"
      try reset(dir)
      try write_fixture(dir, "prog.py", "print(1)\n")
      try write_fixture(dir, "bad-name.py", "print(1)\n")

      graph = try Modules.resolve(compiled.unwrap!, dir + "/prog.py", [])
      try Test.eq(graph.root, "prog")

      message = try error_text(compiled.unwrap!, dir + "/bad-name.py")
      try Test.assert(message.include?("error[PY-IMPORT-UNKNOWN]"), message)
      Test.assert(message.include?("stem `bad-name`, which is not an identifier"), message)
    end,
    Test.test("a frontend refusal inside an imported module names that file") do
      dir = "/tmp/agc_py_modules_frontend"
      try reset(dir)
      try write_fixture(dir, "a.py", "import b\n")
      try write_fixture(dir, "b.py", "def loose(x):\n    return x\n")

      message = try error_text(compiled.unwrap!, dir + "/a.py")
      try Test.assert(message.include?("b.py:1:1 error[PY-UNTYPED-DEF]"), message)
      Test.assert(!message.include?("a.py:"), message)
    end,
  ])
end
