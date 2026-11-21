## Binding-statement codegen for `agc-py` phase 3c lane A: annotated and plain
## assignment, augmented assignment, type aliases, expression statements and
## `return`.
##
## Each emitter takes one statement parse node, the source it was sliced from
## and the lane context, and answers an `EmitCtx.StmtRes`: emitted lines plus
## the scope and temp supply after the statement, or a spanned refusal. Lane A
## has no nested bodies, so emitters take no pre-emitted strings; expression
## values go through `EmitExpr.emit` and their `py_tN` temps shift past
## `ctx.next_temp`, so sequential statements never collide.
##
## The lowering follows `SUBSET.md` sections 1, 2 and 4: the first binding
## carries its annotation (`x: int = 0`), rebinding keeps the type and any
## change is `PY-TYPE-MISMATCH`; `x += e` is sugar for `x = x OP e` (`//=`
## and `**=` have no spelling and refuse); a bare `x: T` binds with no code;
## `type Alias = T` emits the backend alias; an expression statement emits
## and discards its value; `return` carries a value only under a non-`Void`
## return and stands bare only under `-> None`.
## Probed on agentica 0.35.0: `type Alias = Int` checks at the top level and
## reads as an annotation (including `List` and `Optional` targets), while a
## lowercase alias name is `PARSE-UNEXPECTED-TOKEN` and an in-`def` alias is
## `PARSE-TOP-LEVEL-STATEMENT`, so both refuse with `PY-OUT-OF-SUBSET`. Bare
## `return` checks under `-> Void` while `return none` is
## `CHECK-TYPE-MISMATCH`, so an explicit `return None` under `-> None` emits
## a bare `return`.

import EmitCtx from "./emit_ctx"
import EmitExpr from "./emit_expr"
import Tree from "../../src/tree"

## Emits `x: T = e`: declares `x` with the mapped annotation and checks the
## value against it (`PY-TYPE-MISMATCH` on change). A bare `x: T` binds with
## no code; a second binding in the same scope is `PY-DUPLICATE-BINDING`.
def emit_annotated(ctx: EmitCtx.EmitCtx, node: Tree.Node, source: String) -> EmitCtx.StmtRes
  if node.rule != "annotated"
    return EmitCtx.refuse("PY-OUT-OF-SUBSET", "lane A: expected an annotated binding, found #{node.rule}", none, node)
  end

  case need_name(node)
    error(e) -> refuse_split(node.start, node.stop, e)
    ok(name_node) -> emit_annotated_named(ctx, node, name_node, source)
  end
end

## Emits `x = e`: rebinds a declared name, keeping its type. Binding an
## undeclared name is `PY-UNTYPED-NAME`; changing the type is
## `PY-TYPE-MISMATCH`.
def emit_assigned(ctx: EmitCtx.EmitCtx, node: Tree.Node, source: String) -> EmitCtx.StmtRes
  if node.rule != "assign"
    return EmitCtx.refuse("PY-OUT-OF-SUBSET", "lane A: expected an assignment, found #{node.rule}", none, node)
  end

  case need_name(node)
    error(e) -> refuse_split(node.start, node.stop, e)
    ok(name_node) -> emit_assigned_named(ctx, node, name_node, source)
  end
end

## Emits `x OP= e` as the sugar `x = x OP e`: the right side goes through
## `EmitExpr.emit` with the same operator rules, then the result must keep
## `x`'s type (`PY-TYPE-MISMATCH` otherwise). `//=` and `**=` have no
## spelling and refuse with `PY-OUT-OF-SUBSET`.
def emit_augassigned(ctx: EmitCtx.EmitCtx, node: Tree.Node, source: String) -> EmitCtx.StmtRes
  if node.rule != "augmented_assign"
    return EmitCtx.refuse(
      "PY-OUT-OF-SUBSET",
      "lane A: expected an augmented assignment, found #{node.rule}",
      none,
      node,
    )
  end

  case need_name(node)
    error(e) -> refuse_split(node.start, node.stop, e)
    ok(name_node) -> emit_augassigned_named(ctx, node, name_node, source)
  end
end

## Emits `type Alias = T`: the backend alias at the top level, refused with
## `PY-OUT-OF-SUBSET` inside a `def` or for a lowercase name (both probed).
## The alias resolves later annotations through the scope.
def emit_alias(ctx: EmitCtx.EmitCtx, node: Tree.Node, source: String) -> EmitCtx.StmtRes
  if node.rule != "type_alias"
    return EmitCtx.refuse("PY-OUT-OF-SUBSET", "lane A: expected a type alias, found #{node.rule}", none, node)
  end

  case need_name(node)
    error(e) -> refuse_split(node.start, node.stop, e)
    ok(name_node) -> emit_alias_named(ctx, node, name_node, source)
  end
