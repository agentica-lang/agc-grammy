## Local module resolution for `agc-py` phase 3e (issue #25): one entry file
## plus its imports become a `ModuleGraph` whose modules are already parsed,
## built and scope-resolved by `Frontend.program`.
##
## Resolution is flat and ordered: `SUBSET.md` section 5's "the file's folder"
## is the entry file's folder (one program, one module directory), then the
## explicit search path in order, then the closed standard-library surface.
## A local file always wins, so `math.py` beside the entry shadows `math`.
## Only a single-segment path can be local (packages and `__init__` are
## excluded); a dotted path resolves only as a supported stdlib module.
## A module's identity is its name: a file's stem must equal the name the
## import spells, and the entry file's stem must be an identifier, because
## one file is one module and the stem is the module name.
##
## The graph answers `modules` in dependency order (every module follows the
## local modules it imports; the entry module is last) with each module's
## `path`, resolved `program` and `imports`. Each `ImportEdge` carries the
## frontend declaration and where it points (`Local` module or `Stdlib`), so
## linked-module emission (`link.agc`) can walk the same tree without
## re-resolving it. Stdlib members stay unresolved: issue #27 owns them, and
## resolution only checks that the module family is in the closed table.
##
## Refusals are `PY-*` diagnostics rendered like every other frontend one,
## each in the file whose span it uses:
## - `PY-IMPORT-UNKNOWN` at the module path for an unresolvable module.
## - `PY-NAME-UNKNOWN` at the imported name for a member the local module
##   does not define (`SUBSET.md` section 5 pairs unknown modules and unknown
##   names this way; a missing stdlib member stays issue #27's).
## - `PY-IMPORT-CYCLE` at every import statement of the first cycle found
##   (one diagnostic per import span, so the full cycle is reported).
##
## The resolver is a library stage: `link.agc` emits the graph it answers.

import Frontend from "frontend"
import Grammar from "../../src/grammar"

## Where one import points: a local module the graph loaded, or a supported
## standard-library module family whose members issue #27 maps.
enum ModuleSource
  Local(String)
  Stdlib(String)
end

## One resolved import of one module: the declaration that names it and the
## target it resolved to.
struct ImportEdge
  decl: Frontend.ImportDecl
  source: ModuleSource
end

## One loaded module: its name (the file stem), the file it came from, the
## source of that file (a refusal inside the module renders against it), its
## validated program and its resolved imports in source order.
struct Module
  name: String
  path: String
  source: String
  program: Frontend.Program
  imports: List[ImportEdge]
end

## The resolved import graph: the entry module's name and every reachable
## module in dependency order (the entry module last).
struct ModuleGraph
  root: String
  modules: List[Module]
end

## One located import target: a local module with its file, a supported
## standard-library module path, or nothing.
enum Found
  Hit(String, String)
  Stdlib(String)
  Miss
end

## A module loading frame on the depth-first walk: the module, the file and
## source its spans belong to, and the import in its parent that entered it
## (`none` for the entry module).
struct Frame
  name: String
  path: String
  source: String
  entering: Optional[Frontend.ImportDecl]
end

## The walk's state: the imported modules already finished, the frames on the
## current path, the rendered refusals found so far, and whether the first
## cycle has already been reported.
struct Loader
  modules: List[Module]
  loaded: Set[String]
  frames: List[Frame]
  texts: List[String]
  cycle_seen: Bool
end

## One module's walk: the advanced loader plus the import edges of the module
## being loaded, in source order.
struct EdgeRun
  loader: Loader
  edges: List[ImportEdge]
end

