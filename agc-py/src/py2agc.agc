## The Python-to-`.agc` translator: `.py` in, one standalone `.agc` program
## out. The pipeline stays `.py` → `.agc` → `.agcb`: this package never
## emits bytecode, `agentica compile` does that from the emitted `.agc`.
## The command line around this entry point is `main.agc`.
##
## Local imports resolve in a separate library stage (`Modules`,
## `src/modules.agc`) that answers the module graph #26 feeds to emission;
## this single-file entry point keeps refusing imports until then.

import EmitCtx from "emit_ctx"
import EmitModule from "emit_module"
import Frontend from "frontend"
import Grammar from "../../src/grammar"

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