end

## Emits an expression statement (`expr_stmt`, `call_stmt`, or a bare
## expression node): the value emits through `EmitExpr.emit` and its code
## stands alone, discarded.
def emit_expr_stmt(ctx: EmitCtx.EmitCtx, node: Tree.Node, source: String) -> EmitCtx.StmtRes
  case stmt_value_node(node)
    error(e) -> refuse_split(node.start, node.stop, e)
    ok(expr) ->
      case EmitExpr.emit(expr, source, ctx.scope)
        error(e) -> refuse_split(expr.start, expr.stop, e)
        ok(out) ->
          shifted = shift_out(out, ctx.next_temp)
          EmitCtx.StmtRes.Ok(
            EmitCtx.StmtOut(
              code: shifted.pre + [shifted.code],
              scope: ctx.scope,
              next_temp: ctx.next_temp + shifted.used,
            ),
          )
      end
  end
end

## Emits `return e` (or bare `return`): a value only under a non-`Void`
## return, a bare `return` only under `None`/`Void`, else
## `PY-TYPE-MISMATCH`. An explicit `return None` under `-> None` folds to a
## bare `return`, the only shape the backend checks there. A `return`
## outside a `def` is `PY-OUT-OF-SUBSET`.
def emit_return(ctx: EmitCtx.EmitCtx, node: Tree.Node, source: String) -> EmitCtx.StmtRes
  if node.rule != "return_stmt"
    return EmitCtx.refuse("PY-OUT-OF-SUBSET", "lane A: expected a return, found #{node.rule}", none, node)
  end

  if ctx.func_ret == ""
    return EmitCtx.refuse("PY-OUT-OF-SUBSET", "return outside a `def`", some("move it into a `def`"), node)
  end

  case Tree.first_child(node, "cond_expr")
    none -> emit_bare_return(ctx, node)
    some(expr) -> emit_value_return(ctx, node, expr, source)
  end
end

private

# One annotation occurrence: the raw text plus the span it covers.
struct AnnText
  text: String
  start: Int
  stop: Int
end

# One emitted value with its `py_tN` temps shifted past `base`: how many
# temps the value used, so the caller advances the supply by the same.
struct Shifted
  code: String
  pre: List[String]
  used: Int
end

# One parsed emitter error: the `PY-*` code plus its message and help.
struct ErrParts
  code: String
  message: String
  help: Optional[String]
end

# The binding target of a lane A statement: its first direct `name` child.
def need_name(node: Tree.Node) -> Result[Tree.Node]
  case Tree.first_child(node, "name")
    some(found) -> ok(found)
    none -> error("PY-OUT-OF-SUBSET: binding without a name")
  end
end

# The annotation of a lane A statement: its first direct `annotation` child.
def need_ann(node: Tree.Node, source: String) -> Result[AnnText]
  case Tree.first_child(node, "annotation")
    some(found) -> ok(AnnText(text: Tree.text(found, source), start: found.start, stop: found.stop))
    none -> error("PY-OUT-OF-SUBSET: binding without an annotation")
  end
end

def emit_annotated_named(
  ctx: EmitCtx.EmitCtx,
  node: Tree.Node,
  name_node: Tree.Node,
  source: String,
) -> EmitCtx.StmtRes
  case need_ann(node, source)
    error(e) -> refuse_split(node.start, node.stop, e)
    ok(ann) ->
      case map_ann_scoped(ann.text, ctx.scope)
        error(e) -> refuse_split(ann.start, ann.stop, e)
        ok(want) ->
          name = Tree.text(name_node, source)
          if ctx.scope.get(name, "") != ""
            EmitCtx.refuse(
              "PY-DUPLICATE-BINDING",
              "duplicate binding of `#{name}` in the same scope",
              some("rename one of the bindings; a function may shadow a module-level name"),
              name_node,
            )
          else
            case Tree.first_child(node, "cond_expr")
              none ->
                EmitCtx.StmtRes.Ok(
                  EmitCtx.StmtOut(code: [], scope: ctx.scope.put(name, want), next_temp: ctx.next_temp),
                )
              some(expr) -> emit_value_binding(ctx, name, want, expr, source, true)
            end
          end
      end
  end
end

