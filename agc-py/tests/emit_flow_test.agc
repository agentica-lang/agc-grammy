## Phase 3c lane B tests: every `if`/`while`/`for` shape passes
## `agentica check` in the test itself.
##
## Each test parses its statements with a single `Engine.run` (one program of
## one to three lines; attribute-heavy shapes stay on one line — the runner
## step budget dies on bigger batches), emits each through `EmitFlow` with
## canned body lines plus real condition emission, asserts the exact lines
## (or the refusal code), the outgoing scope and the temp supply, then
## appends its checkable fragments to shared accumulators: one
## `agentica check` per test blows the test-runner step budget (a full VM
## boot each, and the process dies around the thirty-third scenario), so a
## single final test checks every fragment together. Each fragment keeps its
## own function (named per test slug, so `check ok` failures point at the
## right fixture) with per-case declarations feeding `puts`. A two-arm `if`
## reuses one parsed guard twice: an `if`/`elif`/`else` needs six lines and
## the budget caps programs at three, so distinct-guard coverage comes from
## the single-arm, compound-guard, `while` and `for` tests instead.

import EmitCtx from "../src/emit_ctx"
import EmitFlow from "../src/emit_flow"
import Engine from "../../src/engine"
import Frontend from "../src/frontend"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

# One `for` header: the target binding plus the iterable node.
struct ForParts
  target: Frontend.NameOcc
  iterable: Tree.Node
end

def flow_ctx(source: String, scope: Map[String, String]) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(source: source, file: "flow.py", scope: scope, func_ret: "Void", in_try: false, next_temp: 0)
end

def try_ctx(source: String, scope: Map[String, String]) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(source: source, file: "flow.py", scope: scope, func_ret: "Void", in_try: true, next_temp: 0)
end

def span_at(start: Int, stop: Int) -> Frontend.Span = Frontend.Span(start: start, stop: stop)

# Every top-level statement of a tiny program, in order.
def stmts_of(compiled: Grammar.Grammar, source: String) -> Result[List[Frontend.Stmt]]
  tree = try Engine.run(compiled, "program", source)
  program = try Frontend.build(tree, source)
  out: List[Frontend.Stmt] = []
  for item in program.top
    case item
      Frontend.TopItem.StmtItem(stmt, _) -> out = out.push(stmt)
      Frontend.TopItem.ImportItem(_) -> out = out
    end
  end

  ok(out)
end

def first_stmt(compiled: Grammar.Grammar, source: String) -> Result[Frontend.Stmt]
  ok(List.first(try stmts_of(compiled, source)))
end

def if_arms_of(compiled: Grammar.Grammar, source: String) -> Result[List[Frontend.CondArm]]
  stmt = try first_stmt(compiled, source)
  ok(try as_if_arms(stmt))
end

def while_cond_of(compiled: Grammar.Grammar, source: String) -> Result[Tree.Node]
  stmt = try first_stmt(compiled, source)
  ok(try as_while_cond(stmt))
end

def for_parts_of(compiled: Grammar.Grammar, source: String) -> Result[ForParts]
  stmt = try first_stmt(compiled, source)
  ok(try as_for_parts(stmt))
end

def as_if_arms(stmt: Frontend.Stmt) -> Result[List[Frontend.CondArm]]
  case stmt
    Frontend.Stmt.IfStmt(arms, _) -> ok(arms)
    _ -> error("expected an if statement")
  end
end

def as_while_cond(stmt: Frontend.Stmt) -> Result[Tree.Node]
  case stmt
    Frontend.Stmt.WhileStmt(cond, _) -> ok(cond)
    _ -> error("expected a while statement")
  end
end

def as_for_parts(stmt: Frontend.Stmt) -> Result[ForParts]
  case stmt
    Frontend.Stmt.ForLoop(target, iterable, _) -> ok(ForParts(target: target, iterable: iterable))
    _ -> error("expected a for statement")
  end
end

def assert_lines(actual: List[String], want: List[String]) -> Result[Void]
  try Test.eq(actual.size, want.size)
  for i in 0...actual.size
    try Test.eq(List.first(actual.drop(i)), List.first(want.drop(i)))
  end

  ok()
end