## Resolves the module graph rooted at `file`: its own folder first, then
## `search_path` in order, then the supported standard library. Answers the
## graph, or every refusal rendered in source order (`file:line:col
## error[PY-*]`, one block per problem, separated by blank lines). The
## `error` is that text and nothing else: spans live only inside it, so a
## caller prints it and cannot inspect a refusal. A
## refusal inside an imported module is reported with that module's own file
## and source; a parse failure the engine words without a position and a file
## that cannot be read start with the path of the file at fault.
def resolve(grammar: Grammar.Grammar, file: String, search_path: List[String]) -> Result[ModuleGraph]
  name = module_stem(file)
  source = try read_source(file)
  if !valid_name?(name)
    return error(
      Frontend.render(
        file,
        source,
        Frontend.Diagnostic(
          code: "PY-IMPORT-UNKNOWN",
          message: "module file `#{file}` has the stem `#{name}`, which is not an identifier",
          help: some("rename it to `<module>.py`, for example `prog.py`"),
          start: 0,
          stop: 0,
        ),
      ),
    )
  end

  loader = load(
    Loader(modules: [], loaded: Set.new([]), frames: [], texts: [], cycle_seen: false),
    grammar,
    Frame(name: name, path: file, source: source, entering: none),
    folder_of(file),
    search_path,
  )

  return error(loader.texts.join("\n\n")) if !loader.texts.empty?

  ok(ModuleGraph(root: name, modules: loader.modules))
end

private

# The closed standard-library surface of `SUBSET.md` section 5. Resolution
# only accepts these module paths; mapping their members is issue #27, and
# anything outside the table (the excluded list included) is unknown.
STDLIB_MODULES = Set.new([
  "argparse",
  "cookies",
  "datetime",
  "hashlib",
  "html",
  "http.client",
  "json",
  "logging",
  "math",
  "mimetypes",
  "os",
  "pathlib",
  "random",
  "re",
  "string",
  "sys",
  "time",
  "toml",
  "urllib.parse",
])

# Loads one module and, depth first, every local module it imports. The
# caller has already refused a name on the current path (a cycle) and skips
# a name already loaded, so every name is parsed at most once.
def load(loader: Loader, grammar: Grammar.Grammar, frame: Frame, folder: String, search_path: List[String]) -> Loader
  return loader if loader.loaded.include?(frame.name)

  pushed = loader.with(frames: loader.frames.push(frame))
  case Frontend.program(grammar, frame.path, frame.source)
    error(e) -> finish(pushed, none, with_file(frame.path, e.message))
    ok(program) ->
      run = load_imports(pushed, grammar, imports_of(program), folder, search_path)
      module = Module(name: frame.name, path: frame.path, source: frame.source, program: program, imports: run.edges)

      finish(run.loader, some(module), "")
  end
end

# Pops the current frame and finishes its module: a module that reached the
# graph is marked loaded and appended (dependencies first); a module the
# frontend refused keeps its rendered diagnostic and is not appended, but is
# still marked loaded so a second importer does not report it twice.
def finish(loader: Loader, module: Optional[Module], text: String) -> Loader
  done = loader.with(
    frames: loader.frames.take(loader.frames.size - 1),
    loaded: loader.loaded.add(List.last(loader.frames).name),
  )

  if !text.empty?
    done = done.with(texts: done.texts.push(text))
  end

  case module
    some(loaded) -> done.with(modules: done.modules.push(loaded))
    none -> done
  end
end

# Walks one module's import clauses in source order, resolving each target
# and recursing into a local module not yet loaded. The current frame is the
# last entry of `loader.frames`.
def load_imports(
  loader: Loader,
  grammar: Grammar.Grammar,
  decls: List[Frontend.ImportDecl],
  folder: String,
  search_path: List[String],
) -> EdgeRun
  current = loader
  edges: List[ImportEdge] = []
  for decl in decls
    path = Frontend.decl_path(decl)
    case locate(path.text, folder, search_path)
      Found.Stdlib(target) -> edges = edges.push(ImportEdge(decl: decl, source: ModuleSource.Stdlib(target)))
      Found.Miss -> current = add_refusal(current, unknown_module_diag(path))
      Found.Hit(target_name, target_path) ->
        edge = ImportEdge(decl: decl, source: ModuleSource.Local(target_name))
        edges = edges.push(edge)
        case frame_index(current.frames, target_name)
          some(_) -> current = report_cycle(current, decl, target_name)
          none ->
            if !current.loaded.include?(target_name)
              current = open_local(current, grammar, decl, target_name, target_path, path, folder, search_path)
            end
        end

        current = check_members(current, decl, target_name)
    end
  end

  EdgeRun(loader: current, edges: edges)
end

