## The Python-to-`.agc` translator: `.py` in, one standalone `.agc` program
## out. The pipeline stays `.py` → `.agc` → `.agcb`: this package never
## emits bytecode, `agentica compile` does that from the emitted `.agc`.
## The command line around this entry point is `main.agc`.
##
## `translate` is the single-file entry point and refuses imports;
## `translate_modules` resolves the local modules (`src/modules.agc`) and
## emits one file per module (`src/link.agc`).

import EmitCtx from "emit_ctx"
import EmitModule from "emit_module"
import Frontend from "frontend"
import Grammar from "../../src/grammar"
import Link from "link"
import Modules from "modules"

## The version of the translator.
def version() -> String = "0.0.0"

## Translates `source` (`file` names it in diagnostics, `grammar` is the
## owned `py312` grammar) to a standalone single-file `.agc` program: parse,
## build and resolve refuse first with their rendered diagnostics (`Frontend
## .program` runs all three once and answers the validated module), then the
## module assembler refuses with its spanned `PY-*` refusals, and a program
## that passes every stage answers the full `.agc` text with a trailing
## newline.
def translate(grammar: Grammar.Grammar, file: String, source: String) -> Result[String]
  return error("agc-py: an empty program has nothing to translate") if source.empty?()

  program = try Frontend.program(grammar, file, source)
  case EmitModule.emit_program(program, source, file)
    EmitModule.ModuleRes.No(refusal) -> error(EmitCtx.render_refusal(file, source, refusal))
    EmitModule.ModuleRes.Ok(out) -> ok(out.code.join("\n") + "\n")
  end
end

## Translates the program whose entry file is `file`, with every local module
## it imports found in the entry's folder, then `search_path` in order: one
## `.agc` file per module, in dependency order, the entry module last. Each
## file is named `<module>.agc` and imports its siblings by that name, so
## they must be written to one folder. The error is the first refusal, with
## its rendered diagnostic.
def translate_modules(grammar: Grammar.Grammar, file: String, search_path: List[String]) -> Result[List[Link.Unit]]
  graph = try Modules.resolve(grammar, file, search_path)
  return error("agc-py: an empty program has nothing to translate") if List.last(graph.modules).source.empty?()

  Link.link(graph)
end
