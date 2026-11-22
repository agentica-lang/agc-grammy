## Call ABI codegen tests (issue #23): user calls carry their `def`'s
## signature, so a keyword call reorders into the backend's positional form
## through source-ordered temps, a defaulted parameter lowers its default
## expression at the call site, a default may read a parameter the call
## passes, and an `Optional` parameter wraps a plain value. The invalid
## shapes (missing, extra, repeated, unknown keyword, type mismatch) refuse
## with their `PY-*` codes. The py2agc pipeline tests prove the same shapes
## against the real backend with `agentica check` and a run.
##
## One test per parsed batch: `agentica test` shares a step budget of one
## million steps per test (plus one) over the file's tests, the grammar
## load costs close to two million and every batch parse about three
## hundred thousand per line, so a test holds one small batch and its
## emissions. Each default node must share its batch's source, because the
## emission slices its text out of it (`Tree.text` spans into the source).

import EmitCtx from "../src/emit_ctx"
import EmitExpr from "../src/emit_expr"
import Engine from "../../src/engine"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

def main() -> Void
  # Agentica 0.35.0 gives discovery a separate, smaller step budget.
  compiled: Result[Grammar.Grammar] = error("grammar is not loaded during discovery")
  if System.args() == ["--agentica-test", "run"]
    compiled = Grammar.load("agc-py/grammars/py312.grammar")
  end

  Test.run([
    Test.test("keyword calls map onto the signature in parameter order") do keyword_flow(compiled.unwrap!) end,
    Test.test("a call missing its required argument refuses") do missing_flow(compiled.unwrap!) end,
    Test.test("repeated, shadowed and unknown keyword arguments refuse") do kw_error_flow(compiled.unwrap!) end,
    Test.test("a defaulted parameter lowers at the call site") do default_flow(compiled.unwrap!) end,
    Test.test("a bad call to a defaulted function refuses") do default_error_flow(compiled.unwrap!) end,
    Test.test("a default reads its parameter") do subst_flow(compiled.unwrap!) end,
    Test.test("an optional parameter wraps a plain value") do optional_flow(compiled.unwrap!) end,
    Test.test("a caller's binding survives beside a defaulted call") do caller_flow(compiled.unwrap!) end,
    Test.test("a sibling argument keeps the caller's binding") do sibling_flow(compiled.unwrap!) end,
    Test.test("a repeated parameter read evaluates its argument once") do temp_flow(compiled.unwrap!) end,
    Test.test("a lowered default wraps and checks like an argument") do default_fit_flow(compiled.unwrap!) end,
    Test.test("a self-referential default refuses") do self_ref_flow(compiled.unwrap!) end,
    Test.test("keyword hoists stay in source order before a later preamble") do kw_preamble_flow(compiled.unwrap!) end,
    Test.test("a default capture runs where its argument sat") do default_order_flow(compiled.unwrap!) end,
  ])
end

def keyword_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["add(1, 2)", "add(y=2, x=1)"])
  nodes = try parse_values(compiled, full)
  add_sig = EmitCtx.Sig(name: "add", params: ["x", "y"], types: ["Int", "Int"], defaults: [none, none], ret: "Int")
  sigs = {"add": add_sig}
  scope = {"add": EmitCtx.def_marker()}

  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "add(1, 2)")
  try Test.eq(out.pre, [])

  # The keywords reorder the call text into parameter order; the hoisted
  # temps keep the source evaluation order (y's value evaluates first).
  out = try EmitExpr.emit(List.first(nodes.drop(1)), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "add(py_t1, py_t0)")
  try Test.eq(out.pre, ["py_t0 = 2", "py_t1 = 1"])
  ok()
end

def missing_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["add(1)"])
  nodes = try parse_values(compiled, full)
  add_sig = EmitCtx.Sig(name: "add", params: ["x", "y"], types: ["Int", "Int"], defaults: [none, none], ret: "Int")
  sigs = {"add": add_sig}
  scope = {"add": EmitCtx.def_marker()}

  emitted = EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try assert_err(emitted, "PY-CALL-ARITY")
  ok()
end

def kw_error_flow(compiled: Grammar.Grammar) -> Result[Void]
  batch = ["add(x=1, x=2)", "add(z=1)", "add(1, x=2)", "add(1, 2, 3)"]
  full = wrap_all(batch)
  nodes = try parse_values(compiled, full)
  add_sig = EmitCtx.Sig(name: "add", params: ["x", "y"], types: ["Int", "Int"], defaults: [none, none], ret: "Int")
  sigs = {"add": add_sig}
  scope = {"add": EmitCtx.def_marker()}

  codes = ["PY-KWARG-DUPLICATE", "PY-KWARG-UNKNOWN", "PY-KWARG-DUPLICATE", "PY-CALL-ARITY"]
  i = 0
  for _ in codes
    emitted = EmitExpr.emit(List.first(nodes.drop(i)), full, scope, sigs)
    try assert_err(emitted, List.first(codes.drop(i)))
    i += 1
  end

  ok()
end