# Reads a local module and loads it below the current frame. A read that
# fails after the file was found refuses like an unresolvable import.
def open_local(
  loader: Loader,
  grammar: Grammar.Grammar,
  decl: Frontend.ImportDecl,
  name: String,
  path: String,
  module_path: Frontend.ModulePath,
  folder: String,
  search_path: List[String],
) -> Loader
  case File.read_text(path)
    error(e) -> add_refusal(loader, unreadable_module_diag(module_path, name, path, first_line(e.message)))
    ok(source) ->
      load(loader, grammar, Frame(name: name, path: path, source: source, entering: some(decl)), folder, search_path)
  end
end

# `from m import name` checks every member against the local module's
# top-level names. Stdlib members stay issue #27's; a local module the
# frontend refused or a cycle kept out of the graph has no member check.
def check_members(loader: Loader, decl: Frontend.ImportDecl, target: String) -> Loader
  case decl
    Frontend.ImportDecl.FromImport(_, names, _) ->
      case find_module(loader.modules, target)
        none -> loader
        some(module) ->
          known = exports(module.program)
          current = loader
          for name in names
            case name.member
              some(member) ->
                if !known.include?(member)
                  current = add_refusal(current, unknown_member_diag(module.name, member, known, name))
                end

              none -> current = current
            end
          end

          current
      end

    _ -> loader
  end
end

# The first cycle found is reported at every import span on the path it
# closes: the entering import of each frame from the cycle's first module on,
# plus the import being resolved. Later cycles are detected (the walk never
# recurses into a name on its path) but not reported twice.
def report_cycle(loader: Loader, decl: Frontend.ImportDecl, target: String) -> Loader
  return loader.with(cycle_seen: true) if loader.cycle_seen

  frames = loader.frames
  start = frame_index(frames, target)
  case start
    none -> loader
    some(from) ->
      chain = frames.drop(from).map { |frame| frame.name }.push(target).join(" -> ")
      current = loader.with(cycle_seen: true)
      i = from + 1
      while i < frames.size
        frame = frames[i]
        case frame.entering
          some(entering) ->
            current = add_in(current, frames[i - 1].path, frames[i - 1].source, cycle_diag(entering, chain))
          none -> current = current
        end

        i += 1
      end

      add_in(current, List.last(frames).path, List.last(frames).source, cycle_diag(decl, chain))
  end
end

# Locates one import target: a local `<name>.py` in the entry folder then the
# search path (single-segment names only; a package is excluded), else a
# supported stdlib module path.
def locate(name: String, folder: String, search_path: List[String]) -> Found
  if !name.include?(".")
    for dir in [folder] + search_path
      candidate = join_path(dir, name + ".py")
      return Found.Hit(name, candidate) if file_exists?(candidate) and module_stem(candidate) == name
    end
  end

  return Found.Stdlib(name) if STDLIB_MODULES.include?(name)

  Found.Miss
end

# The entry file's text; a failed read names the file and keeps one line.
def read_source(file: String) -> Result[String]
  case File.read_text(file)
    error(e) -> error("cannot read `#{file}`: #{first_line(e.message)}")
    ok(source) -> ok(source)
  end
end

def first_line(reason: String) -> String = List.first(reason.split("\n"))

# A frontend failure is either a rendered diagnostic, which already starts
# with `file:`, or a bare engine message with no position, which does not.
def with_file(file: String, text: String) -> String
  return text if text.start_with?(file + ":")

  "#{file}: #{text}"
end

def file_exists?(path: String) -> Bool
  case File.stat(path)
    ok(info) -> info.kind == "file"
    error(_) -> false
  end
end

# Every name a local module defines at top level: its `def`s and the bindings
# its top-level items declare (annotated values, aliases, imported names).
# Uses and `for` targets are not exported.
def exports(program: Frontend.Program) -> List[String]
  out: List[String] = []
  for func_def in program.funcs
    out = add_export(out, func_def.name)
  end

  for item in program.top
    for occ in Frontend.top_names(item)
      if occ.kind == "declare"
        out = add_export(out, occ.name)
      end
    end
  end

  out
end

def add_export(names: List[String], name: String) -> List[String]
  return names if names.include?(name)

  names.push(name)
