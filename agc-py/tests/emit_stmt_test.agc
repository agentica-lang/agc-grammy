## Statement spine tests for phase 3c: every `Frontend.Stmt` shape through
## `EmitStmt.emit_block` with threaded scopes and non-overlapping temps.
##
## Each test parses tiny programs (at most three lines) with a single
## `Engine.run`, emits the statement list through the spine, asserts the
## exact inline lines plus helpers, scope and temp supply (or the refusal
## code and span), then appends the checkable fragments to shared
## accumulators: one `agentica check` per test blows the runner step
## budget, so a single final test checks every fragment together. Helpers
## hoist to the top level, inline lines run inside their own function with
## filtered declarations, and `main` calls each function.

import EmitStmt from "../src/emit_stmt"
import EmitCtx from "../src/emit_ctx"
import Engine from "../../src/engine"
import Frontend from "../src/frontend"
import Grammar from "../../src/grammar"

def stmt_ctx(source: String, scope: Map[String, String], func_ret: String, next_temp: Int) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(
    source: source,
    file: "stmt.py",
    scope: scope,
    func_ret: func_ret,
    in_try: false,
    next_temp: next_temp,
  )
end

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

def assert_ok(res: EmitStmt.BlockRes) -> Result[EmitStmt.BlockOut]
  case res
    EmitStmt.BlockRes.Ok(done) -> ok(done)
    EmitStmt.BlockRes.No(ref) -> error("expected ok, got #{ref.code}: #{ref.message}")
  end
end

def assert_no(res: EmitStmt.BlockRes, code: String) -> Result[EmitCtx.Refusal]
  case res
    EmitStmt.BlockRes.No(ref) ->
      try Test.eq(ref.code, code)
      ok(ref)
    EmitStmt.BlockRes.Ok(done) -> error("expected refusal #{code}, emitted #{done.code.join("\n")}")
  end
end

# Appends one checkable fragment: helpers hoist to the top level, `decls`
# that the fragment names prepend the function, `uses` append `puts` lines
# so checked locals stay read, and the call joins `main`.
def accumulate(
  slug: String,
  idx: Int,
  done: EmitStmt.BlockOut,
  decls: List[String],
  uses: List[String],
) -> Result[Void]
  keep = filter_decls(decls, done.code + done.helpers)
  tails = uses.map { |name| "puts(#{name})" }
  body = (keep + done.code + tails).map { |line| "  #{line}" }.join("\n")
  func = "def py_stmt_#{slug}#{idx}() -> Void\n#{body}\nend\n"
  # `type` aliases are declarations: they sort before every function
  # (`CHECK-DECL-ORDER`), so they land in their own prelude accumulator and
  # stay out of the function chunk.
  aliases = done.helpers.select { |line| line.start_with?("type ") }
  defs = done.helpers.select { |line| !line.start_with?("type ") }
  chunk = func
  if !defs.empty?
    chunk = defs.join("\n") + "\n\n" + func
  end

  if !aliases.empty?
    prelude = try File.read_text("/tmp/3c-spine-stmt-alias.txt")
    try File.write_text("/tmp/3c-spine-stmt-alias.txt", prelude + aliases.join("\n") + "\n\n")
  end

  blocks = try File.read_text("/tmp/3c-spine-stmt-blocks.txt")
  try File.write_text("/tmp/3c-spine-stmt-blocks.txt", blocks + chunk + "\n")
  calls = try File.read_text("/tmp/3c-spine-stmt-calls.txt")
  try File.write_text("/tmp/3c-spine-stmt-calls.txt", calls + "  py_stmt_#{slug}#{idx}()\n")
  ok()
end

def acc_ok(
  slug: String,
  idx: Int,
  res: EmitStmt.BlockRes,
  decls: List[String],
  uses: List[String],
) -> Result[EmitStmt.BlockOut]
  done = try assert_ok(res)
  try accumulate(slug, idx, done, decls, uses)
  ok(done)
end

# Keeps only the declarations the fragment names (a checked program
# refuses unused locals).
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

# Spells interpolation without writing it literally.
def interp(code: String) -> String = "#" + "{" + code + "}"

def quoted(inner: String) -> String = "\"" + inner + "\""

def helper_defs(lines: List[String]) -> Int
  count = 0
  for line in lines
    if line.start_with?("def ")
      count += 1
    end
  end

  count
