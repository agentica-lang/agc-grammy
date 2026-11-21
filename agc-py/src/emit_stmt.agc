## Statement coordinator spine for `agc-py` phase 3c: every `Frontend.Stmt`
## shape through its lane emitter with threaded scopes and temps.
##
## The three 3c lanes never import each other; this spine owns the
## recursion. Lane A (`EmitAssign`) takes narrowed pieces, lane B
## (`EmitFlow`) takes pre-emitted body lines, lane C outlining
## (`EmitTry.emit_try`) takes pre-emitted body lines plus the raw `try`
## body for its `PY-TRY-CONTROL` scan, and `EmitChecks` (parallel owner in
## `./emit_checks`) owns `raise`/`assert` as `emit_raise(ctx, expr)` and
## `emit_assert(ctx, cond, msg)`, each answering `EmitCtx.StmtRes`.
##
## `emit_block` threads one immutable `EmitCtx` through a statement list:
## each statement sees the scope and temp supply the previous one left, so
## sequential temp producers never collide. Nested arms and blocks start
## from the incoming scope with the current temp supply and advance it, so
## two temp-producing blocks or headers stay non-overlapping. Compound
## shapes emit their bodies first (low temps) and their headers after (high
## temps): still disjoint, never shared.
##
## `BlockOut` keeps hoisted helpers apart from inline lines, including
## nested `try` helpers which hoist past every enclosing branch. `If`
## arms stay independent (each starts from the incoming scope; bindings
## inside a branch do not escape, matching the lane's outgoing scope), `for`
## seeds its target before the body and keeps it after, `try` seeds
## `except ... as e` as `String` before the handler and keeps it after, and
## `while` keeps the incoming scope. Bindings inside `while`/`if`/`for`
## bodies and reassignments inside an outlined `try` body do not escape to
## the caller: the helper takes no parameters, so capturing enclosing
## locals needs the phase 3d call ABI (reported, not implemented here).
## Catchable `Result` semantics inside a `try` body flow through
## `EmitExpr` (`try v` unwraps inside the helper); halts stay uncatchable.
##
## Every failure is a `BlockRes.No` refusal with its span; unsupported
## shapes refuse as `PY-OUT-OF-SUBSET` instead of dropping or miscompiling.
## `try` checks prohibited control before lowering its bodies (a probe call
## with empty codes), keeps helper ids unique through `next_temp`, and
## splits the outlined `def` from the inline `case` dispatch.

import EmitAssign from "emit_assign"
import EmitChecks from "emit_checks"
import EmitCtx from "emit_ctx"
import EmitExpr from "emit_expr"
import EmitFlow from "emit_flow"
import EmitTry from "emit_try"
import Frontend from "frontend"
import Tree from "../../src/tree"

## One emitted block: inline lines plus hoisted top-level helper lines, the
## scope and temp supply after the block.
struct BlockOut
  code: List[String]
  helpers: List[String]
  scope: Map[String, String]
  next_temp: Int
end

## A block answer: emitted lines or a spanned refusal.
enum BlockRes
  Ok(BlockOut)
  No(EmitCtx.Refusal)
end

## Emits every statement in `body` in order through `ctx`, threading the
## immutable scope and temp supply. A refusal anywhere stops the block.
def emit_block(ctx: EmitCtx.EmitCtx, body: List[Frontend.Stmt]) -> BlockRes
  current = ctx
  code: List[String] = []
  helpers: List[String] = []
  for stmt in body
    frag = emit_one(current, stmt)
    case frag
      BlockRes.No(_) -> return frag
      BlockRes.Ok(out) ->
        code = code + out.code
        helpers = join_helpers(helpers, out.helpers)
        current = current.with(scope: out.scope, next_temp: out.next_temp)
    end
  end

  BlockRes.Ok(BlockOut(code: code, helpers: helpers, scope: current.scope, next_temp: current.next_temp))
end

private

