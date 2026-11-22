## Lane C tests (exceptions and seams): every emitted fragment passes
## `agentica check` in the test itself.
##
## Each test calls the lane emitters directly with canned statement lists and
## pre-emitted body strings (the coordinator wires recursion later, so no
## parsing runs here), asserts the exact template lines plus scope and temp
## threading, then splits each answer at its helper `def` (leading lines
## through the first `end` hoist to the top level, like the `tops` of the 3b
## tests) into per-file accumulators: one `agentica check` per test blows the
## test-runner step budget, so a single final test checks every fragment
## together. Each fragment keeps its own function (named per test slug, so
## `check ok` failures point at the right fixture); `Result`-returning
## fragments are called as `_ = f()` in `main` so no result is dropped.

import EmitTry from "../src/emit_try"
import EmitCtx from "../src/emit_ctx"
import Frontend from "../src/frontend"
import {Stmt} from "../src/frontend"
import Tree from "../../src/tree"

# One parsed-tree stand-in: the rule, span and children the lane inspects.
def tnode(rule: String, start: Int, stop: Int, kids: List[Tree.Node]) -> Tree.Node
  Tree.Node(rule: rule, start: start, stop: stop, children: kids, tag: none)
end

# An `except ... as` binding (the frontend already dropped the class).
def as_occ(name: String, start: Int, stop: Int) -> Frontend.NameOcc
  Frontend.NameOcc(name: name, span: Frontend.Span(start: start, stop: stop), kind: "reuse")
end

def ctx_for(source: String, func_ret: String, next_temp: Int) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(
    source: source,
    file: "sample.py",
    scope: {},
    func_ret: func_ret,
    in_try: false,
    next_temp: next_temp,
  )
end

def pass_body() -> List[Stmt] = [Stmt.Other(Frontend.Span(start: 0, stop: 4))]

# Splits an answer into hoisted helper lines and inline dispatch lines at
# the first top-level `end`, but only when the answer opens with a helper
# `def` (answers without one keep everything inline).
def split_def(lines: List[String]) -> List[List[String]]
  return [[], lines] if lines.empty? or !List.first(lines).start_with?("def ")

  index = 0
  for line in lines
    if line == "end"
      rest = lines.drop(index + 1)
      if !rest.empty? and List.first(rest) == ""
        rest = rest.drop(1)
      end

      return [lines.take(index + 1), rest]
    end

    index += 1
  end

  [[], lines]
end

# Appends one checked fragment: helper lines hoist to the top level, the
# dispatch lines run inside their own function, and the call joins `main`
# (`Result` answers bind to `_` so no result is dropped).
def accumulate(slug: String, idx: Int, done: EmitCtx.StmtOut, ret: String, decls: List[String]) -> Result[Void]
  parts = split_def(done.code)
  tops = List.first(parts)
  rest = List.first(parts.drop(1))
  body = (decls + rest).map { |line| "  #{line}" }.join("\n")
  func = "def py_try_#{slug}#{idx}() -> #{ret}\n#{body}\nend\n"
  chunk = func
  if !tops.empty?
    chunk = tops.join("\n") + "\n\n" + func
  end

  blocks = try File.read_text("/tmp/agc_emit_try_blocks.txt")
  try File.write_text("/tmp/agc_emit_try_blocks.txt", blocks + chunk + "\n")
  call = "  py_try_#{slug}#{idx}()"
  if ret != "Void"
    call = "  _ = py_try_#{slug}#{idx}()"
  end

  calls = try File.read_text("/tmp/agc_emit_try_calls.txt")
  try File.write_text("/tmp/agc_emit_try_calls.txt", calls + call + "\n")
  ok()
end

# Accumulates an `Ok` answer or fails the test on a refusal.
def acc_ok(slug: String, idx: Int, res: EmitCtx.StmtRes, ret: String, decls: List[String]) -> Result[EmitCtx.StmtOut]
  case res
    EmitCtx.StmtRes.Ok(done) ->
      try accumulate(slug, idx, done, ret, decls)
      ok(done)

    EmitCtx.StmtRes.No(ref) -> error("expected ok, got refusal #{ref.code}: #{ref.message}")
  end
end

# Asserts a refusal carries its code and span and renders like a diagnostic.
def assert_no(res: EmitCtx.StmtRes, source: String, code: String, start: Int, stop: Int) -> Result[Void]
  case res
    EmitCtx.StmtRes.No(ref) ->
      try Test.eq(ref.code, code)
      try Test.eq(ref.start, start)
      try Test.eq(ref.stop, stop)
      rendered = EmitCtx.render_refusal("sample.py", source, ref)
      try Test.assert(rendered.include?("error[#{code}]"), rendered)
      try Test.assert(rendered.include?("= help:"), rendered)
      ok()

    EmitCtx.StmtRes.Ok(_) -> error("expected refusal #{code}")
  end
