## Phase 3c checks adapter: `raise` and `assert` with real expressions.
##
## This lane owns the expression-taking shapes; `EmitTry` keeps the
## pre-emitted templates for the coordinator spine. Every emitter here wires
## parsed expressions through `EmitExpr.emit`, preserves spans and threads
## the temp supply with `EmitCtx.shift_code` and `EmitCtx.advance_temp`, so
## sequential statements never collide. Failures are `StmtRes.No` refusals
## with their spans, rendered by the assembler through
## `EmitCtx.render_refusal`.
##
## The lowering follows `SUBSET.md` section 4: `raise E("msg")` is
## `return error("msg")` inside `-> Result[T]` (message only, the class is
## never modeled) and `IO.warn` plus `System.exit(1)` at the top level
## (`func_ret == ""`, where `main` cannot `return`); `assert c[, msg]` needs
## a `Bool` condition and an optional `String` message, warning on stderr
## and exiting nonzero on failure, never catchable. Shape checks reuse
## `EmitTry.raise_target` and `EmitTry.single_message_arg?`, and the
## templates match `EmitTry` line for line. A condition preamble runs before
## its `if`; a message preamble runs only inside the failure branch, so a
## failing message never evaluates when the assertion holds.

import EmitCtx from "emit_ctx"
import EmitExpr from "emit_expr"
import EmitTry from "emit_try"
import Tree from "../../src/tree"

## Lowers `raise <expr>` with its message emitted from the parsed tree.
## `expr` is the `cond_expr` of a `Frontend.Stmt.RaiseStmt`. A bare name, a
## call with anything but exactly one positional argument, or any other
## shape is `PY-OUT-OF-SUBSET` at the expression span; a non-`String`
## message is `PY-TYPE-MISMATCH` at the message span, naming the inner type
## of a `Result` message (`raise E(int(s))` reports `Int`). The `return
## error(...)` form needs a backend-valid `Result` context: the top level
## (`func_ret == ""`, where `main` cannot return) halts instead, a def
## returning `Result[T]` (including an outlined `try` helper, which returns
## `Result[Void]`) returns the error, and anything else is refused spanned
## — the explicit caller ripple of a raising def is issue #24, kept out of
## 3d on purpose.
def emit_raise(ctx: EmitCtx.EmitCtx, expr: Tree.Node) -> EmitCtx.StmtRes
  if !result_context?(ctx.func_ret)
    return EmitCtx.refuse_at(
      "PY-OUT-OF-SUBSET",
      "raise inside a def returning #{ctx.func_ret} has no backend form",
      some("annotate the def with the Result type its callers handle; the ripple is issue #24"),
      expr.start,
      expr.stop,
    )
  end

  target = EmitTry.raise_target(expr)
  if target.rule == "call" and EmitTry.single_message_arg?(target)
    raw = List.first(target.children.drop(1))
    case EmitExpr.emit_with(raw, ctx.source, ctx.scope, ctx.sigs, ctx.in_try)
      error(err) -> EmitCtx.refusal_from_error(raw.start, raw.stop, err)
      ok(raw_out) ->
        out = raw_out
        # A directly `Result[String]` message would hoist to `try` the way a
        # value binding does once a `String` `Result` producer exists; this
        # slice has none, so it refuses below, naming the inner type when the
        # message answers a different `Result` (for example `Result[Int]`).
        inner = EmitExpr.result_inner(out.type)
        if inner.some? and inner.unwrap! != "String"
          return EmitCtx.refuse_at(
            "PY-TYPE-MISMATCH",
            "raise message must be str, found #{inner.unwrap!}",
            some("pass a string message"),
            raw.start,
            raw.stop,
          )
        end

        if out.type != "String"
          EmitCtx.refuse_at(
            "PY-TYPE-MISMATCH",
            "raise message must be str, found #{out.type}",
            some("pass a string message"),
            raw.start,
            raw.stop,
          )
        else
          shifted_pre = out.pre.map { |line| EmitCtx.shift_code(line, ctx.next_temp) }
          shifted_code = EmitCtx.shift_code(out.code, ctx.next_temp)
          advanced = EmitCtx.advance_temp(ctx.next_temp, out.pre + [out.code])
          if ctx.func_ret == ""
            EmitCtx.StmtRes.Ok(
              EmitCtx.StmtOut(
                code: shifted_pre + ["IO.warn(#{shifted_code})", "System.exit(1)"],
                scope: ctx.scope,
                next_temp: advanced,
              ),
            )
          else
            EmitCtx.StmtRes.Ok(
              EmitCtx.StmtOut(
                code: shifted_pre + ["return error(#{shifted_code})"],
                scope: ctx.scope,
                next_temp: advanced,
              ),
            )
          end
        end
    end
  else
    EmitCtx.refuse_at(
      "PY-OUT-OF-SUBSET",
      raise_message(target),
      some("write raise E(\"msg\") with one message"),
      expr.start,
      expr.stop,
    )
  end
