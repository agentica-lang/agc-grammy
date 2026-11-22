## Phase 3c lane A binding-statement tests: every emitted fragment passes
## `agentica check` in the test itself, and one behavior test runs the
## grouped and quoted shapes to pin their values.
##
## Each test parses tiny programs (at most three lines) with a single
## `Engine.run`, emits each statement through `EmitAssign` with a threaded
## `EmitCtx`, asserts the exact lines (or the refusal code) plus the scope
## and temp supply after, then appends the checkable fragments to shared
## lane-suffixed accumulators: one `agentica check` per test blows the
## test-runner step budget (a full VM boot each), so a single final test
## checks every fragment together. Each fragment keeps its own function
## (named per test slug) with the shared helpers plus `puts` for every bound
## name (a checked program refuses unused locals). Type aliases accumulate
## as top-level lines (the backend only allows them there); everything else
## accumulates as a function plus its `main` call.

import EmitAssign from "../src/emit_assign"
import EmitCtx from "../src/emit_ctx"
import EmitExpr from "../src/emit_expr"
import Engine from "../../src/engine"
import Frontend from "../src/frontend"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

# One threaded run: the emitted lines plus the context after.
struct RunOk
  lines: List[String]
  ctx: EmitCtx.EmitCtx
end

def top_ctx(source: String) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(source: source, file: "assign_test", scope: {}, func_ret: "", in_try: false, next_temp: 0)
end

def func_ctx(source: String, ret: String, scope: Map[String, String]) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(source: source, file: "assign_test", scope: scope, func_ret: ret, in_try: false, next_temp: 0)
end

# A context inside an outlined `try` body: the coordinator sets `in_try`,
# so a `Result[T]` value unwraps with `try` against the declared type.
def try_ctx(source: String, ret: String, scope: Map[String, String]) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(source: source, file: "assign_test", scope: scope, func_ret: ret, in_try: true, next_temp: 0)
end

# Dispatches one statement to its lane A emitter by rule, narrowing the
# parse node to the pieces the emitter takes.
def dispatch(ctx: EmitCtx.EmitCtx, node: Tree.Node, source: String) -> Result[EmitCtx.StmtRes]
  case node.rule
    "annotated" ->
      occ = try occ_of(node, source, "declare")
      ann = try ann_of(node, source)
      ok(EmitAssign.emit_annotated(ctx, occ, ann, Tree.first_child(node, "cond_expr"), source))
    "assign" ->
      occ = try occ_of(node, source, "assign")
      value = try Tree.first_child(node, "cond_expr").to_result("test: assignment without a value")
      ok(EmitAssign.emit_assigned(ctx, occ, value, source))
    "augmented_assign" ->
      occ = try occ_of(node, source, "assign")
      op_node = try Tree.first_child(node, "aug_op").to_result("test: augmented assignment without an operator")
      value = try Tree.first_child(node, "cond_expr").to_result("test: augmented assignment without a value")
      ok(EmitAssign.emit_augassigned(ctx, occ, Tree.text(op_node, source), value, source))
    "type_alias" ->
      occ = try occ_of(node, source, "declare")
      ann = try ann_of(node, source)
      ok(EmitAssign.emit_alias(ctx, occ, ann, source))
    "return_stmt" ->
      span = Frontend.Span(start: node.start, stop: node.stop)
      ok(EmitAssign.emit_return(ctx, Tree.first_child(node, "cond_expr"), span, source))
    "expr_stmt" ->
      expr = try Tree.first_child(node, "cond_expr").to_result("test: expression statement without a value")
      ok(EmitAssign.emit_expr_stmt(ctx, expr, source))
    "call_stmt" ->
      callee = try Tree.first_child(node, "call").to_result("test: call statement without a call")
      ok(EmitAssign.emit_expr_stmt(ctx, callee, source))
    _ -> ok(EmitCtx.refuse("PY-OUT-OF-SUBSET", "statement `#{node.rule}` is not lane A", none, node))
  end
end

# The binding occurrence for a lane A test statement.
def occ_of(node: Tree.Node, source: String, kind: String) -> Result[Frontend.NameOcc]
  name_node = try Tree.first_child(node, "name").to_result("test: binding without a name")
  ok(
    Frontend.NameOcc(
      name: Tree.text(name_node, source),
      span: Frontend.Span(start: name_node.start, stop: name_node.stop),
      kind: kind,
    ),
  )
end

# The annotation occurrence for a lane A test statement.
def ann_of(node: Tree.Node, source: String) -> Result[Frontend.Ann]
  ann_node = try Tree.first_child(node, "annotation").to_result("test: binding without an annotation")
  ok(Frontend.Ann(text: Tree.text(ann_node, source), span: Frontend.Span(start: ann_node.start, stop: ann_node.stop)))
