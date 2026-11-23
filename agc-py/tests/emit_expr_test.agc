## Phase 3b expression codegen tests: every emitted fragment passes
## `agentica check` in the test itself.
##
## Each test parses its expressions with a single `Engine.run` (one program
## of `py_tmp = <expr>` lines), emits each through `EmitExpr.emit`, asserts
## the exact text (or its key parts), the static type and any temp preamble,
## then appends its checkable fragments to a shared accumulator: one
## `agentica check` per test blows the test-runner step budget (a full VM
## boot each, and the process dies around the thirty-third scenario), so a
## single final test checks every fragment together. Each fragment keeps its
## own function (named per test slug, so `check ok` failures point at the
## right fixture) with its shared helpers plus per-case declarations feeding
## `puts`. Fragments whose verbatim form cannot check (module paths such as
## `math.sqrt`, left for phase 4) assert structure only and name their TODO
## mapping; see the stdlib TODO block above the attribute tests.

import EmitCtx from "../src/emit_ctx"
import EmitExpr from "../src/emit_expr"
import Engine from "../../src/engine"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

# One expression fixture: the Python source, the visible names, the
# declarations those names need in the checked program, and what the
# emission must answer. `want_code` empty skips the exact-text check;
# `want_pre` non-empty also checks the temp preamble; `as_type` non-empty
# declares `py_e: T = <code>` instead of `puts`; `skip_check` asserts
# structure only (for verbatim phase-4 paths); `tops` holds top-level
# definitions (named-function stubs) the checked program needs.
struct ErrCase
  expr: String
  scope: Map[String, String]
  code: String
  sigs: Map[String, EmitCtx.Sig] = {}
end

struct Case
  expr: String
  scope: Map[String, String]
  decls: List[String]
  want_type: String
  want_code: String
  want_contains: List[String]
  want_pre: List[String]
  as_type: String
  skip_check: Bool
  tops: List[String]
  sigs: Map[String, EmitCtx.Sig] = {}
end

def cased(expr: String, scope: Map[String, String], decls: List[String], want_type: String, want_code: String) -> Case
  Case(
    expr: expr,
    scope: scope,
    decls: decls,
    want_type: want_type,
    want_code: want_code,
    want_contains: [],
    want_pre: [],
    as_type: "",
    skip_check: false,
    tops: [],
  )
end

def cased_pre(
  expr: String,
  scope: Map[String, String],
  decls: List[String],
  want_type: String,
  want_code: String,
  want_pre: List[String],
) -> Case
  Case(
    expr: expr,
    scope: scope,
    decls: decls,
    want_type: want_type,
    want_code: want_code,
    want_contains: [],
    want_pre: want_pre,
    as_type: "",
    skip_check: false,
    tops: [],
  )
end

def result_sig(name: String, ret: String) -> EmitCtx.Sig
  EmitCtx.Sig(name: name, params: ["x"], types: ["Int"], defaults: [none], ret: ret)
end

# One refusal fixture: emitting `expr` must fail with `code`.
def errcased(expr: String, scope: Map[String, String], code: String) -> ErrCase
  ErrCase(expr: expr, scope: scope, code: code)
end

# One refusal fixture carrying call ABI signatures for the expression.
def errcased_sigs(expr: String, scope: Map[String, String], code: String, sigs: Map[String, EmitCtx.Sig]) -> ErrCase
  ErrCase(expr: expr, scope: scope, code: code, sigs: sigs)
end

# One fixture whose expression runs through the call ABI signatures.
def abi_case(
  expr: String,
  scope: Map[String, String],
  decls: List[String],
  want_type: String,
  want_code: String,
  want_pre: List[String],
  tops: List[String],
  sigs: Map[String, EmitCtx.Sig],
) -> Case
  Case(
    expr: expr,
    scope: scope,
    decls: decls,
    want_type: want_type,
    want_code: want_code,
    want_contains: [],
    want_pre: want_pre,
    as_type: "",
    skip_check: false,
    tops: tops,
    sigs: sigs,
  )
end

def empty_scope() -> Map[String, String] = {}

# Spells `#{code}` without writing `#{` in a literal (which the test file
# itself would interpolate).
def interp(code: String) -> String = "#" + "{" + code + "}"

def quoted(inner: String) -> String = "\"" + inner + "\""

# One program of `py_tmp = <expr>` lines: a single parse for the whole
# batch, with assigns in source order (expressions never contain one).
def wrap_all(exprs: List[String]) -> String = exprs.map { |expr| "py_tmp = #{expr}" }.join("\n") + "\n"

def parse_values(compiled: Grammar.Grammar, exprs: List[String]) -> Result[List[Tree.Node]]
  tree = try Engine.run(compiled, "program", wrap_all(exprs))
  matches = Tree.find_all(tree, "assign")
  ok(matches.map { |assign| value_of(assign) })
end

def value_of(assign: Tree.Node) -> Tree.Node = List.last(assign.children)

def assert_out(out: EmitExpr.Out, one: Case) -> Result[Void]
  try Test.eq(out.type, one.want_type)
  if one.want_code != ""
    try Test.eq(out.code, one.want_code)
  end

  for part in one.want_contains
    try Test.assert(out.code.include?(part), "missing #{part} in #{out.code}")
  end

  if !one.want_pre.empty?
    try Test.eq(out.pre, one.want_pre)
  end

  ok()
end

def assert_err(out: Result[EmitExpr.Out], code: String) -> Result[Void]
  case out
    error(e) -> Test.assert(e.message.include?(code), e.message)
    ok(done) -> Test.assert(false, "expected #{code}, emitted #{done.code}")
  end
end

