## The Python-to-`.agc` translator (pipeline skeleton): today this module only
## names the pipeline stages; phases 1-3 of `agc-py/roadmap.md` grow it into
## the grammar, the AST and the emitter. The pipeline stays `.py` → `.agc` →
## `.agcb`: this package never emits bytecode, `agentica compile` does that
## from the emitted `.agc`.

# The stages a source file goes through.
enum Stage
  Parse
  Emit
end

# A translator failure names the stage that refused the program.
struct Failure
  stage: Stage
  message: String
end

## The version of the translator skeleton.
def version() -> String = "0.0.0"

## Translates `source` to `.agc`. Today every program is refused: the grammar
## (phase 2) and the emitter (phase 3) do not exist yet.
def translate(source: String) -> Result[String]
  empty = source.split("").size == 0
  return error("agc-py: an empty program has nothing to translate") if empty

  error("agc-py: translation is not implemented yet (roadmap phase 3)")
end