end

# Emits every statement of `src` in order, threading the context. A refusal
# anywhere fails the whole run with its code and message.
def run_all(compiled: Grammar.Grammar, src: String, ctx: EmitCtx.EmitCtx) -> Result[RunOk]
  tree = try Engine.run(compiled, "program", src)
  current = ctx
  lines: List[String] = []
  failure = ""
  for stmt in tree.children
    if failure == ""
      case try dispatch(current, stmt, src)
        EmitCtx.StmtRes.Ok(out) ->
          lines = lines + out.code
          current = EmitCtx.EmitCtx(
            source: src,
            file: current.file,
            scope: out.scope,
            func_ret: current.func_ret,
            in_try: current.in_try,
            next_temp: out.next_temp,
          )
        EmitCtx.StmtRes.No(ref) -> failure = "#{ref.code}: #{ref.message}"
      end
    end
  end

  if failure != ""
    error(failure)
  else
    ok(RunOk(lines: lines, ctx: current))
  end
end

# Emits every program in `srcs` in order, threading one context, so
# later statements sit past earlier temps exactly like the coordinator's
# spine. A refusal anywhere fails the whole run with its code.
def run_seq(compiled: Grammar.Grammar, srcs: List[String], ctx: EmitCtx.EmitCtx) -> Result[RunOk]
  lines: List[String] = []
  current = ctx
  for src in srcs
    ran = try run_all(compiled, src, current)
    lines = lines + ran.lines
    current = ran.ctx
  end

  ok(RunOk(lines: lines, ctx: current))
end

# Emits `src` and answers its first refusal; fails when everything emits.
def run_no(compiled: Grammar.Grammar, src: String, ctx: EmitCtx.EmitCtx) -> Result[EmitCtx.Refusal]
  tree = try Engine.run(compiled, "program", src)
  current = ctx
  found: Optional[EmitCtx.Refusal] = none
  for stmt in tree.children
    if !found.some?
      case try dispatch(current, stmt, src)
        EmitCtx.StmtRes.Ok(out) ->
          current = EmitCtx.EmitCtx(
            source: src,
            file: current.file,
            scope: out.scope,
            func_ret: current.func_ret,
            in_try: current.in_try,
            next_temp: out.next_temp,
          )
        EmitCtx.StmtRes.No(ref) -> found = some(ref)
      end
    end
  end

  case found
    some(ref) -> ok(ref)
    none -> error("expected a refusal for #{src.inspect}")
  end
end

# Appends one checkable function fragment: the emitted lines plus `puts`
# for every bound name, wrapped in its own function calling `puts`.
# TODO(parallel): `/tmp/agc_emit_assign_blocks.txt` is order-dependent like
# the 3b accumulator; use env-overridable accumulator paths.
# Writes one function fragment into the block and call accumulators.
def add_fragment(slug: String, body: List[String], ret: String) -> Result[Void]
  head = "def py_assign_#{slug}() -> Void"
  if ret != "" and ret != "None"
    head = "def py_assign_#{slug}() -> #{ret}"
  end

  text = "#{head}\n#{body.map { |line| "  #{line}" }.join("\n")}\nend\n\n"
  blocks = try File.read_text("/tmp/agc_emit_assign_blocks.txt")
  try File.write_text("/tmp/agc_emit_assign_blocks.txt", "#{blocks}#{text}")
  calls = try File.read_text("/tmp/agc_emit_assign_calls.txt")
  try File.write_text("/tmp/agc_emit_assign_calls.txt", "#{calls}  py_assign_#{slug}()\n")
  ok()
end

def add_func(
  compiled: Grammar.Grammar,
  slug: String,
  src: String,
  ctx: EmitCtx.EmitCtx,
  ret: String,
  uses: List[String],
) -> Result[Void]
  ran = try run_all(compiled, src, ctx)
  try add_fragment(slug, ran.lines + uses.map { |name| "puts(#{name})" }, ret)

  ok()
end

# Appends an already-emitted fragment: the lines plus `puts` for every
# bound name. Unlike `add_func` it never re-parses, so a test can check a
# multi-statement emission without paying a second, superlinear parse.
def add_lines(slug: String, lines: List[String], uses: List[String], ret: String) -> Result[Void]
  try add_fragment(slug, lines + uses.map { |name| "puts(#{name})" }, ret)

  ok()
end

