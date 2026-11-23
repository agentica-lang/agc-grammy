## Binding-statement codegen for `agc-py` phase 3c lane A: annotated and plain
## assignment, augmented assignment, type aliases, expression statements and
## `return`.
##
## Each emitter takes the statement pieces the coordinator narrowed from
## the parse tree, the source it was sliced from and the lane context, and
## answers an `EmitCtx.StmtRes`: emitted lines plus the scope and temp
## supply after the statement, or a spanned refusal. Lane A
## has no nested bodies, so emitters take no pre-emitted strings; expression
## values go through `EmitExpr.emit` and their `py_tN` temps shift past
## `ctx.next_temp`, so sequential statements never collide.
##
## The lowering follows `SUBSET.md` sections 1, 2 and 4: the first binding
## carries its annotation (`x: int = 0`), rebinding keeps the type and any
## change is `PY-TYPE-MISMATCH`; `x += e` is sugar for `x = x OP e` (the
## grammar admits no `//=` or `**=` spelling, so those never reach the
## emitter; its `aug_combine` fallback refuses them as defense-in-depth); a bare `x: T` binds with no code;
## `type Alias = T` emits the backend alias; an expression statement emits
## and discards its value; `return` carries a value only under a non-`Void`
## return and stands bare only under `-> None`. A known value landing in
## `Optional[T]` — annotated initialization, rebinding, an unwrapped
## `Result[T]` inside `try`, or a `return` — emits `some(value)`, while
## `none` and an already-`Optional` value stay bare. Annotations resolve
## capitalized aliases structurally through the scope: at the top level,
## inside `list[..]`/`dict[..]`, inside `Optional[..]`, inside a union arm
## and inside a quoted forward reference. Built-ins never take that
## shortcut: `None` maps to `none`, `Any`/`object` refuse `PY-ANY`, a bare
## `Optional` and any `none`-typed position refuse spanned (probed).
## Probed on agentica 0.35.0: a bare scalar, string, list or map under
## `Optional[T]` is `CHECK-TYPE-MISMATCH`, `some(try e)` checks with no
## extra grouping, `type Alias = Int` checks at the top level and
## reads as an annotation (including `List` and `Optional` targets), while a
## lowercase alias name is `PARSE-UNEXPECTED-TOKEN` and an in-`def` alias is
## `PARSE-TOP-LEVEL-STATEMENT`, so both refuse with `PY-OUT-OF-SUBSET`. Bare
## `return` checks under `-> Void` while `return none` is
## `CHECK-TYPE-MISMATCH`, so an explicit `return None` under `-> None` emits
## a bare `return`.

import EmitCtx from "./emit_ctx"
import EmitExpr from "./emit_expr"
import Frontend from "./frontend"
import Tree from "../../src/tree"

## Emits `x: T = e`: declares `x` with the mapped annotation and checks the
## value against it (`PY-TYPE-MISMATCH` on change). A bare `x: T` binds with
## no code; a second binding in the same scope is `PY-DUPLICATE-BINDING`.
def emit_annotated(
  ctx: EmitCtx.EmitCtx,
  occ: Frontend.NameOcc,
  ann: Frontend.Ann,
  value: Optional[Tree.Node],
  source: String,
) -> EmitCtx.StmtRes
  case map_ann_scoped(ann.text, ctx.scope)
    error(e) -> refuse_split(ann.span.start, ann.span.stop, e)
    ok(want) ->
      name = occ.name
      if ctx.scope.get(name, "") != ""
        EmitCtx.refuse_at(
          "PY-DUPLICATE-BINDING",
          "duplicate binding of `#{name}` in the same scope",
          some("rename one of the bindings; a function may shadow a module-level name"),
          occ.span.start,
          occ.span.stop,
        )
      else
        case value
          none ->
            EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: [], scope: ctx.scope.put(name, want), next_temp: ctx.next_temp))
          some(expr) -> emit_value_binding(ctx, name, want, expr, source, true)
        end
      end
  end
end

