## Expression codegen for `agc-py` phase 3b: Python subset expressions become
## typed `.agc` fragments.
##
## `emit` takes one parsed expression node (any rule from `cond_expr` down to
## a literal), the source it was sliced from, and a scope of known names to
## Agentica types (`{"x": "Int"}`), and answers the Agentica text with its
## static type. Types are coarse names (`Int`, `Float`, `String`, `Bool`,
## `List`, `Map`, `Range`, `Void`, `none`, `Optional`, `Result`, `Unknown`);
## container literals refine to `List[E]` / `Map[K, V]` when every element
## agrees, so later phases can name element types without re-walking the tree.
##
## The lowering follows `SUBSET.md` section 3 exactly: `/` on two `Int` maps
## to float division (`a.to_f / b.to_f`), `%` to the `py_pymod` helper
## (Python signs), `//` to `py_floor_div`, `**` to `.pow` (a statically
## negative exponent is `PY-OPERATOR`), string ordering to `.compare`,
## chained comparisons to one temp per middle operand joined with `and`, the
## ternary to a temp plus a statement `if`, slices to the `py_slice_list` /
## `py_slice_str` helpers with clamped bounds, `in` to `include?` / `key?`,
## `is None` to `.none?`, and calls to the section 5 mappings (`print` joins
## with interpolation, `len` picks `size` / `length`, `range(a)` is `0...a`).
## Anything the backend has no form for is a `PY-*` error, never a guess:
## mixed-type arithmetic is `PY-TYPE-MISMATCH`, unknown combinations are
## `PY-OPERATOR`, non-`bool` guards are `PY-COND-NOT-BOOL`, `is` outside
## `None` is `PY-IS`, and in-place mutators (`append` and friends) are
## `PY-MUTATION`.
##
## Attribute paths stay verbatim (`a.b.c` is `a.b.c`): phase 3a already
## guarantees the root is bound, and phase 4 owns module meaning. An unknown
## method on an `Unknown` receiver also stays verbatim (a module path such as
## `math.sqrt`), so only value receivers with known types get mapped or
## refused. The helpers live in `helpers`: prepend it to any checked program.
## Temps are `py_tN` lines in `Out.pre`, in evaluation order; the ternary
## evaluates its guard first but both branches eagerly (no closures exist to
## defer one), and a chained middle operand exactly once.

import Tree from "../../src/tree"

## One emitted expression: Agentica text, its static type, and the temp
## preamble lines to run first, in order.
struct Out
  code: String
  type: String
  pre: List[String]
end

## Emits `node` (an expression rule) with `scope` naming every visible name.
def emit(node: Tree.Node, source: String, scope: Map[String, String]) -> Result[Out]
  done = try emit_in(Cx(scope: scope, next_temp: 0, pre: []), node, source)
  ok(Out(code: done.code, type: done.type, pre: done.cx.pre))
end

## The helper preamble every emitted fragment may call: Python-signed `%`,
## truncating `//` corrected for differing signs, and clamped slices over
## `take` / `drop` (lists) and `slice` (strings). Bounds evaluate once at the
## call; a missing upper bound passes the container length at the call site.
def helpers() -> String
  (
    "def py_pymod(a: Int, b: Int) -> Int\n" +
    "  r: Int = a % b\n" +
    "  if r != 0 and (r < 0) != (b < 0)\n" +
    "    r = r + b\n" +
    "  end\n" +
    "  r\n" +
    "end\n" +
    "\n" +
    "def py_floor_div(a: Int, b: Int) -> Int\n" +
    "  q: Int = a / b\n" +
    "  r: Int = a % b\n" +
    "  if r != 0 and (r < 0) != (b < 0)\n" +
    "    q = q - 1\n" +
    "  end\n" +
    "  q\n" +
    "end\n" +
    "\n" +
    "def py_slice_list[T](xs: List[T], lo: Int, hi: Int) -> List[T]\n" +
    "  a: Int = lo.clamp(0, xs.size)\n" +
    "  b: Int = hi.clamp(0, xs.size)\n" +
    "  if b < a\n" +
    "    b = a\n" +
    "  end\n" +
    "  xs.drop(a).take(b - a)\n" +
    "end\n" +
    "\n" +
    "def py_slice_str(s: String, lo: Int, hi: Int) -> String\n" +
    "  a: Int = lo.clamp(0, s.length)\n" +
    "  b: Int = hi.clamp(0, s.length)\n" +
    "  if b < a\n" +
    "    b = a\n" +
    "  end\n" +
    "  s.slice(a, b - a)\n" +
    "end\n"
  )
end

private

MUTATORS = ["append", "extend", "insert", "remove", "pop", "clear", "update", "setdefault", "popitem"]

BUILTINS = [
  "print",
  "len",
  "range",
  "int",
  "float",
  "str",
  "bool",
  "sorted",
  "sum",
  "min",
  "max",
  "abs",
  "round",
  "chr",
  "ord",
  "reversed",
  "all",
  "any",
  "map",
  "filter",
  "enumerate",
]

# Emission state: the visible names, the next temp number, and the preamble.
struct Cx
  scope: Map[String, String]
  next_temp: Int
  pre: List[String]
end

# An emitted expression still carrying its state.
struct Done
  code: String
  type: String
  cx: Cx
end

# One decoded escape: the character and the offset past it.
struct Decoded
  text: String
  next: Int
end

# A keyword argument: its name and emitted value.
struct Kw
  name: String
  value: Done
end

struct CallArgs
  pos: List[Done]
  raws: List[Tree.Node]
  kw: List[Kw]
  cx: Cx
end