end

## Emits `assert <cond>[, <msg>]` with both sides emitted from the tree.
## The condition must be `Bool` (`PY-COND-NOT-BOOL` at its span otherwise)
## and the message, when present, must be `String` (`PY-TYPE-MISMATCH` at
## its span otherwise). A missing message falls back to `"assert failed"`.
## The condition preamble runs before the `if`; the message preamble runs
## only inside the failure branch. The condition is a strict expression, so
## it emits with the body's `try` unwrapping (`ctx.in_try`): inside an
## outlined `try` a `Result` in a strict sub-expression (a comparison
## operand, say) unwraps inline in place and its error reaches the handler.
def emit_assert(ctx: EmitCtx.EmitCtx, cond: Tree.Node, msg: Optional[Tree.Node]) -> EmitCtx.StmtRes
  case EmitExpr.emit_with(cond, ctx.source, ctx.scope, ctx.sigs, ctx.in_try)
    error(err) -> EmitCtx.refusal_from_error(cond.start, cond.stop, err)
    ok(found) ->
      if found.type != "Bool"
        EmitCtx.refuse_at(
          "PY-COND-NOT-BOOL",
          "assert needs a bool condition, found #{found.type}",
          some("compare or convert to a bool first"),
          cond.start,
          cond.stop,
        )
      else
        cond_pre = found.pre.map { |line| EmitCtx.shift_code(line, ctx.next_temp) }
        cond_code = EmitCtx.shift_code(found.code, ctx.next_temp)
        advanced = EmitCtx.advance_temp(ctx.next_temp, found.pre + [found.code])
        case msg
          none ->
            EmitCtx.StmtRes.Ok(
              EmitCtx.StmtOut(
                code: cond_pre + ["if !(#{cond_code})", "  IO.warn(\"assert failed\")", "  System.exit(1)", "end"],
                scope: ctx.scope,
                next_temp: advanced,
              ),
            )
          some(node) -> emit_assert_msg(ctx, cond_pre, cond_code, advanced, node)
        end
      end
  end
end

private

# Whether `func_ret` accepts the raise lowering: the empty top level halts
# with `IO.warn` plus `System.exit(1)` and any `Result[T]` return takes
# `return error(...)`, so both pass; the outlined `try` helper counts, the
# spine threads its `Result[Void]` through.
def result_context?(func_ret: String) -> Bool
  return true if func_ret.empty?

  func_ret.start_with?("Result[")
end

# Emits the message side of an `assert` once the condition already checked.
# The message preamble joins the failure branch, never the fall-through.
def emit_assert_msg(
  ctx: EmitCtx.EmitCtx,
  cond_pre: List[String],
  cond_code: String,
  advanced: Int,
  node: Tree.Node,
) -> EmitCtx.StmtRes
  case EmitExpr.emit(node, ctx.source, ctx.scope, ctx.sigs)
    error(err) -> EmitCtx.refusal_from_error(node.start, node.stop, err)
    ok(out) ->
      if out.type != "String"
        EmitCtx.refuse_at(
          "PY-TYPE-MISMATCH",
          "assert message must be str, found #{out.type}",
          some("pass a string message"),
          node.start,
          node.stop,
        )
      else
        msg_pre = out.pre.map { |line| EmitCtx.shift_code(line, advanced) }
        msg_code = EmitCtx.shift_code(out.code, advanced)
        next_temp = EmitCtx.advance_temp(advanced, out.pre + [out.code])
        body = EmitCtx.indented(msg_pre, 1) + ["  IO.warn(#{msg_code})", "  System.exit(1)"]
        EmitCtx.StmtRes.Ok(
          EmitCtx.StmtOut(
            code: cond_pre + ["if !(#{cond_code})"] + body + ["end"],
            scope: ctx.scope,
            next_temp: next_temp,
          ),
        )
      end
  end
end

# The refusal message for a `raise` shape with no message to emit. Mirrors
# `EmitTry` without importing its private helper.
def raise_message(target: Tree.Node) -> String
  if target.rule == "name"
    "raise needs a message: write E(\"msg\"), the class is not modeled"
  else
    "raise takes exactly one message argument"
  end
end
