## The standard-library surface of `SUBSET.md` section 5: what each supported
## Python module member lowers to. A function is a `Sig` (Python parameter
## names, backend types, the mapped return) whose `code` spells the backend
## call with `$1`, `$2` for the arguments, so a call through it is checked
## like any other call; a constant has the `const` kind and no parameters. The
## table is closed: a module member that is not here refuses.

import EmitCtx from "emit_ctx"

## The members of `module` (Python's spelling), empty for a module no member
## of which is mapped yet.
def members(module: String) -> Map[String, EmitCtx.Sig]
  case module
    "math" ->
      {
        "sqrt": fn("sqrt", ["x"], ["Float"], "Float", "Math.sqrt($1)"),
        "floor": fn("floor", ["x"], ["Float"], "Int", "$1.floor"),
        "ceil": fn("ceil", ["x"], ["Float"], "Int", "$1.ceil"),
        "pi": const_float("pi", "3.141592653589793"),
        "e": const_float("e", "2.718281828459045"),
        "tau": const_float("tau", "6.283185307179586"),
      }
    "sys" ->
      {
        "argv": const_value("argv", "List[String]", "([System.program_name()] + System.args())"),
        "exit": fn("exit", ["code"], ["Int"], "Void", "System.exit(($1).bit_and(255))"),
      }
    "os" ->
      {
        "getenv": fn("getenv", ["key"], ["String"], "Optional[String]", "py_getenv($1)"),
        "getcwd": fn("getcwd", [], [], "Result[String]", "Path.cwd()"),
        "environ": kinded("environ", "Environ", "environ"),
      }
    "html" ->
      {
        "escape": std_fn(
          "escape",
          ["s"],
          ["String"],
          "String",
          "Html.escape($1).replace(\"&#39;\", \"&#x27;\")",
          "std/html",
        ),
      }
    "urllib.parse" ->
      {
        "quote": std_fn(
          "quote",
          ["string"],
          ["String"],
          "String",
          quote_code("encode_uri_component") + ".replace(\"%2F\", \"/\")",
          "std/uri",
        ),
        "quote_plus": std_fn(
          "quote_plus",
          ["string"],
          ["String"],
          "String",
          quote_code("encode_www_form_component"),
          "std/uri",
        ),
        "unquote": std_fn(
          "unquote",
          ["string"],
          ["String"],
          "Result[String]",
          "Uri.decode_uri_component($1)",
          "std/uri",
        ),
        "unquote_plus": std_fn(
          "unquote_plus",
          ["string"],
          ["String"],
          "Result[String]",
          "Uri.decode_www_form_component($1)",
          "std/uri",
        ),
      }
    "time" ->
      {
        "time": fn("time", [], [], "Float", "(Time.now().to_us.to_f / 1000000.0)"),
        "monotonic": fn("monotonic", [], [], "Float", "(Time.monotonic_ns.to_f / 1000000000.0)"),
        "sleep": fn("sleep", ["secs"], ["Float"], "Void", "Task.sleep((($1) * 1000.0).round)"),
      }
    "random" ->
      {
        "random": fn("random", [], [], "Float", "Random.float()"),
        "randint": fn("randint", ["a", "b"], ["Int", "Int"], "Int", "Random.int($1, $2)"),
      }
    _ -> {}
  end
end

## The alias the spelling of a member uses for the `std/` module it needs.
def needs_alias(path: String) -> Result[String]
  case path
    "std/html" -> ok("Html")
    "std/uri" -> ok("Uri")
    _ -> error("agc-py: no import alias is defined for `#{path}`")
  end
end

## What a call to the backend spelling `template` becomes with `args`, in one
## pass over the `$1`..`$9` marks; an argument that is a receiver (`$1.floor`)
## and has an operator in it (or a sign) is parenthesized.
def spell(template: String, args: List[String]) -> String
  pieces = template.split("$")
  out = List.first(pieces)
  for piece in pieces.drop(1)
    arg = args[piece.slice(0, 1).to_i! - 1]
    rest = piece.slice(1, piece.length - 1)
    if rest.start_with?(".") and (arg.include?(" ") or arg.start_with?("-"))
      arg = "(#{arg})"
    end

    out = out + arg + rest
  end

  out
end

private

def fn(name: String, params: List[String], types: List[String], ret: String, code: String) -> EmitCtx.Sig
  EmitCtx.Sig(name: name, params: params, types: types, defaults: params.map { |_| none }, ret: ret, code: code)
end

# `quote` family: Python leaves `~` alone and escapes `*`, which the
# backend's encoders do the other way round.
def quote_code(encoder: String) -> String = "Uri.#{encoder}($1).replace(\"%7E\", \"~\").replace(\"*\", \"%2A\")"

def std_fn(
  name: String,
  params: List[String],
  types: List[String],
  ret: String,
  code: String,
  needs: String,
) -> EmitCtx.Sig
  fn(name, params, types, ret, code).with(needs: needs)
end

def const_float(name: String, code: String) -> EmitCtx.Sig = const_value(name, "Float", code)

def const_value(name: String, type: String, code: String) -> EmitCtx.Sig
  EmitCtx.Sig(name: name, params: [], types: [], defaults: [], ret: type, code: code, kind: "const")
end

def kinded(name: String, type: String, kind: String) -> EmitCtx.Sig
  EmitCtx.Sig(name: name, params: [], types: [], defaults: [], ret: type, kind: kind)
end