## Emits `x = e`: rebinds a declared name, keeping its type. Binding an
## undeclared name is `PY-UNTYPED-NAME`; changing the type is
## `PY-TYPE-MISMATCH`.
def emit_assigned(ctx: EmitCtx.EmitCtx, occ: Frontend.NameOcc, value: Tree.Node, source: String) -> EmitCtx.StmtRes
  name = occ.name
  want = ctx.scope.get(name, "")
  if want == ""
    EmitCtx.refuse_at(
      "PY-UNTYPED-NAME",
      "first binding of `#{name}` needs an annotation",
      some("write `#{name}: <type> = ...` for the first binding"),
      occ.span.start,
      occ.span.stop,
    )
  else
    emit_value_binding(ctx, name, want, value, source, false)
  end
end

## Emits `x OP= e` as the sugar `x = x OP e`: the right side goes through
## `EmitExpr.emit` with the same operator rules, then the result must keep
## `x`'s type (`PY-TYPE-MISMATCH` otherwise). Inside a `try` body a directly
## `Result[Inner]` operand unwraps like a value binding (`x = x + (try e)`)
## when `Inner` keeps `x`'s type. `//=` and `**=` have no spelling and
## refuse with `PY-OUT-OF-SUBSET`.
def emit_augassigned(
  ctx: EmitCtx.EmitCtx,
  occ: Frontend.NameOcc,
  op: String,
  value: Tree.Node,
  source: String,
) -> EmitCtx.StmtRes
  name = occ.name
  want = ctx.scope.get(name, "")
  if want == ""
    EmitCtx.refuse_at(
      "PY-UNTYPED-NAME",
      "first binding of `#{name}` needs an annotation",
      some("write `#{name}: <type> = ...` for the first binding"),
      occ.span.start,
      occ.span.stop,
    )
  else
    emit_augassigned_value(ctx, name, want, op, value, source)
  end
end

## Emits `type Alias = T`: the backend alias at the top level, refused with
## `PY-OUT-OF-SUBSET` inside a `def` or for a lowercase name (both probed).
## The alias resolves later annotations through the scope.
def emit_alias(ctx: EmitCtx.EmitCtx, occ: Frontend.NameOcc, ann: Frontend.Ann, source: String) -> EmitCtx.StmtRes
  case map_ann_scoped(ann.text, ctx.scope)
    error(e) -> refuse_split(ann.span.start, ann.span.stop, e)
    ok(want) -> emit_alias_line(ctx, occ, want)
  end
end

## Emits an expression statement (`expr_stmt`, `call_stmt`, or a bare
## expression node): the value emits through `EmitExpr.emit` and its code
## stands alone, discarded. Inside a `try` body (`in_try`) a directly
## consumed `Result[T]` unwraps with `try` so the error reaches the
## handler; outside `try` it stays a type error (no handler to catch it).
def emit_expr_stmt(ctx: EmitCtx.EmitCtx, expr: Tree.Node, source: String) -> EmitCtx.StmtRes
  case EmitExpr.emit_with(expr, source, ctx.scope, ctx.sigs, ctx.in_try)
    error(e) -> refuse_split(expr.start, expr.stop, e)
    ok(out) ->
      shifted = shift_out(out, ctx.next_temp)
      if ctx.in_try
        inner = EmitExpr.result_inner(out.type)
        case inner
          some(_) ->
            return EmitCtx.StmtRes.Ok(
              EmitCtx.StmtOut(
                code: shifted.pre + ["try #{shifted.code}"],
                scope: ctx.scope,
                next_temp: ctx.next_temp + shifted.used,
              ),
            )
          none -> shifted = shifted
        end
      end

      EmitCtx.StmtRes.Ok(
        EmitCtx.StmtOut(code: shifted.pre + [shifted.code], scope: ctx.scope, next_temp: ctx.next_temp + shifted.used),
      )
  end
end

## Emits `return e` (or bare `return`): a value only under a non-`Void`
## return, a bare `return` only under `None`/`Void`, else
## `PY-TYPE-MISMATCH`. An explicit `return None` under `-> None` folds to a
## bare `return`, the only shape the backend checks there. A `return`
## inside a `try` body is `PY-TRY-CONTROL` first: the outlined handler
## cannot be crossed. A `return` outside a `def` is `PY-OUT-OF-SUBSET`.
def emit_return(
  ctx: EmitCtx.EmitCtx,
  value: Optional[Tree.Node],
  span: Frontend.Span,
  source: String,
) -> EmitCtx.StmtRes
  if ctx.func_ret == ""
    return EmitCtx.refuse_at(
      "PY-OUT-OF-SUBSET",
      "return outside a `def`",
      some("move it into a `def`"),
      span.start,
      span.stop,
    )
  end

  if ctx.in_try
    return EmitCtx.refuse_at(
      "PY-TRY-CONTROL",
      "return inside a try body cannot cross the handler",
      some("return from outside the try body"),
      span.start,
      span.stop,
    )
  end

  case value
    none -> emit_bare_return(ctx, span)
    some(expr) -> emit_value_return(ctx, expr, span, source)
  end