# Emits every case and refusal from one parse, asserts each answer, then
# checks the checkable fragments with the real compiler through a temp
# file. Each fragment gets its own function (temps are function-local, so
# `py_t0` never collides).
def check_all(compiled: Grammar.Grammar, slug: String, cases: List[Case], errs: List[ErrCase]) -> Result[Void]
  exprs = cases.map { |one| one.expr }
  for err in errs
    exprs = exprs.push(err.expr)
  end

  full = wrap_all(exprs)
  nodes = try parse_values(compiled, exprs)
  outs: List[EmitExpr.Out] = []
  for i in 0...cases.size
    out = try EmitExpr.emit(List.first(nodes.drop(i)), full, cases[i].scope, cases[i].sigs)
    try assert_out(out, cases[i])
    outs = outs.push(out)
  end

  for i in 0...errs.size
    target = List.first(nodes.drop(cases.size + i))
    emitted = EmitExpr.emit(target, full, errs[i].scope, errs[i].sigs)
    try assert_err(emitted, errs[i].code)
  end

  checkable: List[Case] = []
  checkable_outs: List[EmitExpr.Out] = []
  for i in 0...cases.size
    if !cases[i].skip_check
      checkable = checkable.push(cases[i])
      checkable_outs = checkable_outs.push(List.first(outs.drop(i)))
    end
  end

  return ok() if checkable.empty?

  tops: List[String] = []
  for one in checkable
    for top in one.tops
      if !tops.include?(top)
        tops = tops.push(top)
      end
    end
  end

  tops_text = ""
  if !tops.empty?
    tops_text = tops.join("\n\n") + "\n\n"
  end

  funcs: List[String] = []
  mains: List[String] = []
  for i in 0...checkable.size
    one = checkable[i]
    out = checkable_outs[i]
    lines = filter_decls(one.decls, out.code, out.pre) + out.pre
    if one.as_type != ""
      lines = lines.push("py_e: #{one.as_type} = #{out.code}")
      lines = lines.push("puts(py_e)")
    else
      if out.type == "Void"
        lines = lines.push(out.code)
      else
        lines = lines.push("puts(#{out.code})")
      end
    end

    body = lines.map { |line| "  #{line}" }.join("\n")
    funcs = funcs.push("def py_#{slug}_case#{i}() -> Void\n#{body}\nend\n")
    mains = mains.push("  py_#{slug}_case#{i}()")
  end

  # One `agentica check` per test blows the test-runner step budget (a full
  # VM boot each), so fragments accumulate here and the final test checks
  # them all together; `slug` keeps function names unique across tests.
  # TODO(parallel): `/tmp/agc_emit_blocks.txt` is order-dependent and fragile
  # under parallel/sharded runners; use env-overridable accumulator paths.
  blocks = try File.read_text("/tmp/agc_emit_blocks.txt")
  try File.write_text("/tmp/agc_emit_blocks.txt", blocks + tops_text + funcs.join("\n") + "\n\n")
  calls = try File.read_text("/tmp/agc_emit_calls.txt")
  try File.write_text("/tmp/agc_emit_calls.txt", calls + mains.join("\n") + "\n")
  ok()
end

# Keeps only the declarations the fragment uses (a checked program refuses
# unused locals): a name counts when it appears as a whole identifier word in
# the emitted code or preamble.
def filter_decls(decls: List[String], code: String, pre: List[String]) -> List[String]
  words = words_in(code + "\n" + pre.join("\n"))
  decls.select { |decl| words.include?(decl_name(decl)) }
end

def decl_name(decl: String) -> String
  index = decl.index_of(":")
  case index
    some(at) -> decl.slice(0, at).strip
    none -> decl
  end
end

def words_in(text: String) -> List[String]
  words: List[String] = []
  current = ""
  for ch in text.split("")
    if word_char?(ch)
      current = "#{current}#{ch}"
    else
      if current != ""
        words = words.push(current)
        current = ""
      end
    end
  end

  if current != ""
    words = words.push(current)
  end

  words
end

