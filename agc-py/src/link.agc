## Linked-module emission (issue #26): the module graph of `Modules.resolve`
## becomes one `.agc` file per module, in dependency order, entry module last.
##
## Each Python import turns into an Agentica `import` of the sibling file
## `<module>.agc`: `import m [as y]` is `import Y from "m"` (aliases are
## capitalized) and `from m import f [as g]` is `import {f as g} from "m"`.
## What crosses a module boundary is a `def`: a call through an import checks
## against the callee's signature like a call inside one file, except that a
## default is not lowered (its value lives in the other file), so the call
## passes every parameter. A type alias, an imported name (one file is one
## module and Agentica has no implicit re-export) and a top-level value are not
## importable, and an imported module holds only `def`s and `type` aliases.

import EmitCtx from "emit_ctx"
import EmitModule from "emit_module"
import Frontend from "frontend"
import Modules from "modules"
import Stdlib from "stdlib"

## One emitted file: its name (`<module>.agc`) and its text.
struct Unit
  name: String
  text: String
end

## The names the imports of one module bind so far: the scope marker of each
## and the signature behind it.
struct Binds
  scope: Map[String, String]
  sigs: Map[String, EmitCtx.Sig]
  needs: List[String]
end

## What an importer can reach in a module: the signatures of its `def`s (no
## defaults) and the names of its type aliases (named only to refuse them).
struct Exports
  sigs: Map[String, EmitCtx.Sig]
  aliases: List[String]
end

## Emits every module of `graph`. The error is the first refusal, rendered
## against the file that holds it.
def link(graph: Modules.ModuleGraph) -> Result[List[Unit]]
  exports: Map[String, Exports] = {}
  units: List[Unit] = []
  for module in graph.modules
    mode = EmitModule.FileMode.Imported
    if module.name == graph.root
      mode = EmitModule.FileMode.Entry
    end

    wired = try wire(module, mode, exports)
    case EmitModule.emit_linked(module.program, module.source, module.path, wired)
      EmitModule.ModuleRes.No(refusal) -> return error(EmitCtx.render_refusal(module.path, module.source, refusal))
      EmitModule.ModuleRes.Ok(out) ->
        units = units.push(Unit(name: "#{module.name}.agc", text: out.code.join("\n") + "\n"))
    end

    exports = exports.put(
      module.name,
      Exports(sigs: EmitModule.exported_sigs(module.program), aliases: EmitModule.alias_names(module.program)),
    )
  end

  ok(units)
end

private

# The type names the Agentica checker reserves, which no import alias may take
# (`RESERVED_TYPE_NAMES` of the checker, as of 0.36.0).
RESERVED_ALIASES = Set.new([
  "ATS",
  "Await",
  "Base64",
  "Bool",
  "Bytes",
  "Channel",
  "Codec",
  "Dir",
  "Error",
  "File",
  "Float",
  "Fn",
  "IO",
  "Int",
  "JSON",
  "Lazy",
  "List",
  "Map",
  "Math",
  "Nil",
  "OpenSSL",
  "Optional",
  "Path",
  "Process",
  "Random",
  "Range",
  "Result",
  "Set",
  "String",
  "StructMember",
  "System",
  "TCP",
  "TLS",
  "Task",
  "TaskDown",
  "TaskExit",
  "TaskRef",
  "Test",
  "Time",
  "Void",
  "Zlib",
])