# Appends one alias fragment to the top-level accumulator (the backend
# only allows aliases before any function) and answers the scope after.
def add_alias(compiled: Grammar.Grammar, src: String, ctx: EmitCtx.EmitCtx) -> Result[Map[String, String]]
  ran = try run_all(compiled, src, ctx)
  try Test.eq(ran.lines.size, 1)
  aliases = try File.read_text("/tmp/agc_emit_assign_aliases.txt")
  try File.write_text("/tmp/agc_emit_assign_aliases.txt", "#{aliases}#{List.first(ran.lines)}\n\n")
  ok(ran.ctx.scope)
end

def ref_text(source: String, ref: EmitCtx.Refusal) -> String = source.slice(ref.start, ref.stop - ref.start)

# Spells `#{code}` without writing `#{` in a literal (which the test file
# itself would interpolate).
def interp(code: String) -> String = "#" + "{" + code + "}"

def quoted(inner: String) -> String = "\"" + inner + "\""

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  # Compile only in the run worker and share it across the fixtures.
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
    Test.test("backend shapes check clean on their own") do
      program = (
        "type PyHelperA = Int\n\n#{EmitExpr.helpers()}\ndef py_assign_probe() -> Void\n  x: PyHelperA = 1\n  x = x + py_pymod(7, 2)\n  x = py_floor_div(x, 2)\n  puts(x)\nend\n\ndef main() -> Void\n  py_assign_probe()\nend\n"
      )

      try File.write_text("/tmp/agc_emit_assign_helpers.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/agc_emit_assign_helpers.agc"])
      result = try Process.output(proc, 30000)
      try Test.assert(result.stdout.include?("check ok"), result.stdout + result.stderr)
      Test.assert(program.include?("type PyHelperA = Int"), "alias line kept")
    end,
    # The alias line lands first in the accumulator (the backend only
    # checks top-level aliases before any function).
    Test.test("type alias emits and resolves at use") do
      alias_src = "type PyAliasA = int\n"
      ran = try run_all(compiled.unwrap!, alias_src, top_ctx(alias_src))
      try Test.eq(ran.lines, ["type PyAliasA = Int"])
      scope = try add_alias(compiled.unwrap!, alias_src, top_ctx(alias_src))
      try Test.eq(scope.get("PyAliasA", ""), "Int")
      use_src = "x: PyAliasA = 1\n"
      ran2 = try run_all(compiled.unwrap!, use_src, func_ctx(use_src, "None", scope))
      try Test.eq(ran2.lines, ["x: Int = 1"])
      try add_func(compiled.unwrap!, "alias_use", use_src, func_ctx(use_src, "None", scope), "None", ["x"])
      ok()
    end,
    Test.test("alias resolves inside generics, optional and unions") do
      ran = try run_all(compiled.unwrap!, "type PyAliasA = int\n", top_ctx(""))
      try Test.eq(ran.lines, ["type PyAliasA = Int"])
      # The alias line itself stays in the accumulator of the emit test
      # above; the scope it seeded drives every structural resolution here.
      ran2 = try run_seq(
        compiled.unwrap!,
        [
          "x: list[PyAliasA] = [1, 2]\n", "y: PyAliasA | None = None\n", "z: Optional[PyAliasA] = None\n",
          "d: dict[str, PyAliasA] = {}\n", "q: \"PyAliasA\" = 1\n",
        ],
        ran.ctx,
      )

      try Test.eq(
        ran2.lines,
        [
          "x: List[Int] = [1, 2]", "y: Optional[Int] = none", "z: Optional[Int] = none", "d: Map[String, Int] = {}",
          "q: Int = 1",
        ],
      )

      try add_lines("alias_struct", ran2.lines, ["x", "y", "z", "d", "q"], "")
      ok()
    end,
    Test.test("annotated declare emits") do
      src = "x: int = 1\n"
      ran = try run_all(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ran.lines, ["x: Int = 1"])
      try Test.eq(ran.ctx.scope.get("x", ""), "Int")
      try Test.eq(ran.ctx.next_temp, 0)
      try add_func(compiled.unwrap!, "decl", src, top_ctx(src), "None", ["x"])
      ok()
    end,
    Test.test("bare declaration binds with no code") do
      src = "x: int\n"
      ran = try run_all(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ran.lines, [])
      try Test.eq(ran.ctx.scope.get("x", ""), "Int")
      try Test.eq(ran.ctx.next_temp, 0)
      ok()
    end,
    Test.test("annotated mismatch refuses") do
      first = "x: int = 1.5\n"
      ref = try run_no(compiled.unwrap!, first, top_ctx(first))
      try Test.eq(ref.code, "PY-TYPE-MISMATCH")
      second = "x: int = None\n"
      ref2 = try run_no(compiled.unwrap!, second, top_ctx(second))
      try Test.eq(ref2.code, "PY-TYPE-MISMATCH")
      str_src = "bad: Optional[int] = \"a\"\n"
      ref3 = try run_no(compiled.unwrap!, str_src, top_ctx(str_src))
      try Test.eq(ref3.code, "PY-TYPE-MISMATCH")
      seeded = func_ctx(str_src, "None", {"d": "Map[String, Int]"})
      ref4 = try run_no(compiled.unwrap!, "w: Optional[int] = d\n", seeded)
      try Test.eq(ref4.code, "PY-TYPE-MISMATCH")
      ok()
    end,
    Test.test("None, Any and bare Optional annotations refuse spanned") do
      ref = try run_no(compiled.unwrap!, "x: None = None\n", top_ctx(""))
      try Test.eq(ref.code, "PY-ANNOTATION-UNKNOWN")
      try Test.eq(ref_text("x: None = None\n", ref), "None")
      ref2 = try run_no(compiled.unwrap!, "x: None\n", top_ctx(""))
      try Test.eq(ref2.code, "PY-ANNOTATION-UNKNOWN")
      ref3 = try run_no(compiled.unwrap!, "x: Any = 1\n", top_ctx(""))
      try Test.eq(ref3.code, "PY-ANY")
      try Test.eq(ref_text("x: Any = 1\n", ref3), "Any")
      ref4 = try run_no(compiled.unwrap!, "x: Optional = none\n", top_ctx(""))
      try Test.eq(ref4.code, "PY-ANNOTATION-UNKNOWN")
      try Test.eq(ref_text("x: Optional = none\n", ref4), "Optional")
      # Aliases land in the same refusal: a `none` target, a bare
      # `Optional` target, a seeded alias resolving to `none` at a return.
      ref5 = try run_no(compiled.unwrap!, "type PyNoneA = None\n", top_ctx(""))
      try Test.eq(ref5.code, "PY-ANNOTATION-UNKNOWN")
      try Test.eq(ref_text("type PyNoneA = None\n", ref5), "None")
      ref6 = try run_no(compiled.unwrap!, "type PyOptA = Optional\n", top_ctx(""))
      try Test.eq(ref6.code, "PY-ANNOTATION-UNKNOWN")
      seeded = try run_no(compiled.unwrap!, "return 5\n", func_ctx("return 5\n", "PyNoneB", {"PyNoneB": "none"}))
      try Test.eq(seeded.code, "PY-ANNOTATION-UNKNOWN")
      ok()
    end,
    # Bare `list`/`dict` map to no backend type (probed CHECK-UNKNOWN-TYPE
    # for the emitted `List`/`Map` spellings), so every annotation site
    # refuses spanned at the name with a parameterized example.
    Test.test("bare list and dict annotations refuse spanned") do
      ref = try run_no(compiled.unwrap!, "xs: list = []\n", top_ctx("xs: list = []\n"))
      try Test.eq(ref.code, "PY-ANNOTATION-UNKNOWN")
      try Test.eq(ref_text("xs: list = []\n", ref), "list")
      try Test.assert(ref.message.include?("one parameter"), ref.message)
      ref2 = try run_no(compiled.unwrap!, "d: dict = {}\n", top_ctx("d: dict = {}\n"))
      try Test.eq(ref2.code, "PY-ANNOTATION-UNKNOWN")
      try Test.eq(ref_text("d: dict = {}\n", ref2), "dict")
      try Test.assert(ref2.message.include?("two parameters"), ref2.message)
      # Nested inside a parameterized form, the bare head refuses too.
      ref3 = try run_no(compiled.unwrap!, "xss: list[list] = []\n", top_ctx("xss: list[list] = []\n"))
      try Test.eq(ref3.code, "PY-ANNOTATION-UNKNOWN")
      try Test.eq(ref_text("xss: list[list] = []\n", ref3), "list[list]")
      # An alias declaring a bare container refuses at its own annotation.
      ref4 = try run_no(compiled.unwrap!, "type Bunch = list\n", top_ctx("type Bunch = list\n"))
      try Test.eq(ref4.code, "PY-ANNOTATION-UNKNOWN")
      ok()
    end,
    Test.test("duplicate binding refuses") do
      src = "x: int = 1\nx: int = 2\n"
      ref = try run_no(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ref.code, "PY-DUPLICATE-BINDING")
      ok()
    end,
    Test.test("duplicate type alias refuses") do
      src = "type PyAliasDup = int\ntype PyAliasDup = int\n"
      ref = try run_no(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ref.code, "PY-DUPLICATE-BINDING")
      ok()
    end,
    Test.test("assigned rebinds") do
      src = "x: int = 1\nx = x + 1\n"
      ran = try run_all(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ran.lines, ["x: Int = 1", "x = x + 1"])
      try Test.eq(ran.ctx.scope.get("x", ""), "Int")
      try add_func(compiled.unwrap!, "rebind", src, top_ctx(src), "None", ["x"])
      ok()
    end,
    Test.test("assigned change refuses") do
      src = "x: int = 1\nx = \"a\"\n"
      ref = try run_no(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ref.code, "PY-TYPE-MISMATCH")
      ok()
    end,
    Test.test("assigned without declaration refuses") do
      src = "x = 1\n"
      ref = try run_no(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ref.code, "PY-UNTYPED-NAME")
      ok()
    end,
    Test.test("augmented forms emit") do
      first = "x: int = 1\nx += 2\n"
      ran = try run_all(compiled.unwrap!, first, top_ctx(first))
      try Test.eq(ran.lines, ["x: Int = 1", "x = x + (2)"])
      try add_func(compiled.unwrap!, "aug_add", first, top_ctx(first), "None", ["x"])
      second = "f: float = 1.5\nf /= 2.0\n"
      ran2 = try run_all(compiled.unwrap!, second, top_ctx(second))
      try Test.eq(ran2.lines, ["f: Float = 1.5", "f = f / (2.0)"])
      try add_func(compiled.unwrap!, "aug_div", second, top_ctx(second), "None", ["f"])
      third = "s: str = \"a\"\ns += \"b\"\n"
      ran3 = try run_all(compiled.unwrap!, third, top_ctx(third))
      try Test.eq(ran3.lines, ["s: String = \"a\"", "s = s + (\"b\")"])
      try add_func(compiled.unwrap!, "aug_str", third, top_ctx(third), "None", ["s"])
      ok()
    end,
    Test.test("augmented percent uses the helper") do
      src = "x: int = 7\nx %= 2\n"
      ran = try run_all(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ran.lines, ["x: Int = 7", "x = py_pymod(x, 2)"])
      try add_func(compiled.unwrap!, "aug_mod", src, top_ctx(src), "None", ["x"])
      ok()
    end,
    Test.test("augmented int division refuses") do
      src = "x: int = 1\nx /= 2\n"
      ref = try run_no(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ref.code, "PY-TYPE-MISMATCH")
      aug_ctx = func_ctx(src, "None", {"x": "Optional[Int]"})
      ref2 = try run_no(compiled.unwrap!, "x += 5\n", aug_ctx)
      try Test.eq(ref2.code, "PY-TYPE-MISMATCH")
      ok()
    end,
    Test.test("lowercase alias refuses") do
      src = "type alias = int\n"
      ref = try run_no(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ref.code, "PY-OUT-OF-SUBSET")
      ok()
    end,
    Test.test("alias inside a def refuses") do
      src = "type B = int\n"
      ref = try run_no(compiled.unwrap!, src, func_ctx(src, "int", {}))
      try Test.eq(ref.code, "PY-OUT-OF-SUBSET")
      ok()
    end,
    Test.test("expression statement discards") do
      src = "x: int = 1\nx + 1\n"
      ran = try run_all(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(ran.lines, ["x: Int = 1", "x + 1"])
      try add_func(compiled.unwrap!, "discard", src, top_ctx(src), "None", ["x"])
      call_src = "x: int = 1\nprint(x)\n"
      ran2 = try run_all(compiled.unwrap!, call_src, top_ctx(call_src))
      try Test.eq(ran2.lines, ["x: Int = 1", "puts(" + quoted(interp("x")) + ")"])
      try add_func(compiled.unwrap!, "print_stmt", call_src, top_ctx(call_src), "None", ["x"])
      ok()
    end,
    Test.test("return value emits") do
      src = "x: int = 1\nreturn x\n"
      ctx = func_ctx(src, "int", {})
      ran = try run_all(compiled.unwrap!, src, ctx)
      try Test.eq(ran.lines, ["x: Int = 1", "return x"])
      try add_func(compiled.unwrap!, "ret_val", src, func_ctx(src, "int", {}), "Int", [])
      ok()
    end,
    Test.test("bare return under None emits") do
      src = "return\n"
      ran = try run_all(compiled.unwrap!, src, func_ctx(src, "None", {}))
      try Test.eq(ran.lines, ["return"])
      try add_func(compiled.unwrap!, "ret_bare", src, func_ctx(src, "None", {}), "None", [])
      ok()
    end,
    Test.test("explicit return None folds to bare") do
      src = "return None\n"
      ran = try run_all(compiled.unwrap!, src, func_ctx(src, "None", {}))
      try Test.eq(ran.lines, ["return"])
      try add_func(compiled.unwrap!, "ret_none", src, func_ctx(src, "None", {}), "None", [])
      ok()
    end,
    Test.test("return mismatches refuse") do
      bare = "return\n"
      ref = try run_no(compiled.unwrap!, bare, func_ctx(bare, "int", {}))
      try Test.eq(ref.code, "PY-TYPE-MISMATCH")
      valued = "return 1\n"
      ref2 = try run_no(compiled.unwrap!, valued, func_ctx(valued, "None", {}))
      try Test.eq(ref2.code, "PY-TYPE-MISMATCH")
      wrong = "return \"a\"\n"
      ref3 = try run_no(compiled.unwrap!, wrong, func_ctx(wrong, "int", {}))
      try Test.eq(ref3.code, "PY-TYPE-MISMATCH")
      outside = "return 1\n"
      ref4 = try run_no(compiled.unwrap!, outside, top_ctx(outside))
      try Test.eq(ref4.code, "PY-OUT-OF-SUBSET")
      ok()
    end,
    Test.test("temps shift past the supply") do
      src = "c: bool = True\ny: int = 1 if c else 2\nw: int = 3 if c else 4\n"
      ran = try run_all(compiled.unwrap!, src, top_ctx(src))
      try Test.eq(
        ran.lines,
        [
          "c: Bool = true",
          "py_t0 = 2",
          "if c",
          "  py_t0 = 1",
          "end",
          "y: Int = py_t0",
          "py_t1 = 4",
          "if c",
          "  py_t1 = 3",
          "end",
          "w: Int = py_t1",
        ],
      )

      try Test.eq(ran.ctx.next_temp, 2)
      try add_func(compiled.unwrap!, "temps", src, top_ctx(src), "None", ["c", "y", "w"])
      ok()
    end,
    Test.test("augmented RHS groups") do
      first = "x: int = 10\nx -= 2 + 3\n"
      ran = try run_all(compiled.unwrap!, first, top_ctx(first))
      try Test.eq(ran.lines, ["x: Int = 10", "x = x - (2 + 3)"])
      try add_func(compiled.unwrap!, "aug_group", first, top_ctx(first), "None", ["x"])
      second = "x: int = 2\nx *= 3 + 4\n"
      ran2 = try run_all(compiled.unwrap!, second, top_ctx(second))
      try Test.eq(ran2.lines, ["x: Int = 2", "x = x * (3 + 4)"])
      third = "f: float = 20.0\nf /= 2.0 + 3.0\n"
      ran3 = try run_all(compiled.unwrap!, third, top_ctx(third))
      try Test.eq(ran3.lines, ["f: Float = 20.0", "f = f / (2.0 + 3.0)"])
      fourth = "x: int = 7\nx %= 2 + 3\n"
      ran4 = try run_all(compiled.unwrap!, fourth, top_ctx(fourth))
      try Test.eq(ran4.lines, ["x: Int = 7", "x = py_pymod(x, 2 + 3)"])
      mixed = "x: int = 10\nx -= 2 * 3\n"
      ran5 = try run_all(compiled.unwrap!, mixed, top_ctx(mixed))
      try Test.eq(ran5.lines, ["x: Int = 10", "x = x - (2 * 3)"])
      str_src = "s: str = \"a\"\ns += \"b\" + \"c\"\n"
      ran6 = try run_all(compiled.unwrap!, str_src, top_ctx(str_src))
      try Test.eq(ran6.lines, ["s: String = \"a\"", "s = s + (\"b\" + \"c\")"])
      try add_func(compiled.unwrap!, "aug_str_group", str_src, top_ctx(str_src), "None", ["s"])
      grouped = "x: int = 10\nx -= (2 + 3)\n"
      ran7 = try run_all(compiled.unwrap!, grouped, top_ctx(grouped))
      try Test.eq(ran7.lines, ["x: Int = 10", "x = x - ((2 + 3))"])
      ok()
    end,
    Test.test("quoted temps survive the supply") do
      first = "c: bool = True\nq: int = 1 if c else 2\n"
      ran = try run_all(compiled.unwrap!, first, top_ctx(first))
      try Test.eq(ran.lines, ["c: Bool = true", "py_t0 = 2", "if c", "  py_t0 = 1", "end", "q: Int = py_t0"])
      try Test.eq(ran.ctx.next_temp, 1)
      second = "s: str = \"py_t0\"\n"
      ran2 = try run_all(compiled.unwrap!, second, ran.ctx)
      try Test.eq(ran2.lines, ["s: String = \"py_t0\""])
      try Test.eq(ran2.ctx.next_temp, 1)
      third = "w: int = 3 if c else 4\n"
      ran3 = try run_all(compiled.unwrap!, third, ran2.ctx)
      try Test.eq(ran3.lines, ["py_t1 = 4", "if c", "  py_t1 = 3", "end", "w: Int = py_t1"])
      try Test.eq(ran3.ctx.next_temp, 2)
      quoted = "c: bool = True\nq: int = 1 if c else 2\ns: str = \"py_t0\"\n"
      try add_func(compiled.unwrap!, "quoted", quoted, top_ctx(quoted), "None", ["c", "q", "s"])
      ok()
    end,
    Test.test("interpolated temps shift") do
      src = "t: str = f\"{1 if c else 2}\"\n"
      ctx = EmitCtx.EmitCtx(
        source: src,
        file: "assign_test",
        scope: {"c": "Bool"},
        func_ret: "",
        in_try: false,
        next_temp: 1,
      )

      ran = try run_all(compiled.unwrap!, src, ctx)
      try Test.eq(ran.lines, ["py_t1 = 2", "if c", "  py_t1 = 1", "end", "t: String = \"" + interp("py_t1") + "\""])
      try Test.eq(ran.ctx.next_temp, 2)
      interp_src = "c: bool = True\nt: str = f\"{1 if c else 2}\"\n"
      try add_func(compiled.unwrap!, "interp", interp_src, top_ctx(interp_src), "None", ["c", "t"])
      ok()
    end,
    Test.test("optional target wraps known values") do
      ran = try run_all(compiled.unwrap!, "x: Optional[int] = 5\n", top_ctx(""))
      try Test.eq(ran.lines, ["x: Optional[Int] = some(5)"])
      try Test.eq(ran.ctx.scope.get("x", ""), "Optional[Int]")
      try add_lines("opt_scalar", ran.lines, ["x"], "")
      ran2 = try run_seq(
        compiled.unwrap!,
        [
          "x: Optional[int] = None\n",
          "x = 8\n",
          "xs: Optional[list[int]] = [1, 2]\n",
          "m: Optional[dict[str, int]] = {\"a\": 1}\n",
          "d: dict[str, int] = {}\n",
          "og: Optional[int] = d.get(\"k\")\n",
          # Both union spellings stay flat: `Optional[X] | None` is never
          # `Optional[Optional[X]]`.
          "u: Optional[int] | None = None\n",
          "v: int | None = None\n",
        ],
        top_ctx(""),
      )

      try Test.eq(
        ran2.lines,
        [
          "x: Optional[Int] = none", "x = some(8)", "xs: Optional[List[Int]] = some([1, 2])",
          "m: Optional[Map[String, Int]] = some({\"a\": 1})", "d: Map[String, Int] = {}",
          "og: Optional[Int] = d.get(\"k\")", "u: Optional[Int] = none", "v: Optional[Int] = none",
        ],
      )

      try add_lines("opt_wraps", ran2.lines, ["x", "xs", "m", "d", "og", "u", "v"], "")
      ok()
    end,
    Test.test("unwrapped Result bindings wrap inside try lanes") do
      src = "x: Optional[int] = int(s)\n"
      ran = try run_all(compiled.unwrap!, src, try_ctx(src, "Result[int]", {"s": "String"}))
      try Test.eq(ran.lines, ["x: Optional[Int] = some(try s.to_i)"])
      plain = "x: int = int(s)\n"
      ran2 = try run_all(compiled.unwrap!, plain, try_ctx(plain, "Result[int]", {"s": "String"}))
      try Test.eq(ran2.lines, ["x: Int = try s.to_i"])
      # `try` only checks inside a `Result` function, so those fragments
      # carry their own wrapper and fold the unwrapped value; no call in
      # `main`, a discarded `Result` would be `CHECK-UNUSED-RESULT`.
      opt_text = (
        "def py_assign_try_opt(s: String) -> Result[Optional[Int]]\n#{ran.lines.map { |line| "  #{line}" }.join("\n")}\n  ok(x)\nend\n\n"
      )

      plain_text = (
        "def py_assign_try_plain(s: String) -> Result[Int]\n#{ran2.lines.map { |line| "  #{line}" }.join("\n")}\n  ok(x)\nend\n\n"
      )

      blocks = try File.read_text("/tmp/agc_emit_assign_blocks.txt")
      try File.write_text("/tmp/agc_emit_assign_blocks.txt", "#{blocks}#{opt_text}#{plain_text}")
      ok()
    end,
    Test.test("optional return wraps outside try and refuses inside") do
      ret = "return 5\n"
      ran = try run_all(compiled.unwrap!, ret, func_ctx(ret, "Optional[int]", {}))
      try Test.eq(ran.lines, ["return some(5)"])
      try add_lines("ret_opt", ran.lines, [], "Optional[Int]")
      ran2 = try run_all(compiled.unwrap!, "return None\n", func_ctx("return None\n", "Optional[int]", {}))
      try Test.eq(ran2.lines, ["return none"])
      try add_lines("ret_opt_none", ran2.lines, [], "Optional[Int]")
      ref = try run_no(compiled.unwrap!, "return \"a\"\n", func_ctx("return \"a\"\n", "Optional[int]", {}))
      try Test.eq(ref.code, "PY-TYPE-MISMATCH")
      # Inside a try body both shapes refuse at the return span first.
      ref2 = try run_no(compiled.unwrap!, ret, try_ctx(ret, "Optional[int]", {}))
      try Test.eq(ref2.code, "PY-TRY-CONTROL")
      try Test.eq(ref_text(ret, ref2), "return 5")
      ref3 = try run_no(compiled.unwrap!, "return\n", try_ctx("return\n", "None", {}))
      try Test.eq(ref3.code, "PY-TRY-CONTROL")
      try Test.eq(ref_text("return\n", ref3), "return")
      ok()
    end,
    Test.test("grouped and quoted shapes run") do
      ran = try run_seq(
        compiled.unwrap!,
        [
          "ax: int = 10\nax -= 2 + 3\n",
          "ay: int = 2\nay *= 3 + 4\n",
          "af: float = 20.0\naf /= 2.0 + 3.0\n",
          "am: int = 7\nam %= 2 + 3\n",
          "c: bool = True\nq: int = 1 if c else 2\n",
          "s: str = \"py_t0\"\n",
          "t: str = f\"{1 if c else 2}\"\n",
        ],
        top_ctx(""),
      )

      body = ran.lines + ["puts(ax)", "puts(ay)", "puts(af)", "puts(am)", "puts(q)", "puts(s)", "puts(t)"]
      program = "#{EmitExpr.helpers()}\ndef main() -> Void\n#{body.map { |line| "  #{line}" }.join("\n")}\nend\n"

      try File.write_text("/tmp/agc_emit_assign_behavior.agc", program)
      proc = try Process.spawn_captured("agentica", ["/tmp/agc_emit_assign_behavior.agc"])
      result = try Process.output(proc, 30000)
      Test.assert(
        result.stdout == "5\n14\n4.0\n2\n1\npy_t0\n1\n",
        "run /tmp/agc_emit_assign_behavior.agc printed #{result.stdout.inspect}:\n#{result.stderr}\n#{program}",
      )
    end,
    Test.test("optional shapes run") do
      ran = try run_seq(
        compiled.unwrap!,
        [
          "x: Optional[int] = 5\n",
          "y: Optional[int] = None\n",
          "xs: Optional[list[int]] = [1, 2]\n",
          "m: Optional[dict[str, int]] = {\"a\": 1}\n",
        ],
        top_ctx(""),
      )

      body = ran.lines + ["puts(x)", "puts(y)", "puts(xs)", "puts(m)"]
      program = "#{EmitExpr.helpers()}\ndef main() -> Void\n#{body.map { |line| "  #{line}" }.join("\n")}\nend\n"

      try File.write_text("/tmp/agc_emit_assign_optional.agc", program)
      proc = try Process.spawn_captured("agentica", ["/tmp/agc_emit_assign_optional.agc"])
      result = try Process.output(proc, 30000)
      Test.assert(
        result.stdout == "some(5)\nnone\nsome([1, 2])\nsome({\"a\": 1})\n",
        "run /tmp/agc_emit_assign_optional.agc printed #{result.stdout.inspect}:\n#{result.stderr}\n#{program}",
      )
    end,
    Test.test("all fragments check clean together") do
      aliases = try File.read_text("/tmp/agc_emit_assign_aliases.txt")
      blocks = try File.read_text("/tmp/agc_emit_assign_blocks.txt")
      calls = try File.read_text("/tmp/agc_emit_assign_calls.txt")
      program = "#{aliases}\n#{EmitExpr.helpers()}\n#{blocks}\ndef main() -> Void\n#{calls}end\n"

      try File.write_text("/tmp/agc_emit_assign_all.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/agc_emit_assign_all.agc"])
      result = try Process.output(proc, 30000)
      Test.assert(
        result.stdout.include?("check ok"),
        "check /tmp/agc_emit_assign_all.agc failed:\n#{result.stdout}\n#{result.stderr}\n#{program}",
      )
    end,
  ])
end

# Starts the fragment accumulators empty: a fresh file per run, so a
# previous aborted run never leaks fragments into this one.
def reset_accumulators() -> Result[Void]
  try File.write_text("/tmp/agc_emit_assign_aliases.txt", "")
  try File.write_text("/tmp/agc_emit_assign_blocks.txt", "")
  try File.write_text("/tmp/agc_emit_assign_calls.txt", "")
  ok()
end