def emit_assigned_named(ctx: EmitCtx.EmitCtx, node: Tree.Node, name_node: Tree.Node, source: String) -> EmitCtx.StmtRes
  name = Tree.text(name_node, source)
  want = ctx.scope.get(name, "")
  if want == ""
    EmitCtx.refuse_at(
      "PY-UNTYPED-NAME",
      "first binding of `#{name}` needs an annotation",
      some("write `#{name}: <type> = ...` for the first binding"),
      name_node.start,
      name_node.stop,
    )
  else
    case Tree.first_child(node, "cond_expr")
      none -> EmitCtx.refuse("PY-OUT-OF-SUBSET", "assignment without a value", none, node)
      some(expr) -> emit_value_binding(ctx, name, want, expr, source, false)
    end
  end
end

def emit_augassigned_named(
  ctx: EmitCtx.EmitCtx,
  node: Tree.Node,
  name_node: Tree.Node,
  source: String,
) -> EmitCtx.StmtRes
  name = Tree.text(name_node, source)
  want = ctx.scope.get(name, "")
  if want == ""
    EmitCtx.refuse_at(
      "PY-UNTYPED-NAME",
      "first binding of `#{name}` needs an annotation",
      some("write `#{name}: <type> = ...` for the first binding"),
      name_node.start,
      name_node.stop,
    )
  else
    case Tree.first_child(node, "aug_op")
      none -> EmitCtx.refuse("PY-OUT-OF-SUBSET", "augmented assignment without an operator", none, node)
      some(op) -> emit_augassigned_op(ctx, node, name, want, op, source)
    end
  end
end

def emit_augassigned_op(
  ctx: EmitCtx.EmitCtx,
  node: Tree.Node,
  name: String,
  want: String,
  op: Tree.Node,
  source: String,
) -> EmitCtx.StmtRes
  case aug_binop(Tree.text(op, source))
    error(e) -> refuse_split(op.start, op.stop, e)
    ok(binop) ->
      case Tree.first_child(node, "cond_expr")
        none -> EmitCtx.refuse("PY-OUT-OF-SUBSET", "augmented assignment without a value", none, node)
        some(expr) -> emit_augassigned_value(ctx, name, want, op, binop, expr, source)
      end
  end
end

def emit_augassigned_value(
  ctx: EmitCtx.EmitCtx,
  name: String,
  want: String,
  op: Tree.Node,
  binop: String,
  expr: Tree.Node,
  source: String,
) -> EmitCtx.StmtRes
  case EmitExpr.emit(expr, source, ctx.scope)
    error(e) -> refuse_split(expr.start, expr.stop, e)
    ok(out) ->
      shifted = shift_out(out, ctx.next_temp)
      case aug_combine(name, want, binop, shifted.code, out.type)
        error(e) -> refuse_split(op.start, op.stop, e)
        ok(pair) -> emit_augassigned_line(ctx, name, want, op, expr, shifted, pair)
      end
  end
end

def emit_augassigned_line(
  ctx: EmitCtx.EmitCtx,
  name: String,
  want: String,
  op: Tree.Node,
  expr: Tree.Node,
  shifted: Shifted,
  pair: List[String],
) -> EmitCtx.StmtRes
  got = List.first(pair.drop(1))
  if types_match?(want, got)
    EmitCtx.StmtRes.Ok(
      EmitCtx.StmtOut(
        code: shifted.pre + ["#{name} = #{List.first(pair)}"],
        scope: ctx.scope,
        next_temp: ctx.next_temp + shifted.used,
      ),
    )
  else
    EmitCtx.refuse_at(
      "PY-TYPE-MISMATCH",
      "augmented `#{Tree.text(op, ctx.source)}` on `#{name}: #{want}` gives #{got}",
      some("convert the value explicitly or fix the annotation"),
      expr.start,
      expr.stop,
    )
  end
end

def emit_alias_named(ctx: EmitCtx.EmitCtx, node: Tree.Node, name_node: Tree.Node, source: String) -> EmitCtx.StmtRes
  case need_ann(node, source)
    error(e) -> refuse_split(node.start, node.stop, e)
    ok(ann) ->
      case map_ann_scoped(ann.text, ctx.scope)
        error(e) -> refuse_split(ann.start, ann.stop, e)
        ok(want) -> emit_alias_line(ctx, node, name_node, want)
      end
  end
end