end

def imports_of(program: Frontend.Program) -> List[Frontend.ImportDecl]
  out: List[Frontend.ImportDecl] = []
  for item in program.top
    case item
      Frontend.TopItem.ImportItem(decls) -> out = out + decls
      _ -> out = out
    end
  end

  out
end

def find_module(modules: List[Module], name: String) -> Optional[Module]
  for module in modules
    return some(module) if module.name == name
  end

  none
end

def frame_index(frames: List[Frame], name: String) -> Optional[Int]
  i = 0
  for frame in frames
    return some(i) if frame.name == name

    i += 1
  end

  none
end

def add_refusal(loader: Loader, diagnostic: Frontend.Diagnostic) -> Loader
  frame = List.last(loader.frames)
  add_in(loader, frame.path, frame.source, diagnostic)
end

def add_in(loader: Loader, file: String, source: String, diagnostic: Frontend.Diagnostic) -> Loader
  loader.with(texts: loader.texts.push(Frontend.render(file, source, diagnostic)))
end

def unknown_module_diag(path: Frontend.ModulePath) -> Frontend.Diagnostic
  help = "add `#{path.text}.py` to the entry folder or a search path, or check the name"
  if path.text.include?(".")
    dotted = STDLIB_MODULES.to_a.filter { |module| module.include?(".") }
    help = "a dotted module path must be a supported standard-library module: #{dotted.join(", ")}"
  end

  Frontend.Diagnostic(
    code: "PY-IMPORT-UNKNOWN",
    message: "unknown module `#{path.text}`",
    help: some(help),
    start: path.span.start,
    stop: path.span.stop,
  )
end

def unreadable_module_diag(
  path: Frontend.ModulePath,
  name: String,
  file: String,
  reason: String,
) -> Frontend.Diagnostic
  Frontend.Diagnostic(
    code: "PY-IMPORT-UNKNOWN",
    message: "cannot read module `#{name}` from `#{file}`: #{reason}",
    help: some("check the file's permissions"),
    start: path.span.start,
    stop: path.span.stop,
  )
end

def unknown_member_diag(
  module: String,
  member: String,
  known: List[String],
  name: Frontend.ImportName,
) -> Frontend.Diagnostic
  help = some("the module defines: #{known.join(", ")}")
  if known.empty?
    help = some("the module defines no top-level names")
  end

  Frontend.Diagnostic(
    code: "PY-NAME-UNKNOWN",
    message: "module `#{module}` does not define `#{member}`",
    help: help,
    start: name.span.start,
    stop: name.span.stop,
  )
end

def cycle_diag(decl: Frontend.ImportDecl, chain: String) -> Frontend.Diagnostic
  span = Frontend.decl_span(decl)
  Frontend.Diagnostic(
    code: "PY-IMPORT-CYCLE",
    message: "circular import: #{chain}",
    help: some("move the names both sides need into a module they import, or drop one import"),
    start: span.start,
    stop: span.stop,
  )
end

# The module name is the file stem (`SUBSET.md` section 5): the last path
# segment without its `.py` suffix.
def module_stem(path: String) -> String
  base = List.last(path.split("/"))
  return base.slice(0, base.length - 3) if base.end_with?(".py") and base.length > 3

  base
end

# The folder of `path`, `"."` when it has none.
def folder_of(path: String) -> String
  parts = path.split("/")
  return "." if parts.size <= 1

  folder = parts.take(parts.size - 1).join("/")
  return "/" if folder.empty? and path.start_with?("/")
  return "." if folder.empty?

  folder
end

def join_path(dir: String, name: String) -> String
  return name if dir.empty? or dir == "."
  return dir + name if dir.end_with?("/")

  dir + "/" + name
end

def valid_name?(name: String) -> Bool
  return false if name.empty?

  chars = name.split("")
  return false if !name_start?(chars[0])

  for ch in chars.drop(1)
    return false if !name_char?(ch)
  end

  true
end

def name_start?(ch: String) -> Bool
  code = ch.code
  (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code == 95
end

def name_char?(ch: String) -> Bool = name_start?(ch) or (ch.code >= 48 and ch.code <= 57)