def assert_refusal(res: EmitCtx.StmtRes, code: String) -> Result[Void]
  case res
    EmitCtx.StmtRes.No(refusal) -> Test.assert(refusal.code == code, "expected #{code}, got #{refusal.code}")
    EmitCtx.StmtRes.Ok(done) ->
      joined = done.code.join("\n")
      Test.assert(false, "expected #{code}, emitted #{joined}")
  end
end

def assert_ok(res: EmitCtx.StmtRes) -> Result[EmitCtx.StmtOut]
  case res
    EmitCtx.StmtRes.Ok(done) -> ok(done)
    EmitCtx.StmtRes.No(refusal) -> error("expected ok, got #{refusal.code}: #{refusal.message}")
  end
end

# Appends one checkable fragment: its own function (temps are
# function-local, so `py_t0` never collides) plus its call in `main`.
# TODO(parallel): `/tmp/agc_emit_flow_blocks.txt` is order-dependent and
# fragile under parallel/sharded runners; use env-overridable paths.
def accumulate(slug: String, index: Int, decls: List[String], lines: List[String]) -> Result[Void]
  keep = filter_decls(decls, lines)
  body = (keep + lines).map { |line| "  #{line}" }.join("\n")
  func = "def py_flow_#{slug}_case#{index}() -> Void\n#{body}\nend\n"
  blocks = try File.read_text("/tmp/agc_emit_flow_blocks.txt")
  try File.write_text("/tmp/agc_emit_flow_blocks.txt", blocks + func + "\n")
  calls = try File.read_text("/tmp/agc_emit_flow_calls.txt")
  try File.write_text("/tmp/agc_emit_flow_calls.txt", calls + "  py_flow_#{slug}_case#{index}()\n")
  ok()
end