def emit_alias_line(ctx: EmitCtx.EmitCtx, node: Tree.Node, name_node: Tree.Node, want: String) -> EmitCtx.StmtRes
  name = Tree.text(name_node, ctx.source)
  # TODO(3d): the backend only checks `type` aliases at the top level
  # (probed PARSE-TOP-LEVEL-STATEMENT on agentica 0.35.0); revisit if local
  # aliases ever check.
  if ctx.func_ret != ""
    EmitCtx.refuse(
      "PY-OUT-OF-SUBSET",
      "type alias `#{name}` inside a `def` has no backend form",
      some("move it to the top level"),
      node,
    )
  else
    # TODO(3d): the backend only checks capitalized alias names (probed
    # PARSE-UNEXPECTED-TOKEN on agentica 0.35.0); revisit if lowercase
    # aliases ever check.
    if capitalized?(name)
      EmitCtx.StmtRes.Ok(
        EmitCtx.StmtOut(code: ["type #{name} = #{want}"], scope: ctx.scope.put(name, want), next_temp: ctx.next_temp),
      )
    else
      EmitCtx.refuse_at(
        "PY-OUT-OF-SUBSET",
        "type alias `#{name}` needs a capitalized name for the backend",
        some("name it with a leading capital, for example `type Alias = ...`"),
        name_node.start,
        name_node.stop,
      )
    end
  end
end

# Emits `name: Want = <value>` for a declaration or `name = <value>` for a
# rebinding: the value emits through `EmitExpr.emit` and must keep the
# declared type.
def emit_value_binding(
  ctx: EmitCtx.EmitCtx,
  name: String,
  want: String,
  expr: Tree.Node,
  source: String,
  decl: Bool,
) -> EmitCtx.StmtRes
  case EmitExpr.emit(expr, source, ctx.scope)
    error(e) -> refuse_split(expr.start, expr.stop, e)
    ok(out) ->
      if types_match?(want, out.type)
        shifted = shift_out(out, ctx.next_temp)
        line = "#{name} = #{shifted.code}"
        if decl
          line = "#{name}: #{want} = #{shifted.code}"
        end

        EmitCtx.StmtRes.Ok(
          EmitCtx.StmtOut(
            code: shifted.pre + [line],
            scope: ctx.scope.put(name, want),
            next_temp: ctx.next_temp + shifted.used,
          ),
        )
      else
        EmitCtx.refuse_at(
          "PY-TYPE-MISMATCH",
          "cannot bind #{out.type} to `#{name}: #{want}`",
          some("convert the value explicitly or fix the annotation"),
          expr.start,
          expr.stop,
        )
      end
  end
end

# A bare `return` only checks under a `Void` return; anything else is
# `PY-TYPE-MISMATCH`.
def emit_bare_return(ctx: EmitCtx.EmitCtx, node: Tree.Node) -> EmitCtx.StmtRes
  if is_void_return?(ctx.func_ret)
    EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: ["return"], scope: ctx.scope, next_temp: ctx.next_temp))
  else
    EmitCtx.refuse(
      "PY-TYPE-MISMATCH",
      "bare `return` under `-> #{ctx.func_ret}` returns nothing",
      some("return a value of the declared type"),
      node,
    )
  end
end

def emit_value_return(ctx: EmitCtx.EmitCtx, node: Tree.Node, expr: Tree.Node, source: String) -> EmitCtx.StmtRes
  if is_none_expr(expr) and is_void_return?(ctx.func_ret)
    EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: ["return"], scope: ctx.scope, next_temp: ctx.next_temp))
  else
    if is_void_return?(ctx.func_ret)
      EmitCtx.refuse_at(
        "PY-TYPE-MISMATCH",
        "cannot return a value under `-> #{ctx.func_ret}`",
        some("drop the value or annotate a return type"),
        expr.start,
        expr.stop,
      )
    else
      case map_ann_scoped(ctx.func_ret, ctx.scope)
        error(e) -> refuse_split(node.start, node.stop, e)
        ok(want) ->
          case EmitExpr.emit(expr, source, ctx.scope)
            error(e) -> refuse_split(expr.start, expr.stop, e)
            ok(out) -> emit_return_line(ctx, node, expr, want, out)
          end
      end
    end
  end
end