end

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  args = System.args()
  if args != ["--agentica-test", "list"] and args != ["--agentica-test", "run"]
    IO.warn("expected Agentica test worker args [--agentica-test, list|run], got #{args.inspect}")
    System.exit(1)
  end

  if args == ["--agentica-test", "run"]
    case reset_accumulators()
      error(e) -> IO.warn("cannot reset fragment accumulators: #{e.message}")
      ok(_) -> IO.puts("fragment accumulators reset")
    end
  end

  Test.run([
    Test.test("try with as-e binds the message string") do
      caught = as_occ("e", 10, 11)
      res = EmitTry.emit_try(
        ctx_for("pass", "Int", 0),
        pass_body(),
        ["v: Result[Int] = \"s\".to_i", "n: Int = try v", "puts(n)"],
        ["puts(e)"],
        some(caught),
      )

      done = try acc_ok("basic", 0, res, "Void", [])
      try Test.eq(
        done.code,
        [
          "def py_try_body0() -> Result[Void]",
          "  v: Result[Int] = \"s\".to_i",
          "  n: Int = try v",
          "  puts(n)",
          "  ok()",
          "end",
          "",
          "e: String = \"\"",
          "case py_try_body0()",
          "  ok(_) -> nil",
          "  error(py_try_err0) ->",
          "    e = py_try_err0.message",
          "    puts(e)",
          "end",
        ],
      )

      try Test.eq(done.next_temp, 1)
      Test.eq(Map.get(done.scope, "e", ""), "String")
    end,
    Test.test("bare except maps errors to the blank arm") do
      res = EmitTry.emit_try(ctx_for("pass", "Int", 10), pass_body(), ["puts(1)"], ["puts(\"failed\")"], none)
      done = try acc_ok("bare", 0, res, "Void", [])
      try Test.eq(
        done.code,
        [
          "def py_try_body10() -> Result[Void]",
          "  puts(1)",
          "  ok()",
          "end",
          "",
          "case py_try_body10()",
          "  ok(_) -> nil",
          "  error(_) ->",
          "    puts(\"failed\")",
          "end",
        ],
      )

      try Test.eq(done.next_temp, 11)
      Test.eq(Map.get(done.scope, "e", ""), "")
    end,
    Test.test("an unused as-e still binds without an unused error") do
      res = EmitTry.emit_try(
        ctx_for("pass", "Int", 20),
        pass_body(),
        ["puts(1)"],
        ["puts(\"handled\")"],
        some(as_occ("e", 10, 11)),
      )

      done = try acc_ok("unused", 0, res, "Void", [])
      try Test.assert(done.code.include?("e: String = \"\""), done.code.join("\n"))
      try Test.assert(done.code.include?("    e = py_try_err20.message"), done.code.join("\n"))
      try Test.assert(done.code.include?("    _ = e"), done.code.join("\n"))
      Test.eq(Map.get(done.scope, "e", ""), "String")
    end,
    Test.test("a string naming e still marks it read") do
      res = EmitTry.emit_try(
        ctx_for("pass", "Int", 60),
        pass_body(),
        ["puts(1)"],
        ["puts(\"e\")"],
        some(as_occ("e", 10, 11)),
      )

      done = try acc_ok("litread", 0, res, "Void", [])
      try Test.assert(done.code.include?("    e = py_try_err60.message"), done.code.join("\n"))
      try Test.assert(done.code.include?("    _ = e"), done.code.join("\n"))
      Test.eq(Map.get(done.scope, "e", ""), "String")
    end,
    Test.test("a trailing return omits the unreachable ok") do
      res = EmitTry.emit_try(
        ctx_for("pass", "Int", 70),
        pass_body(),
        ["return error(\"boom\")"],
        ["puts(\"caught\")"],
        none,
      )

      done = try acc_ok("tailret", 0, res, "Void", [])
      try Test.eq(
        done.code,
        [
          "def py_try_body70() -> Result[Void]",
          "  return error(\"boom\")",
          "end",
          "",
          "case py_try_body70()",
          "  ok(_) -> nil",
          "  error(_) ->",
          "    puts(\"caught\")",
          "end",
        ],
      )

      Test.eq(done.next_temp, 71)
    end,
    Test.test("an already-bound e reuses without redeclaring") do
      base = ctx_for("pass", "Int", 80)
      ctx = EmitCtx.EmitCtx(
        source: base.source,
        file: base.file,
        scope: {"e": "String"},
        func_ret: base.func_ret,
        in_try: base.in_try,
        next_temp: base.next_temp,
      )

      res = EmitTry.emit_try(ctx, pass_body(), ["puts(1)"], ["puts(e)"], some(as_occ("e", 10, 11)))
      done = try acc_ok("reuse", 0, res, "Void", ["e: String = \"old\""])
      try Test.assert(!done.code.include?("e: String = \"\""), done.code.join("\n"))
      try Test.assert(done.code.include?("    e = py_try_err80.message"), done.code.join("\n"))
      Test.eq(Map.get(done.scope, "e", ""), "String")
    end,
    Test.test("an already-bound non-string e is refused") do
      base = ctx_for("pass", "Int", 81)
      ctx = EmitCtx.EmitCtx(
        source: base.source,
        file: base.file,
        scope: {"e": "Int"},
        func_ret: base.func_ret,
        in_try: base.in_try,
        next_temp: base.next_temp,
      )

      res = EmitTry.emit_try(ctx, pass_body(), ["puts(1)"], ["puts(e)"], some(as_occ("e", 10, 11)))
      try assert_no(res, "pass", "PY-TYPE-MISMATCH", 10, 11)
      ok()
    end,
    Test.test("empty bodies outline to nil and ok") do
      res = EmitTry.emit_try(ctx_for("pass", "", 30), pass_body(), [], [], none)
      done = try acc_ok("empty", 0, res, "Void", [])
      try Test.eq(
        done.code,
        [
          "def py_try_body30() -> Result[Void]",
          "  nil",
          "  ok()",
          "end",
          "",
          "case py_try_body30()",
          "  ok(_) -> nil",
          "  error(_) ->",
          "    nil",
          "end",
        ],
      )

      Test.eq(done.next_temp, 31)
    end,
    Test.test("return with a value in a try body is refused") do
      source = "  return x"
      body = [Stmt.ReturnStmt(some(tnode("cond_expr", 9, 10, [])), Frontend.Span(start: 2, stop: 10))]
      res = EmitTry.emit_try(ctx_for(source, "Int", 0), body, ["puts(1)"], ["puts(2)"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 9, 10)
      ok()
    end,
    Test.test("a bare return reports at the body start") do
      source = "pass"
      body = [Stmt.Other(Frontend.Span(start: 0, stop: 4)), Stmt.ReturnStmt(none, Frontend.Span(start: 0, stop: 4))]
      res = EmitTry.emit_try(ctx_for(source, "Void", 0), body, ["nil"], ["nil"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 0, 4)
      ok()
    end,
    Test.test("break inside a nested while is refused") do
      source = "while c:\n  break"
      inner = [Stmt.Other(Frontend.Span(start: 11, stop: 16))]
      body = [Stmt.WhileStmt(tnode("cond_expr", 6, 7, []), inner)]
      res = EmitTry.emit_try(ctx_for(source, "Int", 0), body, ["nil"], ["nil"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 11, 16)
      ok()
    end,
    Test.test("next inside a for is refused") do
      source = "for i in xs:\n  next"
      target = Frontend.NameOcc(name: "i", span: Frontend.Span(start: 4, stop: 5), kind: "reuse")
      inner = [Stmt.Other(Frontend.Span(start: 15, stop: 19))]
      body = [Stmt.ForLoop(target, tnode("cond_expr", 9, 11, []), inner)]
      res = EmitTry.emit_try(ctx_for(source, "Int", 0), body, ["nil"], ["nil"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 15, 19)
      ok()
    end,
    Test.test("return inside a nested if is refused") do
      source = "if c:\n  return x"
      arm = Frontend.CondArm(
        cond: tnode("cond_expr", 3, 4, []),
        body: [Stmt.ReturnStmt(some(tnode("cond_expr", 15, 16, [])), Frontend.Span(start: 8, stop: 16))],
      )

      body = [Stmt.IfStmt([arm], [])]
      res = EmitTry.emit_try(ctx_for(source, "Int", 0), body, ["nil"], ["nil"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 15, 16)
      ok()
    end,
    Test.test("return inside a nested handler is refused") do
      source = "pass                x"
      inner_try = [Stmt.Other(Frontend.Span(start: 0, stop: 4))]
      handler = [Stmt.ReturnStmt(some(tnode("cond_expr", 20, 21, [])), Frontend.Span(start: 14, stop: 21))]
      body = [Stmt.TryStmt(inner_try, handler, none)]
      res = EmitTry.emit_try(ctx_for(source, "Int", 40), body, ["nil"], ["puts(\"caught\")", "return"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 20, 21)
      ok()
    end,
    Test.test("return inside a nested try body is refused") do
      source = "pass  x"
      inner_try = [Stmt.ReturnStmt(some(tnode("cond_expr", 6, 7, [])), Frontend.Span(start: 0, stop: 7))]
      handler = [Stmt.Other(Frontend.Span(start: 0, stop: 4))]
      body = [Stmt.TryStmt(inner_try, handler, none)]
      res = EmitTry.emit_try(ctx_for(source, "Int", 0), body, ["nil"], ["nil"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 6, 7)
      ok()
    end,
    Test.test("break inside a nested try body is refused") do
      source = "pass\nbreak"
      inner_try = [Stmt.Other(Frontend.Span(start: 5, stop: 10))]
      handler = [Stmt.Other(Frontend.Span(start: 0, stop: 4))]
      body = [Stmt.TryStmt(inner_try, handler, none)]
      res = EmitTry.emit_try(ctx_for(source, "Int", 0), body, ["nil"], ["nil"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 5, 10)
      ok()
    end,
    Test.test("a bare return nested in an if reports at the body start") do
      source = "pass"
      arm = Frontend.CondArm(
        cond: tnode("cond_expr", 5, 6, []),
        body: [Stmt.ReturnStmt(none, Frontend.Span(start: 0, stop: 4))],
      )

      body = [Stmt.Other(Frontend.Span(start: 0, stop: 4)), Stmt.IfStmt([arm], [])]
      res = EmitTry.emit_try(ctx_for(source, "Void", 0), body, ["nil"], ["nil"], none)
      try assert_no(res, source, "PY-TRY-CONTROL", 0, 4)
      ok()
    end,
    Test.test("raise inside a try body stays legal") do
      source = "pass"
      expr = tnode("call", 0, 8, [tnode("name", 0, 1, []), tnode("text", 1, 8, [])])
      body = [Stmt.RaiseStmt(expr)]
      res = EmitTry.emit_try(ctx_for(source, "Int", 50), body, ["puts(1)"], ["puts(\"caught\")"], none)
      done = try acc_ok("raisetry", 0, res, "Void", [])
      try Test.assert(done.code.include?("case py_try_body50()"), done.code.join("\n"))
      ok()
    end,
    Test.test("assert inside a try body stays legal") do
      source = "pass"
      body = [Stmt.AssertStmt(tnode("comparison", 0, 5, []), none)]
      res = EmitTry.emit_try(ctx_for(source, "Int", 51), body, ["puts(1)"], ["puts(\"caught\")"], none)
      done = try acc_ok("asserttry", 0, res, "Void", [])
      try Test.assert(done.code.include?("case py_try_body51()"), done.code.join("\n"))
      ok()
    end,
    Test.test("raise with a message returns the error") do
      source = "E(\"boom\")"
      expr = tnode("call", 0, 8, [tnode("name", 0, 1, []), tnode("text", 1, 8, [])])
      res = EmitTry.emit_raise(ctx_for(source, "Int", 0), expr, "\"boom\"", "String")
      done = try acc_ok("raise", 0, res, "Result[Int]", [])
      try Test.eq(done.code, ["return error(\"boom\")"])
      try Test.eq(done.next_temp, 0)
      Test.eq(Map.get(done.scope, "e", ""), "")
    end,
    Test.test("raise at the top level warns and exits") do
      source = "E(\"boom\")"
      expr = tnode("call", 0, 8, [tnode("name", 0, 1, []), tnode("text", 1, 8, [])])
      res = EmitTry.emit_raise(ctx_for(source, "", 0), expr, "\"boom\"", "String")
      done = try acc_ok("raisetop", 0, res, "Void", [])
      Test.eq(done.code, ["IO.warn(\"boom\")", "System.exit(1)"])
    end,
    Test.test("a bare raise name is refused") do
      source = "E"
      res = EmitTry.emit_raise(ctx_for(source, "Int", 0), tnode("name", 0, 1, []), "\"E\"", "String")
      try assert_no(res, source, "PY-OUT-OF-SUBSET", 0, 1)
      ok()
    end,
    Test.test("raise with no message call is refused") do
      source = "E()"
      expr = tnode("call", 0, 3, [tnode("name", 0, 1, [])])
      res = EmitTry.emit_raise(ctx_for(source, "Int", 0), expr, "\"\"", "String")
      try assert_no(res, source, "PY-OUT-OF-SUBSET", 0, 3)
      ok()
    end,
    Test.test("raise with two messages is refused") do
      source = "E(\"a\", \"b\")"
      expr = tnode("call", 0, 10, [tnode("name", 0, 1, []), tnode("text", 1, 4, []), tnode("text", 6, 9, [])])

      res = EmitTry.emit_raise(ctx_for(source, "Int", 0), expr, "\"a\"", "String")
      try assert_no(res, source, "PY-OUT-OF-SUBSET", 0, 10)
      ok()
    end,
    Test.test("raise with a non-str message is refused") do
      source = "E(x)"
      expr = tnode("call", 0, 4, [tnode("name", 0, 1, []), tnode("name", 2, 3, [])])
      res = EmitTry.emit_raise(ctx_for(source, "Int", 0), expr, "x", "Int")
      try assert_no(res, source, "PY-TYPE-MISMATCH", 2, 3)
      ok()
    end,
    Test.test("raise with a keyword message is refused") do
      source = "E(msg=\"x\")"
      kw = tnode("kwarg", 2, 9, [])
      expr = tnode("call", 0, 10, [tnode("name", 0, 1, []), kw])
      res = EmitTry.emit_raise(ctx_for(source, "Int", 0), expr, "\"x\"", "String")
      try assert_no(res, source, "PY-OUT-OF-SUBSET", 0, 10)
      ok()
    end,
    Test.test("raise of a bare message is refused") do
      source = "\"boom\""
      res = EmitTry.emit_raise(ctx_for(source, "Int", 0), tnode("text", 0, 6, []), "\"boom\"", "String")
      try assert_no(res, source, "PY-OUT-OF-SUBSET", 0, 6)
      ok()
    end,
    Test.test("assert emits warn and exit on failure") do
      source = "x > 0"
      res = EmitTry.emit_assert(
        ctx_for(source, "Int", 0),
        tnode("comparison", 0, 5, []),
        none,
        "x > 0",
        "Bool",
        none,
        none,
      )

      done = try acc_ok("assert", 0, res, "Void", ["x: Int = 3"])
      try Test.eq(done.code, ["if !(x > 0)", "  IO.warn(\"assert failed\")", "  System.exit(1)", "end"])

      Test.eq(done.next_temp, 0)
    end,
    Test.test("assert with a message warns it") do
      source = "x > 0, \"bad\""
      res = EmitTry.emit_assert(
        ctx_for(source, "Int", 0),
        tnode("comparison", 0, 5, []),
        some(tnode("text", 7, 12, [])),
        "x > 0",
        "Bool",
        some("\"bad\""),
        some("String"),
      )

      done = try acc_ok("assertmsg", 0, res, "Void", ["x: Int = 3"])
      Test.eq(done.code, ["if !(x > 0)", "  IO.warn(\"bad\")", "  System.exit(1)", "end"])
    end,
    Test.test("assert on a non-bool is refused") do
      source = "x + 1"
      res = EmitTry.emit_assert(ctx_for(source, "Int", 0), tnode("sum", 0, 5, []), none, "x + 1", "Int", none, none)
      try assert_no(res, source, "PY-COND-NOT-BOOL", 0, 5)
      ok()
    end,
    Test.test("assert with a non-str message is refused") do
      source = "x > 0, n"
      res = EmitTry.emit_assert(
        ctx_for(source, "Int", 0),
        tnode("comparison", 0, 5, []),
        some(tnode("name", 7, 8, [])),
        "x > 0",
        "Bool",
        some("n"),
        some("Int"),
      )

      try assert_no(res, source, "PY-TYPE-MISMATCH", 7, 8)
      ok()
    end,
    Test.test("all lane C fragments check clean together") do
      blocks = try File.read_text("/tmp/agc_emit_try_blocks.txt")
      calls = try File.read_text("/tmp/agc_emit_try_calls.txt")
      program = "#{blocks}\ndef main() -> Void\n#{calls}end\n"

      try File.write_text("/tmp/agc_emit_try_all.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/agc_emit_try_all.agc"])
      result = try Process.output(proc, 30000)
      Test.assert(
        result.stdout.include?("check ok"),
        "check /tmp/agc_emit_try_all.agc failed:\n#{result.stdout}\n#{result.stderr}\n#{program}",
      )
    end,
  ])
end

# Starts the fragment accumulators empty (see accumulate): a fresh file per
# run, so a previous aborted run never leaks fragments into this one.
def reset_accumulators() -> Result[Void]
  try File.write_text("/tmp/agc_emit_try_blocks.txt", "")
  try File.write_text("/tmp/agc_emit_try_calls.txt", "")
  ok()
end