# Emits one statement as a block fragment (helpers empty except for `try`).
def emit_one(ctx: EmitCtx.EmitCtx, stmt: Frontend.Stmt) -> BlockRes
  case stmt
    Frontend.Stmt.Annotated(occ, ann, value) -> from_res(EmitAssign.emit_annotated(ctx, occ, ann, value, ctx.source))
    Frontend.Stmt.AliasDef(occ, ann) -> from_res(EmitAssign.emit_alias(ctx, occ, ann, ctx.source))
    Frontend.Stmt.Assigned(occ, value) -> from_res(EmitAssign.emit_assigned(ctx, occ, value, ctx.source))
    Frontend.Stmt.AugAssigned(occ, op, value) -> from_res(EmitAssign.emit_augassigned(ctx, occ, op, value, ctx.source))
    Frontend.Stmt.ExprStmt(expr) -> from_res(EmitAssign.emit_expr_stmt(ctx, expr, ctx.source))
    Frontend.Stmt.ReturnStmt(value, span) -> from_res(EmitAssign.emit_return(ctx, value, span, ctx.source))
    Frontend.Stmt.Other(span) -> emit_other(ctx, span)
    Frontend.Stmt.IfStmt(arms, else_body) -> emit_if_block(ctx, arms, else_body)
    Frontend.Stmt.WhileStmt(cond, body) -> emit_while_block(ctx, cond, body)
    Frontend.Stmt.ForLoop(target, iterable, body) -> emit_for_block(ctx, target, iterable, body)
    Frontend.Stmt.TryStmt(try_body, handler_body, caught) -> emit_try_block(ctx, try_body, handler_body, caught)
    Frontend.Stmt.AssertStmt(cond, msg) -> from_res(EmitChecks.emit_assert(ctx, cond, msg))
    Frontend.Stmt.RaiseStmt(expr) -> from_res(EmitChecks.emit_raise(ctx, expr))
  end
end

# Lifts a lane `StmtRes` into a helper-free block fragment.
def from_res(res: EmitCtx.StmtRes) -> BlockRes
  case res
    EmitCtx.StmtRes.Ok(done) ->
      BlockRes.Ok(BlockOut(code: done.code, helpers: [], scope: done.scope, next_temp: done.next_temp))
    EmitCtx.StmtRes.No(ref) -> BlockRes.No(ref)
  end
end

# `Other` covers only `pass`/`break`/`next`: the word at the span decides.
def emit_other(ctx: EmitCtx.EmitCtx, span: Frontend.Span) -> BlockRes
  word = ctx.source.slice(span.start, span.stop - span.start)
  return from_res(EmitFlow.emit_break(ctx, span)) if word == "break"

  return from_res(EmitFlow.emit_next(ctx, span)) if word == "next"

  from_res(EmitFlow.pass_stmt(ctx, span))
end

# Emits each arm body from the incoming scope with a threaded temp supply,
# then the lane splices the inline lines under its guards. Arm bindings do
# not escape; temps never overlap between bodies and guards.
def emit_if_block(ctx: EmitCtx.EmitCtx, arms: List[Frontend.CondArm], else_body: List[Frontend.Stmt]) -> BlockRes
  temp = ctx.next_temp
  helpers: List[String] = []
  then_codes: List[List[String]] = []
  for arm in arms
    frag = emit_block(ctx.with(next_temp: temp), arm.body)
    case frag
      BlockRes.No(_) -> return frag
      BlockRes.Ok(out) ->
        then_codes = then_codes.push(out.code)
        helpers = join_helpers(helpers, out.helpers)
        temp = out.next_temp
    end
  end

  else_frag = emit_block(ctx.with(next_temp: temp), else_body)
  else_code: List[String] = []
  case else_frag
    BlockRes.No(_) -> return else_frag
    BlockRes.Ok(out) ->
      else_code = out.code
      helpers = join_helpers(helpers, out.helpers)
      temp = out.next_temp
  end

  lane_arms: List[EmitFlow.IfArm] = []
  index = 0
  for arm in arms
    lane_arms = lane_arms.push(EmitFlow.IfArm(cond: arm.cond, then_code: List.first(then_codes.drop(index))))
    index += 1
  end

  res = EmitFlow.emit_if(ctx.with(next_temp: temp), lane_arms, else_code)
  case res
    EmitCtx.StmtRes.Ok(done) ->
      BlockRes.Ok(BlockOut(code: done.code, helpers: helpers, scope: done.scope, next_temp: done.next_temp))
    EmitCtx.StmtRes.No(ref) -> BlockRes.No(ref)
  end
end

# Emits the body first, then the lane re-evaluates the guard around it.
# Body bindings do not escape; the guard preamble sits past body temps.
def emit_while_block(ctx: EmitCtx.EmitCtx, cond: Tree.Node, body: List[Frontend.Stmt]) -> BlockRes
  frag = emit_block(ctx, body)
  case frag
    BlockRes.No(_) -> frag
    BlockRes.Ok(out) ->
      res = EmitFlow.emit_while(ctx.with(next_temp: out.next_temp), cond, out.code)
      case res
        EmitCtx.StmtRes.Ok(done) ->
          BlockRes.Ok(BlockOut(code: done.code, helpers: out.helpers, scope: done.scope, next_temp: done.next_temp))
        EmitCtx.StmtRes.No(ref) -> BlockRes.No(ref)
      end
  end
end