def default_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["f(1)", "5"])
  nodes = try parse_values(compiled, full)
  five = List.first(nodes.drop(1))
  def_sig = EmitCtx.Sig(name: "f", params: ["x", "y"], types: ["Int", "Int"], defaults: [none, some(five)], ret: "Int")
  sigs = {"f": def_sig}
  scope = {"f": EmitCtx.def_marker()}

  # A missing argument lowers its default at the call site.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "f(1, 5)")
  try Test.eq(out.pre, [])
  ok()
end

def default_error_flow(compiled: Grammar.Grammar) -> Result[Void]
  # The `5` default shares the batch so the signature's node spans this
  # source; the refused shapes fail before any default lowers.
  full = wrap_all(["f(\"s\", 2)", "f()", "5"])
  nodes = try parse_values(compiled, full)
  five = List.first(nodes.drop(2))
  def_sig = EmitCtx.Sig(name: "f", params: ["x", "y"], types: ["Int", "Int"], defaults: [none, some(five)], ret: "Int")
  sigs = {"f": def_sig}
  scope = {"f": EmitCtx.def_marker()}

  emitted = EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try assert_err(emitted, "PY-TYPE-MISMATCH")
  emitted = EmitExpr.emit(List.first(nodes.drop(1)), full, scope, sigs)
  try assert_err(emitted, "PY-CALL-ARITY")
  ok()
end

def subst_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["g(3)", "a * 2"])
  nodes = try parse_values(compiled, full)
  a_times_two = List.first(nodes.drop(1))
  subst_sig = EmitCtx.Sig(
    name: "g",
    params: ["a", "b"],
    types: ["Int", "Int"],
    defaults: [none, some(a_times_two)],
    ret: "Int",
  )

  sigs = {"g": subst_sig}
  scope = {"g": EmitCtx.def_marker()}

  # A default reading a parameter lowers with that call's value, spelled
  # through the hoisted temp so the argument evaluates once.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "g(py_t0, py_t0 * 2)")
  try Test.eq(out.pre, ["py_t0 = 3"])
  ok()
end

def optional_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["h(5)"])
  nodes = try parse_values(compiled, full)
  opt_sig = EmitCtx.Sig(name: "h", params: ["x"], types: ["Optional[Int]"], defaults: [none], ret: "Int")
  sigs = {"h": opt_sig}
  scope = {"h": EmitCtx.def_marker()}

  # A plain value into an `Optional[...]` parameter wraps in `some`.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "h(some(5))")
  try Test.eq(out.pre, [])
  ok()
end

def caller_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["g(3) + a", "a * 2"])
  nodes = try parse_values(compiled, full)
  a_times_two = List.first(nodes.drop(1))
  subst_sig = EmitCtx.Sig(
    name: "g",
    params: ["a", "b"],
    types: ["Int", "Int"],
    defaults: [none, some(a_times_two)],
    ret: "Int",
  )

  sigs = {"g": subst_sig}
  scope = {"g": EmitCtx.def_marker(), "a": "Int"}

  # The trailing `a` is the caller's binding (100 at run time), not the
  # callee temp: the call must restore the caller substitutions on return.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "g(py_t0, py_t0 * 2) + a")
  try Test.eq(out.pre, ["py_t0 = 3"])
  ok()
end

def sibling_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["h(g(3), a)", "a * 2"])
  nodes = try parse_values(compiled, full)
  a_times_two = List.first(nodes.drop(1))
  g_sig = EmitCtx.Sig(
    name: "g",
    params: ["a", "b"],
    types: ["Int", "Int"],
    defaults: [none, some(a_times_two)],
    ret: "Int",
  )

  h_sig = EmitCtx.Sig(name: "h", params: ["x", "y"], types: ["Int", "Int"], defaults: [none, none], ret: "Int")
  sigs = {"g": g_sig, "h": h_sig}
  scope = {"g": EmitCtx.def_marker(), "h": EmitCtx.def_marker(), "a": "Int"}

  # The sibling `a` reads the caller binding even though the first argument
  # bound the same name as a callee temp while it lowered.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "h(g(py_t0, py_t0 * 2), a)")
  try Test.eq(out.pre, ["py_t0 = 3"])
  ok()
end

def temp_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["g(py_tmp + f())", "a + a"])
  nodes = try parse_values(compiled, full)
  a_plus_a = List.first(nodes.drop(1))
  g_sig = EmitCtx.Sig(
    name: "g",
    params: ["a", "b"],
    types: ["Int", "Int"],
    defaults: [none, some(a_plus_a)],
    ret: "Int",
  )

  f_sig = EmitCtx.Sig(name: "f", params: [], types: [], defaults: [], ret: "Int")
  sigs = {"g": g_sig, "f": f_sig}
  scope = {"g": EmitCtx.def_marker(), "f": EmitCtx.def_marker(), "py_tmp": "Int"}

  # `py_tmp + f()` is not a generated temp, so the parameter hoists to one:
  # the default reads it twice but `f()` evaluates once.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "g(py_t0, py_t0 + py_t0)")
  try Test.eq(out.pre, ["py_t0 = py_tmp + f()"])
  ok()
