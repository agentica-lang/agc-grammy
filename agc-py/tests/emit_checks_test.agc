## Phase 3c checks tests: `raise` and `assert` with real expressions.
##
## Each test parses its statements with a single `Engine.run` (one program of
## one to three lines), emits each through `EmitChecks` with a threaded
## `EmitCtx`, asserts the exact lines (or the refusal code), the outgoing
## scope and the temp supply, then appends its checkable fragments to shared
## accumulators: one `agentica check` per test blows the test-runner step
## budget, so a single final test checks every fragment together. Each
## fragment keeps its own function (named per test slug) with per-case
## declarations feeding `puts`. `Result`-returning fragments are called as
## `_ = f()` in `main` so no result is dropped.

import EmitChecks from "../src/emit_checks"
import EmitCtx from "../src/emit_ctx"
import EmitExpr from "../src/emit_expr"
import Engine from "../../src/engine"
import Frontend from "../src/frontend"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

struct AssertParts
  cond: Tree.Node
  msg: Optional[Tree.Node]
end

def checks_ctx(source: String, scope: Map[String, String], func_ret: String, next_temp: Int) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(
    source: source,
    file: "checks.py",
    scope: scope,
    func_ret: func_ret,
    in_try: false,
    next_temp: next_temp,
  )
end

# Spells `#{code}` without writing it in a literal (the compiler reads `"#{"`
# as the start of an interpolation).
def interp(code: String) -> String = "#" + "{" + code + "}"

def try_ctx(source: String, scope: Map[String, String]) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(
    source: source,
    file: "checks.py",
    scope: scope,
    func_ret: "Result[Void]",
    in_try: true,
    next_temp: 0,
  )
end

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

def raise_of(compiled: Grammar.Grammar, source: String) -> Result[Tree.Node]
  stmts = try stmts_of(compiled, source)
  case List.first(stmts)
    Frontend.Stmt.RaiseStmt(expr) -> ok(expr)
    _ -> error("expected a raise statement")
  end
end

def assert_of(compiled: Grammar.Grammar, source: String) -> Result[AssertParts]
  stmts = try stmts_of(compiled, source)
  case List.first(stmts)
    Frontend.Stmt.AssertStmt(cond, msg) -> ok(AssertParts(cond: cond, msg: msg))
    _ -> error("expected an assert statement")
  end
end

def assert_lines(actual: List[String], want: List[String]) -> Result[Void]
  try Test.eq(actual.size, want.size)
  for i in 0...actual.size
    try Test.eq(List.first(actual.drop(i)), List.first(want.drop(i)))
  end

  ok()
end

def assert_ok(res: EmitCtx.StmtRes) -> Result[EmitCtx.StmtOut]
  case res
    EmitCtx.StmtRes.Ok(done) -> ok(done)
    EmitCtx.StmtRes.No(refusal) -> error("expected ok, got #{refusal.code}: #{refusal.message}")
  end
end

def assert_no(res: EmitCtx.StmtRes, code: String) -> Result[EmitCtx.Refusal]
  case res
    EmitCtx.StmtRes.No(refusal) ->
      try Test.eq(refusal.code, code)
      ok(refusal)
    EmitCtx.StmtRes.Ok(done) -> error("expected #{code}, emitted #{done.code.join("\n")}")
  end
end

# Appends one checkable fragment: its own function (temps are
# function-local, so `py_t0` never collides) plus its call in `main`
# (`Result` answers bind to `_` so no result is dropped).
def accumulate(slug: String, index: Int, decls: List[String], lines: List[String], ret: String) -> Result[Void]
  keep = filter_decls(decls, lines)
  body = (keep + lines).map { |line| "  #{line}" }.join("\n")
  func = "def py_checks_#{slug}_case#{index}() -> #{ret}\n#{body}\nend\n"
  blocks = try File.read_text("/tmp/3c-checks-emit-checks-blocks.txt")
  try File.write_text("/tmp/3c-checks-emit-checks-blocks.txt", blocks + func + "\n")
  call = "  py_checks_#{slug}_case#{index}()"
  if ret != "Void"
    call = "  _ = py_checks_#{slug}_case#{index}()"
  end

  calls = try File.read_text("/tmp/3c-checks-emit-checks-calls.txt")
  try File.write_text("/tmp/3c-checks-emit-checks-calls.txt", calls + call + "\n")
  ok()