# Keeps only the declarations the fragment uses (a checked program refuses
# unused locals): a name counts when it appears as a whole identifier word in
# the emitted lines.
def filter_decls(decls: List[String], lines: List[String]) -> List[String]
  words = words_in(lines.join("\n"))
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
    Test.test("loop shapes probe check clean on their own") do
      program = (
        "def py_probe_while() -> Void\n" +
        "  i: Int = 0\n" +
        "  while i < 3\n" +
        "    i = i + 1\n" +
        "    if i == 2\n" +
        "      break\n" +
        "    end\n" +
        "  end\n" +
        "  puts(i)\n" +
        "end\n" +
        "\n" +
        "def py_probe_for() -> Void\n" +
        "  total: Int = 0\n" +
        "  for x in [1, 2]\n" +
        "    total = total + x\n" +
        "  end\n" +
        "  for j in 0...2\n" +
        "    total = total + j\n" +
        "  end\n" +
        "  for ch in \"ab\".split(\"\")\n" +
        "    puts(ch)\n" +
        "  end\n" +
        "  for m in [1, 2]\n" +
        "    if m == 1\n" +
        "      break\n" +
        "    end\n" +
        "    total = total + m\n" +
        "  end\n" +
        "  for q in 0...3\n" +
        "    if q == 0\n" +
        "      next\n" +
        "    end\n" +
        "    total = total + q\n" +
        "  end\n" +
        "  k: Int = 0\n" +
        "  while k < 5\n" +
        "    k = k + 1\n" +
        "    if k == 2\n" +
        "      next\n" +
        "    end\n" +
        "    puts(k)\n" +
        "  end\n" +
        "  puts(total)\n" +
        "end\n" +
        "\n" +
        "def main() -> Void\n" +
        "  py_probe_while()\n" +
        "  py_probe_for()\n" +
        "end\n"
      )

      try File.write_text("/tmp/agc_emit_flow_shapes.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/agc_emit_flow_shapes.agc"])
      result = try Process.output(proc, 30000)
      try Test.assert(result.stdout.include?("check ok"), result.stdout + result.stderr)
      Test.assert(program.include?("next"), "probe covers next")
    end,
    Test.test("if without else emits a single branch") do
      source = "if x > 0:\n  pass\n"
      arms = try if_arms_of(compiled.unwrap!, source)
      arm = List.first(arms)
      res = EmitFlow.emit_if(
        flow_ctx(source, {"x": "Int"}),
        [EmitFlow.IfArm(cond: arm.cond, then_code: ["puts(\"pos\")"])],
        [],
      )

      done = try assert_ok(res)
      try assert_lines(done.code, ["if x > 0", "  puts(\"pos\")", "end"])
      try Test.eq(done.next_temp, 0)
      try accumulate("if", 0, ["x: Int = 1"], done.code)
      ok()
    end,
    Test.test("if with else emits both branches") do
      source = "if x > 0:\n  pass\n"
      arms = try if_arms_of(compiled.unwrap!, source)
      arm = List.first(arms)
      res = EmitFlow.emit_if(
        flow_ctx(source, {"x": "Int"}),
        [EmitFlow.IfArm(cond: arm.cond, then_code: ["puts(\"pos\")"])],
        ["puts(\"neg\")"],
      )

      done = try assert_ok(res)
      try assert_lines(done.code, ["if x > 0", "  puts(\"pos\")", "else", "  puts(\"neg\")", "end"])
      try accumulate("ifelse", 0, ["x: Int = 1"], done.code)
      ok()
    end,
    Test.test("two arms nest the second if in the else") do
      source = "if x > 0:\n  pass\n"
      arms = try if_arms_of(compiled.unwrap!, source)
      arm = List.first(arms)
      res = EmitFlow.emit_if(
        flow_ctx(source, {"x": "Int"}),
        [
          EmitFlow.IfArm(cond: arm.cond, then_code: ["puts(\"a\")"]),
          EmitFlow.IfArm(cond: arm.cond, then_code: ["puts(\"b\")"]),
        ],
        ["puts(\"other\")"],
      )

      done = try assert_ok(res)
      try assert_lines(
        done.code,
        [
          "if x > 0",
          "  puts(\"a\")",
          "else",
          "  if x > 0",
          "    puts(\"b\")",
          "  else",
          "    puts(\"other\")",
          "  end",
          "end",
        ],
      )

      try accumulate("elif", 0, ["x: Int = 1"], done.code)
      ok()
    end,
    Test.test("compound guards join with and") do
      source = "if x > 0 and y < 2:\n  pass\n"
      arms = try if_arms_of(compiled.unwrap!, source)
      arm = List.first(arms)
      res = EmitFlow.emit_if(
        flow_ctx(source, {"x": "Int", "y": "Int"}),
        [EmitFlow.IfArm(cond: arm.cond, then_code: ["puts(\"both\")"])],
        [],
      )

      done = try assert_ok(res)
      try assert_lines(done.code, ["if x > 0 and y < 2", "  puts(\"both\")", "end"])
      try accumulate("compound", 0, ["x: Int = 1", "y: Int = 1"], done.code)
      ok()
    end,
    Test.test("non-bool if guards are refused") do
      source = "if x:\n  pass\n"
      arms = try if_arms_of(compiled.unwrap!, source)
      arm = List.first(arms)
      res = EmitFlow.emit_if(
        flow_ctx(source, {"x": "Int"}),
        [EmitFlow.IfArm(cond: arm.cond, then_code: ["puts(x)"])],
        [],
      )

      try assert_refusal(res, "PY-COND-NOT-BOOL")
      case res
        EmitCtx.StmtRes.No(refusal) ->
          try Test.eq(refusal.start, 3)
          try Test.eq(refusal.stop, 4)
          try Test.assert(refusal.message.include?("Int"), refusal.message)
        EmitCtx.StmtRes.Ok(_) -> try Test.assert(false, "expected a refusal")
      end

      ok()
    end,
    Test.test("while emits its guard and body") do
      source = "while n > 0:\n  pass\n"
      cond = try while_cond_of(compiled.unwrap!, source)
      res = EmitFlow.emit_while(flow_ctx(source, {"n": "Int"}), cond, ["n = n - 1"])
      done = try assert_ok(res)
      try assert_lines(done.code, ["while true", "  if !(n > 0)", "    break", "  end", "  n = n - 1", "end"])
      try Test.eq(done.next_temp, 0)
      try accumulate("while", 0, ["n: Int = 2"], done.code)
      ok()
    end,
    Test.test("empty while bodies emit nil") do
      source = "while n > 0:\n  pass\n"
      cond = try while_cond_of(compiled.unwrap!, source)
      res = EmitFlow.emit_while(flow_ctx(source, {"n": "Int"}), cond, [])
      done = try assert_ok(res)
      try assert_lines(done.code, ["while true", "  if !(n > 0)", "    break", "  end", "  nil", "end"])
      try accumulate("whilenil", 0, ["n: Int = 2"], done.code)
      ok()
    end,
    Test.test("non-bool while guards are refused") do
      source = "while s:\n  pass\n"
      cond = try while_cond_of(compiled.unwrap!, source)
      res = EmitFlow.emit_while(flow_ctx(source, {"s": "String"}), cond, ["puts(s)"])
      try assert_refusal(res, "PY-COND-NOT-BOOL")
      ok()
    end,
    Test.test("while re-evaluates chained guards each iteration") do
      source = "while a < b < c:\n  pass\n"
      cond = try while_cond_of(compiled.unwrap!, source)
      res = EmitFlow.emit_while(flow_ctx(source, {"a": "Int", "b": "Int", "c": "Int"}), cond, ["b = b + 1"])
      done = try assert_ok(res)
      try assert_lines(
        done.code,
        ["while true", "  py_t0 = b", "  if !(a < py_t0 and py_t0 < c)", "    break", "  end", "  b = b + 1", "end"],
      )

      try Test.eq(done.next_temp, 1)
      try accumulate("whilechain", 0, ["a: Int = 1", "b: Int = 2", "c: Int = 3"], done.code)
      ok()
    end,
    Test.test("for over a list binds the element type") do
      source = "for x in xs:\n  pass\n"
      parts = try for_parts_of(compiled.unwrap!, source)
      res = EmitFlow.emit_for(flow_ctx(source, {"xs": "List[Int]"}), parts.target, parts.iterable, ["puts(x)"])
      done = try assert_ok(res)
      try assert_lines(done.code, ["for x in xs", "  puts(x)", "end"])
      try Test.eq(done.scope.get("x", ""), "Int")
      try Test.eq(done.scope.get("xs", ""), "List[Int]")
      try accumulate("forlist", 0, ["xs: List[Int] = [1, 2]"], done.code)
      ok()
    end,
    Test.test("for over range binds Int") do
      source = "for i in range(3):\n  pass\n"
      parts = try for_parts_of(compiled.unwrap!, source)
      res = EmitFlow.emit_for(flow_ctx(source, {}), parts.target, parts.iterable, ["puts(i)"])
      done = try assert_ok(res)
      try assert_lines(done.code, ["for i in 0...3", "  puts(i)", "end"])
      try Test.eq(done.scope.get("i", ""), "Int")
      try accumulate("forrange", 0, [], done.code)
      ok()
    end,
    Test.test("for over a string splits into scalars") do
      source = "for ch in s:\n  pass\n"
      parts = try for_parts_of(compiled.unwrap!, source)
      res = EmitFlow.emit_for(flow_ctx(source, {"s": "String"}), parts.target, parts.iterable, ["puts(ch)"])
      done = try assert_ok(res)
      try assert_lines(done.code, ["for ch in (s).split(\"\")", "  puts(ch)", "end"])
      try Test.eq(done.scope.get("ch", ""), "String")
      try accumulate("forstr", 0, ["s: String = \"ab\""], done.code)
      ok()
    end,
    Test.test("for over an int is refused") do
      source = "for i in n:\n  pass\n"
      parts = try for_parts_of(compiled.unwrap!, source)
      res = EmitFlow.emit_for(flow_ctx(source, {"n": "Int"}), parts.target, parts.iterable, ["puts(i)"])
      try assert_refusal(res, "PY-OPERATOR")
      ok()
    end,
    # `break` and `next` assert as spellings only: bare loop control never
    # checks, so only `nil` accumulates (the shapes probe checks them in loops).
    Test.test("pass break and next emit their spellings") do
      ctx = flow_ctx("pass\n", {})
      pass_res = try assert_ok(EmitFlow.pass_stmt(ctx, span_at(0, 4)))
      try assert_lines(pass_res.code, ["nil"])
      try Test.eq(pass_res.next_temp, 0)
      break_res = try assert_ok(EmitFlow.emit_break(ctx, span_at(0, 5)))
      try assert_lines(break_res.code, ["break"])
      next_res = try assert_ok(EmitFlow.emit_next(ctx, span_at(0, 4)))
      try assert_lines(next_res.code, ["next"])
      try accumulate("control", 0, [], ["nil"])
      ok()
    end,
    Test.test("break and next inside try are refused") do
      ctx = try_ctx("break\n", {})
      try assert_refusal(EmitFlow.emit_break(ctx, span_at(0, 5)), "PY-TRY-CONTROL")
      try assert_refusal(EmitFlow.emit_next(ctx, span_at(0, 4)), "PY-TRY-CONTROL")
      ok()
    end,
    Test.test("chained guards hoist one temp") do
      source = "if a < b < c:\n  pass\n"
      arms = try if_arms_of(compiled.unwrap!, source)
      arm = List.first(arms)
      res = EmitFlow.emit_if(
        flow_ctx(source, {"a": "Int", "b": "Int", "c": "Int"}),
        [EmitFlow.IfArm(cond: arm.cond, then_code: ["puts(\"chain\")"])],
        [],
      )

      done = try assert_ok(res)
      try assert_lines(done.code, ["py_t0 = b", "if a < py_t0 and py_t0 < c", "  puts(\"chain\")", "end"])
      try Test.eq(done.next_temp, 1)
      try accumulate("chained", 0, ["a: Int = 1", "b: Int = 2", "c: Int = 3"], done.code)
      ok()
    end,
    Test.test("string literals never shift temps") do
      source = "if a < b < c and x == \"py_t5\":\n  pass\n"
      arms = try if_arms_of(compiled.unwrap!, source)
      arm = List.first(arms)
      ctx = flow_ctx(source, {"a": "Int", "b": "Int", "c": "Int", "x": "String"}).with(next_temp: 2)
      res = EmitFlow.emit_if(ctx, [EmitFlow.IfArm(cond: arm.cond, then_code: ["puts(\"lit\")"])], [])
      done = try assert_ok(res)
      try assert_lines(
        done.code,
        ["py_t2 = b", "if a < py_t2 and py_t2 < c and x == \"py_t5\"", "  puts(\"lit\")", "end"],
      )

      try Test.eq(done.next_temp, 3)
      try accumulate("littemp", 0, ["a: Int = 1", "b: Int = 2", "c: Int = 3", "x: String = \"py_t5\""], done.code)
      ok()
    end,
    Test.test("nested bodies compose through canned lines") do
      while_source = "while y < 2:\n  pass\n"
      while_cond = try while_cond_of(compiled.unwrap!, while_source)
      while_ctx = flow_ctx(while_source, {"y": "Int"})
      inner = try assert_ok(EmitFlow.emit_while(while_ctx, while_cond, ["puts(y)"]))
      if_source = "if x > 0:\n  pass\n"
      if_arms = try if_arms_of(compiled.unwrap!, if_source)
      if_arm = List.first(if_arms)
      outer_ctx = flow_ctx(if_source, {"x": "Int"}).with(next_temp: inner.next_temp)
      outer = try assert_ok(
        EmitFlow.emit_if(outer_ctx, [EmitFlow.IfArm(cond: if_arm.cond, then_code: inner.code)], []),
      )

      try assert_lines(
        outer.code,
        ["if x > 0", "  while true", "    if !(y < 2)", "      break", "    end", "    puts(y)", "  end", "end"],
      )

      try accumulate("nested", 0, ["x: Int = 1", "y: Int = 1"], outer.code)
      ok()
    end,
    Test.test("all fragments check clean together") do
      blocks = try File.read_text("/tmp/agc_emit_flow_blocks.txt")
      calls = try File.read_text("/tmp/agc_emit_flow_calls.txt")
      program = "#{blocks}\ndef main() -> Void\n#{calls}end\n"

      try File.write_text("/tmp/agc_emit_flow_all.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/agc_emit_flow_all.agc"])
      result = try Process.output(proc, 30000)
      Test.assert(
        result.stdout.include?("check ok"),
        "check /tmp/agc_emit_flow_all.agc failed:\n#{result.stdout}\n#{result.stderr}\n#{program}",
      )
    end,
  ])
end

# Starts the fragment accumulators empty (see accumulate): a fresh file per
# run, so a previous aborted run never leaks fragments into this one.
def reset_accumulators() -> Result[Void]
  try File.write_text("/tmp/agc_emit_flow_blocks.txt", "")
  try File.write_text("/tmp/agc_emit_flow_calls.txt", "")
  ok()
end