def word_char?(ch: String) -> Bool
  code = ch.code
  (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or (code >= 48 and code <= 57) or code == 95
end

def int_scope() -> Map[String, String]
  {"x": "Int", "y": "Int", "z": "Int", "n": "Int", "i": "Int", "a": "Int", "b": "Int"}
end

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  # Compile only in the run worker and share its result across the fixtures.
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  args = System.args()
  if args != ["--agentica-test", "list"] and args != ["--agentica-test", "run"]
    IO.warn("expected Agentica test worker args [--agentica-test, list|run], got #{args.inspect}")
    System.exit(1)
  end

  if args == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
    case reset_accumulators()
      error(e) -> IO.warn("cannot reset fragment accumulators: #{e.message}")
      ok(_) -> IO.puts("fragment accumulators reset")
    end
  end

  Test.run([
    Test.test("helpers check clean on their own") do
      program = (
        "#{EmitExpr.helpers()}\ndef main() -> Void\n  puts(py_pymod(-7, 2))\n  puts(py_floor_div(-7, 2))\n  puts(py_slice_list([1, 2, 3], 1, 2))\n  puts(py_slice_str(\"abcd\", 1, 3))\nend\n"
      )

      try File.write_text("/tmp/agc_emit_helpers.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/agc_emit_helpers.agc"])
      result = try Process.output(proc, 30000)
      try Test.assert(result.stdout.include?("check ok"), result.stdout + result.stderr)
      Test.assert(EmitExpr.helpers().include?("def py_pymod"), "helpers name pymod")
    end,
    Test.test("ints keep their base spellings") do
      check_all(
        compiled.unwrap!,
        "ints",
        [
          cased("0xFF", empty_scope(), [], "Int", "0xFF"),
          cased("0o17", empty_scope(), [], "Int", "0o17"),
          cased("0b101", empty_scope(), [], "Int", "0b101"),
          cased("1_000", empty_scope(), [], "Int", "1_000"),
          cased("0", empty_scope(), [], "Int", "0"),
          cased("0x_FF", empty_scope(), [], "Int", "0xFF"),
          cased("42", empty_scope(), [], "Int", "42"),
        ],
        [],
      )
    end,
    Test.test("floats normalize to backend spellings") do
      check_all(
        compiled.unwrap!,
        "floats",
        [
          cased("1e10", empty_scope(), [], "Float", "1e10"),
          cased("1.5e-3", empty_scope(), [], "Float", "1.5e-3"),
          cased("1.0", empty_scope(), [], "Float", "1.0"),
          cased("1.", empty_scope(), [], "Float", "1.0"),
          cased(".5", empty_scope(), [], "Float", "0.5"),
          cased("1_000.0_5", empty_scope(), [], "Float", "1000.05"),
          cased("1E+10", empty_scope(), [], "Float", "1E+10"),
          cased("0e2", empty_scope(), [], "Float", "0e2"),
        ],
        [],
      )
    end,
    Test.test("strings decode escapes and re-encode minimally") do
      check_all(
        compiled.unwrap!,
        "strings",
        [
          cased("\"sq\"", empty_scope(), [], "String", "\"sq\""),
          cased("'sq'", empty_scope(), [], "String", "\"sq\""),
          cased("\"a\\nb\"", empty_scope(), [], "String", "\"a\\nb\""),
          cased("\"a\\x41b\"", empty_scope(), [], "String", "\"aAb\""),
          cased("\"a\\u0041b\"", empty_scope(), [], "String", "\"aAb\""),
          cased("r\"a\\nb\"", empty_scope(), [], "String", "\"a\\\\nb\""),
          cased("r'c\\td'", empty_scope(), [], "String", "\"c\\\\td\""),
        ],
        [],
      )
    end,
    Test.test("a full escape set decodes to plain characters") do
      check_all(
        compiled.unwrap!,
        "escapes",
        [
          Case(
            expr: "\"\\0\\a\\b\\f\\v\"",
            scope: empty_scope(),
            decls: [],
            want_type: "String",
            want_code: (
              "\"#{String.from_code(0)}#{String.from_code(7)}#{String.from_code(8)}#{String.from_code(12)}#{String.from_code(11)}\""
            ),
            want_contains: [],
            want_pre: [],
            as_type: "",
            skip_check: false,
            tops: [],
          ),
        ],
        [],
      )
    end,
    Test.test("triple-quoted strings span lines") do
      check_all(compiled.unwrap!, "triple", [cased("\"\"\"a\nb\"\"\"", empty_scope(), [], "String", "\"a\\nb\"")], [])
    end,
    Test.test("True False and None map to backend literals") do
      check_all(
        compiled.unwrap!,
        "constants",
        [
          cased("True", empty_scope(), [], "Bool", "true"),
          cased("False", empty_scope(), [], "Bool", "false"),
          Case(
            expr: "None",
            scope: empty_scope(),
            decls: [],
            want_type: "none",
            want_code: "none",
            want_contains: [],
            want_pre: [],
            as_type: "Optional[Int]",
            skip_check: false,
            tops: [],
          ),
        ],
        [],
      )
    end,
    Test.test("names resolve through the scope") do
      check_all(
        compiled.unwrap!,
        "names",
        [cased("x", {"x": "Int"}, ["x: Int = 3"], "Int", "x")],
        [errcased("y", {"x": "Int"}, "PY-NAME-UNKNOWN")],
      )
    end,
    Test.test("same-type arithmetic emits directly") do
      check_all(
        compiled.unwrap!,
        "arith",
        [
          cased("x + y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Int", "x + y"),
          cased("x - y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Int", "x - y"),
          cased("x * y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Int", "x * y"),
          cased("x + y * n", int_scope(), ["x: Int = 3", "y: Int = 4", "n: Int = 2"], "Int", "x + y * n"),
          cased("-x", int_scope(), ["x: Int = 3"], "Int", "-x"),
          cased("+x", int_scope(), ["x: Int = 3"], "Int", "x"),
          cased("(x)", int_scope(), ["x: Int = 3"], "Int", "(x)"),
        ],
        [
          errcased("x + 1.5", {"x": "Int"}, "PY-TYPE-MISMATCH"),
          errcased("x - 1.5", {"x": "Int"}, "PY-TYPE-MISMATCH"),
          errcased("\"a\" - \"b\"", empty_scope(), "PY-TYPE-MISMATCH"),
        ],
      )
    end,
    Test.test("int division lowers to float division") do
      check_all(
        compiled.unwrap!,
        "truediv",
        [
          cased("x / y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Float", "x.to_f / y.to_f"),
          cased("7 / 2", empty_scope(), [], "Float", "7.to_f / 2.to_f"),
          cased("1.5 / 2.5", empty_scope(), [], "Float", "1.5 / 2.5"),
        ],
        [errcased("x / 1.5", {"x": "Int"}, "PY-TYPE-MISMATCH")],
      )
    end,
    Test.test("percent lowers to the pymod helper") do
      check_all(
        compiled.unwrap!,
        "pymod",
        [cased("x % y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Int", "py_pymod(x, y)")],
        [errcased("1.5 % 2.0", empty_scope(), "PY-OPERATOR")],
      )
    end,
    Test.test("floor division lowers to its helper") do
      check_all(
        compiled.unwrap!,
        "floordiv",
        [cased("x // y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Int", "py_floor_div(x, y)")],
        [errcased("1.5 // 2.0", empty_scope(), "PY-OPERATOR")],
      )
    end,
    Test.test("power lowers to pow with right associativity") do
      check_all(
        compiled.unwrap!,
        "pow",
        [
          cased("x ** y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Int", "x.pow(y)"),
          cased("2 ** 3 ** 4", empty_scope(), [], "Int", "2.pow(3.pow(4))"),
          cased("-2 ** 3", empty_scope(), [], "Int", "-(2.pow(3))"),
          cased("+2 ** 3", empty_scope(), [], "Int", "2.pow(3)"),
          cased("2 ** -x", {"x": "Int"}, ["x: Int = 1"], "Int", "2.pow(-x)"),
        ],
        [
          errcased("2 ** -1", empty_scope(), "PY-OPERATOR"),
          errcased("2 ** -(1)", empty_scope(), "PY-OPERATOR"),
          errcased("2.0 ** 3", empty_scope(), "PY-OPERATOR"),
        ],
      )
    end,
    Test.test("strings concat and repeat") do
      check_all(
        compiled.unwrap!,
        "strarith",
        [
          cased("\"a\" + \"b\"", empty_scope(), [], "String", "\"a\" + \"b\""),
          cased("s + s", {"s": "String"}, ["s: String = \"a\""], "String", "s + s"),
          cased("s * n", {"s": "String", "n": "Int"}, ["s: String = \"ab\"", "n: Int = 3"], "String", "s * n"),
        ],
        [
          errcased("n * s", {"s": "String", "n": "Int"}, "PY-OPERATOR"),
          errcased("xs * 2", {"xs": "List[Int]"}, "PY-OPERATOR"),
        ],
      )
    end,
    Test.test("lists concat with plus") do
      check_all(
        compiled.unwrap!,
        "listadd",
        [
          cased(
            "xs + ys",
            {"xs": "List[Int]", "ys": "List[Int]"},
            ["xs: List[Int] = [1]", "ys: List[Int] = [2]"],
            "List[Int]",
            "xs + ys",
          ),
          Case(
            expr: "[1, 2]",
            scope: empty_scope(),
            decls: [],
            want_type: "List[Int]",
            want_code: "[1, 2]",
            want_contains: [],
            want_pre: [],
            as_type: "List[Int]",
            skip_check: false,
            tops: [],
          ),
          Case(
            expr: "{\"k\": 1}",
            scope: empty_scope(),
            decls: [],
            want_type: "Map[String, Int]",
            want_code: "{\"k\": 1}",
            want_contains: [],
            want_pre: [],
            as_type: "Map[String, Int]",
            skip_check: false,
            tops: [],
          ),
          Case(
            expr: "[]",
            scope: empty_scope(),
            decls: [],
            want_type: "List",
            want_code: "[]",
            want_contains: [],
            want_pre: [],
            as_type: "List[Int]",
            skip_check: false,
            tops: [],
          ),
        ],
        [errcased("xs + ys", {"xs": "List[Int]", "ys": "List[String]"}, "PY-TYPE-MISMATCH")],
      )
    end,
    Test.test("equality works on anything") do
      check_all(
        compiled.unwrap!,
        "equality",
        [
          cased("x == y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Bool", "x == y"),
          cased("x != y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Bool", "x != y"),
          cased("\"a\" == \"b\"", empty_scope(), [], "Bool", "\"a\" == \"b\""),
          cased("1 == 1.5", empty_scope(), [], "Bool", "1.to_f == 1.5"),
          cased("1 == \"a\"", empty_scope(), [], "Bool", "false"),
          cased("1 != \"a\"", empty_scope(), [], "Bool", "true"),
        ],
        [
          errcased("1 == True", empty_scope(), "PY-TYPE-MISMATCH"),
          errcased("True == 1", empty_scope(), "PY-TYPE-MISMATCH"),
          errcased("1.0 == True", empty_scope(), "PY-TYPE-MISMATCH"),
          errcased("0 == False", empty_scope(), "PY-TYPE-MISMATCH"),
          errcased("1 != True", empty_scope(), "PY-TYPE-MISMATCH"),
        ],
      )
    end,
    Test.test("ordering works on numbers and strings") do
      check_all(
        compiled.unwrap!,
        "ordering",
        [
          cased("x < y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Bool", "x < y"),
          cased("x >= y", int_scope(), ["x: Int = 3", "y: Int = 4"], "Bool", "x >= y"),
          cased("1.5 <= 2.5", empty_scope(), [], "Bool", "1.5 <= 2.5"),
          cased("x < 1.5", {"x": "Int"}, ["x: Int = 1"], "Bool", "x.to_f < 1.5"),
          cased(
            "s1 < s2",
            {"s1": "String", "s2": "String"},
            ["s1: String = \"a\"", "s2: String = \"b\""],
            "Bool",
            "s1.compare(s2) < 0",
          ),
          cased(
            "s1 >= s2",
            {"s1": "String", "s2": "String"},
            ["s1: String = \"a\"", "s2: String = \"b\""],
            "Bool",
            "s1.compare(s2) >= 0",
          ),
        ],
        [errcased("s < x", {"s": "String", "x": "Int"}, "PY-OPERATOR")],
      )
    end,
    Test.test("chained comparisons evaluate middles once") do
      scope = {"x": "Int", "y": "Int", "z": "Int"}
      decls = ["x: Int = 1", "y: Int = 2", "z: Int = 3"]
      check_all(
        compiled.unwrap!,
        "chained",
        [cased_pre("x < y < z", scope, decls, "Bool", "x < py_t0 and py_t0 < z", ["py_t0 = y"])],
        [],
      )
    end,
    Test.test("four-operand chains thread two middles") do
      scope = {"a": "Int", "b": "Int", "c": "Int", "d": "Int"}
      decls = ["a: Int = 1", "b: Int = 2", "c: Int = 3", "d: Int = 4"]
      check_all(
        compiled.unwrap!,
        "chained4",
        [
          cased_pre(
            "a < b < c < d",
            scope,
            decls,
            "Bool",
            "a < py_t0 and py_t0 < py_t1 and py_t1 < d",
            ["py_t0 = b", "py_t1 = c"],
          ),
        ],
        [],
      )
    end,
    Test.test("and or and not need bools") do
      scope = {"a": "Bool", "b": "Bool", "c": "Bool"}
      decls = ["a: Bool = true", "b: Bool = false", "c: Bool = true"]
      check_all(
        compiled.unwrap!,
        "bools",
        [
          cased("a and b", scope, decls, "Bool", "a and b"),
          cased("a or b or c", scope, decls, "Bool", "a or b or c"),
          cased("not a", scope, decls, "Bool", "!(a)"),
          cased("not (a == b)", scope, decls, "Bool", "!((a == b))"),
        ],
        [
          errcased("a and x", {"a": "Bool", "x": "Int"}, "PY-COND-NOT-BOOL"),
          errcased("not x", {"x": "Int"}, "PY-COND-NOT-BOOL"),
        ],
      )
    end,
    Test.test("the ternary lowers to a temp assigned a case value") do
      scope = {"x": "Int", "y": "Int", "c": "Bool"}
      decls = ["x: Int = 1", "y: Int = 2", "c: Bool = true"]
      check_all(
        compiled.unwrap!,
        "ternary",
        [
          cased_pre(
            "x if c else y",
            scope,
            decls,
            "Int",
            "py_t0",
            ["py_t0 = case c", "  true ->", "    x", "  _ ->", "    y", "end"],
          ),
        ],
        [
          errcased("x if y else z", {"x": "Int", "y": "Int", "z": "Int"}, "PY-COND-NOT-BOOL"),
          errcased("x if c else 1.5", {"x": "Int", "c": "Bool"}, "PY-TYPE-MISMATCH"),
        ],
      )
    end,
    Test.test("ternary Unknown unifies with the concrete side") do
      check_all(
        compiled.unwrap!,
        "ternary_unknown",
        [
          Case(
            expr: "h(x) if c else y",
            scope: {"h": "Unknown", "x": "Int", "c": "Bool", "y": "Int"},
            decls: ["x: Int = 1", "y: Int = 2", "c: Bool = true"],
            want_type: "Int",
            want_code: "py_t0",
            want_contains: [],
            want_pre: ["py_t0 = case c", "  true ->", "    h(x)", "  _ ->", "    y", "end"],
            as_type: "",
            skip_check: false,
            tops: ["def h(x: Int) -> Int\n  x\nend"],
          ),
        ],
        [],
      )
    end,
    Test.test("slices clamp through helpers") do
      lscope = {"xs": "List[Int]", "x": "Int"}
      ldecls = ["xs: List[Int] = [1, 2, 3]", "x: Int = 1"]
      check_all(
        compiled.unwrap!,
        "slices",
        [
          cased("xs[0:2]", lscope, ldecls, "List[Int]", "py_slice_list(xs, 0, 2)"),
          cased_pre("xs[x:]", lscope, ldecls, "List[Int]", "py_slice_list(py_t0, x, py_t0.size)", ["py_t0 = xs"]),
          cased("xs[:2]", lscope, ldecls, "List[Int]", "py_slice_list(xs, 0, 2)"),
          cased_pre("xs[:]", lscope, ldecls, "List[Int]", "py_slice_list(py_t0, 0, py_t0.size)", ["py_t0 = xs"]),
          cased(
            "xs[x:y]",
            {"xs": "List[Int]", "x": "Int", "y": "Int"},
            ["xs: List[Int] = [1, 2, 3]", "x: Int = 1", "y: Int = 2"],
            "List[Int]",
            "py_slice_list(xs, x, y)",
          ),
          cased("\"abcd\"[1:3]", empty_scope(), [], "String", "py_slice_str(\"abcd\", 1, 3)"),
          cased_pre(
            "s[1:]",
            {"s": "String"},
            ["s: String = \"abcd\""],
            "String",
            "py_slice_str(py_t0, 1, py_t0.length)",
            ["py_t0 = s"],
          ),
        ],
        [],
      )
    end,
    Test.test("indexes read and wrap negatives") do
      check_all(
        compiled.unwrap!,
        "indexes",
        [
          cased("xs[0]", {"xs": "List[Int]"}, ["xs: List[Int] = [1, 2]"], "Int", "xs[0]"),
          cased_pre(
            "xs[-1]",
            {"xs": "List[Int]"},
            ["xs: List[Int] = [1, 2]"],
            "Int",
            "py_t0[py_t0.size - (1)]",
            ["py_t0 = xs"],
          ),
          cased("s[0]", {"s": "String"}, ["s: String = \"ab\""], "String", "s.at(0)"),
          cased_pre(
            "s[-1]",
            {"s": "String"},
            ["s: String = \"ab\""],
            "String",
            "py_t0.at(py_t0.length - (1))",
            ["py_t0 = s"],
          ),
          cased("d[\"k\"]", {"d": "Map[String, Int]"}, ["d: Map[String, Int] = {\"k\": 1}"], "Int", "d[\"k\"]"),
        ],
        [],
      )
    end,
    Test.test("in and not-in map to include and key") do
      scope = {"x": "Int", "xs": "List[Int]", "s": "String", "d": "Map[String, Int]", "k": "String"}
      decls = [
        "x: Int = 1",
        "xs: List[Int] = [1]",
        "s: String = \"ab\"",
        "d: Map[String, Int] = {\"k\": 1}",
        "k: String = \"k\"",
      ]

      check_all(
        compiled.unwrap!,
        "membership",
        [
          cased("x in xs", scope, decls, "Bool", "xs.include?(x)"),
          cased("x not in xs", scope, decls, "Bool", "!(xs.include?(x))"),
          cased("k in s", scope, decls, "Bool", "s.include?(k)"),
          cased("k in d", scope, decls, "Bool", "d.key?(k)"),
          cased("k not in d", scope, decls, "Bool", "!(d.key?(k))"),
        ],
        [errcased("x in y", {"x": "Int", "y": "Int"}, "PY-OPERATOR")],
      )
    end,
    Test.test("is only tests None") do
      scope = {"o": "Optional[Int]", "x": "Int"}
      decls = ["o: Optional[Int] = none", "x: Int = 1"]
      check_all(
        compiled.unwrap!,
        "identity",
        [
          cased("o is None", scope, decls, "Bool", "o.none?"),
          cased("o is not None", scope, decls, "Bool", "!o.none?"),
          cased("None is None", empty_scope(), [], "Bool", "true"),
          cased("x == None", scope, decls, "Bool", "false"),
          cased("x is None", scope, decls, "Bool", "false"),
          cased("x is not None", scope, decls, "Bool", "true"),
          cased("None is not None", empty_scope(), [], "Bool", "false"),
        ],
        [errcased("x is y", {"x": "Int", "y": "Int"}, "PY-IS")],
      )
    end,
    Test.test("calls pass positionals and refuse keywords") do
      # A name bound to a value keeps the verbatim value-call spelling (the
      # backend judges it); a keyword there still refuses.
      check_all(
        compiled.unwrap!,
        "calls",
        [
          Case(
            expr: "f(x)",
            scope: {"f": "Unknown", "x": "Int"},
            decls: ["x: Int = 1"],
            want_type: "Unknown",
            want_code: "f(x)",
            want_contains: [],
            want_pre: [],
            as_type: "",
            skip_check: false,
            tops: ["def f(x: Int) -> Int\n  x\nend"],
          ),
        ],
        [
          errcased("nosuchfn(x)", {"x": "Int"}, "PY-NAME-UNKNOWN"),
          errcased("add(x, y=1)", {"add": "Unknown", "x": "Int"}, "PY-OUT-OF-SUBSET"),
          errcased("len", empty_scope(), "PY-OUT-OF-SUBSET"),
          errcased("(len)", empty_scope(), "PY-OUT-OF-SUBSET"),
          errcased("-len", empty_scope(), "PY-OUT-OF-SUBSET"),
          errcased("len + 1", empty_scope(), "PY-OUT-OF-SUBSET"),
          errcased("str", empty_scope(), "PY-OUT-OF-SUBSET"),
          # A def name carries the callable marker and is not a value either:
          # the backend has no function values, so a bare use refuses.
          errcased("greet", {"greet": EmitCtx.def_marker()}, "PY-OUT-OF-SUBSET"),
        ],
      )
    end,
    Test.test("print joins with single spaces") do
      check_all(
        compiled.unwrap!,
        "print",
        [
          cased(
            "print(x, s)",
            {"x": "Int", "s": "String"},
            ["x: Int = 1", "s: String = \"a\""],
            "Void",
            "puts(" + quoted(interp("x") + " " + interp("s")) + ")",
          ),
          cased("print()", empty_scope(), [], "Void", "puts(\"\")"),
          cased("print(x)", {"x": "Int"}, ["x: Int = 1"], "Void", "puts(" + quoted(interp("x")) + ")"),
        ],
        [errcased("print(x, sep=\",\")", {"x": "Int"}, "PY-OUT-OF-SUBSET")],
      )
    end,
    Test.test("len picks size or length") do
      check_all(
        compiled.unwrap!,
        "len",
        [
          cased("len(xs)", {"xs": "List[Int]"}, ["xs: List[Int] = [1]"], "Int", "xs.size"),
          cased("len(s)", {"s": "String"}, ["s: String = \"ab\""], "Int", "s.length"),
          cased("len(d)", {"d": "Map[String, Int]"}, ["d: Map[String, Int] = {\"k\": 1}"], "Int", "d.size"),
          cased("len(r)", {"r": "Range"}, ["r: Range = 0...3"], "Int", "r.size"),
        ],
        [errcased("len(x)", {"x": "Int"}, "PY-TYPE-MISMATCH")],
      )
    end,
    Test.test("range maps to backend ranges") do
      check_all(
        compiled.unwrap!,
        "range",
        [
          cased("range(3)", empty_scope(), [], "Range", "0...3"),
          cased("range(x, y)", {"x": "Int", "y": "Int"}, ["x: Int = 1", "y: Int = 5"], "Range", "x...y"),
          cased("range(u)", {"u": "Unknown"}, ["u: Int = 1"], "Range", "0...u"),
        ],
        [
          errcased("range()", empty_scope(), "PY-OPERATOR"),
          errcased("range(1, 9, 2)", empty_scope(), "PY-OUT-OF-SUBSET"),
          errcased("range(\"a\")", empty_scope(), "PY-TYPE-MISMATCH"),
          errcased("range(x)", {"x": "String"}, "PY-TYPE-MISMATCH"),
        ],
      )
    end,
    Test.test("int and float convert by the table") do
      scope = {"s": "String", "x": "Int", "f": "Float"}
      decls = ["s: String = \"42\"", "x: Int = 1", "f: Float = 1.5"]
      check_all(
        compiled.unwrap!,
        "intfloat",
        [
          cased("int(s)", scope, decls, "Result[Int]", "s.to_i"),
          cased("int(f)", scope, decls, "Result[Int]", "f.to_i"),
          cased("float(s)", scope, decls, "Result[Float]", "s.to_f"),
          cased("float(x)", scope, decls, "Float", "x.to_f"),
        ],
        [
          errcased("int(x)", {"x": "Int"}, "PY-TYPE-MISMATCH"),
          errcased("float(f)", {"f": "Float"}, "PY-TYPE-MISMATCH"),
          errcased("int(b)", {"b": "Bool"}, "PY-TYPE-MISMATCH"),
        ],
      )
    end,
    Test.test("str and bool convert by the table") do
      scope = {"x": "Int", "b": "Bool"}
      decls = ["x: Int = 1", "b: Bool = true"]
      check_all(
        compiled.unwrap!,
        "strbool",
        [
          cased("str(x)", scope, decls, "String", quoted(interp("x"))),
          cased("str()", empty_scope(), [], "String", "\"\""),
          cased("bool(b)", scope, decls, "Bool", "b"),
        ],
        [
          errcased("bool(x)", {"x": "Int"}, "PY-TYPE-MISMATCH"),
          errcased("str(x, y)", {"x": "Int", "y": "Int"}, "PY-OPERATOR"),
        ],
      )
    end,
    Test.test("ordered builtins map to methods") do
      scope = {"xs": "List[Int]", "f": "Float", "x": "Int", "s": "String"}
      decls = ["xs: List[Int] = [2, 1]", "f: Float = 1.2", "x: Int = 0", "s: String = \"A\""]
      check_all(
        compiled.unwrap!,
        "builtins1",
        [
          cased("sorted(xs)", scope, decls, "List[Int]", "xs.sort"),
          cased("sum(xs)", scope, decls, "Int", "xs.sum"),
          cased("min(xs)", scope, decls, "Optional[Int]", "xs.min"),
          cased("max(xs)", scope, decls, "Optional[Int]", "xs.max"),
          cased("abs(x)", scope, decls, "Int", "x.abs"),
          cased("abs(f)", scope, decls, "Float", "f.abs"),
          cased("round(f)", scope, decls, "Int", "f.round"),
          cased("chr(x)", scope, decls, "String", "String.from_code(x)"),
          cased("ord(s)", scope, decls, "Int", "s.code"),
        ],
        [
          errcased("round(x)", {"x": "Int"}, "PY-OPERATOR"),
          errcased("abs(s)", {"s": "String"}, "PY-TYPE-MISMATCH"),
          errcased("sorted(s)", {"s": "String"}, "PY-TYPE-MISMATCH"),
          errcased("sum(s)", {"s": "String"}, "PY-TYPE-MISMATCH"),
          errcased("min(s)", {"s": "String"}, "PY-TYPE-MISMATCH"),
          errcased("sorted(bs)", {"bs": "List[Bool]"}, "PY-TYPE-MISMATCH"),
          errcased("sum(ss)", {"ss": "List[String]"}, "PY-TYPE-MISMATCH"),
        ],
      )
    end,
    Test.test("higher-order builtins map through blocks") do
      scope = {"xs": "List[Int]", "bs": "List[Bool]"}
      decls = ["xs: List[Int] = [2, 1]", "bs: List[Bool] = [true]"]
      check_all(
        compiled.unwrap!,
        "builtins2",
        [
          cased("reversed(xs)", scope, decls, "List[Int]", "xs.reverse"),
          cased("all(bs)", scope, decls, "Bool", "(bs.all? { |py_x0| py_x0 })"),
          cased("any(bs)", scope, decls, "Bool", "(bs.any? { |py_x0| py_x0 })"),
          Case(
            expr: "map(inc, xs)",
            scope: {"inc": EmitCtx.def_marker(), "xs": "List[Int]"},
            decls: ["xs: List[Int] = [1]"],
            want_type: "List",
            want_code: "(xs.map { |py_x0| inc(py_x0) })",
            want_contains: [],
            want_pre: [],
            as_type: "",
            skip_check: false,
            tops: ["def inc(x: Int) -> Int\n  x\nend"],
          ),
          Case(
            expr: "filter(keep, xs)",
            scope: {"keep": EmitCtx.def_marker(), "xs": "List[Int]"},
            decls: ["xs: List[Int] = [1]"],
            want_type: "List",
            want_code: "(xs.filter { |py_x0| keep(py_x0) })",
            want_contains: [],
            want_pre: [],
            as_type: "",
            skip_check: false,
            tops: ["def keep(x: Int) -> Bool\n  x > 0\nend"],
          ),
        ],
        [
          errcased("map(len, xs)", {"xs": "List[Int]"}, "PY-OPERATOR"),
          errcased("enumerate(xs)", {"xs": "List[Int]"}, "PY-OUT-OF-SUBSET"),
          errcased("map(nosuch, xs)", {"xs": "List[Int]"}, "PY-NAME-UNKNOWN"),
          errcased("filter(nosuch, xs)", {"xs": "List[Int]"}, "PY-NAME-UNKNOWN"),
          errcased("map(nosuch(x), xs)", {"xs": "List[Int]", "x": "Int"}, "PY-NAME-UNKNOWN"),
          # A local holding a value is not a callable: only a `def` name
          # lowers to the block callback.
          errcased("map(n, xs)", {"n": "Int", "xs": "List[Int]"}, "PY-OPERATOR"),
          # A Result def has no block form: the callback would yield Results.
          errcased_sigs(
            "map(parse, xs)",
            {"parse": EmitCtx.def_marker(), "xs": "List[String]"},
            "PY-OPERATOR",
            {"parse": result_sig("parse", "Result[Int]")},
          ),
          errcased_sigs(
            "filter(check, xs)",
            {"check": EmitCtx.def_marker(), "xs": "List[Int]"},
            "PY-OPERATOR",
            {"check": result_sig("check", "Result[Bool]")},
          ),
          errcased("reversed(s)", {"s": "String"}, "PY-TYPE-MISMATCH"),
          errcased("all(xs)", {"xs": "List[Int]"}, "PY-TYPE-MISMATCH"),
          errcased("any(xs)", {"xs": "List[Int]"}, "PY-TYPE-MISMATCH"),
        ],
      )
    end,
    Test.test("d.get reads") do
      scope = {"d": "Map[String, Int]", "k": "String"}
      decls = ["d: Map[String, Int] = {\"k\": 1}", "k: String = \"k\""]
      check_all(compiled.unwrap!, "get_read", [cased("d.get(k)", scope, decls, "Optional[Int]", "d.get(k)")], [])
    end,
    Test.test("d.get with default") do
      scope = {"d": "Map[String, Int]", "k": "String"}
      decls = ["d: Map[String, Int] = {\"k\": 1}", "k: String = \"k\""]
      check_all(compiled.unwrap!, "get_dflt", [cased("d.get(k, 0)", scope, decls, "Int", "d.get(k, 0)")], [])
    end,
    Test.test("d.get rejects three args") do
      check_all(
        compiled.unwrap!,
        "get_3args",
        [],
        [
          errcased("d.get(k, 0, 1)", {"d": "Map[String, Int]", "k": "String"}, "PY-OUT-OF-SUBSET"),
          errcased("d.get()", {"d": "Map[String, Int]"}, "PY-OUT-OF-SUBSET"),
          errcased("d.get(k, v=1)", {"d": "Map[String, Int]", "k": "String"}, "PY-OUT-OF-SUBSET"),
        ],
      )
    end,
    Test.test("s.strip") do
      scope = {"s": "String", "xs": "List[String]"}
      decls = ["s: String = \"  a,b  \"", "xs: List[String] = [\"a\", \"b\"]"]
      check_all(
        compiled.unwrap!,
        "strip",
        [cased("s.strip()", scope, decls, "String", "s.strip()")],
        [errcased("s.strip(\",\")", scope, "PY-OPERATOR")],
      )
    end,
    Test.test("s.split") do
      scope = {"s": "String", "xs": "List[String]"}
      decls = ["s: String = \"  a,b  \"", "xs: List[String] = [\"a\", \"b\"]"]
      check_all(
        compiled.unwrap!,
        "split",
        [cased("s.split(\",\")", scope, decls, "List[String]", "s.split(\",\")")],
        [],
      )
    end,
    Test.test("sep.join") do
      scope = {"s": "String", "xs": "List[String]"}
      decls = ["s: String = \"  a,b  \"", "xs: List[String] = [\"a\", \"b\"]"]
      check_all(compiled.unwrap!, "join", [cased("\"sep\".join(xs)", scope, decls, "String", "xs.join(\"sep\")")], [])
    end,
    Test.test("s.replace") do
      scope = {"s": "String", "xs": "List[String]"}
      decls = ["s: String = \"  a,b  \"", "xs: List[String] = [\"a\", \"b\"]"]
      check_all(
        compiled.unwrap!,
        "replace",
        [cased("s.replace(\"a\", \"b\")", scope, decls, "String", "s.replace(\"a\", \"b\")")],
        [],
      )
    end,
    Test.test("s.lower") do
      scope = {"s": "String", "xs": "List[String]"}
      decls = ["s: String = \"  a,b  \"", "xs: List[String] = [\"a\", \"b\"]"]
      check_all(compiled.unwrap!, "lower", [cased("s.lower()", scope, decls, "String", "s.downcase()")], [])
    end,
    Test.test("s.upper") do
      scope = {"s": "String", "xs": "List[String]"}
      decls = ["s: String = \"  a,b  \"", "xs: List[String] = [\"a\", \"b\"]"]
      check_all(compiled.unwrap!, "upper", [cased("s.upper()", scope, decls, "String", "s.upcase()")], [])
    end,
    Test.test("s.startswith") do
      scope = {"s": "String", "xs": "List[String]"}
      decls = ["s: String = \"  a,b  \"", "xs: List[String] = [\"a\", \"b\"]"]
      check_all(
        compiled.unwrap!,
        "startswith",
        [cased("s.startswith(\"a\")", scope, decls, "Bool", "s.start_with?(\"a\")")],
        [],
      )
    end,
    Test.test("s.endswith") do
      scope = {"s": "String", "xs": "List[String]"}
      decls = ["s: String = \"  a,b  \"", "xs: List[String] = [\"a\", \"b\"]"]
      check_all(
        compiled.unwrap!,
        "endswith",
        [cased("s.endswith(\"b\")", scope, decls, "Bool", "s.end_with?(\"b\")")],
        [],
      )
    end,
    Test.test("xs.append is refused") do
      check_all(
        compiled.unwrap!,
        "ref_append",
        [],
        [errcased("xs.append(x)", {"xs": "List[Int]", "x": "Int"}, "PY-MUTATION")],
      )
    end,
    Test.test("xs.sort is refused") do
      check_all(compiled.unwrap!, "ref_sort", [], [errcased("xs.sort()", {"xs": "List[Int]"}, "PY-MUTATION")])
    end,
    Test.test("xs.reverse is refused") do
      check_all(
        compiled.unwrap!,
        "ref_reverse",
        [],
        [
          errcased("xs.reverse()", {"xs": "List[Int]"}, "PY-MUTATION"),
          errcased("xs.reverse()", {"xs": "Unknown"}, "PY-MUTATION"),
        ],
      )
    end,
    Test.test("d.pop is refused") do
      check_all(
        compiled.unwrap!,
        "ref_pop",
        [],
        [errcased("d.pop(k)", {"d": "Map[String, Int]", "k": "String"}, "PY-MUTATION")],
      )
    end,
    Test.test("unknown method is refused") do
      check_all(compiled.unwrap!, "ref_frob", [], [errcased("s.frobnicate()", {"s": "String"}, "PY-OUT-OF-SUBSET")])
    end,
    Test.test("bare method name is refused") do
      check_all(compiled.unwrap!, "ref_bare", [], [errcased("s.strip", {"s": "String"}, "PY-OUT-OF-SUBSET")])
    end,
    # Stdlib TODO (phase 3b probes on agentica 0.35.0): every dotted module
    # path below stays verbatim because phase 4 owns module meaning, and none
    # of the lowercase paths check as Agentica references — so no fixture may
    # run `check` over them. Skipped mappings, each verified by probe:
    # TODO(math.sqrt -> Math.sqrt: `math.sqrt` verbatim is CHECK-UNKNOWN-NAME)
    # TODO(math.floor/ceil -> Float methods `x.floor()`/`x.ceil()`)
    # TODO(math.pi/e/tau -> Float literals 3.14159.../2.71828.../6.28318...)
    # TODO(math.inf: excluded, no spelling)
    # TODO(sys.argv -> System.args(), sys.exit -> System.exit(code))
    # TODO(sys stdin/stderr -> IO.gets/IO.warn)
    # TODO(os.environ[k]/os.getenv -> System.env (a catchable Result))
    # TODO(os.getcwd() -> Path.cwd(), open(p)/open(p,"w")/open(p,"a") -> File.*)
    # TODO(json/re/toml/datetime/urllib/http/html/mime/cookies/argparse/logging/time/random/hashlib/pathlib -> std/*
    # or closed)
    # TODO(enumerate expression form: desugars to an index counter in phase 3c)
    # TODO(3-arg range(a, b, step): desugars to a `while` in phase 3c)
    Test.test("math.sqrt stays verbatim") do
      check_all(
        compiled.unwrap!,
        "verb_sqrt",
        [
          Case(
            expr: "math.sqrt(4.0)",
            scope: {"math": "Unknown"},
            decls: [],
            want_type: "Unknown",
            want_code: "math.sqrt(4.0)",
            want_contains: [],
            want_pre: [],
            as_type: "",
            skip_check: true,
            tops: [],
          ),
        ],
        [],
      )
    end,
    Test.test("dotted path stays verbatim") do
      check_all(
        compiled.unwrap!,
        "verb_path",
        [
          Case(
            expr: "a.b.c",
            scope: {"a": "Unknown"},
            decls: [],
            want_type: "Unknown",
            want_code: "a.b.c",
            want_contains: [],
            want_pre: [],
            as_type: "",
            skip_check: true,
            tops: [],
          ),
        ],
        [],
      )
    end,
    Test.test("f-strings interpolate holes") do
      check_all(
        compiled.unwrap!,
        "fstrings",
        [
          cased(
            "f\"hi {name}!\"",
            {"name": "String"},
            ["name: String = \"bob\""],
            "String",
            quoted("hi " + interp("name") + "!"),
          ),
          cased("f\"{{x}}\"", {}, [], "String", "\"{x}\""),
          cased(
            "f\"{x + y}\"",
            {"x": "Int", "y": "Int"},
            ["x: Int = 1", "y: Int = 2"],
            "String",
            quoted(interp("x + y")),
          ),
        ],
        [],
      )
    end,
    Test.test("all fragments check clean together") do
      blocks = try File.read_text("/tmp/agc_emit_blocks.txt")
      calls = try File.read_text("/tmp/agc_emit_calls.txt")
      program = "#{EmitExpr.helpers()}\n#{blocks}\ndef main() -> Void\n#{calls}end\n"

      try File.write_text("/tmp/agc_emit_all.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/agc_emit_all.agc"])
      result = try Process.output(proc, 30000)
      Test.assert(
        result.stdout.include?("check ok"),
        "check /tmp/agc_emit_all.agc failed:\n#{result.stdout}\n#{result.stderr}\n#{program}",
      )
    end,
  ])
end

# Starts the fragment accumulators empty (see check_all): a fresh file per
# run, so a previous aborted run never leaks fragments into this one.
def reset_accumulators() -> Result[Void]
  try File.write_text("/tmp/agc_emit_blocks.txt", "")
  try File.write_text("/tmp/agc_emit_calls.txt", "")
  ok()
end
