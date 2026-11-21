## The Python-to-`.agc` translator (pipeline skeleton): today this module only
## names the entry point; phases 1-3 of `agc-py/roadmap.md` grow it into
## the grammar, the AST and the emitter. The pipeline stays `.py` → `.agc` →
## `.agcb`: this package never emits bytecode, `agentica compile` does that
## from the emitted `.agc`.

## The version of the translator skeleton.
def version() -> String = "0.0.0"

## Translates `source` to `.agc`. Today every program is refused: the grammar
## (phase 2) and the emitter (phase 3) do not exist yet.
def translate(source: String) -> Result[String]
  return error("agc-py: an empty program has nothing to translate") if source.empty?()

  error("agc-py: translation is not implemented yet for #{preview(source)} (roadmap phase 3)")
end

# The first characters of a source, for an error that names its input.
def preview(source: String) -> String
  shown = source.slice(0, 40.clamp(0, source.length))
  shown.inspect
end