def emit_in(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  case node.rule
    "cond_expr" -> emit_cond(cx, node, source)
    "or_expr" -> emit_logic(cx, node, source, "or")
    "and_expr" -> emit_logic(cx, node, source, "and")
    "boolean_not" -> emit_not(cx, node, source)
    "comparison" -> emit_comparison(cx, node, source)
    "sum" -> emit_sum(cx, node, source)
    "term" -> emit_term(cx, node, source)
    "minus" -> emit_minus(cx, node, source)
    "plus" -> emit_plus(cx, node, source)
    "group" -> emit_group(cx, node, source)
    "number" -> emit_number(cx, node, source)
    "text" -> emit_text(cx, node, source)
    "list_lit" -> emit_list(cx, node, source)
    "dict_lit" -> emit_dict(cx, node, source)
    "boolean" -> emit_boolean(cx, node, source)
    "none_lit" -> ok(Done(code: "none", type: "none", cx: cx))
    "name" -> emit_name(cx, node, source)
    "call" -> emit_call(cx, node, source)
    "attr" -> emit_attr(cx, node, source)
    "expr_stmt" -> emit_only_child(cx, node, source)
    "call_stmt" -> emit_only_child(cx, node, source)
    "assign" -> emit_last_child(cx, node, source)
    "annotated" -> emit_last_child(cx, node, source)
    "arg" -> emit_only_child(cx, node, source)
    "hole" -> emit_only_child(cx, node, source)
    _ -> error("agc-py: cannot emit #{node.rule}")
  end
end

def emit_only_child(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  return error("agc-py: #{node.rule} without a child") if node.children.empty?

  emit_in(cx, List.last(node.children), source)
end

def emit_last_child(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  return error("agc-py: #{node.rule} without a value") if node.children.empty?

  emit_in(cx, List.last(node.children), source)
end

# `a if c else b` lowers to a temp plus a statement `if`: the guard runs
# first, the `else` value seeds the temp, and the `then` value replaces it.
# Both branches evaluate eagerly; only the selected value survives.
def emit_cond(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  return emit_in(cx, List.first(node.children), source) if node.children.size == 1
  return error("agc-py: cond without three parts") if node.children.size != 3

  kids = node.children
  guard = try emit_in(cx, List.first(kids.drop(1)), source)
  return cond_bool_error(guard.type) if guard.type != "Bool"

  then_done = try emit_in(guard.cx, List.first(kids), source)
  else_done = try emit_in(then_done.cx, List.first(kids.drop(2)), source)
  if then_done.type != else_done.type
    return error(
      "PY-TYPE-MISMATCH: ternary branches differ: #{then_done.type} vs #{else_done.type} = help: convert one side explicitly",
    )
  end

  temp = "py_t#{else_done.cx.next_temp}"
  pre = else_done.cx.pre + ["#{temp} = #{else_done.code}", "if #{guard.code}", "  #{temp} = #{then_done.code}", "end"]
  ok(Done(code: temp, type: then_done.type, cx: else_done.cx.with(next_temp: else_done.cx.next_temp + 1, pre: pre)))
end

def cond_bool_error(found: String) -> Result[Done]
  error("PY-COND-NOT-BOOL: ternary guard must be bool, found #{found} = help: compare or convert to a bool first")
end

def emit_logic(cx: Cx, node: Tree.Node, source: String, op: String) -> Result[Done]
  return emit_in(cx, List.first(node.children), source) if node.children.size == 1

  first = try emit_in(cx, List.first(node.children), source)
  return logic_bool_error(first.type, op) if first.type != "Bool"

  code = first.code
  current = first.cx
  for child in node.children.drop(1)
    next_done = try emit_in(current, child, source)
    return logic_bool_error(next_done.type, op) if next_done.type != "Bool"

    code = "#{code} #{op} #{next_done.code}"
    current = next_done.cx
  end

  ok(Done(code: code, type: "Bool", cx: current))
end

def logic_bool_error(found: String, op: String) -> Result[Done]
  error("PY-COND-NOT-BOOL: `#{op}` needs bool operands, found #{found} = help: compare or convert to a bool first")
end

def emit_not(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  return error("agc-py: not without an operand") if node.children.empty?

  inner = try emit_in(cx, List.first(node.children), source)
  if inner.type != "Bool"
    return error(
      "PY-COND-NOT-BOOL: `not` needs a bool, found #{inner.type} = help: compare or convert to a bool first",
    )
  end

  ok(Done(code: "!(#{inner.code})", type: "Bool", cx: inner.cx))
end

def emit_comparison(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  return emit_in(cx, List.first(node.children), source) if node.children.size == 1

  operands: List[Tree.Node] = []
  ops: List[String] = []
  index = 0
  for child in node.children
    if index % 2 == 0
      operands = operands.push(child)
    else
      ops = ops.push(Tree.text(child, source))
    end

    index += 1
  end

  if operands.size == 2
    return emit_binary(cx, List.first(operands), List.first(ops), List.first(operands.drop(1)), source)
  end

  emit_chained(cx, operands, ops, source)
end

# A chained comparison evaluates each middle operand once into a temp and
# joins the pairwise links with `and`.
def emit_chained(cx: Cx, operands: List[Tree.Node], ops: List[String], source: String) -> Result[Done]
  left = try emit_in(cx, List.first(operands), source)
  current = left.cx
  prev_code = left.code
  prev_type = left.type
  links: List[String] = []
  middle = operands.drop(1).take(operands.size - 2)
  op_index = 0
  for operand in middle
    next_done = try emit_in(current, operand, source)
    temp = "py_t#{next_done.cx.next_temp}"
    current = next_done.cx.with(
      next_temp: next_done.cx.next_temp + 1,
      pre: next_done.cx.pre.push("#{temp} = #{next_done.code}"),
    )

    links = links.push(try emit_link(prev_code, prev_type, temp, next_done.type, List.first(ops.drop(op_index))))
    prev_code = temp
    prev_type = next_done.type
    op_index += 1
  end

  right = try emit_in(current, List.last(operands), source)
  links = links.push(try emit_link(prev_code, prev_type, right.code, right.type, List.first(ops.drop(op_index))))
  ok(Done(code: links.join(" and "), type: "Bool", cx: right.cx))
end

def emit_binary(cx: Cx, left_node: Tree.Node, op: String, right_node: Tree.Node, source: String) -> Result[Done]
  left = try emit_in(cx, left_node, source)
  right = try emit_in(left.cx, right_node, source)
  code = try emit_link(left.code, left.type, right.code, right.type, op)
  ok(Done(code: code, type: "Bool", cx: right.cx))
end

def emit_link(lcode: String, ltype: String, rcode: String, rtype: String, op: String) -> Result[String]
  case op
    "==" -> emit_eq(lcode, ltype, rcode, rtype, true)
    "!=" -> emit_eq(lcode, ltype, rcode, rtype, false)
    "<" -> emit_order(lcode, ltype, rcode, rtype, op)
    "<=" -> emit_order(lcode, ltype, rcode, rtype, op)
    ">" -> emit_order(lcode, ltype, rcode, rtype, op)
    ">=" -> emit_order(lcode, ltype, rcode, rtype, op)
    "in" -> emit_membership(lcode, ltype, rcode, rtype, false)
    "not in" -> emit_membership(lcode, ltype, rcode, rtype, true)
    "is" -> emit_identity(lcode, ltype, rcode, rtype, false)
    "is not" -> emit_identity(lcode, ltype, rcode, rtype, true)
    _ -> error("agc-py: unknown comparison #{op}")
  end
end

def emit_eq(lcode: String, ltype: String, rcode: String, rtype: String, equal: Bool) -> Result[String]
  return emit_none_eq(lcode, ltype, rcode, rtype, equal) if ltype == "none" or rtype == "none"

  if is_num?(ltype) and is_num?(rtype)
    pair = numeric_pair(lcode, ltype, rcode, rtype)
    return ok("#{pair[0]} #{eq_op(equal)} #{pair[1]}")
  end

  return ok(eq_answer(equal, false)) if comparable_fold?(ltype, rtype)

  ok("#{lcode} #{eq_op(equal)} #{rcode}")
end

# Two concrete, non-optional, different types are never equal: `1 == "a"`
# is `false` without consulting the backend. `Optional` and `Unknown` stay
# verbal (an `Optional` may hold either side at run time).
def comparable_fold?(ltype: String, rtype: String) -> Bool
  return false if ltype == "Unknown" or rtype == "Unknown"

  return false if base_of(ltype) == "Optional" or base_of(rtype) == "Optional"

  return false if ltype == "List" or rtype == "List" or ltype == "Map" or rtype == "Map"

  ltype != rtype
end

def eq_op(equal: Bool) -> String
  if equal
    "=="
  else
    "!="
  end
end

# `None` only meets `Optional` (or another `None`): against a concrete type
# the answer is already known, so `1 == None` is `false`, never a guess.
def emit_none_eq(lcode: String, ltype: String, rcode: String, rtype: String, equal: Bool) -> Result[String]
  return ok(eq_answer(equal, true)) if ltype == "none" and rtype == "none"

  other_code = lcode
  other_type = ltype
  none_first = true
  if rtype != "none"
    other_code = rcode
    other_type = rtype
    none_first = false
  end

  if base_of(other_type) == "Optional" or other_type == "Unknown"
    return ok("none #{eq_op(equal)} #{other_code}") if none_first

    return ok("#{other_code} #{eq_op(equal)} none")
  end

  ok(eq_answer(equal, false))
end

def eq_answer(equal: Bool, same: Bool) -> String
  decide = equal == same
  if decide
    "true"
  else
    "false"
  end
end

def emit_order(lcode: String, ltype: String, rcode: String, rtype: String, op: String) -> Result[String]
  return ok("#{lcode}.compare(#{rcode}) #{op} 0") if ltype == "String" and rtype == "String"

  if is_num?(ltype) and is_num?(rtype)
    pair = numeric_pair(lcode, ltype, rcode, rtype)
    return ok("#{pair[0]} #{op} #{pair[1]}")
  end

  error("PY-OPERATOR: ordering needs two numbers or two strings, found #{ltype} and #{rtype}")
end

# Mixed `Int` / `Float` meets at `Float`: the `Int` side converts once.
def numeric_pair(lcode: String, ltype: String, rcode: String, rtype: String) -> List[String]
  return ["#{lcode}.to_f", rcode] if ltype == "Int" and rtype == "Float"

  return [lcode, "#{rcode}.to_f"] if ltype == "Float" and rtype == "Int"

  [lcode, rcode]
end

def emit_membership(lcode: String, ltype: String, rcode: String, rtype: String, negate: Bool) -> Result[String]
  base = base_of(rtype)
  test: String = ""
  if base == "List" or base == "String"
    test = "#{rcode}.include?(#{lcode})"
  else
    if base == "Map"
      test = "#{rcode}.key?(#{lcode})"
    else
      return error("PY-OPERATOR: `in` needs a list, string or map on the right, found #{rtype}")
    end
  end

  return ok("!(#{test})") if negate

  ok(test)
end

# Only `None` may follow `is`: anything else names `==`, and a bare temp
# reads through `.none?`.
def emit_identity(lcode: String, ltype: String, rcode: String, rtype: String, negate: Bool) -> Result[String]
  return ok(eq_answer(!negate, true)) if ltype == "none" and rtype == "none"

  if ltype == "none" or rtype == "none"
    other = lcode
    if rtype != "none"
      other = rcode
    end

    return ok("!#{other}.none?") if negate

    return ok("#{other}.none?")
  end

  error("PY-IS: `is` only tests None (`x is None`); compare values with ==")
end

def emit_sum(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  groups = split_operands(node.children, "add_op")
  acc = try emit_group_nodes(cx, List.first(groups), source)
  index = 0
  for op_node in split_operators(node.children, "add_op")
    right = try emit_group_nodes(acc.cx, List.first(groups.drop(index + 1)), source)
    op = Tree.text(op_node, source)
    folded = try fold_add(acc.code, acc.type, op, right.code, right.type)
    acc = Done(code: List.first(folded), type: List.first(folded.drop(1)), cx: right.cx)
    index += 1
  end

  ok(acc)
end

def emit_term(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  groups = split_operands(node.children, "mul_op")
  acc = try emit_group_nodes(cx, List.first(groups), source)
  index = 0
  for op_node in split_operators(node.children, "mul_op")
    right = try emit_group_nodes(acc.cx, List.first(groups.drop(index + 1)), source)
    op = Tree.text(op_node, source)
    folded = try fold_mul(acc.code, acc.type, op, right.code, right.type)
    acc = Done(code: List.first(folded), type: List.first(folded.drop(1)), cx: right.cx)
    index += 1
  end

  ok(acc)
end

def fold_add(lcode: String, ltype: String, op: String, rcode: String, rtype: String) -> Result[List[String]]
  if op == "+"
    return ok(["#{lcode} + #{rcode}", "Int"]) if ltype == "Int" and rtype == "Int"

    return ok(["#{lcode} + #{rcode}", "Float"]) if ltype == "Float" and rtype == "Float"

    return ok(["#{lcode} + #{rcode}", "String"]) if ltype == "String" and rtype == "String"

    if base_of(ltype) == "List" and base_of(rtype) == "List"
      return ok(["#{lcode} + #{rcode}", ltype]) if ltype == rtype

      return ok(["#{lcode} + #{rcode}", "List"])
    end

    if ltype != "Unknown" and rtype != "Unknown"
      return error("PY-TYPE-MISMATCH: `+` needs two numbers, two strings or two lists, found #{ltype} and #{rtype}")
    end

    return error("PY-OPERATOR: `+` has no form for #{ltype} and #{rtype}")
  end

  return ok(["#{lcode} - #{rcode}", "Int"]) if ltype == "Int" and rtype == "Int"

  return ok(["#{lcode} - #{rcode}", "Float"]) if ltype == "Float" and rtype == "Float"

  if ltype != "Unknown" and rtype != "Unknown"
    return error("PY-TYPE-MISMATCH: `-` needs two numbers, found #{ltype} and #{rtype}")
  end

  error("PY-OPERATOR: `-` has no form for #{ltype} and #{rtype}")
end

def fold_mul(lcode: String, ltype: String, op: String, rcode: String, rtype: String) -> Result[List[String]]
  case op
    "*" -> fold_star(lcode, ltype, rcode, rtype)
    "/" -> fold_slash(lcode, ltype, rcode, rtype)
    "//" -> fold_floor(lcode, ltype, rcode, rtype)
    "%" -> fold_percent(lcode, ltype, rcode, rtype)
    _ -> error("agc-py: unknown operator #{op}")
  end
end

# Only `s * n` repeats (`List * Int` has no backend form, and neither does
# `n * s`): a same-typed `*` otherwise needs two numbers.
def fold_star(lcode: String, ltype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["#{lcode} * #{rcode}", "Int"]) if ltype == "Int" and rtype == "Int"

  return ok(["#{lcode} * #{rcode}", "Float"]) if ltype == "Float" and rtype == "Float"

  return ok(["#{lcode} * #{rcode}", "String"]) if ltype == "String" and rtype == "Int"

  if ltype == "Int" and rtype == "String"
    return error("PY-OPERATOR: repeat as `s * n`, not `n * s` = help: write #{rcode} * #{lcode}")
  end

  if base_of(ltype) == "List" and rtype == "Int"
    return error("PY-OPERATOR: lists do not repeat with `*` = help: build the list with a loop")
  end

  if ltype != "Unknown" and rtype != "Unknown"
    return error("PY-TYPE-MISMATCH: `*` needs two numbers or `s * n`, found #{ltype} and #{rtype}")
  end

  error("PY-OPERATOR: `*` has no form for #{ltype} and #{rtype}")
end

# `/` on two `Int` would truncate in the backend, while Python divides
# exactly: two ints convert once and divide as floats.
def fold_slash(lcode: String, ltype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["#{lcode}.to_f / #{rcode}.to_f", "Float"]) if ltype == "Int" and rtype == "Int"

  return ok(["#{lcode} / #{rcode}", "Float"]) if ltype == "Float" and rtype == "Float"

  if ltype != "Unknown" and rtype != "Unknown"
    return error("PY-TYPE-MISMATCH: `/` needs two numbers, found #{ltype} and #{rtype}")
  end

  error("PY-OPERATOR: `/` has no form for #{ltype} and #{rtype}")
end

def fold_floor(lcode: String, ltype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["py_floor_div(#{lcode}, #{rcode})", "Int"]) if ltype == "Int" and rtype == "Int"

  return error("PY-OPERATOR: `//` is int-only = help: use `//` on two ints") if ltype == "Float" or rtype == "Float"

  if ltype != "Unknown" and rtype != "Unknown"
    return error("PY-TYPE-MISMATCH: `//` needs two ints, found #{ltype} and #{rtype}")
  end

  error("PY-OPERATOR: `//` has no form for #{ltype} and #{rtype}")
end

def fold_percent(lcode: String, ltype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["py_pymod(#{lcode}, #{rcode})", "Int"]) if ltype == "Int" and rtype == "Int"

  if ltype == "Float" or rtype == "Float"
    return error("PY-OPERATOR: `%` is int-only with Python signs = help: use `%` on two ints")
  end

  if ltype != "Unknown" and rtype != "Unknown"
    return error("PY-TYPE-MISMATCH: `%` needs two ints, found #{ltype} and #{rtype}")
  end

  error("PY-OPERATOR: `%` has no form for #{ltype} and #{rtype}")
end

def emit_minus(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  parts = unary_parts(node)
  inner = try emit_group_nodes(cx, parts["base"], source)
  if !parts["power"].empty?
    powered = try emit_pow_base(inner, List.first(parts["power"]), source, inner.cx)
    return ok(Done(code: "-(#{powered.code})", type: powered.type, cx: powered.cx))
  end

  return emit_unary_mismatch(inner.type) if inner.type != "Int" and inner.type != "Float"

  ok(Done(code: "-#{inner.code}", type: inner.type, cx: inner.cx))
end

def emit_plus(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  parts = unary_parts(node)
  return error("PY-OPERATOR: `+` cannot carry `**`; write the power without the sign") if !parts["power"].empty?

  inner = try emit_group_nodes(cx, parts["base"], source)
  return emit_unary_mismatch(inner.type) if inner.type != "Int" and inner.type != "Float"

  ok(inner)
end

def emit_unary_mismatch(found: String) -> Result[Done]
  error("PY-OPERATOR: unary `+`/`-` needs a number, found #{found}")
end

# Splits a `minus` / `plus` node into its base operand nodes and an optional
# trailing `power` node (`-2**3` negates the whole power).
def unary_parts(node: Tree.Node) -> Map[String, List[Tree.Node]]
  kids = node.children
  last = List.last(kids)
  return {"base": kids.take(kids.size - 1), "power": [last]} if kids.size > 1 and last.rule == "power"

  {"base": kids, "power": []}
end

# Emits operand nodes: one node directly, or a head plus postfix trailers
# (`f(a)[0].b`), or a base plus a trailing `power` (`2**3`).
def emit_group_nodes(cx: Cx, nodes: List[Tree.Node], source: String) -> Result[Done]
  return error("agc-py: missing operand") if nodes.empty?

  return emit_in(cx, List.first(nodes), source) if nodes.size == 1

  last = List.last(nodes)
  if last.rule == "power"
    base = try emit_group_nodes(cx, nodes.take(nodes.size - 1), source)
    return emit_pow_base(base, last, source, base.cx)
  end

  emit_chain(cx, nodes, source)
end

def emit_chain(cx: Cx, nodes: List[Tree.Node], source: String) -> Result[Done]
  head = try emit_in(cx, List.first(nodes), source)
  recv = head
  attrs: List[String] = []
  current = head.cx
  for trailer in nodes.drop(1)
    case trailer.rule
      "attr_trailer" ->
        text = Tree.text(trailer, source)
        attrs = attrs.push(text.slice(1, text.length - 1))
      "call_trailer" ->
        called = try emit_trailer_call(current, recv, attrs, trailer, source)
        recv = Done(code: called.code, type: called.type, cx: called.cx)
        attrs = []
        current = called.cx
      "index" ->
        if !attrs.empty?
          recv = Done(code: "#{recv.code}.#{attrs.join(".")}", type: "Unknown", cx: current)
          attrs = []
        end

        sub = try emit_subscript(current, recv, trailer, source)
        recv = sub
        current = sub.cx
      _ -> return error("agc-py: unexpected trailer #{trailer.rule}")
    end
  end

  return ok(Done(code: recv.code, type: recv.type, cx: current)) if attrs.empty?

  emit_trailing_attr(Done(code: recv.code, type: recv.type, cx: current), attrs)
end

# A bare `x.method` without a call cannot be a value (there are no function
# values); anything else reads as a dotted path for phase 4.
def emit_trailing_attr(recv: Done, attrs: List[String]) -> Result[Done]
  if attrs.size == 1 and known_method?(List.first(attrs))
    return error(
      "PY-OUT-OF-SUBSET: method `#{List.first(attrs)}` needs a call = help: write `x.#{List.first(attrs)}(...)`",
    )
  end

  if attrs.size == 1 and MUTATORS.include?(List.first(attrs))
    return error("PY-MUTATION: `#{List.first(attrs)}` mutates; rebind instead = help: write `xs = xs.push(x)`")
  end

  ok(Done(code: "#{recv.code}.#{attrs.join(".")}", type: "Unknown", cx: recv.cx))
end

def known_method?(name: String) -> Bool
  (
    name == "get" or
    name == "strip" or
    name == "split" or
    name == "join" or
    name == "replace" or
    name == "lower" or
    name == "upper" or
    name == "startswith" or
    name == "endswith"
  )
end

def emit_group(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  return error("agc-py: empty group") if node.children.empty?

  inner = try emit_in(cx, List.first(node.children), source)
  ok(Done(code: "(#{inner.code})", type: inner.type, cx: inner.cx))
end

# Right-associative `**`: the exponent of an outer power may itself carry a
# power (`2**3**4` is `2**(3**4)`). Only `Int ** Int` exists; a statically
# negative exponent is `PY-OPERATOR` (it would be a float in Python).
def emit_pow_base(base: Done, power: Tree.Node, source: String, cx: Cx) -> Result[Done]
  exp = try emit_pow_exp(base.cx, power.children, source)
  if base.type != "Int" or exp.type != "Int"
    return error("PY-OPERATOR: `**` needs an int base and an int exponent, found #{base.type} and #{exp.type}")
  end

  if static_neg?(power.children)
    return error(
      "PY-OPERATOR: negative `**` exponents halt; Python would return a float = help: use a positive exponent",
    )
  end

  ok(Done(code: "#{base.code}.pow(#{exp.code})", type: "Int", cx: exp.cx))
end

def emit_pow_exp(cx: Cx, nodes: List[Tree.Node], source: String) -> Result[Done]
  return error("agc-py: `**` without an exponent") if nodes.empty?

  last = List.last(nodes)
  if nodes.size > 1 and last.rule == "power"
    base = try emit_group_nodes(cx, nodes.take(nodes.size - 1), source)
    return emit_pow_base(base, last, source, base.cx)
  end

  emit_group_nodes(cx, nodes, source)
end

def static_neg?(nodes: List[Tree.Node]) -> Bool
  return false if nodes.size != 1

  neg_single?(List.first(nodes))
end

def neg_single?(node: Tree.Node) -> Bool
  return true if node.rule == "minus"

  return neg_single?(List.first(node.children)) if node.rule == "group" and node.children.size == 1

  return neg_single?(List.first(node.children)) if node.rule == "plus" and node.children.size == 1

  neg_chain?(node)
end

def neg_chain?(node: Tree.Node) -> Bool
  return node.children.size == 1 and neg_single?(List.first(node.children)) if single_chain?(node.rule)

  return node.children.size == 1 and neg_operand?(List.first(node.children)) if node.rule == "term"

  false
end

def neg_operand?(node: Tree.Node) -> Bool
  node.rule == "minus" or (node.rule == "group" and node.children.size == 1 and neg_single?(List.first(node.children)))
end

def emit_number(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  raw = Tree.text(node, source)
  return ok(Done(code: normalize_float(raw), type: "Float", cx: cx)) if is_float_text?(raw)

  ok(Done(code: normalize_int(raw), type: "Int", cx: cx))
end

def is_float_text?(raw: String) -> Bool
  chars = raw.split("")
  return false if chars.size > 1 and chars[0] == "0" and prefix_char?(chars[1])

  return true if chars.include?(".") or chars.include?("e") or chars.include?("E")

  false
end

# Underscores after a base prefix are Python-only (`0x_FF`): Agentica wants
# `0xFF`, while plain `1_000` and `00` already check, so only that strip runs.
def normalize_int(raw: String) -> String
  chars = raw.split("")
  return chars.select { |ch| ch != "_" }.join("") if chars.size > 2 and prefix_char?(chars[1]) and chars[2] == "_"

  raw
end

def prefix_char?(ch: String) -> Bool = ch == "x" or ch == "X" or ch == "o" or ch == "O" or ch == "b" or ch == "B"

# Agentica floats need digits around the dot (`1.` and `.5` do not check):
# underscores go, `.5` gains a `0`, and `1.` / `1.e10` gain one after it.
def normalize_float(raw: String) -> String
  stripped = raw.split("").select { |ch| ch != "_" }.join("")
  with_lead = stripped
  if with_lead.start_with?(".")
    with_lead = "0#{with_lead}"
  end

  parts = split_exponent(with_lead)
  mantissa = List.first(parts)
  if mantissa.end_with?(".")
    mantissa = "#{mantissa}0"
  end

  return mantissa if List.first(parts.drop(1)) == ""

  "#{mantissa}#{List.first(parts.drop(1))}#{List.first(parts.drop(2))}"
end

# Splits mantissa, the `e`/`E` separator (kept verbatim: `1E+10` stays
# uppercase) and the exponent; an empty separator means a plain decimal.
def split_exponent(text: String) -> List[String]
  chars = text.split("")
  index = 0
  for ch in chars
    return [chars.take(index).join(""), ch, chars.drop(index + 1).join("")] if ch == "e" or ch == "E"

    index += 1
  end

  [text, "", ""]
end

def emit_boolean(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  return ok(Done(code: "true", type: "Bool", cx: cx)) if Tree.text(node, source) == "True"

  ok(Done(code: "false", type: "Bool", cx: cx))
end

def emit_name(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  name = Tree.text(node, source)
  found = cx.scope.get(name, "")
  if found == ""
    return ok(Done(code: name, type: "Unknown", cx: cx)) if BUILTINS.include?(name)

    return error("PY-NAME-UNKNOWN: unknown name `#{name}` = help: bind it first, for example `#{name}: int = ...`")
  end

  ok(Done(code: name, type: found, cx: cx))
end

# A dotted path that is not a call: a known method name on a bound value
# needs its call (`s.strip` is not a value); anything else stays verbatim
# for phase 4, like module paths do.
def emit_attr(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  full = Tree.text(node, source)
  parts = full.split(".")
  return ok(Done(code: full, type: "Unknown", cx: cx)) if parts.size < 2

  method = List.last(parts)
  root = List.first(parts)
  if (
    parts.size == 2 and
    (known_method?(method) or MUTATORS.include?(method) or method == "sort" or method == "reverse")
  )
    found = cx.scope.get(root, "")
    if found != "" and found != "Unknown" and !BUILTINS.include?(root)
      if MUTATORS.include?(method) or method == "sort" or method == "reverse"
        return error(
          "PY-MUTATION: `#{method}` mutates; rebinding is the subset spelling = help: write `xs = xs.push(x)`",
        )
      end

      return error("PY-OUT-OF-SUBSET: method `#{method}` needs a call = help: write `x.#{method}(...)`")
    end
  end

  ok(Done(code: full, type: "Unknown", cx: cx))
end

def emit_list(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  items: List[Done] = []
  current = cx
  for child in node.children
    next_done = try emit_in(current, child, source)
    items = items.push(next_done)
    current = next_done.cx
  end

  ok(Done(code: "[#{items.map { |item| item.code }.join(", ")}]", type: list_type(items), cx: current))
end

def list_type(items: List[Done]) -> String
  return "List" if items.empty?

  first = List.first(items).type
  for item in items.drop(1)
    return "List" if item.type != first or item.type == "Unknown"
  end

  "List[#{first}]"
end

def emit_dict(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  entries: List[String] = []
  current = cx
  key_type = ""
  value_type = ""
  uniform = true
  for child in node.children
    pair = try emit_dict_entry(current, child, source)
    key = List.first(pair)
    value = List.first(pair.drop(1))
    current = value.cx
    entries = entries.push("#{key.code}: #{value.code}")
    if key_type == ""
      key_type = key.type
      value_type = value.type
    else
      if key.type != key_type or value.type != value_type
        uniform = false
      end
    end
  end

  type = "Map"
  if !node.children.empty? and uniform and key_type != "Unknown" and value_type != "Unknown"
    type = "Map[#{key_type}, #{value_type}]"
  end

  ok(Done(code: "{#{entries.join(", ")}}", type: type, cx: current))
end

def emit_dict_entry(cx: Cx, node: Tree.Node, source: String) -> Result[List[Done]]
  return error("agc-py: dict entry without key and value") if node.children.size != 2

  key = try emit_in(cx, List.first(node.children), source)
  value = try emit_in(key.cx, List.first(node.children.drop(1)), source)
  ok([key, value])
end

# Strings decode the whole Python set (`\a \b \f \v \0 \xNN \uNNNN \n \r \t
# \\ \" \'`), then re-encode minimally: only `\" \\ \n \r \t` escape and
# every other character (including `'`) stays raw in the UTF-8 source.
# `r"..."` skips decoding; `f"..."` interpolates holes, `{{` / `}}` spell
# braces, and a hole holding a `"` hoists to a temp (nested quotes do not
# check inside interpolation).
def emit_text(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  raw = Tree.text(node, source)
  info = string_info(raw)
  holes = Tree.find_all(node, "hole")
  if Map.get(info, "raw", "") == "true"
    return ok(Done(code: "\"#{encode_raw(inner_text(raw, info))}\"", type: "String", cx: cx))
  end

  if Map.get(info, "prefix", "") == "f" or Map.get(info, "prefix", "") == "F"
    if holes.empty?
      decoded = try decode_f_gap(inner_text(raw, info))
      return ok(Done(code: "\"#{encode_cooked(decoded)}\"", type: "String", cx: cx))
    end

    return emit_f_string(cx, node, source, raw, info, holes)
  end

  decoded = try decode_escapes(inner_text(raw, info))
  ok(Done(code: "\"#{encode_cooked(decoded)}\"", type: "String", cx: cx))
end

def string_info(raw: String) -> Map[String, String]
  first = raw.slice(0, 1)
  prefix = ""
  if first == "f" or first == "F" or first == "r" or first == "R"
    prefix = first
  end

  rest = raw
  if prefix != ""
    rest = raw.slice(1, raw.length - 1)
  end

  quote = "\""
  if rest.start_with?("\"\"\"") or rest.start_with?("'''")
    quote = rest.slice(0, 3)
  else
    quote = rest.slice(0, 1)
  end

  is_raw = "false"
  if prefix == "r" or prefix == "R"
    is_raw = "true"
  end

  {"prefix": prefix, "quote": quote, "raw": is_raw}
end

def inner_text(raw: String, info: Map[String, String]) -> String
  start = 0
  if Map.get(info, "prefix", "") != ""
    start = 1
  end

  quote_len = Map.get(info, "quote", "\"").length
  raw.slice(start + quote_len, raw.length - start - quote_len * 2)
end

def emit_f_string(
  cx: Cx,
  node: Tree.Node,
  source: String,
  raw: String,
  info: Map[String, String],
  holes: List[Tree.Node],
) -> Result[Done]
  inner = inner_text(raw, info)
  prefix_len = 0
  if Map.get(info, "prefix", "") != ""
    prefix_len = 1
  end

  inner_start = node.start + prefix_len + Map.get(info, "quote", "\"").length
  parts: List[String] = []
  current = cx
  cursor = 0
  for hole in holes
    gap = inner.slice(cursor, hole.start - inner_start - cursor)
    parts = parts.push(encode_cooked(try decode_f_gap(gap)))
    hole_done = try emit_only_child(current, hole, source)
    current = hole_done.cx
    if hole_done.code.include?("\"")
      temp = "py_t#{current.next_temp}"
      current = current.with(next_temp: current.next_temp + 1, pre: current.pre.push("#{temp} = #{hole_done.code}"))
      parts = parts.push("#" + "{" + temp + "}")
    else
      parts = parts.push("#" + "{" + hole_done.code + "}")
    end

    cursor = hole.stop - inner_start
  end

  tail = inner.slice(cursor, inner.length - cursor)
  parts = parts.push(encode_cooked(try decode_f_gap(tail)))
  ok(Done(code: "\"#{parts.join("")}\"", type: "String", cx: current))
end

def decode_f_gap(gap: String) -> Result[String]
  out = ""
  chars = gap.split("")
  index = 0
  while index < chars.size
    if chars[index] == "{" and index + 1 < chars.size and chars[index + 1] == "{"
      out = "#{out}{"
      index += 2
    else
      if chars[index] == "}" and index + 1 < chars.size and chars[index + 1] == "}"
        out = "#{out}}"
        index += 2
      else
        if chars[index] == "\\"
          decoded = try decode_one(chars, index)
          out = "#{out}#{decoded.text}"
          index = decoded.next
        else
          out = "#{out}#{chars[index]}"
          index += 1
        end
      end
    end
  end

  ok(out)
end

def decode_escapes(inner: String) -> Result[String]
  out = ""
  chars = inner.split("")
  index = 0
  while index < chars.size
    if chars[index] == "\\"
      decoded = try decode_one(chars, index)
      out = "#{out}#{decoded.text}"
      index = decoded.next
    else
      out = "#{out}#{chars[index]}"
      index += 1
    end
  end

  ok(out)
end

def decode_one(chars: List[String], at: Int) -> Result[Decoded]
  return error("agc-py: trailing backslash in a string") if at + 1 >= chars.size

  next_ch = chars[at + 1]
  case next_ch
    "n" -> ok(Decoded(text: "\n", next: at + 2))
    "r" -> ok(Decoded(text: "\r", next: at + 2))
    "t" -> ok(Decoded(text: "\t", next: at + 2))
    "\\" -> ok(Decoded(text: "\\", next: at + 2))
    "\"" -> ok(Decoded(text: "\"", next: at + 2))
    "'" -> ok(Decoded(text: "'", next: at + 2))
    "0" -> ok(Decoded(text: String.from_code(0), next: at + 2))
    "a" -> ok(Decoded(text: String.from_code(7), next: at + 2))
    "b" -> ok(Decoded(text: String.from_code(8), next: at + 2))
    "f" -> ok(Decoded(text: String.from_code(12), next: at + 2))
    "v" -> ok(Decoded(text: String.from_code(11), next: at + 2))
    "x" -> decode_hex(chars, at + 2, 2)
    "u" -> decode_hex(chars, at + 2, 4)
    _ -> error("agc-py: unknown escape `\\#{next_ch}`")
  end
end

def decode_hex(chars: List[String], at: Int, count: Int) -> Result[Decoded]
  return error("agc-py: short escape") if at + count > chars.size

  value = 0
  index = 0
  while index < count
    digit = try hex_val(chars[at + index])
    value = value * 16 + digit
    index += 1
  end

  ok(Decoded(text: String.from_code(value), next: at + count))
end

def hex_val(ch: String) -> Result[Int]
  code = ch.code
  return ok(code - 48) if code >= 48 and code <= 57

  return ok(code - 87) if code >= 97 and code <= 102

  return ok(code - 55) if code >= 65 and code <= 70

  error("agc-py: bad hex digit `#{ch}`")
end

def encode_cooked(decoded: String) -> String
  out = ""
  for ch in decoded.split("")
    case ch
      "\"" -> out = "#{out}\\\""
      "\\" -> out = "#{out}\\\\"
      "\n" -> out = "#{out}\\n"
      "\r" -> out = "#{out}\\r"
      "\t" -> out = "#{out}\\t"
      _ -> out = "#{out}#{ch}"
    end
  end

  out
end

# Raw strings keep backslashes literally, so only the framing needs work:
# backslashes double, newlines spell `\n` (triple-quoted raws span lines),
# and `'` stays raw like every other non-framing character.
def encode_raw(inner: String) -> String
  out = ""
  for ch in inner.split("")
    case ch
      "\\" -> out = "#{out}\\\\"
      "\"" -> out = "#{out}\\\""
      "\n" -> out = "#{out}\\n"
      "\r" -> out = "#{out}\\r"
      "\t" -> out = "#{out}\\t"
      _ -> out = "#{out}#{ch}"
    end
  end

  out
end

def emit_subscript(cx: Cx, recv: Done, index: Tree.Node, source: String) -> Result[Done]
  slice = Tree.first_child(index, "slice")
  case slice
    some(node) -> emit_slice(cx, recv, index, node, source)
    none -> emit_index(cx, recv, index, source)
  end
end

def emit_index(cx: Cx, recv: Done, index: Tree.Node, source: String) -> Result[Done]
  kids = index.children
  return error("agc-py: index without a bound") if kids.empty?

  bound_node = List.first(kids)
  neg = index_negation(bound_node)
  base = base_of(recv.type)
  return emit_string_index(cx, recv, bound_node, neg, source) if base == "String"

  if base == "List"
    case neg
      some(inner) -> emit_neg_list_index(cx, recv, inner, source)
      none ->
        bound = try emit_in(cx, bound_node, source)
        ok(Done(code: "#{recv.code}[#{bound.code}]", type: elem_of(recv.type), cx: bound.cx))
    end
  else
    if base == "Map" or base == "Unknown"
      bound = try emit_in(cx, bound_node, source)
      return ok(Done(code: "#{recv.code}[#{bound.code}]", type: elem_of(recv.type), cx: bound.cx))
    end

    error("PY-OPERATOR: cannot index #{recv.type}")
  end
end

# The container binds before the bound evaluates, so `xs[-f(0)]` keeps
# Python's evaluation order (container, then index) in the preamble.
def emit_string_index(
  cx: Cx,
  recv: Done,
  bound_node: Tree.Node,
  neg: Optional[List[Tree.Node]],
  source: String,
) -> Result[Done]
  case neg
    some(inner) ->
      temp = "py_t#{cx.next_temp}"
      bound_cx = cx.with(next_temp: cx.next_temp + 1, pre: cx.pre.push("#{temp} = #{recv.code}"))
      key = try emit_group_nodes(bound_cx, inner, source)
      ok(Done(code: "#{temp}.at(#{temp}.length - (#{key.code}))", type: "String", cx: key.cx))
    none ->
      bound = try emit_in(cx, bound_node, source)
      ok(Done(code: "#{recv.code}.at(#{bound.code})", type: "String", cx: bound.cx))
  end
end

def emit_neg_list_index(cx: Cx, recv: Done, inner: List[Tree.Node], source: String) -> Result[Done]
  temp = "py_t#{cx.next_temp}"
  bound_cx = cx.with(next_temp: cx.next_temp + 1, pre: cx.pre.push("#{temp} = #{recv.code}"))
  key = try emit_group_nodes(bound_cx, inner, source)
  code = "#{temp}[#{temp}.size - (#{key.code})]"
  ok(Done(code: code, type: elem_of(recv.type), cx: key.cx))
end

# Slices clamp dynamic bounds to `[0, len]` at run time (`a > b` and an
# out-of-range `b` give empty, never a halt). The grammar already refuses
# static negative bounds and steps, so everything arriving here lowers.
def emit_slice(cx: Cx, recv: Done, index: Tree.Node, slice: Tree.Node, source: String) -> Result[Done]
  base = base_of(recv.type)
  if base != "List" and base != "String"
    return error("PY-OPERATOR: slices need a list or a string, found #{recv.type}")
  end

  helper = "py_slice_list"
  if base == "String"
    helper = "py_slice_str"
  end

  upper = slice_upper(slice)
  case upper
    some(hi_node) -> emit_full_slice(cx, recv, index, hi_node, helper, source)
    none -> emit_open_slice(cx, recv, index, helper, source)
  end
end

def emit_full_slice(
  cx: Cx,
  recv: Done,
  index: Tree.Node,
  hi_node: Tree.Node,
  helper: String,
  source: String,
) -> Result[Done]
  lo_code = "0"
  current = cx
  lower = slice_lower(index)
  case lower
    some(lo_node) ->
      lo = try emit_in(current, lo_node, source)
      lo_code = lo.code
      current = lo.cx
    none -> current = cx
  end

  hi = try emit_in(current, hi_node, source)
  ok(Done(code: "#{helper}(#{recv.code}, #{lo_code}, #{hi.code})", type: slice_type(recv, helper), cx: hi.cx))
end

# A missing upper bound reads the container length, so the container binds
# to a temp first: `xs[a:]` evaluates `xs` a single time.
def emit_open_slice(cx: Cx, recv: Done, index: Tree.Node, helper: String, source: String) -> Result[Done]
  temp = "py_t#{cx.next_temp}"
  current = cx.with(next_temp: cx.next_temp + 1, pre: cx.pre.push("#{temp} = #{recv.code}"))
  lo_code = "0"
  lower = slice_lower(index)
  case lower
    some(lo_node) ->
      lo = try emit_in(current, lo_node, source)
      lo_code = lo.code
      current = lo.cx
    none -> current = current
  end

  len_call = "#{temp}.size"
  if helper == "py_slice_str"
    len_call = "#{temp}.length"
  end

  ok(Done(code: "#{helper}(#{temp}, #{lo_code}, #{len_call})", type: slice_type(recv, helper), cx: current))
end

def slice_lower(index: Tree.Node) -> Optional[Tree.Node]
  for child in index.children
    return some(child) if child.rule != "slice"
  end

  none
end

def slice_upper(slice: Tree.Node) -> Optional[Tree.Node]
  found = Tree.first_child(slice, "cond_expr")
  case found
    some(node) -> some(node)
    none -> none
  end
end

def slice_type(recv: Done, helper: String) -> String
  return "String" if helper == "py_slice_str"

  recv.type
end

# The top expression of an index bound, unwrapped through single-child
# chain nodes: a `minus` on top means a from-the-end index.
def index_negation(node: Tree.Node) -> Optional[List[Tree.Node]]
  current = node
  while single_chain?(current.rule) and current.children.size == 1
    current = List.first(current.children)
  end

  if current.rule == "term" and current.children.size == 1
    inner = List.first(current.children)
    return some(inner.children) if inner.rule == "minus"

    return none
  end

  return some(current.children) if current.rule == "minus"

  none
end

def single_chain?(rule: String) -> Bool
  rule == "cond_expr" or rule == "or_expr" or rule == "and_expr" or rule == "comparison" or rule == "sum"
end

def emit_call(cx: Cx, node: Tree.Node, source: String) -> Result[Done]
  return error("agc-py: call without a head") if node.children.empty?

  head = List.first(node.children)
  args = try emit_call_args(cx, node.children.drop(1), source)
  emit_head_call(args.cx, head, args, source)
end

def emit_call_args(cx: Cx, nodes: List[Tree.Node], source: String) -> Result[CallArgs]
  pos: List[Done] = []
  raws: List[Tree.Node] = []
  kw: List[Kw] = []
  current = cx
  for child in nodes
    if child.rule == "kwarg"
      kw = kw.push(try emit_kwarg(current, child, source))
      current = List.last(kw).value.cx
    else
      if child.rule == "arg" and !child.children.empty? and List.last(child.children).rule == "kwarg"
        kw = kw.push(try emit_kwarg(current, List.last(child.children), source))
        current = List.last(kw).value.cx
      else
        value = try emit_in(current, arg_expr(child), source)
        pos = pos.push(value)
        raws = raws.push(child)
        current = value.cx
      end
    end
  end

  ok(CallArgs(pos: pos, raws: raws, kw: kw, cx: current))
end

def emit_kwarg(cx: Cx, node: Tree.Node, source: String) -> Result[Kw]
  name_node = Tree.first_child(node, "name")
  case name_node
    some(found) ->
      value = try emit_in(cx, List.last(node.children), source)
      ok(Kw(name: Tree.text(found, source), value: value))
    none -> error("agc-py: kwarg without a name")
  end
end

# The value node of a positional argument: a bare expression, or the inner
# expression of an `arg` wrapper.
def arg_expr(node: Tree.Node) -> Tree.Node
  return List.last(node.children) if node.rule == "arg" and !node.children.empty?

  node
end

# Spells `#{` without writing it in a literal (the compiler reads `"#{"`
# as the start of an interpolation, not two characters).
def open_interp() -> String = "#" + "{"

def emit_head_call(cx: Cx, head: Tree.Node, args: CallArgs, source: String) -> Result[Done]
  return emit_attr_call(cx, head, args, source) if head.rule == "attr"

  return error("agc-py: cannot call #{head.rule}") if head.rule != "name"

  name = Tree.text(head, source)
  mapped = try emit_builtin(name, args, source)
  case mapped
    some(done) -> ok(done)
    none -> emit_user_call(name, args)
  end
end

# A dotted call head splits at the last dot: `d.get` maps as a method on the
# bound name, while a deeper path (or an unknown root) stays verbatim for
# phase 4 — which is also how module paths like `math.sqrt` survive this
# phase untouched.
def emit_attr_call(cx: Cx, head: Tree.Node, args: CallArgs, source: String) -> Result[Done]
  full = Tree.text(head, source)
  parts = full.split(".")
  method = List.last(parts)
  recv_text = parts.take(parts.size - 1).join(".")
  recv: Done = Done(code: recv_text, type: "Unknown", cx: cx)
  if !recv_text.include?(".")
    found = cx.scope.get(recv_text, "")
    if found == ""
      return error(
        "PY-NAME-UNKNOWN: unknown name `#{recv_text}` = help: bind it first, for example `#{recv_text}: int = ...`",
      )
    end

    recv = Done(code: recv_text, type: found, cx: cx)
  end

  return emit_method_named(recv, method, args) if known_method?(method) or MUTATORS.include?(method)

  return emit_method_named(recv, method, args) if method == "sort" or method == "reverse"

  if base_of(recv.type) == "Unknown"
    return ok(Done(code: "#{full}(#{format_args(args)})", type: "Unknown", cx: args.cx))
  end

  error("PY-OUT-OF-SUBSET: no mapping for `#{recv.type}.#{method}` = help: only the section 5 surface maps")
end

def emit_trailer_call(cx: Cx, recv: Done, attrs: List[String], trailer: Tree.Node, source: String) -> Result[Done]
  args = try emit_call_args(cx, trailer.children, source)
  return error("PY-OPERATOR: calling a value as a function = help: call a named function instead") if attrs.empty?

  target = recv
  if attrs.size > 1
    target = Done(code: "#{recv.code}.#{attrs.take(attrs.size - 1).join(".")}", type: "Unknown", cx: args.cx)
  end

  emit_method_named(target.with(cx: args.cx), List.last(attrs), args)
end

def emit_method_named(recv: Done, method: String, args: CallArgs) -> Result[Done]
  if MUTATORS.include?(method)
    return error("PY-MUTATION: `#{method}` mutates; rebinding is the subset spelling = help: write `xs = xs.push(x)`")
  end

  if method == "sort"
    return error(
      "PY-MUTATION: `.sort()` sorts in place; rebinding is the subset spelling = help: write `xs = sorted(xs)`",
    )
  end

  if method == "reverse" and base_of(recv.type) != "Unknown"
    return error(
      "PY-MUTATION: `.reverse()` reverses in place; rebinding is the subset spelling = help: write `xs = reversed(xs)`",
    )
  end

  case method
    "get" -> emit_map_get(recv, args)
    "strip" -> emit_str_method(recv, args, "strip", 0)
    "split" -> emit_str_method(recv, args, "split", 1)
    "join" -> emit_join(recv, args)
    "replace" -> emit_str_method(recv, args, "replace", 2)
    "lower" -> emit_str_method(recv, args, "downcase", 0)
    "upper" -> emit_str_method(recv, args, "upcase", 0)
    "startswith" -> emit_str_method(recv, args, "start_with?", 1)
    "endswith" -> emit_str_method(recv, args, "end_with?", 1)
    _ -> emit_unknown_method(recv, method, args)
  end
end

def emit_unknown_method(recv: Done, method: String, args: CallArgs) -> Result[Done]
  if base_of(recv.type) == "Unknown"
    return ok(Done(code: "#{recv.code}.#{method}(#{format_args(args)})", type: "Unknown", cx: args.cx))
  end

  error("PY-OUT-OF-SUBSET: no mapping for `#{recv.type}.#{method}` = help: only the section 5 surface maps")
end

def emit_map_get(recv: Done, args: CallArgs) -> Result[Done]
  if base_of(recv.type) != "Map" and base_of(recv.type) != "Unknown"
    return error("PY-OPERATOR: `.get` needs a map, found #{recv.type}")
  end

  if !args.kw.empty?
    return error("PY-OUT-OF-SUBSET: `d.get` takes no keyword args = help: write `d.get(k)` or `d.get(k, default)`")
  end

  if args.pos.size == 1
    return ok(Done(code: "#{recv.code}.get(#{List.first(args.pos).code})", type: "Optional", cx: args.cx))
  end

  if args.pos.size == 2
    first = List.first(args.pos)
    second = List.first(args.pos.drop(1))
    return ok(Done(code: "#{recv.code}.get(#{first.code}, #{second.code})", type: elem_of(recv.type), cx: args.cx))
  end

  error("PY-OUT-OF-SUBSET: `d.get` takes 1 or 2 args = help: write `d.get(k)` or `d.get(k, default)`")
end

def emit_str_method(recv: Done, args: CallArgs, target: String, arity: Int) -> Result[Done]
  if base_of(recv.type) != "String" and base_of(recv.type) != "Unknown"
    return error("PY-OUT-OF-SUBSET: string method on #{recv.type} = help: only the section 5 string surface maps")
  end

  return error("PY-OUT-OF-SUBSET: string methods take no keyword args = help: pass positionals") if !args.kw.empty?

  return error("PY-OPERATOR: string method takes #{arity} args, found #{args.pos.size}") if args.pos.size != arity

  codes = args.pos.map { |arg| arg.code }.join(", ")
  ok(Done(code: "#{recv.code}.#{target}(#{codes})", type: method_type(target), cx: args.cx))
end

def method_type(target: String) -> String
  return "Bool" if target == "start_with?" or target == "end_with?"

  return "List[String]" if target == "split"

  "String"
end

# `"sep".join(xs)` flips: the separator becomes the argument and the list
# the receiver, matching the backend `xs.join(sep)`.
def emit_join(recv: Done, args: CallArgs) -> Result[Done]
  if base_of(recv.type) != "String" and base_of(recv.type) != "Unknown"
    return error("PY-OUT-OF-SUBSET: `join` needs a string separator, found #{recv.type}")
  end

  return error("PY-OUT-OF-SUBSET: `join` takes no keyword args = help: write `\"sep\".join(xs)`") if !args.kw.empty?

  return error("PY-OPERATOR: `join` takes 1 arg, found #{args.pos.size}") if args.pos.size != 1

  ok(Done(code: "#{List.first(args.pos).code}.join(#{recv.code})", type: "String", cx: args.cx))
end

def format_args(args: CallArgs) -> String
  parts = args.pos.map { |arg| arg.code }
  for kw in args.kw
    parts = parts.push("#{kw.name}: #{kw.value.code}")
  end

  parts.join(", ")
end

def emit_user_call(name: String, args: CallArgs) -> Result[Done]
  ok(Done(code: "#{name}(#{format_args(args)})", type: "Unknown", cx: args.cx))
end

# Builtins map by the section 5 table; anything else is `none` here so the
# caller falls through to a plain user call.
def emit_builtin(name: String, args: CallArgs, source: String) -> Result[Optional[Done]]
  case name
    "print" -> ok(some(try emit_print(args)))
    "len" -> ok(some(try emit_len(args)))
    "range" -> ok(some(try emit_range(args)))
    "int" -> ok(some(try emit_int(args)))
    "float" -> ok(some(try emit_float(args)))
    "str" -> ok(some(try emit_str(args)))
    "bool" -> ok(some(try emit_bool(args)))
    "sorted" -> ok(some(try emit_sorted(args)))
    "sum" -> ok(some(try emit_sum_call(args)))
    "min" -> ok(some(try emit_min_max(args, "min")))
    "max" -> ok(some(try emit_min_max(args, "max")))
    "abs" -> ok(some(try emit_abs(args)))
    "round" -> ok(some(try emit_round(args)))
    "chr" -> ok(some(try emit_chr(args)))
    "ord" -> ok(some(try emit_ord(args)))
    "reversed" -> ok(some(try emit_reversed(args)))
    "all" -> ok(some(try emit_all_any(args, "all", "all?")))
    "any" -> ok(some(try emit_all_any(args, "any", "any?")))
    "map" -> ok(some(try emit_map_filter(args, "map", source)))
    "filter" -> ok(some(try emit_map_filter(args, "filter", source)))
    "enumerate" -> error("PY-OUT-OF-SUBSET: `enumerate` needs a loop counter = help: count with an index in phase 3c")
    _ -> ok(none)
  end
end

# `print(a, b)` joins with single spaces through one backend arg; an argument
# holding a `"` hoists to a temp because quotes cannot nest in interpolation.
def emit_print(args: CallArgs) -> Result[Done]
  if !args.kw.empty?
    return error("PY-OUT-OF-SUBSET: `print` kwargs (`sep=`/`end=`/`file=`) are excluded = help: join the parts first")
  end

  return ok(Done(code: "puts(\"\")", type: "Void", cx: args.cx)) if args.pos.empty?

  parts: List[String] = []
  current = args.cx
  for arg in args.pos
    if arg.code.include?("\"")
      temp = "py_t#{current.next_temp}"
      current = current.with(next_temp: current.next_temp + 1, pre: current.pre.push("#{temp} = #{arg.code}"))
      parts = parts.push("#" + "{" + temp + "}")
    else
      parts = parts.push("#" + "{" + arg.code + "}")
    end
  end

  ok(Done(code: "puts(\"#{parts.join(" ")}\")", type: "Void", cx: current))
end

def emit_len(args: CallArgs) -> Result[Done]
  return error("PY-OPERATOR: `len` takes exactly 1 arg") if args.pos.size != 1 or !args.kw.empty?

  item = List.first(args.pos)
  base = base_of(item.type)
  if base == "List" or base == "Map" or base == "Range"
    return ok(Done(code: "#{item.code}.size", type: "Int", cx: args.cx))
  end

  return ok(Done(code: "#{item.code}.length", type: "Int", cx: args.cx)) if base == "String"

  error("PY-OPERATOR: `len` has no form for #{item.type} = help: use a list, string, map or range")
end

def emit_range(args: CallArgs) -> Result[Done]
  if !args.kw.empty?
    return error("PY-OUT-OF-SUBSET: `range` takes no keyword args = help: write `range(a)` or `range(a, b)`")
  end

  return ok(Done(code: "0...#{List.first(args.pos).code}", type: "Range", cx: args.cx)) if args.pos.size == 1

  if args.pos.size == 2
    first = List.first(args.pos)
    second = List.first(args.pos.drop(1))
    return ok(Done(code: "#{first.code}...#{second.code}", type: "Range", cx: args.cx))
  end

  return error("PY-OPERATOR: `range` needs 1 or 2 args") if args.pos.empty?

  error("PY-OUT-OF-SUBSET: 3-arg `range(a, b, step)` desugars to a `while` = help: step in phase 3c")
end

def emit_int(args: CallArgs) -> Result[Done]
  return error("PY-OPERATOR: `int` takes exactly 1 arg") if args.pos.size != 1 or !args.kw.empty?

  item = List.first(args.pos)
  if item.type == "String" or item.type == "Float"
    return ok(Done(code: "#{item.code}.to_i", type: "Result[Int]", cx: args.cx))
  end

  return error("PY-TYPE-MISMATCH: `int` converts str or float, found #{item.type}") if item.type != "Unknown"

  error("PY-OPERATOR: `int` has no form for #{item.type}")
end

def emit_float(args: CallArgs) -> Result[Done]
  return error("PY-OPERATOR: `float` takes exactly 1 arg") if args.pos.size != 1 or !args.kw.empty?

  item = List.first(args.pos)
  if item.type == "String" or item.type == "Int"
    return ok(Done(code: "#{item.code}.to_f", type: "Result[Float]", cx: args.cx))
  end

  return error("PY-TYPE-MISMATCH: `float` converts str or int, found #{item.type}") if item.type != "Unknown"

  error("PY-OPERATOR: `float` has no form for #{item.type}")
end

def emit_str(args: CallArgs) -> Result[Done]
  return error("PY-OPERATOR: `str` takes no keyword args") if !args.kw.empty?

  return ok(Done(code: "\"\"", type: "String", cx: args.cx)) if args.pos.empty?

  return error("PY-OPERATOR: `str` takes at most 1 arg") if args.pos.size > 1

  item = List.first(args.pos)
  if item.code.include?("\"")
    temp = "py_t#{args.cx.next_temp}"
    current = args.cx.with(next_temp: args.cx.next_temp + 1, pre: args.cx.pre.push("#{temp} = #{item.code}"))
    return ok(Done(code: "\"" + open_interp() + temp + "}\"", type: "String", cx: current))
  end

  ok(Done(code: "\"" + open_interp() + item.code + "}\"", type: "String", cx: args.cx))
end

def emit_bool(args: CallArgs) -> Result[Done]
  return error("PY-OPERATOR: `bool` takes exactly 1 arg") if args.pos.size != 1 or !args.kw.empty?

  item = List.first(args.pos)
  return ok(Done(code: item.code, type: "Bool", cx: args.cx)) if item.type == "Bool"

  if item.type != "Unknown"
    return error(
      "PY-TYPE-MISMATCH: `bool` keeps Bool only, found #{item.type} = help: there is no truthiness to convert",
    )
  end

  error("PY-OPERATOR: `bool` has no form for #{item.type}")
end

def emit_sorted(args: CallArgs) -> Result[Done]
  sole = try sole_arg(args, "sorted")
  return error("PY-OPERATOR: `sorted` needs a list, found #{sole.type}") if base_of(sole.type) != "List"

  ok(Done(code: "#{sole.code}.sort", type: sole.type, cx: args.cx))
end

def emit_sum_call(args: CallArgs) -> Result[Done]
  sole = try sole_arg(args, "sum")
  return error("PY-OPERATOR: `sum` needs a list, found #{sole.type}") if base_of(sole.type) != "List"

  ok(Done(code: "#{sole.code}.sum", type: elem_of(sole.type), cx: args.cx))
end

def emit_min_max(args: CallArgs, op: String) -> Result[Done]
  sole = try sole_arg(args, op)
  return error("PY-OPERATOR: `#{op}` needs a list, found #{sole.type}") if base_of(sole.type) != "List"

  elem = elem_of(sole.type)
  type = "Optional"
  if elem != "Unknown"
    type = "Optional[#{elem}]"
  end

  ok(Done(code: "#{sole.code}.#{op}", type: type, cx: args.cx))
end

def emit_abs(args: CallArgs) -> Result[Done]
  sole = try sole_arg(args, "abs")
  return ok(Done(code: "#{sole.code}.abs", type: sole.type, cx: args.cx)) if sole.type == "Int" or sole.type == "Float"

  return error("PY-TYPE-MISMATCH: `abs` needs a number, found #{sole.type}") if sole.type != "Unknown"

  error("PY-OPERATOR: `abs` has no form for #{sole.type}")
end

# `round` is `Float`-only: `Int` has no `round`, an int needs no rounding.
def emit_round(args: CallArgs) -> Result[Done]
  sole = try sole_arg(args, "round")
  return ok(Done(code: "#{sole.code}.round", type: "Int", cx: args.cx)) if sole.type == "Float"

  return error("PY-OPERATOR: `round` takes a Float; an int needs no rounding") if sole.type == "Int"

  return error("PY-TYPE-MISMATCH: `round` needs a float, found #{sole.type}") if sole.type != "Unknown"

  error("PY-OPERATOR: `round` has no form for #{sole.type}")
end

def emit_chr(args: CallArgs) -> Result[Done]
  sole = try sole_arg(args, "chr")
  return emit_conv_mismatch("chr", "int", sole.type) if sole.type != "Int"

  ok(Done(code: "String.from_code(#{sole.code})", type: "String", cx: args.cx))
end

def emit_ord(args: CallArgs) -> Result[Done]
  sole = try sole_arg(args, "ord")
  return emit_conv_mismatch("ord", "str", sole.type) if sole.type != "String"

  ok(Done(code: "#{sole.code}.code", type: "Int", cx: args.cx))
end

def emit_conv_mismatch(name: String, want: String, found: String) -> Result[Done]
  return error("PY-TYPE-MISMATCH: `#{name}` converts #{want}, found #{found}") if found != "Unknown"

  error("PY-OPERATOR: `#{name}` has no form for #{found}")
end

def emit_reversed(args: CallArgs) -> Result[Done]
  sole = try sole_arg(args, "reversed")
  return error("PY-OPERATOR: `reversed` needs a list, found #{sole.type}") if base_of(sole.type) != "List"

  ok(Done(code: "#{sole.code}.reverse", type: sole.type, cx: args.cx))
end

def emit_all_any(args: CallArgs, name: String, target: String) -> Result[Done]
  sole = try sole_arg(args, name)
  return error("PY-OPERATOR: `#{name}` needs a list, found #{sole.type}") if base_of(sole.type) != "List"

  temp = "py_x#{args.cx.next_temp}"
  current = args.cx.with(next_temp: args.cx.next_temp + 1)
  ok(Done(code: "#{sole.code}.#{target} { |#{temp}| #{temp} }", type: "Bool", cx: current))
end

# `map` / `filter` take a named function and lower through a block, since
# functions are not values: `map(f, xs)` is `xs.map { |t| f(t) }`.
def emit_map_filter(args: CallArgs, target: String, source: String) -> Result[Done]
  return error("PY-OPERATOR: `#{target}` takes a function and a list") if args.pos.size != 2 or !args.kw.empty?

  func = List.first(args.pos)
  xs = List.first(args.pos.drop(1))
  return error("PY-OPERATOR: `#{target}` needs a list, found #{xs.type}") if base_of(xs.type) != "List"

  head = bare_name(List.first(args.raws), source)
  case head
    some(name) ->
      if BUILTINS.include?(name)
        return error(
          "PY-OPERATOR: `#{target}` takes a user function; `#{name}` needs its own lowering = help: wrap `#{name}` in a def first",
        )
      end

      temp = "py_x#{args.cx.next_temp}"
      current = args.cx.with(next_temp: args.cx.next_temp + 1)
      method = "map"
      if target == "filter"
        method = "filter"
      end

      ok(Done(code: "#{xs.code}.#{method} { |#{temp}| #{name}(#{temp}) }", type: "List", cx: current))
    none -> error("PY-OPERATOR: `#{target}` takes a named function, found `#{func.code}`")
  end
end

# A bare function name through single-child chain nodes (`arg` wrappers and
# parens included); anything else is not a callable value.
def bare_name(node: Tree.Node, source: String) -> Optional[String]
  current = node
  if current.rule == "arg" and !current.children.empty?
    current = List.last(current.children)
  end

  while single_chain?(current.rule) and current.children.size == 1
    current = List.first(current.children)
  end

  if current.rule == "term" and current.children.size == 1
    current = List.first(current.children)
  end

  return bare_name(List.first(current.children), source) if current.rule == "group" and current.children.size == 1

  return some(Tree.text(current, source)) if current.rule == "name"

  none
end

def sole_arg(args: CallArgs, name: String) -> Result[Done]
  return error("PY-OPERATOR: `#{name}` takes exactly 1 arg") if args.pos.size != 1 or !args.kw.empty?

  ok(List.first(args.pos))
end

# Splits `term`-style children into operand groups at operator nodes.
def split_operands(children: List[Tree.Node], op_rule: String) -> List[List[Tree.Node]]
  groups: List[List[Tree.Node]] = [[]]
  for child in children
    if child.rule == op_rule
      groups = groups.push([])
    else
      groups = groups.take(groups.size - 1).push(List.last(groups).push(child))
    end
  end

  groups
end

def split_operators(children: List[Tree.Node], op_rule: String) -> List[Tree.Node]
  children.select { |child| child.rule == op_rule }
end

# The head segment of a (possibly generic) type: `List` of `List[Int]`,
# `Optional` of `Optional[X]`, the name itself otherwise.
def base_of(type: String) -> String
  index = type.index_of("[")
  case index
    some(at) -> type.slice(0, at)
    none -> type
  end
end

def is_num?(type: String) -> Bool = type == "Int" or type == "Float"

# The element of `List[E]` / `Map[K, V]` (the value side), else `Unknown`.
def elem_of(type: String) -> String
  open = type.index_of("[")
  close = type.index_of("]")
  case open
    some(at) ->
      case close
        some(stop) ->
          inner = type.slice(at + 1, stop - at - 1)
          if base_of(type) == "Map"
            comma = inner.index_of(",")
            case comma
              some(found) -> inner.slice(found + 1, inner.length - found - 1).strip
              none -> "Unknown"
            end
          else
            inner.strip
          end

        none -> "Unknown"
      end

    none -> "Unknown"
  end
end