end

def default_fit_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["h()", "5"])
  nodes = try parse_values(compiled, full)
  five = List.first(nodes.drop(1))
  h_sig = EmitCtx.Sig(name: "h", params: ["x"], types: ["Optional[Int]"], defaults: [some(five)], ret: "Int")
  sigs = {"h": h_sig}
  scope = {"h": EmitCtx.def_marker()}

  # A plain default into an `Optional` parameter wraps in `some`, exactly
  # like a plain explicit argument does.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "h(some(5))")
  try Test.eq(out.pre, [])

  # A default of the wrong type refuses with the same code an explicit
  # argument would carry, instead of reaching the backend unspanned.
  bad_full = wrap_all(["f(1)", "\"s\""])
  bad_nodes = try parse_values(compiled, bad_full)
  s_lit = List.first(bad_nodes.drop(1))
  f_sig = EmitCtx.Sig(name: "f", params: ["x", "y"], types: ["Int", "Int"], defaults: [none, some(s_lit)], ret: "Int")
  bad = EmitExpr.emit(List.first(bad_nodes), bad_full, {"f": EmitCtx.def_marker()}, {"f": f_sig})
  try assert_err(bad, "PY-TYPE-MISMATCH")
  ok()
end

def self_ref_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["g(1)", "b"])
  nodes = try parse_values(compiled, full)
  b_only = List.first(nodes.drop(1))
  g_sig = EmitCtx.Sig(name: "g", params: ["a", "b"], types: ["Int", "Int"], defaults: [none, some(b_only)], ret: "Int")

  sigs = {"g": g_sig}
  scope = {"g": EmitCtx.def_marker()}

  # `b`'s default reads `b` itself: no call can satisfy that by passing,
  # so it refuses instead of reading a like-named caller local.
  emitted = EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try assert_err(emitted, "PY-OUT-OF-SUBSET")
  ok()
end

def kw_preamble_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["h(a=f(), b=1 < g() < 3)"])
  nodes = try parse_values(compiled, full)
  h_sig = EmitCtx.Sig(name: "h", params: ["a", "b"], types: ["Int", "Bool"], defaults: [none, none], ret: "Int")
  f_sig = EmitCtx.Sig(name: "f", params: [], types: [], defaults: [], ret: "Int")
  g_sig = EmitCtx.Sig(name: "g", params: [], types: [], defaults: [], ret: "Int")
  sigs = {"h": h_sig, "f": f_sig, "g": g_sig}
  scope = {"h": EmitCtx.def_marker(), "f": EmitCtx.def_marker(), "g": EmitCtx.def_marker()}

  # The chained middle hoists `g()` to `py_t0`; the keyword hoists must not
  # append `f()` after it. Source order is `f()` before `g()`.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "h(py_t1, py_t2)")
  try Test.eq(out.pre, ["py_t1 = f()", "py_t0 = g()", "py_t2 = 1 < py_t0 and py_t0 < 3"])
  ok()
end

def default_order_flow(compiled: Grammar.Grammar) -> Result[Void]
  full = wrap_all(["g(f(), h() if True else 0)", "a + b"])
  nodes = try parse_values(compiled, full)
  dflt = List.first(nodes.drop(1))
  g_sig = EmitCtx.Sig(
    name: "g",
    params: ["a", "b", "c"],
    types: ["Int", "Int", "Int"],
    defaults: [none, none, some(dflt)],
    ret: "Int",
  )

  f_sig = EmitCtx.Sig(name: "f", params: [], types: [], defaults: [], ret: "Int")
  h_sig = EmitCtx.Sig(name: "h", params: [], types: [], defaults: [], ret: "Int")
  sigs = {"g": g_sig, "f": f_sig, "h": h_sig}
  scope = {"g": EmitCtx.def_marker(), "f": EmitCtx.def_marker(), "h": EmitCtx.def_marker()}

  # The ternary preamble holds `h()`; capturing `a` for the default must run
  # where `f()` sat, before that preamble, so `f()` evaluates once first.
  out = try EmitExpr.emit(List.first(nodes), full, scope, sigs)
  try Test.eq(out.type, "Int")
  try Test.eq(out.code, "g(py_t1, py_t0, py_t1 + py_t0)")
  try Test.eq(out.pre, ["py_t1 = f()", "py_t0 = 0", "if true", "  py_t0 = h()", "end"])
  ok()
end

def wrap_all(exprs: List[String]) -> String = exprs.map { |expr| "py_tmp = #{expr}" }.join("\n") + "\n"

def parse_values(compiled: Grammar.Grammar, full: String) -> Result[List[Tree.Node]]
  tree = try Engine.run(compiled, "program", full)
  matches = Tree.find_all(tree, "assign")
  ok(matches.map { |assign| List.last(assign.children) })
end

def assert_err(out: Result[EmitExpr.Out], code: String) -> Result[Void]
  case out
    ok(_) -> try Test.assert(false, "expected #{code}, got a value")
    error(e) -> try Test.assert(e.message.start_with?(code), e.message)
  end

  ok()
end