end

# Keeps only the declarations the fragment uses (a checked program refuses
# unused locals): a name counts when it appears as a whole identifier word
# in the emitted lines.
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
    Test.test("raise with a literal returns the error") do
      source = "raise E(\"boom\")\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {}, "Result[Int]", 0), expr)
      done = try assert_ok(res)
      try assert_lines(done.code, ["return error(\"boom\")"])
      try Test.eq(done.next_temp, 0)
      try accumulate("raise", 0, [], done.code, "Result[Int]")
      ok()
    end,
    Test.test("raise at the top level warns and exits") do
      source = "raise E(\"boom\")\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {}, "", 0), expr)
      done = try assert_ok(res)
      try assert_lines(done.code, ["IO.warn(\"boom\")", "System.exit(1)"])
      try accumulate("raisetop", 0, [], done.code, "Void")
      ok()
    end,
    Test.test("raise with a typed message keeps its type") do
      source = "raise E(msg)\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {"msg": "String"}, "Result[Int]", 0), expr)
      done = try assert_ok(res)
      try assert_lines(done.code, ["return error(msg)"])
      try accumulate("raisemsg", 0, ["msg: String = \"oops\""], done.code, "Result[Int]")
      ok()
    end,
    Test.test("raise with a non-str message is refused") do
      source = "raise E(n)\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {"n": "Int"}, "Result[Int]", 0), expr)
      ref = try assert_no(res, "PY-TYPE-MISMATCH")
      try Test.eq(ref.start, 8)
      try Test.eq(ref.stop, 9)
      try Test.assert(ref.message.include?("Int"), ref.message)
      ok()
    end,
    Test.test("raise with no message is refused") do
      source = "raise E()\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {}, "Result[Int]", 0), expr)
      ref = try assert_no(res, "PY-OUT-OF-SUBSET")
      try Test.eq(ref.start, expr.start)
      try Test.eq(ref.stop, expr.stop)
      ok()
    end,
    Test.test("raise with two messages is refused") do
      source = "raise E(\"a\", \"b\")\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {}, "Result[Int]", 0), expr)
      ref = try assert_no(res, "PY-OUT-OF-SUBSET")
      try Test.eq(ref.start, expr.start)
      try Test.eq(ref.stop, expr.stop)
      ok()
    end,
    Test.test("a bare raise name is refused") do
      source = "raise E\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {}, "Result[Int]", 0), expr)
      ref = try assert_no(res, "PY-OUT-OF-SUBSET")
      try Test.assert(ref.message.include?("needs a message"), ref.message)
      ok()
    end,
    Test.test("raise of a bare message is refused") do
      source = "raise \"boom\"\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {}, "Result[Int]", 0), expr)
      try assert_no(res, "PY-OUT-OF-SUBSET")
      ok()
    end,
    Test.test("raise with a keyword message is refused") do
      source = "raise E(msg=\"x\")\n"
      expr = try raise_of(compiled.unwrap!, source)
      res = EmitChecks.emit_raise(checks_ctx(source, {}, "Result[Int]", 0), expr)
      try assert_no(res, "PY-OUT-OF-SUBSET")
      ok()
    end,
    Test.test("raise threads temps past the supply") do
      source = "raise E(y if c else \"d\")\n"
      expr = try raise_of(compiled.unwrap!, source)
      ctx = checks_ctx(source, {"y": "String", "c": "Bool"}, "Result[Int]", 2)
      res = EmitChecks.emit_raise(ctx, expr)
      done = try assert_ok(res)
      try assert_lines(
        done.code,
        ["py_t2 = case c", "  true ->", "    y", "  _ ->", "    \"d\"", "end", "return error(py_t2)"],
      )

      try Test.eq(done.next_temp, 3)
      try accumulate("raisetemp", 0, ["y: String = \"hi\"", "c: Bool = true"], done.code, "Result[Int]")

      ok()
    end,
    Test.test("assert emits warn and exit on failure") do
      source = "assert x > 0\n"
      parts = try assert_of(compiled.unwrap!, source)
      res = EmitChecks.emit_assert(checks_ctx(source, {"x": "Int"}, "Void", 0), parts.cond, parts.msg)
      done = try assert_ok(res)
      try assert_lines(done.code, ["if !(x > 0)", "  IO.warn(\"assert failed\")", "  System.exit(1)", "end"])
      try Test.eq(done.next_temp, 0)
      try accumulate("assert", 0, ["x: Int = 1"], done.code, "Void")
      ok()
    end,
    Test.test("assert with a message warns it") do
      source = "assert x > 0, \"bad\"\n"
      parts = try assert_of(compiled.unwrap!, source)
      res = EmitChecks.emit_assert(checks_ctx(source, {"x": "Int"}, "Void", 0), parts.cond, parts.msg)
      done = try assert_ok(res)
      try assert_lines(done.code, ["if !(x > 0)", "  IO.warn(\"bad\")", "  System.exit(1)", "end"])
      try accumulate("assertmsg", 0, ["x: Int = 1"], done.code, "Void")
      ok()
    end,
    Test.test("assert on a non-bool is refused") do
      source = "assert x\n"
      parts = try assert_of(compiled.unwrap!, source)
      res = EmitChecks.emit_assert(checks_ctx(source, {"x": "Int"}, "Void", 0), parts.cond, parts.msg)
      ref = try assert_no(res, "PY-COND-NOT-BOOL")
      try Test.eq(ref.start, parts.cond.start)
      try Test.eq(ref.stop, parts.cond.stop)
      ok()
    end,
    Test.test("assert with a non-str message is refused") do
      source = "assert x > 0, n\n"
      parts = try assert_of(compiled.unwrap!, source)
      res = EmitChecks.emit_assert(checks_ctx(source, {"x": "Int", "n": "Int"}, "Void", 0), parts.cond, parts.msg)
      msg = parts.msg.unwrap!
      ref = try assert_no(res, "PY-TYPE-MISMATCH")
      try Test.eq(ref.start, msg.start)
      try Test.eq(ref.stop, msg.stop)
      ok()
    end,
    Test.test("assert message unwraps a conversion inside try") do
      source = "assert x > 0, str(int(s))\n"
      parts = try assert_of(compiled.unwrap!, source)
      ctx = try_ctx(source, {"x": "Int", "s": "String"})
      res = EmitChecks.emit_assert(ctx, parts.cond, parts.msg)
      done = try assert_ok(res)
      try assert_lines(
        done.code,
        ["if !(x > 0)", "  IO.warn(\"" + interp("(try s.to_i)") + "\")", "  System.exit(1)", "end"],
      )

      ok()
    end,
    Test.test("assert message that is a Result names its inner type") do
      source = "assert x > 0, int(s)\n"
      parts = try assert_of(compiled.unwrap!, source)
      ctx = try_ctx(source, {"x": "Int", "s": "String"})
      ref = try assert_no(EmitChecks.emit_assert(ctx, parts.cond, parts.msg), "PY-TYPE-MISMATCH")
      try Test.assert(ref.message.include?("found Int"), ref.message)
      try Test.eq(ref.start, parts.msg.unwrap!.start)
      outside = checks_ctx(source, {"x": "Int", "s": "String"}, "Void", 0)
      ref_outside = try assert_no(EmitChecks.emit_assert(outside, parts.cond, parts.msg), "PY-TYPE-MISMATCH")
      try Test.assert(ref_outside.message.include?("found Int"), ref_outside.message)
      ok()
    end,
    Test.test("assert hoists a chained guard once") do
      source = "assert a < b < c\n"
      parts = try assert_of(compiled.unwrap!, source)
      ctx = checks_ctx(source, {"a": "Int", "b": "Int", "c": "Int"}, "Void", 0)
      res = EmitChecks.emit_assert(ctx, parts.cond, parts.msg)
      done = try assert_ok(res)
      try assert_lines(
        done.code,
        ["py_t0 = b", "if !(a < py_t0 and py_t0 < c)", "  IO.warn(\"assert failed\")", "  System.exit(1)", "end"],
      )

      try Test.eq(done.next_temp, 1)
      try accumulate("assertchain", 0, ["a: Int = 1", "b: Int = 2", "c: Int = 3"], done.code, "Void")
      ok()
    end,
    Test.test("assert message preambles run only on failure") do
      source = "assert x > 0, y if c else \"d\"\n"
      parts = try assert_of(compiled.unwrap!, source)
      ctx = checks_ctx(source, {"x": "Int", "y": "String", "c": "Bool"}, "Void", 0)
      res = EmitChecks.emit_assert(ctx, parts.cond, parts.msg)
      done = try assert_ok(res)
      try assert_lines(
        done.code,
        [
          "if !(x > 0)",
          "  py_t0 = case c",
          "    true ->",
          "      y",
          "    _ ->",
          "      \"d\"",
          "  end",
          "  IO.warn(py_t0)",
          "  System.exit(1)",
          "end",
        ],
      )

      try Test.eq(done.next_temp, 1)
      try Test.assert(!done.code.include?("py_t0 = case c\nif"), "message preamble stays inside the branch")
      try accumulate("assertfail", 0, ["x: Int = 1", "y: String = \"hi\"", "c: Bool = true"], done.code, "Void")
      ok()
    end,
    Test.test("string literals never shift temps") do
      source = "assert a < b < c and x == \"py_t5\"\n"
      parts = try assert_of(compiled.unwrap!, source)
      ctx = checks_ctx(source, {"a": "Int", "b": "Int", "c": "Int", "x": "String"}, "Void", 2)
      res = EmitChecks.emit_assert(ctx, parts.cond, parts.msg)
      done = try assert_ok(res)
      try assert_lines(
        done.code,
        [
          "py_t2 = b",
          "if !(a < py_t2 and py_t2 < c and x == \"py_t5\")",
          "  IO.warn(\"assert failed\")",
          "  System.exit(1)",
          "end",
        ],
      )

      try Test.eq(done.next_temp, 3)
      try accumulate(
        "assertlit",
        0,
        ["a: Int = 1", "b: Int = 2", "c: Int = 3", "x: String = \"py_t5\""],
        done.code,
        "Void",
      )

      ok()
    end,
    Test.test("all fragments check clean together") do
      blocks = try File.read_text("/tmp/3c-checks-emit-checks-blocks.txt")
      calls = try File.read_text("/tmp/3c-checks-emit-checks-calls.txt")
      program = "#{EmitExpr.helpers()}\n#{blocks}\ndef main() -> Void\n#{calls}end\n"

      try File.write_text("/tmp/3c-checks-emit-checks-all.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/3c-checks-emit-checks-all.agc"])
      result = try Process.output(proc, 30000)
      Test.assert(
        result.stdout.include?("check ok"),
        "check /tmp/3c-checks-emit-checks-all.agc failed:\n#{result.stdout}\n#{result.stderr}\n#{program}",
      )
    end,
  ])
end

# Starts the fragment accumulators empty: a fresh file per run, so a
# previous aborted run never leaks fragments into this one.
def reset_accumulators() -> Result[Void]
  try File.write_text("/tmp/3c-checks-emit-checks-blocks.txt", "")
  try File.write_text("/tmp/3c-checks-emit-checks-calls.txt", "")
  ok()
end