end

## Maps one annotation to its Agentica spelling for the module assembler:
## the lane-internal `map_ann_scoped` rules with the scope in hand, so a
## `def` header and the lane agree on aliases and built-in spellings.
def map_annotation(text: String, scope: Map[String, String]) -> Result[String] = map_ann_scoped(text, scope)

private

# How a value of type `got` lands in the declared type `want`: `bare`
# emits as written (equal types, `none` under `Optional`, or `Unknown`),
# `wrap` needs `some(...)` for a known value under `Optional[T]` (probed
# on agentica 0.35.0: a bare scalar, string, list or map there is
# `CHECK-TYPE-MISMATCH`), `no` refuses. The non-`Optional` branch keeps
# the plain `types_match?` rule, so `x += e` still refuses an `Optional`
# target instead of wrapping its operand.
enum OptFit
  Bare
  Wrap
  No
end

# One emitted value with its `py_tN` temps shifted past `base`: how many
# temps the value used, so the caller advances the supply by the same.
struct Shifted
  code: String
  pre: List[String]
  used: Int
end

# One read hole: the `#{...}` code plus the offset past its closer.
struct InterpTake
  code: String
  next: Int
end

# The binding target of a lane A statement comes from the coordinator as
# a `NameOcc` that retains the target span for diagnostics.

def emit_augassigned_value(
  ctx: EmitCtx.EmitCtx,
  name: String,
  want: String,
  op: String,
  expr: Tree.Node,
  source: String,
) -> EmitCtx.StmtRes
  case EmitExpr.emit_with(expr, source, ctx.scope, ctx.sigs, ctx.in_try)
    error(e) -> refuse_split(expr.start, expr.stop, e)
    ok(out) ->
      shifted = shift_out(out, ctx.next_temp)
      # Inside a `try` body a directly consumed `Result[Inner]` unwraps with
      # `try` when `Inner` keeps the target type, like `emit_value_binding`:
      # the operand is spelled `try e` and `aug_combine` places it: `x += e`
      # lowers to `x = x + (try e)` and `x %= e` to `x = py_pymod(x, try e)`.
      # Outside `try` the `Result` stays and `aug_combine` refuses the
      # operand combination.
      rcode = shifted.code
      rtype = out.type
      if ctx.in_try
        inner = EmitExpr.result_inner(out.type)
        if inner.some? and bind_fit(want, inner.unwrap!) == OptFit.Bare
          rcode = "try #{shifted.code}"
          rtype = inner.unwrap!
        end
      end

      case aug_combine(name, want, op, rcode, rtype)
        error(e) -> refuse_split(expr.start, expr.stop, e)
        ok(pair) -> emit_augassigned_line(ctx, name, want, op, expr, shifted, pair)
      end
  end
end

def emit_augassigned_line(
  ctx: EmitCtx.EmitCtx,
  name: String,
  want: String,
  op: String,
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
      "augmented `#{op}` on `#{name}: #{want}` gives #{got}",
      some("convert the value explicitly or fix the annotation"),
      expr.start,
      expr.stop,
    )
  end
end