# Seeds the loop target from the iterable element type before the body,
# then the lane binds it again for the outgoing scope. A non-iterable
# refuses like the lane; body bindings do not escape.
def emit_for_block(
  ctx: EmitCtx.EmitCtx,
  target: Frontend.NameOcc,
  iterable: Tree.Node,
  body: List[Frontend.Stmt],
) -> BlockRes
  elem = for_elem(ctx, iterable)
  case elem
    error(e) -> block_no(ctx, iterable, e)
    ok(item) ->
      body_frag = emit_block(ctx.with(scope: ctx.scope.put(target.name, item)), body)
      case body_frag
        BlockRes.No(_) -> body_frag
        BlockRes.Ok(out) ->
          res = EmitFlow.emit_for(ctx.with(next_temp: out.next_temp), target, iterable, out.code)
          case res
            EmitCtx.StmtRes.Ok(done) ->
              BlockRes.Ok(
                BlockOut(code: done.code, helpers: out.helpers, scope: done.scope, next_temp: done.next_temp),
              )
            EmitCtx.StmtRes.No(ref) -> BlockRes.No(ref)
          end
      end
  end
end

# The element type for a `for` target, refusing like the lane when the
# iterable has no loop form. Errors are `CODE: message` strings.
def for_elem(ctx: EmitCtx.EmitCtx, iterable: Tree.Node) -> Result[String]
  out = try emit_expr_type(ctx, iterable)
  case EmitFlow.elem_type(out)
    some(item) -> ok(item)
    none -> error("PY-OPERATOR: for needs a List, Range or String iterable, found #{out}")
  end
end

# Renders a header failure at the iterable span as a block refusal.
def block_no(ctx: EmitCtx.EmitCtx, node: Tree.Node, err: Error) -> BlockRes
  case EmitCtx.refusal_from_error(node.start, node.stop, err)
    EmitCtx.StmtRes.No(ref) -> BlockRes.No(ref)
    EmitCtx.StmtRes.Ok(_) ->
      BlockRes.No(
        EmitCtx.Refusal(
          code: "PY-OUT-OF-SUBSET",
          message: err.message,
          help: none,
          start: node.start,
          stop: node.stop,
        ),
      )
  end
end

# The static type of `node`.
def emit_expr_type(ctx: EmitCtx.EmitCtx, node: Tree.Node) -> Result[String]
  case EmitExpr.emit(node, ctx.source, ctx.scope)
    error(e) -> error(e.message)
    ok(out) -> ok(out.type)
  end
end

# Outlines the `try` body into a helper and dispatches on it. Control is
# probed before either body lowers, the handler starts from the incoming
# scope plus `e: String` when bound, helper ids come from the threaded
# supply, and nested helpers hoist past the new helper.
def emit_try_block(
  ctx: EmitCtx.EmitCtx,
  try_body: List[Frontend.Stmt],
  handler_body: List[Frontend.Stmt],
  caught: Optional[Frontend.NameOcc],
) -> BlockRes
  probe = EmitTry.emit_try(ctx, try_body, [], [], caught)
  case probe
    EmitCtx.StmtRes.No(ref) -> return BlockRes.No(ref)
    EmitCtx.StmtRes.Ok(_) -> probe = probe
  end

  try_frag = emit_block(ctx.with(in_try: true), try_body)
  case try_frag
    BlockRes.No(_) -> try_frag
    BlockRes.Ok(try_out) ->
      handler_scope = ctx.scope
      case caught
        some(occ) -> handler_scope = handler_scope.put(occ.name, "String")
        none -> handler_scope = handler_scope
      end

      handler_ctx = EmitCtx.EmitCtx(
        source: ctx.source,
        file: ctx.file,
        scope: handler_scope,
        func_ret: ctx.func_ret,
        in_try: ctx.in_try,
        next_temp: try_out.next_temp,
      )

      handler_frag = emit_block(handler_ctx, handler_body)
      case handler_frag
        BlockRes.No(_) -> handler_frag
        BlockRes.Ok(handler_out) ->
          nested = join_helpers(try_out.helpers, handler_out.helpers)
          res = EmitTry.emit_try(
            ctx.with(next_temp: handler_out.next_temp),
            try_body,
            try_out.code,
            handler_out.code,
            caught,
          )

          case res
            EmitCtx.StmtRes.No(ref) -> BlockRes.No(ref)
            EmitCtx.StmtRes.Ok(done) ->
              parts = split_try(done.code)
              BlockRes.Ok(
                BlockOut(
                  code: List.first(parts.drop(1)),
                  helpers: join_helpers(nested, List.first(parts)),
                  scope: done.scope,
                  next_temp: done.next_temp,
                ),
              )
          end
      end
  end
end

# Joins two helper blocks with a blank line between top-level `def`s,
# so the backend `blank_line_after_end` rule stays happy.
def join_helpers(left: List[String], right: List[String]) -> List[String]
  return right if left.empty?

  return left if right.empty?

  left + [""] + right
end

# Splits an outlined `try` answer into hoisted helper lines and inline
# dispatch lines at the first top-level `end`, but only when the answer
# opens with a helper `def`.
def split_try(lines: List[String]) -> List[List[String]]
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