def emit_return_line(
  ctx: EmitCtx.EmitCtx,
  node: Tree.Node,
  expr: Tree.Node,
  want: String,
  out: EmitExpr.Out,
) -> EmitCtx.StmtRes
  if types_match?(want, out.type)
    shifted = shift_out(out, ctx.next_temp)
    EmitCtx.StmtRes.Ok(
      EmitCtx.StmtOut(
        code: shifted.pre + ["return #{shifted.code}"],
        scope: ctx.scope,
        next_temp: ctx.next_temp + shifted.used,
      ),
    )
  else
    EmitCtx.refuse_at(
      "PY-TYPE-MISMATCH",
      "cannot return #{out.type} under `-> #{ctx.func_ret}`",
      some("convert the value explicitly or fix the return annotation"),
      expr.start,
      expr.stop,
    )
  end
end

def is_void_return?(func_ret: String) -> Bool = func_ret == "Void" or func_ret == "None" or func_ret == "none"

# The value of an expression statement: the `cond_expr` of an `expr_stmt`,
# the `call` of a `call_stmt`, or the node itself when the coordinator
# already narrowed it to an expression.
def stmt_value_node(node: Tree.Node) -> Result[Tree.Node]
  if node.rule == "expr_stmt"
    case Tree.first_child(node, "cond_expr")
      some(found) -> ok(found)
      none -> error("PY-OUT-OF-SUBSET: expression statement without a value")
    end
  else
    if node.rule == "call_stmt"
      case Tree.first_child(node, "call")
        some(found) -> ok(found)
        none -> error("PY-OUT-OF-SUBSET: call statement without a call")
      end
    else
      ok(node)
    end
  end
end

# Whether `node` spells a bare `None`: a single-child chain down to
# `none_lit` (unary signs excluded, so `-None` never folds).
def is_none_expr(node: Tree.Node) -> Bool
  cur = node
  while cur.children.size == 1 and expr_chain?(cur.rule)
    cur = List.first(cur.children)
  end

  cur.rule == "none_lit"
end

def expr_chain?(rule: String) -> Bool = single_chain?(rule) or rule == "term" or rule == "group"

# The single-child expression chain between `cond_expr` and an operand.
def single_chain?(rule: String) -> Bool
  rule == "cond_expr" or rule == "or_expr" or rule == "and_expr" or rule == "comparison" or rule == "sum"
end

# Maps an augmented operator to its plain sugar; `//=` and `**=` have no
# spelling in the subset.
def aug_binop(op: String) -> Result[String]
  case op
    "+=" -> ok("+")
    "-=" -> ok("-")
    "*=" -> ok("*")
    "/=" -> ok("/")
    "%=" -> ok("%")
    _ ->
      error("PY-OUT-OF-SUBSET: augmented `#{op}` has no spelling = help: write `x = x OP y` with the plain operator")
  end
end

# Combines `x OP e` for an augmented assignment, mirroring the `EmitExpr`
# operator rules; the caller then applies the same-type rule.
def aug_combine(xname: String, xtype: String, op: String, rcode: String, rtype: String) -> Result[List[String]]
  case op
    "+" -> aug_add(xname, xtype, rcode, rtype)
    "-" -> aug_minus(xname, xtype, rcode, rtype)
    "*" -> aug_star(xname, xtype, rcode, rtype)
    "/" -> aug_slash(xname, xtype, rcode, rtype)
    "%" -> aug_mod(xname, xtype, rcode, rtype)
    _ -> error("agc-py: unknown augmented operator #{op}")
  end
end

def aug_add(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["#{xname} + #{rcode}", "Int"]) if xtype == "Int" and rtype == "Int"

  return ok(["#{xname} + #{rcode}", "Float"]) if xtype == "Float" and rtype == "Float"

  return ok(["#{xname} + #{rcode}", "String"]) if xtype == "String" and rtype == "String"

  return aug_add_lists(xname, xtype, rcode, rtype) if ann_base(xtype) == "List" and ann_base(rtype) == "List"

  return ok(["#{xname} + #{rcode}", "Unknown"]) if xtype == "Unknown" or rtype == "Unknown"

  error("PY-TYPE-MISMATCH: `+=` needs two numbers, two strings or two lists, found #{xtype} and #{rtype}")
end

def aug_add_lists(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["#{xname} + #{rcode}", xtype]) if xtype == rtype

  x_bare = xtype == "List" or ann_elem(xtype) == "Unknown"
  r_bare = rtype == "List" or ann_elem(rtype) == "Unknown"
  return ok(["#{xname} + #{rcode}", "List"]) if x_bare and r_bare

  return ok(["#{xname} + #{rcode}", rtype]) if x_bare

  return ok(["#{xname} + #{rcode}", xtype]) if r_bare

  error("PY-TYPE-MISMATCH: `+=` needs two same-typed lists, found #{xtype} and #{rtype}")
end

