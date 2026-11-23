## The standard-library surface of `SUBSET.md` section 5: what each supported
## Python module member lowers to. A function is a `Sig` (Python parameter
## names, backend types, the mapped return) whose `code` spells the backend
## call with `$1`, `$2` for the arguments, so a call through it is checked
## like any other call; a constant has `value` set and no parameters. The
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
        "exit": fn("exit", ["code"], ["Int"], "Void", "System.exit($1)"),
      }
    "os" ->
      {
        "getenv": fn("getenv", ["key"], ["String"], "Result[String]", "System.env($1)"),
        "getcwd": fn("getcwd", [], [], "Result[String]", "Path.cwd()"),
        "environ": const_value("environ", "Environ", "@environ"),
      }
    _ -> {}
  end
end

## What a call to the backend spelling `template` becomes with `args`; an
## argument that is a receiver (`$1.floor`) and has an operator in it (or a sign) is
## parenthesized.
def spell(template: String, args: List[String]) -> String
  out = template
  index = args.size
  while index > 0
    arg = args[index - 1]
    if arg.include?(" ") or arg.start_with?("-")
      out = out.replace("$#{index}.", "(#{arg}).")
    end

    out = out.replace("$#{index}", arg)
    index -= 1
  end

  out
end

private

def fn(name: String, params: List[String], types: List[String], ret: String, code: String) -> EmitCtx.Sig
  EmitCtx.Sig(name: name, params: params, types: types, defaults: params.map { |_| none }, ret: ret, code: code)
end

def const_float(name: String, code: String) -> EmitCtx.Sig = const_value(name, "Float", code)

def const_value(name: String, type: String, code: String) -> EmitCtx.Sig
  EmitCtx.Sig(name: name, params: [], types: [], defaults: [], ret: type, code: code, value: true)
end