def emit_alias_line(ctx: EmitCtx.EmitCtx, occ: Frontend.NameOcc, want: String) -> EmitCtx.StmtRes
  name = occ.name
  # TODO(3d): the backend only checks `type` aliases at the top level
  # (probed PARSE-TOP-LEVEL-STATEMENT on agentica 0.35.0); revisit if local
  # aliases ever check.
  if ctx.func_ret != ""
    EmitCtx.refuse_at(
      "PY-OUT-OF-SUBSET",
      "type alias `#{name}` inside a `def` has no backend form",
      some("move it to the top level"),
      occ.span.start,
      occ.span.stop,
    )
  else
    # TODO(3d): the backend only checks capitalized alias names (probed
    # PARSE-UNEXPECTED-TOKEN on agentica 0.35.0); revisit if lowercase
    # aliases ever check.
    if capitalized?(name)
      if ctx.scope.get(name, "") != ""
        EmitCtx.refuse_at(
          "PY-DUPLICATE-BINDING",
          "type alias `#{name}` is already bound",
          some("pick another name or drop the second alias"),
          occ.span.start,
          occ.span.stop,
        )
      else
        EmitCtx.StmtRes.Ok(
          EmitCtx.StmtOut(
            code: ["type #{name} = #{want}"],
            scope: ctx.scope.put(name, want),
            next_temp: ctx.next_temp,
          ),
        )
      end
    else
      EmitCtx.refuse_at(
        "PY-OUT-OF-SUBSET",
        "type alias `#{name}` needs a capitalized name for the backend",
        some("name it with a leading capital, for example `type Alias = ...`"),
        occ.span.start,
        occ.span.stop,
      )
    end
  end
end

# Emits `name: Want = <value>` for a declaration or `name = <value>` for a
# rebinding: the value emits through `EmitExpr.emit` and must keep the
# declared type. Inside a `try` body a directly consumed `Result[Inner]`
# unwraps with `try` when `Inner` keeps the declared type, so catchable
# conversions like `int(s)` reach the handler.
def emit_value_binding(
  ctx: EmitCtx.EmitCtx,
  name: String,
  want: String,
  expr: Tree.Node,
  source: String,
  decl: Bool,
) -> EmitCtx.StmtRes
  case EmitExpr.emit_with(expr, source, ctx.scope, ctx.sigs, ctx.in_try)
    error(e) -> refuse_split(expr.start, expr.stop, e)
    ok(out) ->
      shifted = shift_out(out, ctx.next_temp)
      case bind_fit(want, out.type)
        OptFit.Bare -> emit_bound(ctx, name, want, shifted, decl, shifted.code)
        OptFit.Wrap -> emit_bound(ctx, name, want, shifted, decl, "some(#{shifted.code})")
        OptFit.No ->
          # Inside a `try` body the value may unwrap to `Result[T]`:
          # `try value` when `T` keeps the declared type, `some(try value)`
          # when `T` lands in an `Optional[T]`.
          if ctx.in_try
            inner = EmitExpr.result_inner(out.type)
            case inner
              some(found) ->
                case bind_fit(want, found)
                  OptFit.Bare -> return emit_bound(ctx, name, want, shifted, decl, "try #{shifted.code}")
                  OptFit.Wrap -> return emit_bound(ctx, name, want, shifted, decl, "some(try #{shifted.code})")
                  OptFit.No -> found = found
                end

              none -> inner = inner
            end
          end

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

# Emits one binding line (`name: Want = value` declared, `name = value`
# rebinding) with the value's temps already shifted past the supply.
def emit_bound(
  ctx: EmitCtx.EmitCtx,
  name: String,
  want: String,
  shifted: Shifted,
  decl: Bool,
  value: String,
) -> EmitCtx.StmtRes
  line = "#{name} = #{value}"
  if decl
    line = "#{name}: #{want} = #{value}"
  end

  EmitCtx.StmtRes.Ok(
    EmitCtx.StmtOut(
      code: shifted.pre + [line],
      scope: ctx.scope.put(name, want),
      next_temp: ctx.next_temp + shifted.used,
    ),
  )
end

def bind_fit(want: String, got: String) -> OptFit
  if ann_base(want) == "Optional"
    return OptFit.Bare if got == "none" or got == "Unknown" or got == want

    inner = ann_elem(want)
    return OptFit.Wrap if got == inner

    if ann_base(got) == ann_base(inner) and (ann_base(got) == "List" or ann_base(got) == "Map")
      return OptFit.Wrap if inner == ann_base(inner) or got == ann_base(got)
    end

    return OptFit.No
  end

  return OptFit.Bare if types_match?(want, got)

  OptFit.No
end