def aug_minus(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["#{xname} - #{rcode}", "Int"]) if xtype == "Int" and rtype == "Int"

  return ok(["#{xname} - #{rcode}", "Float"]) if xtype == "Float" and rtype == "Float"

  return ok(["#{xname} - #{rcode}", "Unknown"]) if xtype == "Unknown" or rtype == "Unknown"

  error("PY-TYPE-MISMATCH: `-=` needs two numbers, found #{xtype} and #{rtype}")
end

def aug_star(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["#{xname} * #{rcode}", "Int"]) if xtype == "Int" and rtype == "Int"

  return ok(["#{xname} * #{rcode}", "Float"]) if xtype == "Float" and rtype == "Float"

  return ok(["#{xname} * #{rcode}", "String"]) if xtype == "String" and rtype == "Int"

  if xtype == "Int" and rtype == "String"
    return error("PY-OPERATOR: repeat as `s * n`, not `n * s` = help: write #{rcode} * #{xname}")
  end

  if ann_base(xtype) == "List" and rtype == "Int"
    return error("PY-OPERATOR: lists do not repeat with `*=` = help: build the list with a loop")
  end

  if xtype != "Unknown" and rtype != "Unknown"
    return error("PY-TYPE-MISMATCH: `*=` needs two numbers or `s * n`, found #{xtype} and #{rtype}")
  end

  error("PY-OPERATOR: `*=` has no form for #{xtype} and #{rtype}")
end

def aug_slash(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["#{xname}.to_f / #{rcode}.to_f", "Float"]) if xtype == "Int" and rtype == "Int"

  return ok(["#{xname} / #{rcode}", "Float"]) if xtype == "Float" and rtype == "Float"

  if xtype != "Unknown" and rtype != "Unknown"
    return error("PY-TYPE-MISMATCH: `/=` needs two numbers, found #{xtype} and #{rtype}")
  end

  error("PY-OPERATOR: `/=` has no form for #{xtype} and #{rtype}")
end