# The `Link` of one module: an import line and the bound names per import,
# or the first import that cannot link, rendered in this module's file.
def wire(module: Modules.Module, mode: EmitModule.FileMode, exports: Map[String, Exports]) -> Result[EmitModule.Link]
  lines: List[String] = []
  scope: Map[String, String] = {}
  sigs: Map[String, EmitCtx.Sig] = {}
  used = used_names(module.program)
  aliases: List[String] = []
  needs: List[String] = []
  type_aliases = EmitModule.alias_names(module.program)
  for edge in module.imports
    case edge.source
      Modules.ModuleSource.Stdlib(std) ->
        bound = try std_binds(module, edge.decl, std, used, Binds(scope: scope, sigs: sigs, needs: needs))
        scope = bound.scope
        sigs = bound.sigs
        needs = bound.needs
        next

      Modules.ModuleSource.Local(_) -> nil
    end

    target = try local_target(edge)
    found = exports.get(target).unwrap!
    case edge.decl
      Frontend.ImportDecl.ModuleImport(_, binding, _) ->
        alias = EmitCtx.module_alias(binding.bound)
        if used.include?(binding.bound)
          case alias_clash(alias, aliases, type_aliases)
            some(why) ->
              return error(
                refusal_text(
                  module,
                  "the import `#{binding.bound}` becomes `#{alias}`, #{why}",
                  "rename it with `as`",
                  binding.span,
                  "PY-OUT-OF-SUBSET",
                ),
              )

            none -> nil
          end

          aliases = aliases.push(alias)
          lines = lines.push("import #{alias} from \"#{target}\"")
        end

        scope = scope.put(binding.bound, EmitCtx.module_marker())
        for member in found.sigs.keys()
          dotted = "#{binding.bound}.#{member}"
          sigs = sigs.put(dotted, found.sigs.get(member).unwrap!.with(name: dotted))
        end

      Frontend.ImportDecl.FromImport(_, names, _) ->
        entries: List[String] = []
        for name in names
          member = name.member.unwrap!
          case found.sigs.get(member)
            some(sig) ->
              if !lowercase_start?(name.bound)
                return error(
                  refusal_text(
                    module,
                    "`#{name.bound}` renames a function, so it must start with a lowercase letter",
                    "pick a lowercase name after `as`",
                    name.span,
                    "PY-OUT-OF-SUBSET",
                  ),
                )
              end

              scope = scope.put(name.bound, EmitCtx.def_marker())
              sigs = sigs.put(name.bound, sig.with(name: name.bound))
              entries = entries.push(import_entry(member, name.bound))
            none -> return error(refuse_member(module, target, name, found))
          end
        end

        lines = lines.push("import {#{entries.join(", ")}} from \"#{target}\"")
    end
  end

  for need in needs
    alias = try Stdlib.needs_alias(need)
    case alias_clash(alias, aliases, type_aliases)
      some(why) ->
        return error(
          refusal_text(
            module,
            "the standard-library import of `#{need}` becomes `#{alias}`, #{why}",
            "rename the other import with `as`",
            module.program.span,
            "PY-OUT-OF-SUBSET",
          ),
        )

      none -> nil
    end

    aliases = aliases.push(alias)
    lines = lines.push("import #{alias} from \"#{need}\"")
  end

  ok(EmitModule.Link(mode: mode, import_lines: lines, scope: scope, sigs: sigs))
end

# Why an import alias cannot be spelled `alias`, or none: Agentica reserves
# some type names, and an alias may not repeat another alias or a type alias
# of the file.
def alias_clash(alias: String, taken: List[String], type_aliases: List[String]) -> Optional[String]
  return some("a type name Agentica reserves") if RESERVED_ALIASES.include?(alias)
  return some("the name of a type alias of this file") if type_aliases.include?(alias)
  return some("which another import of this file already uses") if taken.include?(alias)

  none
end

def lowercase_start?(name: String) -> Bool
  code = name.slice(0, 1).code
  code >= 97 and code <= 122
end

def import_entry(member: String, bound: String) -> String
  return member if member == bound

  "#{member} as #{bound}"
end

# The local module an edge names.
def local_target(edge: Modules.ImportEdge) -> Result[String]
  case edge.source
    Modules.ModuleSource.Local(name) -> ok(name)
    Modules.ModuleSource.Stdlib(name) -> error("agc-py: `#{name}` is not a local module")
  end
end