# A bare `return` only checks under a `Void` return; anything else is
# `PY-TYPE-MISMATCH`.
def emit_bare_return(ctx: EmitCtx.EmitCtx, span: Frontend.Span) -> EmitCtx.StmtRes
  if is_void_return?(ctx.func_ret)
    EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: ["return"], scope: ctx.scope, next_temp: ctx.next_temp))
  else
    EmitCtx.refuse_at(
      "PY-TYPE-MISMATCH",
      "bare `return` under `-> #{ctx.func_ret}` returns nothing",
      some("return a value of the declared type"),
      span.start,
      span.stop,
    )
  end
end

def emit_value_return(ctx: EmitCtx.EmitCtx, expr: Tree.Node, span: Frontend.Span, source: String) -> EmitCtx.StmtRes
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
        error(e) -> refuse_split(span.start, span.stop, e)
        ok(want) ->
          # `emit_return` already refused inside a `try` body, so this is
          # false today; thread it anyway so the strict value expression
          # keeps unwrapping if that control refusal ever moves.
          case EmitExpr.emit_with(expr, source, ctx.scope, ctx.sigs, ctx.in_try)
            error(e) -> refuse_split(expr.start, expr.stop, e)
            ok(out) -> emit_return_line(ctx, expr, want, out)
          end
      end
    end
  end
end

def emit_return_line(ctx: EmitCtx.EmitCtx, expr: Tree.Node, want: String, out: EmitExpr.Out) -> EmitCtx.StmtRes
  shifted = shift_out(out, ctx.next_temp)
  fit = bind_fit(want, out.type)
  if fit == OptFit.No
    EmitCtx.refuse_at(
      "PY-TYPE-MISMATCH",
      "cannot return #{out.type} under `-> #{ctx.func_ret}`",
      some("convert the value explicitly or fix the return annotation"),
      expr.start,
      expr.stop,
    )
  else
    value = shifted.code
    if fit == OptFit.Wrap
      value = "some(#{shifted.code})"
    end

    EmitCtx.StmtRes.Ok(
      EmitCtx.StmtOut(
        code: shifted.pre + ["return #{value}"],
        scope: ctx.scope,
        next_temp: ctx.next_temp + shifted.used,
      ),
    )
  end
end

def is_void_return?(func_ret: String) -> Bool = func_ret == "Void" or func_ret == "None" or func_ret == "none"

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

# Combines `x OP= e` as the sugar `x OP e`, mirroring the `EmitExpr`
# operator rules; the caller then applies the same-type rule. The fallback
# keeps `//=` and `**=` out: they have no spelling in the subset.
def aug_combine(xname: String, xtype: String, op: String, rcode: String, rtype: String) -> Result[List[String]]
  case op
    "+=" -> aug_add(xname, xtype, rcode, rtype)
    "-=" -> aug_minus(xname, xtype, rcode, rtype)
    "*=" -> aug_star(xname, xtype, rcode, rtype)
    "/=" -> aug_slash(xname, xtype, rcode, rtype)
    "%=" -> aug_mod(xname, xtype, rcode, rtype)
    _ ->
      error("PY-OUT-OF-SUBSET: augmented `#{op}` has no spelling = help: write `x = x OP y` with the plain operator")
  end
end