def aug_mod(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  return ok(["py_pymod(#{xname}, #{rcode})", "Int"]) if xtype == "Int" and rtype == "Int"

  if xtype == "Float" or rtype == "Float"
    return error("PY-OPERATOR: `%=` is int-only with Python signs = help: use `%=` on two ints")
  end

  if xtype != "Unknown" and rtype != "Unknown"
    return error("PY-TYPE-MISMATCH: `%=` needs two ints, found #{xtype} and #{rtype}")
  end

  error("PY-OPERATOR: `%=` has no form for #{xtype} and #{rtype}")
end

# Whether the declared type accepts the value type: exact names, `Unknown`
# either side (phase 4 owns its meaning), `none` only under `Optional`, and
# a bare `List`/`Map` either side of the same base.
def types_match?(want: String, got: String) -> Bool
  return true if want == got

  return true if got == "Unknown" or want == "Unknown"

  if ann_base(want) == "Optional"
    return true if got == "none"

    inner = ann_elem(want)
    return true if got == inner

    if ann_base(got) == ann_base(inner) and (ann_base(got) == "List" or ann_base(got) == "Map")
      return true if inner == ann_base(inner) or got == ann_base(got)
    end

    return false
  end

  if ann_base(want) == ann_base(got) and (ann_base(want) == "List" or ann_base(want) == "Map")
    return true if want == ann_base(want) or got == ann_base(got)
  end

  false
end

# The head segment of a (possibly generic) type: `List` of `List[Int]`.
def ann_base(type: String) -> String
  index = type.index_of("[")
  case index
    some(at) -> type.slice(0, at)
    none -> type
  end
end

# The element of `List[E]` / `Optional[X]` (the value side of `Map[K, V]).
def ann_elem(type: String) -> String
  open = type.index_of("[")
  case open
    some(at) ->
      inner = type.slice(at + 1, type.length - at - 2)
      if ann_base(type) == "Map"
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
end

# Maps an annotation to its Agentica spelling, resolving capitalized names
# (aliases) through the scope; anything else refuses.
def map_ann_scoped(text: String, scope: Map[String, String]) -> Result[String]
  if bare_capitalized?(text.strip)
    found = scope.get(text.strip, "")
    return ok(found) if found != ""

    return ok(text.strip)
  end

  map_ann(text.strip)
end

def map_ann(text: String) -> Result[String]
  return ok(text.slice(1, text.length - 2)) if quoted?(text)

  arms = split_top(text, "|")
  return map_union(List.first(arms).strip, List.first(arms.drop(1)).strip, text) if arms.size == 2

  return error("PY-OUT-OF-SUBSET: union `#{text}` only allows `X | None` = help: write `Optional[X]`") if arms.size > 2

  open = text.index_of("[")
  case open
    some(at) ->
      head = text.slice(0, at).strip
      return error("PY-OUT-OF-SUBSET: annotation `#{text}` has unbalanced brackets") if !text.end_with?("]")

      map_generic(head, text.slice(at + 1, text.length - at - 2))
    none -> map_bare(text)
  end
end

# Only `X | None` unions exist in the subset; anything else refuses.
def map_union(first: String, second: String, text: String) -> Result[String]
  return ok("Optional[#{try map_ann(second)}]") if first == "None" or first == "none"

  return ok("Optional[#{try map_ann(first)}]") if second == "None" or second == "none"

  error("PY-OUT-OF-SUBSET: union `#{text}` only allows `X | None` = help: write `Optional[X]`")
end

def map_generic(head: String, inner: String) -> Result[String]
  if head == "list" or head == "List"
    args = split_top(inner, ",")
    return error("PY-OUT-OF-SUBSET: `#{head}` takes one parameter = help: write `list[T]`") if args.size != 1

    return ok("List[#{try map_ann(List.first(args).strip)}]")
  end

  if head == "dict" or head == "Map"
    args = split_top(inner, ",")
    return error("PY-OUT-OF-SUBSET: `#{head}` takes two parameters = help: write `dict[K, V]`") if args.size != 2

    key = try map_ann(List.first(args).strip)
    value = try map_ann(List.first(args.drop(1)).strip)
    return ok("Map[#{key}, #{value}]")
  end

  if head == "Optional"
    args = split_top(inner, ",")
    return error("PY-OUT-OF-SUBSET: `Optional` takes one parameter = help: write `Optional[X]`") if args.size != 1

    return ok("Optional[#{try map_ann(List.first(args).strip)}]")
  end

  error(
    "PY-ANNOTATION-UNKNOWN: unknown annotation `#{head}` = help: use one of int, str, float, bool, None, list, dict, Optional",
  )
end

def map_bare(text: String) -> Result[String]
  case text
    "int" -> ok("Int")
    "str" -> ok("String")
    "float" -> ok("Float")
    "bool" -> ok("Bool")
    "None" -> ok("none")
    "none" -> ok("none")
    "list" -> ok("List")
    "dict" -> ok("Map")
    "Int" -> ok("Int")
    "String" -> ok("String")
    "Float" -> ok("Float")
    "Bool" -> ok("Bool")
    "Void" -> ok("Void")
    "List" -> ok("List")
    "Map" -> ok("Map")
    "Any" ->
      error("PY-ANY: annotation `Any` is excluded; annotate with a concrete type = help: write int, str, or list[int]")
    "object" ->
      error(
        "PY-ANY: annotation `object` is excluded; annotate with a concrete type = help: write a concrete type such as int or str",
      )
    _ -> map_bare_name(text)
  end
end

def map_bare_name(text: String) -> Result[String]
  if text.include?(".")
    head = List.first(text.split(".")).strip
    if head == "typing"
      tail = List.last(text.split(".")).strip
      if tail == "Any" or tail == "object"
        return error(
          "PY-ANY: annotation `#{text}` is excluded; annotate with a concrete type = help: write a concrete type such as int or str",
        )
      end
    end

    return error(
      "PY-ANNOTATION-UNKNOWN: unknown annotation `#{head}` = help: use one of int, str, float, bool, None, list, dict, Optional",
    )
  end

  return ok(text) if capitalized?(text)

  error(
    "PY-ANNOTATION-UNKNOWN: unknown annotation `#{text}` = help: use one of int, str, float, bool, None, list, dict, Optional",
  )
end

# A bare capitalized name: an alias or named type, resolved through the
# scope when known.
def bare_capitalized?(text: String) -> Bool
  return false if !capitalized?(text)

  return false if text.include?(" ") or text.include?("\t")

  return false if text.include?("[") or text.include?("|") or text.include?(".")

  return false if text.include?("\"") or text.include?("'")

  return false if text.include?(",") or text.include?("(")

  true
end

def capitalized?(text: String) -> Bool
  return false if text == ""

  code = text.slice(0, 1).code
  code >= 65 and code <= 90
end

def quoted?(text: String) -> Bool
  return false if text.length < 2

  first = text.slice(0, 1)
  last = text.slice(text.length - 1, 1)
  (first == "\"" and last == "\"") or (first == "'" and last == "'")
end

# Splits on a single-character separator, ignoring separators nested in
# `[]`/`()` or quotes.
def split_top(text: String, sep: String) -> List[String]
  parts: List[String] = []
  cur = ""
  depth = 0
  quote = ""
  chars = text.split("")
  i = 0
  while i < chars.size
    ch = chars[i]
    if quote != ""
      cur = "#{cur}#{ch}"
      if ch == quote
        quote = ""
      end

      i += 1
    else
      if ch == "\"" or ch == "'"
        quote = ch
        cur = "#{cur}#{ch}"
        i += 1
      else
        if ch == "[" or ch == "("
          depth += 1
          cur = "#{cur}#{ch}"
          i += 1
        else
          if ch == "]" or ch == ")"
            depth -= 1
            cur = "#{cur}#{ch}"
            i += 1
          else
            if depth == 0 and ch == sep
              parts = parts.push(cur)
              cur = ""
              i += 1
            else
              cur = "#{cur}#{ch}"
              i += 1
            end
          end
        end
      end
    end
  end

  parts.push(cur)
end

def shift_out(out: EmitExpr.Out, base: Int) -> Shifted
  used = temps_used(out.pre + [out.code])
  return Shifted(code: out.code, pre: out.pre, used: used) if base == 0

  Shifted(code: shift_temps(out.code, base), pre: out.pre.map { |line| shift_temps(line, base) }, used: used)
end

# How many `py_tN` temps a value used: one past the highest index.
def temps_used(lines: List[String]) -> Int
  top = 0
  for line in lines
    found = max_temp_in(line)
    if found > top
      top = found
    end
  end

  top
end

def max_temp_in(text: String) -> Int
  chars = text.split("")
  top = 0
  i = 0
  while i < chars.size
    if temp_at?(chars, i)
      j = i + 4
      digits = ""
      while j < chars.size and digit?(chars[j])
        digits = "#{digits}#{chars[j]}"
        j += 1
      end

      found = parse_int(digits) + 1
      if found > top
        top = found
      end

      i = j
    else
      i += 1
    end
  end

  top
end

def temp_at?(chars: List[String], i: Int) -> Bool
  return false if i + 4 >= chars.size

  chars[i] == "p" and chars[i + 1] == "y" and chars[i + 2] == "_" and chars[i + 3] == "t" and digit?(chars[i + 4])
end

def digit?(ch: String) -> Bool
  code = ch.code
  code >= 48 and code <= 57
end

def parse_int(digits: String) -> Int
  num = 0
  for ch in digits.split("")
    num = num * 10 + (ch.code - 48)
  end

  num
end

# Renames every `py_tN` in `text` to `py_t{base + N}`.
def shift_temps(text: String, base: Int) -> String
  chars = text.split("")
  out = ""
  i = 0
  while i < chars.size
    if temp_at?(chars, i)
      j = i + 4
      digits = ""
      while j < chars.size and digit?(chars[j])
        digits = "#{digits}#{chars[j]}"
        j += 1
      end

      out = "#{out}py_t#{base + parse_int(digits)}"
      i = j
    else
      out = "#{out}#{chars[i]}"
      i += 1
    end
  end

  out
end

# Splits an `EmitExpr` message-only error (`CODE: message = help: hint`)
# into a refusal; anything without a `PY-*` code refuses as
# `PY-OUT-OF-SUBSET`.
def split_error(msg: String) -> ErrParts
  colon = msg.index_of(":")
  case colon
    some(at) ->
      code = msg.slice(0, at).strip
      rest = msg.slice(at + 1, msg.length - at - 1).strip
      if code.start_with?("PY-")
        marker = rest.index_of("= help:")
        case marker
          some(found) ->
            ErrParts(
              code: code,
              message: rest.slice(0, found).strip,
              help: some(rest.slice(found + 7, rest.length - found - 7).strip),
            )
          none -> ErrParts(code: code, message: rest, help: none)
        end
      else
        ErrParts(code: "PY-OUT-OF-SUBSET", message: msg, help: none)
      end

    none -> ErrParts(code: "PY-OUT-OF-SUBSET", message: msg, help: none)
  end
end

# Refuses with a parsed emitter error at an explicit span.
def refuse_split(start: Int, stop: Int, err: Error) -> EmitCtx.StmtRes
  parts = split_error(err.message)
  EmitCtx.refuse_at(parts.code, parts.message, parts.help, start, stop)
end