# The names a standard-library import binds: `import m` binds the module (its
# members as `m.name` signatures, and `m.` itself marks it as standard library
# for the refusals) and `from m import a` binds each mapped member. Neither
# emits an import line: the backend spelling is in the signature.
def std_binds(
  module: Modules.Module,
  decl: Frontend.ImportDecl,
  std: String,
  used: List[String],
  binds: Binds,
) -> Result[Binds]
  table = Stdlib.members(std)
  scope = binds.scope
  sigs = binds.sigs
  needs = binds.needs
  case decl
    Frontend.ImportDecl.ModuleImport(_, binding, _) ->
      # `import urllib.parse` binds `urllib` and spells its members in full.
      prefix = binding.bound
      if std.include?(".") and binding.bound == List.first(std.split("."))
        prefix = std
      end

      scope = scope.put(binding.bound, EmitCtx.module_marker())
      sigs = sigs.put("#{binding.bound}.", EmitCtx.Sig(name: std, params: [], types: [], defaults: [], ret: ""))
      for member in table.keys()
        sig = table.get(member).unwrap!
        sigs = sigs.put("#{prefix}.#{member}", sig.with(name: "#{std}.#{member}"))
        if !sig.needs.empty? and used.include?(binding.bound)
          needs = add_need(needs, sig.needs)
        end
      end

    Frontend.ImportDecl.FromImport(_, names, _) ->
      for name in names
        member = name.member.unwrap!
        case table.get(member)
          some(sig) ->
            scope = scope.put(name.bound, EmitCtx.def_marker())
            sigs = sigs.put(name.bound, sig.with(name: "#{std}.#{member}"))
            if !sig.needs.empty? and used.include?(name.bound)
              needs = add_need(needs, sig.needs)
            end

          none ->
            return error(
              refusal_text(
                module,
                "`#{std}.#{member}` is not in the supported standard-library surface",
                std_help(std, table),
                name.span,
                "PY-IMPORT-UNKNOWN",
              ),
            )
        end
      end
  end

  ok(Binds(scope: scope, sigs: sigs, needs: needs))
end

def add_need(needs: List[String], need: String) -> List[String]
  return needs if needs.include?(need)

  needs.push(need)
end

def std_help(std: String, table: Map[String, EmitCtx.Sig]) -> String
  return "no member of `#{std}` is mapped yet" if table.empty?

  "`#{std}` maps #{table.keys().sort.join(", ")}"
end

def refuse_member(module: Modules.Module, target: String, name: Frontend.ImportName, found: Exports) -> String
  member = name.member.unwrap!
  if found.aliases.include?(member)
    return refusal_text(
      module,
      "`#{member}` is a type alias of module `#{target}`: type aliases do not cross modules",
      "spell the type out where you use it",
      name.span,
      "PY-OUT-OF-SUBSET",
    )
  end

  help = "only a `def` of the module can be imported, and the module defines none"
  if !found.sigs.empty?
    help = "only a `def` of the module can be imported: the module defines #{found.sigs.keys().join(", ")}"
  end

  refusal_text(module, "module `#{target}` has no function `#{member}` to import", help, name.span, "PY-NAME-UNKNOWN")
end

def refusal_text(module: Modules.Module, message: String, help: String, span: Frontend.Span, code: String) -> String
  EmitCtx.render_refusal(
    module.path,
    module.source,
    EmitCtx.Refusal(code: code, message: message, help: some(help), start: span.start, stop: span.stop),
  )
end

# The names a module reads, so an `import m` nothing uses (which Python
# allows and Agentica refuses as `CHECK-UNUSED-IMPORT`) emits no line.
def used_names(program: Frontend.Program) -> List[String]
  out: List[String] = []
  for func_def in program.funcs
    out = out + func_def.body_names.filter { |occ| occ.kind == "use" }.map { |occ| occ.name }
  end

  for item in program.top
    out = out + Frontend.top_names(item).filter { |occ| occ.kind == "use" }.map { |occ| occ.name }
  end

  out
end