def aug_add(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  rhs = group_operand(rcode)
  return ok(["#{xname} + #{rhs}", "Int"]) if xtype == "Int" and rtype == "Int"

  return ok(["#{xname} + #{rhs}", "Float"]) if xtype == "Float" and rtype == "Float"

  return ok(["#{xname} + #{rhs}", "String"]) if xtype == "String" and rtype == "String"

  return aug_add_lists(xname, xtype, rhs, rtype) if ann_base(xtype) == "List" and ann_base(rtype) == "List"

  return ok(["#{xname} + #{rhs}", "Unknown"]) if xtype == "Unknown" or rtype == "Unknown"

  error("PY-TYPE-MISMATCH: `+=` needs two numbers, two strings or two lists, found #{xtype} and #{rtype}")
end

def aug_add_lists(xname: String, xtype: String, rhs: String, rtype: String) -> Result[List[String]]
  return ok(["#{xname} + #{rhs}", xtype]) if xtype == rtype

  x_bare = xtype == "List" or ann_elem(xtype) == "Unknown"
  r_bare = rtype == "List" or ann_elem(rtype) == "Unknown"
  return ok(["#{xname} + #{rhs}", "List"]) if x_bare and r_bare

  return ok(["#{xname} + #{rhs}", rtype]) if x_bare

  return ok(["#{xname} + #{rhs}", xtype]) if r_bare

  error("PY-TYPE-MISMATCH: `+=` needs two same-typed lists, found #{xtype} and #{rtype}")
end

def aug_minus(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  rhs = group_operand(rcode)
  return ok(["#{xname} - #{rhs}", "Int"]) if xtype == "Int" and rtype == "Int"

  return ok(["#{xname} - #{rhs}", "Float"]) if xtype == "Float" and rtype == "Float"

  return ok(["#{xname} - #{rhs}", "Unknown"]) if xtype == "Unknown" or rtype == "Unknown"

  error("PY-TYPE-MISMATCH: `-=` needs two numbers, found #{xtype} and #{rtype}")
end

def aug_star(xname: String, xtype: String, rcode: String, rtype: String) -> Result[List[String]]
  rhs = group_operand(rcode)
  return ok(["#{xname} * #{rhs}", "Int"]) if xtype == "Int" and rtype == "Int"

  return ok(["#{xname} * #{rhs}", "Float"]) if xtype == "Float" and rtype == "Float"

  return ok(["#{xname} * #{rhs}", "String"]) if xtype == "String" and rtype == "Int"

  if xtype == "Int" and rtype == "String"
    shown = rcode
    if rcode.start_with?("try ")
      shown = rcode.slice(4, rcode.length - 4)
    end

    return error("PY-OPERATOR: repeat as `s * n`, not `n * s` = help: write #{shown} * #{xname}")
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
  rhs = group_operand(rcode)
  return ok(["#{xname}.to_f / #{rhs}.to_f", "Float"]) if xtype == "Int" and rtype == "Int"

  return ok(["#{xname} / #{rhs}", "Float"]) if xtype == "Float" and rtype == "Float"

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

# The RHS is a single operand even when it contains operators.
def group_operand(code: String) -> String = "(#{code})"

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

# Maps an annotation to its Agentica spelling with the scope in hand: a
# bare capitalized name answers its scope mapping (a real alias reads the
# same wherever it stands), built-ins take the normal mapping and its
# refusals, and a `none` result refuses spanned at the caller's span — the
# backend has no type spelling for `none` (probed PARSE-UNEXPECTED-TOKEN).
def map_ann_scoped(text: String, scope: Map[String, String]) -> Result[String]
  stripped = text.strip
  if bare_capitalized?(stripped)
    found = scope.get(stripped, "")
    return ok(found) if found != "" and found != "none"
  end

  mapped = try map_ann(stripped, scope)
  return error("PY-ANNOTATION-UNKNOWN: `#{stripped}` maps to `none` = help: write `Optional[X]`") if mapped == "none"

  ok(mapped)
end

# Maps an annotation to its Agentica spelling with the scope in hand, so a
# capitalized alias resolves structurally wherever it appears: quoted, in a
# union arm, or inside `list[..]`/`dict[..]`/`Optional[..]`.
def map_ann(text: String, scope: Map[String, String]) -> Result[String]
  return ok(try map_ann(text.slice(1, text.length - 2), scope)) if quoted?(text)

  arms = split_top(text, "|")
  return map_union(List.first(arms).strip, List.first(arms.drop(1)).strip, text, scope) if arms.size == 2

  return error("PY-OUT-OF-SUBSET: union `#{text}` only allows `X | None` = help: write `Optional[X]`") if arms.size > 2

  open = text.index_of("[")
  case open
    some(at) ->
      head = text.slice(0, at).strip
      return error("PY-OUT-OF-SUBSET: annotation `#{text}` has unbalanced brackets") if !text.end_with?("]")

      map_generic(head, text.slice(at + 1, text.length - at - 2), scope)
    none -> map_bare(text, scope)
  end
end

# Only `X | None` unions exist in the subset; anything else refuses. An
# already-`Optional` side stays flat: `Optional[X] | None` is
# `Optional[X]`, never `Optional[Optional[X]]`.
def map_union(first: String, second: String, text: String, scope: Map[String, String]) -> Result[String]
  if first == "None" or first == "none"
    inner = try map_ann(second, scope)
    return ok(inner) if ann_base(inner) == "Optional"

    return ok("Optional[#{inner}]")
  end

  if second == "None" or second == "none"
    inner = try map_ann(first, scope)
    return ok(inner) if ann_base(inner) == "Optional"

    return ok("Optional[#{inner}]")
  end

  error("PY-OUT-OF-SUBSET: union `#{text}` only allows `X | None` = help: write `Optional[X]`")
end

def map_generic(head: String, inner: String, scope: Map[String, String]) -> Result[String]
  if head == "list" or head == "List"
    args = split_top(inner, ",")
    return error("PY-OUT-OF-SUBSET: `#{head}` takes one parameter = help: write `list[T]`") if args.size != 1

    return ok("List[#{try map_ann(List.first(args).strip, scope)}]")
  end

  if head == "dict" or head == "Map"
    args = split_top(inner, ",")
    return error("PY-OUT-OF-SUBSET: `#{head}` takes two parameters = help: write `dict[K, V]`") if args.size != 2

    key = try map_ann(List.first(args).strip, scope)
    value = try map_ann(List.first(args.drop(1)).strip, scope)
    return ok("Map[#{key}, #{value}]")
  end

  if head == "Optional"
    args = split_top(inner, ",")
    return error("PY-OUT-OF-SUBSET: `Optional` takes one parameter = help: write `Optional[X]`") if args.size != 1

    return ok("Optional[#{try map_ann(List.first(args).strip, scope)}]")
  end

  error(
    "PY-ANNOTATION-UNKNOWN: unknown annotation `#{head}` = help: use one of int, str, float, bool, None, Optional, list[T], dict[K, V]",
  )
end

# A bare `list`/`dict` annotation is refused with a parameterized example:
# the backend has no bare `List`/`Map` type (probed CHECK-UNKNOWN-TYPE on
# agentica 0.35.0), while every parameterized form keeps its normal mapping
# through `map_generic`.
def map_bare(text: String, scope: Map[String, String]) -> Result[String]
  case text
    "int" -> ok("Int")
    "str" -> ok("String")
    "float" -> ok("Float")
    "bool" -> ok("Bool")
    "None" -> ok("none")
    "none" -> ok("none")
    "list" ->
      error(
        "PY-ANNOTATION-UNKNOWN: annotation `list` needs one parameter = help: write `list[T]`, for example `list[int]`",
      )
    "dict" ->
      error(
        "PY-ANNOTATION-UNKNOWN: annotation `dict` needs two parameters = help: write `dict[K, V]`, for example `dict[str, int]`",
      )
    "Int" -> ok("Int")
    "String" -> ok("String")
    "Float" -> ok("Float")
    "Bool" -> ok("Bool")
    "Void" -> ok("Void")
    "List" -> ok("List")
    "Map" -> ok("Map")
    "Optional" -> error("PY-ANNOTATION-UNKNOWN: annotation `Optional` needs one parameter = help: write `Optional[X]`")
    "Any" ->
      error("PY-ANY: annotation `Any` is excluded; annotate with a concrete type = help: write int, str, or list[int]")
    "object" ->
      error(
        "PY-ANY: annotation `object` is excluded; annotate with a concrete type = help: write a concrete type such as int or str",
      )
    _ -> map_bare_name(text, scope)
  end
end

def map_bare_name(text: String, scope: Map[String, String]) -> Result[String]
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
      "PY-ANNOTATION-UNKNOWN: unknown annotation `#{head}` = help: use one of int, str, float, bool, None, Optional, list[T], dict[K, V]",
    )
  end

  if capitalized?(text)
    found = scope.get(text, "")
    return ok(found) if found != ""

    # Leave named types not in the emitter scope for frontend resolution (#21).
    return ok(text)
  end

  error(
    "PY-ANNOTATION-UNKNOWN: unknown annotation `#{text}` = help: use one of int, str, float, bool, None, Optional, list[T], dict[K, V]",
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
  used = shift_used(out.pre + [out.code])
  return Shifted(code: out.code, pre: out.pre, used: used) if base == 0

  Shifted(code: shift_line(out.code, base), pre: out.pre.map { |line| shift_line(line, base) }, used: used)
end

# How many `py_tN` temps a value used: one past the highest index anywhere
# a temp can hide — the preamble and code plus every `"...#{...}..."`
# interpolation they carry. The shared `EmitCtx` scan sees code segments
# and skips literal text, so a quoted `"py_t0"` never bumps the supply.
def shift_used(texts: List[String]) -> Int
  top = EmitCtx.max_temp_index(texts)
  for text in texts
    for inner in interp_inners(text)
      found = EmitCtx.max_temp_index([inner])
      if found > top
        top = found
      end
    end
  end

  return 0 if top < 0

  top + 1
end

# Renames one emitted line's temps past `base`, inside interpolations too:
# code outside strings and each `"...#{...}..."` hole shift through the
# shared `EmitCtx.shift_code`, while literal text (including a quoted
# `"py_t0"`) stays verbatim.
def shift_line(text: String, base: Int) -> String
  out = ""
  cur = ""
  chars = text.split("")
  i = 0
  in_string = false
  while i < chars.size
    ch = chars[i]
    if in_string
      if ch == "\\" and i + 1 < chars.size
        cur = "#{cur}#{ch}#{chars[i + 1]}"
        i += 2
      else
        if ch == "\""
          out = "#{out}#{cur}#{ch}"
          cur = ""
          in_string = false
          i += 1
        else
          if ch == "#" and i + 1 < chars.size and chars[i + 1] == "{"
            taken = take_interp(chars, i + 2)
            cur = "#{cur}#" + "{" + EmitCtx.shift_code(taken.code, base) + "}"
            i = taken.next
          else
            cur = "#{cur}#{ch}"
            i += 1
          end
        end
      end
    else
      if ch == "\""
        out = "#{out}#{EmitCtx.shift_code(cur, base)}"
        cur = ch
        in_string = true
        i += 1
      else
        cur = "#{cur}#{ch}"
        i += 1
      end
    end
  end

  if in_string
    out = "#{out}#{cur}"
  else
    out = "#{out}#{EmitCtx.shift_code(cur, base)}"
  end

  out
end

# Every `#{...}` hole inside the `"..."` strings of `text`. Holes never
# nest: `EmitExpr` hoists a hole holding a `"` to a temp, and a dict
# literal only balances braces, which the reader tracks.
def interp_inners(text: String) -> List[String]
  inners: List[String] = []
  chars = text.split("")
  i = 0
  in_string = false
  while i < chars.size
    ch = chars[i]
    if in_string
      if ch == "\\" and i + 1 < chars.size
        i += 2
      else
        if ch == "\""
          in_string = false
          i += 1
        else
          if ch == "#" and i + 1 < chars.size and chars[i + 1] == "{"
            taken = take_interp(chars, i + 2)
            inners = inners.push(taken.code)
            i = taken.next
          else
            i += 1
          end
        end
      end
    else
      if ch == "\""
        in_string = true
      end

      i += 1
    end
  end

  inners
end

# Reads the hole after `#{` at `from - 2`: balances braces with string
# awareness (a dict literal balances; a nested quote was hoisted to a
# temp by `EmitExpr`, so none appears). Answers the hole code and the
# offset past the closing `}`.
def take_interp(chars: List[String], from: Int) -> InterpTake
  inner = ""
  depth = 1
  j = from
  in_string = false
  while j < chars.size and depth > 0
    ch = chars[j]
    if in_string
      if ch == "\\" and j + 1 < chars.size
        inner = "#{inner}#{ch}#{chars[j + 1]}"
        j += 2
      else
        if ch == "\""
          in_string = false
        end

        inner = "#{inner}#{ch}"
        j += 1
      end
    else
      if ch == "\""
        in_string = true
        inner = "#{inner}#{ch}"
        j += 1
      else
        if ch == "{"
          depth += 1
          inner = "#{inner}#{ch}"
          j += 1
        else
          if ch == "}"
            depth -= 1
            if depth > 0
              inner = "#{inner}#{ch}"
            end

            j += 1
          else
            inner = "#{inner}#{ch}"
            j += 1
          end
        end
      end
    end
  end

  InterpTake(code: inner, next: j)
end

# Refuses with a parsed emitter error at an explicit span.
def refuse_split(start: Int, stop: Int, err: Error) -> EmitCtx.StmtRes = EmitCtx.refusal_from_error(start, stop, err)