end

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
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
    Test.test("sequential temps never collide") do
      source = "c: bool = True\ny: int = 1 if c else 2\nw: int = 3 if c else 4\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("temps", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 0), stmts), [], ["y", "w"])
      try Test.assert(done.code.join("\n").include?("py_t0 = case c"), done.code.join("\n"))
      try Test.assert(done.code.join("\n").include?("py_t1 = case c"), done.code.join("\n"))
      try Test.eq(done.next_temp, 2)
      try Test.eq(done.scope.get("y", ""), "Int")
      try Test.eq(done.scope.get("w", ""), "Int")
      try Test.eq(done.helpers.size, 0)
      ok()
    end,
    Test.test("two temp-producing headers stay disjoint") do
      source = "if a < b < c:\n  pass\nif d < e < f:\n  pass\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"a": "Int", "b": "Int", "c": "Int", "d": "Int", "e": "Int", "f": "Int"}, "", 0)
      decls = ["a: Int = 1", "b: Int = 2", "c: Int = 3", "d: Int = 1", "e: Int = 2", "f: Int = 3"]
      done = try acc_ok("headers", 0, EmitStmt.emit_block(ctx, stmts), decls, [])
      try Test.assert(done.code.join("\n").include?("py_t0 = b"), done.code.join("\n"))
      try Test.assert(done.code.join("\n").include?("py_t1 = e"), done.code.join("\n"))
      try Test.eq(done.next_temp, 2)
      ok()
    end,
    Test.test("for binds a new target only inside the body") do
      source = "for x in xs:\n  print(x)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"xs": "List[Int]"}, "", 0)
      done = try acc_ok("for", 0, EmitStmt.emit_block(ctx, stmts), ["xs: List[Int] = [1, 2]"], [])
      want_for = ["for x in xs", "  puts(" + quoted(interp("x")) + ")", "end"]
      try Test.eq(done.code, want_for)
      try Test.eq(done.scope.get("x", ""), "")
      try Test.eq(done.scope.get("xs", ""), "List[Int]")
      ok()
    end,
    Test.test("for over a bad iterable refuses") do
      source = "for i in n:\n  print(i)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"n": "Int"}, "", 0)
      ref = try assert_no(EmitStmt.emit_block(ctx, stmts), "PY-OPERATOR")
      try Test.eq(ref.start, 9)
      ok()
    end,
    Test.test("if bindings do not escape") do
      source = "if x > 0:\n  y: int = 1\n  print(y)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"x": "Int"}, "", 0)
      done = try acc_ok("ifscope", 0, EmitStmt.emit_block(ctx, stmts), ["x: Int = 1"], [])
      try Test.eq(done.scope.get("y", ""), "")
      try Test.eq(done.scope.get("x", ""), "Int")
      ok()
    end,
    Test.test("while re-evaluates its guard") do
      source = "while a < b < c:\n  b = b + 1\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"a": "Int", "b": "Int", "c": "Int"}, "", 0)
      decls = ["a: Int = 1", "b: Int = 2", "c: Int = 3"]
      done = try acc_ok("while", 0, EmitStmt.emit_block(ctx, stmts), decls, ["b"])
      try Test.assert(done.code.join("\n").include?("py_t0 = b"), done.code.join("\n"))
      try Test.eq(done.next_temp, 1)
      ok()
    end,
    Test.test("try hoists its helper and seeds e") do
      source = "try:\n  print(1)\nexcept E as e:\n  print(e)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("try", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 0), stmts), [], [])
      try Test.eq(helper_defs(done.helpers), 1)
      try Test.assert(List.first(done.helpers).start_with?("def py_try_body0"), done.helpers.join("\n"))
      try Test.assert(done.code.join("\n").include?("case py_try_body0()"), done.code.join("\n"))
      try Test.assert(done.code.join("\n").include?("e: String = \"\""), done.code.join("\n"))
      try Test.assert(done.code.join("\n").include?("e = py_try_err0.message"), done.code.join("\n"))
      try Test.eq(done.scope.get("e", ""), "String")
      try Test.eq(done.next_temp, 1)
      ok()
    end,
    Test.test("top-level raise inside try returns to the handler") do
      source = "try:\n  raise E(\"boom\")\nexcept:\n  print(9)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("topraise", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 2), stmts), [], [])
      try Test.assert(done.helpers.join("\n").include?("return error(\"boom\")"), done.helpers.join("\n"))
      try Test.assert(!done.helpers.join("\n").include?("System.exit"), done.helpers.join("\n"))
      try Test.assert(!done.helpers.join("\n").include?("  ok()"), done.helpers.join("\n"))
      try Test.assert(done.code.join("\n").include?("case py_try_body2()"), done.code.join("\n"))
      ok()
    end,
    Test.test("raise inside try returns in function context too") do
      source = "try:\n  raise E(\"boom\")\nexcept:\n  print(9)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      res = EmitStmt.emit_block(stmt_ctx(source, {}, "Int", 0), stmts)
      done = try assert_ok(res)
      try Test.assert(done.helpers.join("\n").include?("return error(\"boom\")"), done.helpers.join("\n"))
      try Test.assert(!done.helpers.join("\n").include?("  ok()"), done.helpers.join("\n"))
      ok()
    end,
    Test.test("outer reads become typed captures") do
      source = "x: int = 1\ntry:\n  print(x)\nexcept:\n  print(2)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "", 3)
      done = try acc_ok("cap", 0, EmitStmt.emit_block(ctx, stmts), [], ["x"])
      try Test.assert(done.helpers.join("\n").include?("def py_try_body3(x: Int)"), done.helpers.join("\n"))
      try Test.assert(done.code.join("\n").include?("case py_try_body3(x)"), done.code.join("\n"))
      ok()
    end,
    Test.test("string literals never capture") do
      source = "x: int = 1\ntry:\n  print(\"x\")\nexcept:\n  print(2)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "", 4)
      done = try acc_ok("caplit", 0, EmitStmt.emit_block(ctx, stmts), [], ["x"])
      try Test.assert(!done.helpers.join("\n").include?("py_try_body5(x"), done.helpers.join("\n"))
      try Test.assert(done.code.join("\n").include?("case py_try_body5()"), done.code.join("\n"))
      ok()
    end,
    Test.test("outer writes are refused") do
      source = "x: int = 1\ntry:\n  x = 2\nexcept:\n  print(3)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "", 0)
      ref = try assert_no(EmitStmt.emit_block(ctx, stmts), "PY-OUT-OF-SUBSET")
      try Test.assert(ref.message.include?("outer"), ref.message)
      ok()
    end,
    Test.test("augmented outer writes are refused") do
      source = "x: int = 1\ntry:\n  x += 1\nexcept:\n  print(3)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "", 0)
      ref = try assert_no(EmitStmt.emit_block(ctx, stmts), "PY-OUT-OF-SUBSET")
      try Test.assert(ref.message.include?("outer"), ref.message)
      ok()
    end,
    Test.test("for targets over outer names are refused") do
      source = "x: int = 0\ntry:\n  for x in xs:\n    print(x)\nexcept:\n  print(1)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"xs": "List[Int]"}, "", 0)
      ref = try assert_no(EmitStmt.emit_block(ctx, stmts), "PY-OUT-OF-SUBSET")
      try Test.assert(ref.message.include?("outer"), ref.message)
      ok()
    end,
    Test.test("int conversion unwraps inside try") do
      source = "try:\n  y: int = int(\"bad\")\n  print(y)\nexcept:\n  print(0)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("intbad", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 8), stmts), [], [])
      try Test.assert(done.helpers.join("\n").include?("y: Int = try \"bad\".to_i"), done.helpers.join("\n"))
      ok()
    end,
    Test.test("bare catchable results unwrap inside try") do
      source = "try:\n  int(\"bad\")\n  print(1)\nexcept:\n  print(0)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("intstmt", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 9), stmts), [], [])
      try Test.assert(done.helpers.join("\n").include?("try \"bad\".to_i"), done.helpers.join("\n"))
      ok()
    end,
    Test.test("except e stays visible after the handler") do
      source = "try:\n  print(1)\nexcept E as e:\n  print(e)\nprint(e)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("eescape", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 7), stmts), [], ["e"])
      try Test.eq(done.scope.get("e", ""), "String")
      try Test.assert(done.code.join("\n").include?(quoted(interp("e"))), done.code.join("\n"))
      ok()
    end,
    Test.test("nested try keeps helpers separate with unique ids") do
      source = "try:\n  try:\n    print(1)\n  except:\n    print(2)\nexcept:\n  print(3)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("nested", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 10), stmts), [], [])
      try Test.eq(helper_defs(done.helpers), 2)
      try Test.assert(done.helpers.join("\n").include?("def py_try_body10"), done.helpers.join("\n"))
      try Test.assert(done.helpers.join("\n").include?("def py_try_body11"), done.helpers.join("\n"))
      try Test.assert(done.code.join("\n").include?("case py_try_body11()"), done.code.join("\n"))
      try Test.eq(done.next_temp, 12)
      ok()
    end,
    Test.test("nested try captures outer reads through both helpers") do
      source = "x: int = 3\ntry:\n  try:\n    print(x)\n  except:\n    print(1)\nexcept:\n  print(2)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("nestcap", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 20), stmts), [], ["x"])
      try Test.eq(helper_defs(done.helpers), 2)
      try Test.assert(done.helpers.join("\n").include?("def py_try_body20(x: Int)"), done.helpers.join("\n"))
      try Test.assert(done.helpers.join("\n").include?("def py_try_body21(x: Int)"), done.helpers.join("\n"))
      try Test.assert(done.helpers.join("\n").include?("case py_try_body20(x)"), done.helpers.join("\n"))
      try Test.assert(done.code.join("\n").include?("case py_try_body21(x)"), done.code.join("\n"))
      try Test.eq(done.next_temp, 22)
      ok()
    end,
    Test.test("return inside a try body is refused before lowering") do
      source = "try:\n  return x\nexcept:\n  print(1)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"x": "Int"}, "Int", 0)
      ref = try assert_no(EmitStmt.emit_block(ctx, stmts), "PY-TRY-CONTROL")
      try Test.eq(ref.start, 14)
      ok()
    end,
    Test.test("bare return under Int refuses") do
      source = "return\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "Int", 0)
      ref = try assert_no(EmitStmt.emit_block(ctx, stmts), "PY-TYPE-MISMATCH")
      try Test.eq(ref.start, 0)
      ok()
    end,
    Test.test("bare return outside a def refuses") do
      source = "return\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "", 0)
      res = EmitStmt.emit_block(ctx, stmts)
      ref = try assert_no(res, "PY-OUT-OF-SUBSET")
      try Test.eq(ref.start, 0)
      ok()
    end,
    Test.test("break inside a try body is refused") do
      source = "try:\n  break\nexcept:\n  print(1)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "", 0)
      res = EmitStmt.emit_block(ctx, stmts)
      ref = try assert_no(res, "PY-TRY-CONTROL")
      try Test.assert(ref.message.include?("break"), ref.message)
      ok()
    end,
    Test.test("raise emits an error return under a Result context") do
      source = "x: int = 1\nraise E(\"boom\")\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "Result[Int]", 0)
      res = EmitStmt.emit_block(ctx, stmts)
      done = try assert_ok(res)
      try Test.assert(done.code.join("\n").include?("return error(\"boom\")"), done.code.join("\n"))
      try Test.eq(done.helpers.size, 0)
      ok()
    end,
    Test.test("raise in an ordinary function context refuses spanned") do
      source = "x: int = 1\nraise E(\"boom\")\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      res = EmitStmt.emit_block(stmt_ctx(source, {}, "Int", 0), stmts)
      ref = try assert_no(res, "PY-OUT-OF-SUBSET")
      try Test.eq(ref.start, 17)
      try Test.assert(ref.message.include?("Int"), ref.message)
      try Test.assert(ref.help.unwrap!.include?("Result"), ref.help.unwrap!)
      ok()
    end,
    Test.test("break outside a loop refuses spanned") do
      source = "x: int = 1\nbreak\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      res = EmitStmt.emit_block(stmt_ctx(source, {}, "", 0), stmts)
      ref = try assert_no(res, "PY-OUT-OF-SUBSET")
      try Test.eq(ref.start, 11)
      try Test.assert(ref.message.include?("break"), ref.message)
      ok()
    end,
    Test.test("next outside a loop refuses spanned") do
      source = "x: int = 1\nnext\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      res = EmitStmt.emit_block(stmt_ctx(source, {}, "", 0), stmts)
      ref = try assert_no(res, "PY-OUT-OF-SUBSET")
      try Test.eq(ref.start, 11)
      try Test.assert(ref.message.include?("next"), ref.message)
      ok()
    end,
    Test.test("break inside a while body emits") do
      source = "while a < b:\n  break\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"a": "Int", "b": "Int"}, "", 0)
      decls = ["a: Int = 1", "b: Int = 2"]
      done = try acc_ok("brkwhile", 0, EmitStmt.emit_block(ctx, stmts), decls, [])
      try Test.eq(List.first(done.code), "while true")
      try Test.assert(done.code.join("\n").include?("\n  break\n"), done.code.join("\n"))
      ok()
    end,
    Test.test("break inside an if inside a loop emits") do
      source = "while a < b:\n  if a > 0:\n    break\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"a": "Int", "b": "Int"}, "", 0)
      decls = ["a: Int = 1", "b: Int = 2"]
      done = try acc_ok("brkif", 0, EmitStmt.emit_block(ctx, stmts), decls, [])
      try Test.assert(done.code.join("\n").include?("\n    break\n"), done.code.join("\n"))
      ok()
    end,
    Test.test("next inside a for body emits") do
      source = "for x in xs:\n  print(x)\n  next\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"xs": "List[Int]"}, "", 0)
      done = try acc_ok("nextfor", 0, EmitStmt.emit_block(ctx, stmts), ["xs: List[Int] = [1, 2]"], [])
      try Test.assert(done.code.join("\n").include?("for x in xs"), done.code.join("\n"))
      try Test.assert(done.code.join("\n").include?("\n  next\n"), done.code.join("\n"))
      ok()
    end,
    Test.test("break inside a handler of a loop try emits") do
      source = "for x in xs:\n  try:\n    print(x)\n  except:\n    break\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"xs": "List[Int]"}, "", 0)
      done = try acc_ok("brkh", 0, EmitStmt.emit_block(ctx.with(next_temp: 40), stmts), ["xs: List[Int] = [1, 2]"], [])
      try Test.assert(done.code.join("\n").include?("\n      break\n"), done.code.join("\n"))
      ok()
    end,
    Test.test("for rebinds a prebound target keeping its type") do
      source = "x: int = 0\nfor x in xs:\n  print(x)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"xs": "List[Int]"}, "", 0)
      done = try acc_ok("forre", 0, EmitStmt.emit_block(ctx, stmts), ["xs: List[Int] = [1, 2]"], [])
      try Test.assert(done.code.join("\n").include?("for py_t0 in xs"), done.code.join("\n"))
      try Test.assert(done.code.join("\n").include?("  x = py_t0\n"), done.code.join("\n"))
      try Test.eq(done.scope.get("x", ""), "Int")
      ok()
    end,
    # A fresh target reassigned in the body (augmented here) gets the
    # iterator lowering: the direct header would assign the backend's
    # immutable loop variable (probed CHECK-IMMUTABLE-ASSIGNMENT).
    Test.test("a reassigned fresh for target lowers through an iterator") do
      source = "for x in xs:\n  x += 1\n  print(x)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"xs": "List[Int]"}, "", 0)
      done = try acc_ok("forfresh", 0, EmitStmt.emit_block(ctx, stmts), ["xs: List[Int] = [1, 2]"], [])
      text = done.code.join("\n")
      try Test.assert(text.include?("for py_t0 in xs"), text)
      try Test.assert(text.include?("\n  x = py_t0\n"), text)
      try Test.assert(!text.include?("for x in xs"), text)
      try Test.eq(done.scope.get("x", ""), "")
      ok()
    end,
    # The detection recurses: an assignment nested in an `if` counts, and
    # so does a nested loop binding the same name (Python rebinds the outer
    # target through the inner header).
    Test.test("a nested reassignment of a fresh for target keeps the lowering") do
      source = "for x in xs:\n  if x > 0:\n    x = 9\n  for x in ys:\n    print(x)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {"xs": "List[Int]", "ys": "List[Int]"}, "", 0)
      done = try acc_ok(
        "fornest",
        0,
        EmitStmt.emit_block(ctx, stmts),
        ["xs: List[Int] = [1, 2]", "ys: List[Int] = [3, 4]"],
        [],
      )

      text = done.code.join("\n")
      # The inner loop's iterator temp comes first: body temps sit past the
      # incoming supply, the outer iterator past the whole body.
      try Test.assert(text.include?("for py_t1 in xs"), text)
      try Test.assert(text.include?("\n  x = py_t1\n"), text)
      try Test.assert(text.include?("for py_t0 in ys"), text)
      try Test.assert(text.include?("\n    x = py_t0\n"), text)
      try Test.assert(!text.include?("for x in xs"), text)
      try Test.eq(done.scope.get("x", ""), "")
      ok()
    end,
    Test.test("nested try in the handler hoists its helper") do
      source = "try:\n  print(1)\nexcept:\n  try:\n    print(2)\n  except:\n    print(3)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("nexth", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 30), stmts), [], [])
      try Test.eq(helper_defs(done.helpers), 2)
      try Test.assert(done.helpers.join("\n").include?("def py_try_body30"), done.helpers.join("\n"))
      try Test.assert(done.helpers.join("\n").include?("def py_try_body31"), done.helpers.join("\n"))
      try Test.assert(done.code.join("\n").include?("case py_try_body31()"), done.code.join("\n"))
      try Test.eq(done.next_temp, 32)
      ok()
    end,
    Test.test("alias annotations resolve and check end to end") do
      source = "type Color = int\nx: Color = 3\nxs: list[Color] = [1, 2]\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("alias", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 0), stmts), [], ["x", "xs"])
      try Test.eq(done.helpers, ["type Color = Int"])
      try Test.eq(done.scope.get("x", ""), "Int")
      try Test.eq(done.scope.get("xs", ""), "List[Int]")
      try Test.assert(done.code.join("\n").include?("x: Int = 3"), done.code.join("\n"))
      try Test.assert(done.code.join("\n").include?("xs: List[Int] = [1, 2]"), done.code.join("\n"))
      ok()
    end,
    Test.test("assert emits warn and exit") do
      source = "x: int = 3\nassert x > 0\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      done = try acc_ok("assert", 0, EmitStmt.emit_block(stmt_ctx(source, {}, "", 0), stmts), [], ["x"])
      try Test.assert(done.code.join("\n").include?("if !(x > 0)"), done.code.join("\n"))
      try Test.assert(done.code.join("\n").include?("System.exit(1)"), done.code.join("\n"))
      ok()
    end,
    Test.test("generated try code catches at runtime") do
      source = "x: int = 7\ntry:\n  print(x)\n  y: int = int(\"bad\")\n  print(y)\nexcept E as e:\n  print(e)\n"
      stmts = try stmts_of(compiled.unwrap!, source)
      ctx = stmt_ctx(source, {}, "", 0)
      done = try assert_ok(EmitStmt.emit_block(ctx, stmts))
      helpers = done.helpers.join("\n")
      inline = done.code.join("\n")
      program = "#{helpers}\n\ndef main() -> Void\n#{inline.split("\n").map { |line| "  #{line}" }.join("\n")}\nend\n"
      try File.write_text("/tmp/w3c-spine-try-runtime.agc", program)
      proc = try Process.spawn_captured("agentica", ["/tmp/w3c-spine-try-runtime.agc"])
      result = try Process.output(proc, 30000)
      try Test.assert(
        result.stdout.include?("7"),
        "missing capture read:\n#{result.stdout}\n#{result.stderr}\n#{program}",
      )

      try Test.assert(
        result.stdout.include?("cannot convert"),
        "missing catchable int path:\n#{result.stdout}\n#{result.stderr}\n#{program}",
      )

      ok()
    end,
    Test.test("all fragments check clean together") do
      aliases = try File.read_text("/tmp/3c-spine-stmt-alias.txt")
      blocks = try File.read_text("/tmp/3c-spine-stmt-blocks.txt")
      calls = try File.read_text("/tmp/3c-spine-stmt-calls.txt")
      program = "#{aliases}#{blocks}\ndef main() -> Void\n#{calls}end\n"

      try File.write_text("/tmp/3c-spine-stmt-all.agc", program)
      proc = try Process.spawn_captured("agentica", ["check", "/tmp/3c-spine-stmt-all.agc"])
      result = try Process.output(proc, 30000)
      Test.assert(
        result.stdout.include?("check ok"),
        "check /tmp/3c-spine-stmt-all.agc failed:\n#{result.stdout}\n#{result.stderr}\n#{program}",
      )
    end,
  ])
end

# Starts the fragment accumulators empty: a fresh file per run, so a
# previous aborted run never leaks fragments into this one.
def reset_accumulators() -> Result[Void]
  try File.write_text("/tmp/3c-spine-stmt-alias.txt", "")
  try File.write_text("/tmp/3c-spine-stmt-blocks.txt", "")
  try File.write_text("/tmp/3c-spine-stmt-calls.txt", "")
  ok()
end
