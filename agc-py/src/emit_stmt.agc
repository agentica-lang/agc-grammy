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
## seeds a new target only for its body, `try` seeds
## `except ... as e` as `String` before the handler and keeps it after, and
## `while` keeps the incoming scope. Bindings inside `while`/`if`/`for`
## bodies do not escape to the caller. A `try` body runs in an outlined
## helper: reads of outer locals become typed read-only captures (helper
## parameters, verified by `check`), while writes to outer locals are
## refused at the source instead of silently discarding them. The helper
## runs with the helper's own `Result[Void]` return type threaded as
## `func_ret`, so `raise` returns an error to the handler instead of
## exiting (the raise seam in `EmitChecks` accepts only that shape).
## Catchable `Result` semantics inside a `try` body flow through
## `EmitExpr` plus lane A `try` unwrapping (`try v` unwraps inside the
## helper; directly consumed `Result` values unwrap, nested ones refuse);
## halts stay uncatchable.
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
import {Stmt} from "frontend"
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
def emit_block(ctx: EmitCtx.EmitCtx, body: List[Stmt]) -> BlockRes
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
def emit_one(ctx: EmitCtx.EmitCtx, stmt: Stmt) -> BlockRes
  case stmt
    Stmt.Annotated(occ, ann, value) -> from_res(EmitAssign.emit_annotated(ctx, occ, ann, value, ctx.source))
    Stmt.AliasDef(occ, ann) -> hoist_alias(ctx, occ, ann)
    Stmt.Assigned(occ, value) -> from_res(EmitAssign.emit_assigned(ctx, occ, value, ctx.source))
    Stmt.AugAssigned(occ, op, value) -> from_res(EmitAssign.emit_augassigned(ctx, occ, op, value, ctx.source))
    Stmt.ExprStmt(expr) -> from_res(EmitAssign.emit_expr_stmt(ctx, expr, ctx.source))
    Stmt.ReturnStmt(value, span) -> from_res(EmitAssign.emit_return(ctx, value, span, ctx.source))
    Stmt.Other(span) -> emit_other(ctx, span)
    Stmt.IfStmt(arms, else_body) -> emit_if_block(ctx, arms, else_body)
    Stmt.WhileStmt(cond, body) -> emit_while_block(ctx, cond, body)
    Stmt.ForLoop(target, iterable, body) -> emit_for_block(ctx, target, iterable, body)
    Stmt.TryStmt(try_body, handler_body, caught) -> emit_try_block(ctx, try_body, handler_body, caught)
    Stmt.AssertStmt(cond, msg) -> from_res(EmitChecks.emit_assert(ctx, cond, msg))
    Stmt.RaiseStmt(expr) -> from_res(EmitChecks.emit_raise(ctx, expr))
  end
end

# `type Alias = T` is a top-level declaration: the lane refuses it inside a
# `def` (including an outlined `try` helper), so a passing fragment hoists
# its `type` line next to the helper `def`s instead of leaving it inline,
# where a later function assembly would find it inside a body.
def hoist_alias(ctx: EmitCtx.EmitCtx, occ: Frontend.NameOcc, ann: Frontend.Ann) -> BlockRes
  case EmitAssign.emit_alias(ctx, occ, ann, ctx.source)
    EmitCtx.StmtRes.Ok(done) ->
      BlockRes.Ok(BlockOut(code: [], helpers: done.code, scope: done.scope, next_temp: done.next_temp))
    EmitCtx.StmtRes.No(ref) -> BlockRes.No(ref)
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
# Inside a `try` body the lane refuses first (`PY-TRY-CONTROL`), otherwise
# `break`/`next` need a `for`/`while` body around them: the spine threads
# `in_loop` from the body emitters, so a stray `break` refuses spanned
# instead of emitting code the backend cannot place.
def emit_other(ctx: EmitCtx.EmitCtx, span: Frontend.Span) -> BlockRes
  word = ctx.source.slice(span.start, span.stop - span.start)
  if word == "break" or word == "next"
    return refuse_control(word, span) if !ctx.in_loop and !ctx.in_try

    return from_res(EmitFlow.emit_break(ctx, span)) if word == "break"

    return from_res(EmitFlow.emit_next(ctx, span))
  end

  from_res(EmitFlow.pass_stmt(ctx, span))
end

# `break`/`next` need a `for`/`while` body around them: the spine threads
# `in_loop` from the body emitters, so a stray control word refuses spanned
# instead of emitting code the backend cannot place. Inside a `try` body
# the lane refuses first (`PY-TRY-CONTROL`), so that code wins where both
# could apply.
def refuse_control(word: String, span: Frontend.Span) -> BlockRes
  BlockRes.No(
    EmitCtx.Refusal(
      code: "PY-OUT-OF-SUBSET",
      message: "`#{word}` outside a loop has no backend form",
      help: some("put it inside a for or while loop"),
      start: span.start,
      stop: span.stop,
    ),
  )
end

# Emits each arm body from the incoming scope with a threaded temp supply,
# then the lane splices the inline lines under its guards. Arm bindings do
# not escape; temps never overlap between bodies and guards.
def emit_if_block(ctx: EmitCtx.EmitCtx, arms: List[Frontend.CondArm], else_body: List[Stmt]) -> BlockRes
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
# The body runs with `in_loop`, so a `break`/`next` there reaches the lane.
def emit_while_block(ctx: EmitCtx.EmitCtx, cond: Tree.Node, body: List[Stmt]) -> BlockRes
  frag = emit_block(ctx.with(in_loop: true), body)
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

# Seeds a new loop target from the iterable element type for the body.
# A prebound target keeps its declared type; body bindings do not escape.
# The body runs with `in_loop`, so a `break`/`next` there reaches the lane.
# A fresh target the body reassigns is reported to the lane: the direct
# header would lower to assigning the backend's immutable loop variable
# (probed CHECK-IMMUTABLE-ASSIGNMENT on agentica 0.35.0), so that shape
# gets the iterator lowering (`emit_fresh_assigned_for`) instead.
def emit_for_block(ctx: EmitCtx.EmitCtx, target: Frontend.NameOcc, iterable: Tree.Node, body: List[Stmt]) -> BlockRes
  elem = for_elem(ctx, iterable)
  case elem
    error(e) -> block_no(ctx, iterable, e)
    ok(item) ->
      target_type = ctx.scope.get(target.name, item)
      assigned = ctx.scope.get(target.name, "") == "" and body_assigns_target?(body, target.name)
      body_frag = emit_block(ctx.with(scope: ctx.scope.put(target.name, target_type), in_loop: true), body)
      case body_frag
        BlockRes.No(_) -> body_frag
        BlockRes.Ok(out) ->
          res = EmitFlow.emit_for(ctx.with(next_temp: out.next_temp), target, iterable, out.code, assigned)
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

# Whether the `for` body reassigns the fresh target `name` anywhere it
# runs: a direct or augmented assignment, or a nested loop binding the
# same name (Python rebinds the outer target through the inner header).
# `try` bodies refuse outer writes on their own, so their recursion here
# only covers the inline handler, which does rebind.
def body_assigns_target?(stmts: List[Stmt], name: String) -> Bool
  for stmt in stmts
    return true if assigns_target_in(stmt, name)
  end

  false
end

# One statement's reassignment of `name`, recursing into nested bodies.
def assigns_target_in(stmt: Stmt, name: String) -> Bool
  case stmt
    Stmt.Assigned(occ, _) -> occ.name == name
    Stmt.AugAssigned(occ, _, _) -> occ.name == name
    Stmt.ForLoop(target, _, body) -> target.name == name or body_assigns_target?(body, name)
    Stmt.IfStmt(arms, else_body) -> if_assigns_target?(arms, else_body, name)
    Stmt.WhileStmt(_, body) -> body_assigns_target?(body, name)
    Stmt.TryStmt(try_body, handler_body, _) ->
      body_assigns_target?(try_body, name) or body_assigns_target?(handler_body, name)
    _ -> false
  end
end

def if_assigns_target?(arms: List[Frontend.CondArm], else_body: List[Stmt], name: String) -> Bool
  for arm in arms
    return true if body_assigns_target?(arm.body, name)
  end

  body_assigns_target?(else_body, name)
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
# probed before either body lowers, outer writes inside the body are
# refused, the helper runs with its real `Result[Void]` return type so
# `raise` lowers to `return error(...)` there and `return` still refuses
# first through `in_try`, outer reads become typed captures, the handler
# starts from the incoming scope plus `e: String` when bound, helper ids
# come from the threaded supply, and nested helpers hoist past the new
# helper.
def emit_try_block(
  ctx: EmitCtx.EmitCtx,
  try_body: List[Stmt],
  handler_body: List[Stmt],
  caught: Optional[Frontend.NameOcc],
) -> BlockRes
  probe = EmitTry.emit_try(ctx, try_body, [], [], caught)
  case probe
    EmitCtx.StmtRes.No(ref) -> return BlockRes.No(ref)
    EmitCtx.StmtRes.Ok(_) -> probe = probe
  end

  outer_write = find_outer_write(try_body, ctx.scope)
  case outer_write
    some(occ) ->
      return BlockRes.No(
        EmitCtx.Refusal(
          code: "PY-OUT-OF-SUBSET",
          message: "assignment to outer `#{occ.name}` inside a try body has no backend form",
          help: some("move it out of the try body or copy it to a new name"),
          start: occ.span.start,
          stop: occ.span.stop,
        ),
      )
    none -> outer_write = outer_write
  end

  body_ret = "Result[Void]"

  try_frag = emit_block(ctx.with(in_try: true, func_ret: body_ret), try_body)
  case try_frag
    BlockRes.No(_) -> try_frag
    BlockRes.Ok(try_out) ->
      caps = try_captures(try_out.code, ctx.scope)
      cap_types: List[String] = []
      for name in caps
        cap_types = cap_types.push(ctx.scope.get(name, ""))
      end

      index = 0
      for name in caps
        ty = List.first(cap_types.drop(index))
        if ty == "" or ty == "Unknown"
          fallback = try_fallback(try_body)
          return BlockRes.No(
            EmitCtx.Refusal(
              code: "PY-OUT-OF-SUBSET",
              message: "try body reads outer `#{name}` with no backend capture form",
              help: some("move it out of the try body or give it a concrete type"),
              start: fallback.start,
              stop: fallback.stop,
            ),
          )
        end

        index += 1
      end

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
        in_loop: ctx.in_loop,
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
              shaped = with_captures(done.code, handler_out.next_temp, caps, cap_types)
              parts = split_try(shaped)
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

# The first write to an outer name inside `stmts`, if any: assignments
# and `for` targets that name a caller local are refused instead of
# silently discarding them in the by-value helper. New bindings inside
# the body never match `outer`, so only true outer writes refuse.
def find_outer_write(stmts: List[Stmt], outer: Map[String, String]) -> Optional[Frontend.NameOcc]
  for stmt in stmts
    hit = write_in(stmt, outer)
    case hit
      some(_) -> return hit
      none -> hit = hit
    end
  end

  none
end

# Checks one statement for an outer write, recursing into nested bodies.
# A nested `try` contributes both its body and its handler: both run
# inside the outer helper, so both would discard an outer write.
def write_in(stmt: Stmt, outer: Map[String, String]) -> Optional[Frontend.NameOcc]
  case stmt
    Stmt.Assigned(occ, _) ->
      if outer.get(occ.name, "") != ""
        some(occ)
      else
        none
      end

    Stmt.AugAssigned(occ, _, _) ->
      if outer.get(occ.name, "") != ""
        some(occ)
      else
        none
      end

    Stmt.ForLoop(target, _, body) ->
      if outer.get(target.name, "") != ""
        some(target)
      else
        find_outer_write(body, outer)
      end

    Stmt.IfStmt(arms, else_body) ->
      for arm in arms
        hit = find_outer_write(arm.body, outer)
        case hit
          some(_) -> return hit
          none -> hit = hit
        end
      end

      find_outer_write(else_body, outer)
    Stmt.WhileStmt(_, body) -> find_outer_write(body, outer)
    Stmt.TryStmt(inner_try, handler, _) ->
      hit = find_outer_write(inner_try, outer)
      case hit
        some(_) -> hit
        none -> find_outer_write(handler, outer)
      end

    _ -> none
  end
end

# Outer locals read by the outlined body, in caller scope order: the
# typed read-only captures the helper takes as parameters. `def` names
# carry the callable marker in the scope, not a value type: a try body
# that calls a def is not a capture, so marker entries never invent a
# `name: Function` helper parameter.
def try_captures(code: List[String], outer: Map[String, String]) -> List[String]
  words = words_in(strip_strings(code.join("\n")))
  caps: List[String] = []
  for name in outer.keys()
    if words.include?(name) and outer.get(name, "") != EmitCtx.def_marker()
      caps = caps.push(name)
    end
  end

  caps
end

# Adds capture parameters to the outlined helper and arguments to its
# call site (`def py_try_bodyN(a: Int)` / `case py_try_bodyN(a)`).
def with_captures(code: List[String], num: Int, caps: List[String], types: List[String]) -> List[String]
  return code if caps.empty?

  params: List[String] = []
  index = 0
  for name in caps
    params = params.push("#{name}: #{List.first(types.drop(index))}")
    index += 1
  end

  decl = "def py_try_body#{num}(#{params.join(", ")}) -> Result[Void]"
  call = "case py_try_body#{num}(#{caps.join(", ")})"
  out: List[String] = []
  for line in code
    if line == "def py_try_body#{num}() -> Result[Void]"
      out = out.push(decl)
    else
      if line == "case py_try_body#{num}()"
        out = out.push(call)
      else
        out = out.push(line)
      end
    end
  end

  out
end

# The first span of a `try` body for capture refusals without a precise
# name span: the first statement span, else file start.
def try_fallback(stmts: List[Stmt]) -> Frontend.Span
  for stmt in stmts
    found = stmt_span(stmt)
    case found
      some(span) -> return span
      none -> found = found
    end
  end

  Frontend.Span(start: 0, stop: 0)
end

# The first span a statement offers for diagnostics.
def stmt_span(stmt: Stmt) -> Optional[Frontend.Span]
  case stmt
    Stmt.ReturnStmt(value, span) ->
      case value
        some(node) -> some(Frontend.Span(start: node.start, stop: node.stop))
        none -> some(span)
      end

    Stmt.Other(span) -> some(span)
    Stmt.Annotated(occ, _, _) -> some(occ.span)
    Stmt.AliasDef(occ, _) -> some(occ.span)
    Stmt.Assigned(occ, _) -> some(occ.span)
    Stmt.AugAssigned(occ, _, _) -> some(occ.span)
    Stmt.ForLoop(occ, _, _) -> some(occ.span)
    Stmt.WhileStmt(cond, _) -> some(Frontend.Span(start: cond.start, stop: cond.stop))
    Stmt.IfStmt(arms, else_body) ->
      for arm in arms
        return some(Frontend.Span(start: arm.cond.start, stop: arm.cond.stop))
      end

      some(try_fallback(else_body))
    Stmt.TryStmt(inner_try, handler, _) -> some(try_fallback(inner_try + handler))
    Stmt.ExprStmt(expr) -> some(Frontend.Span(start: expr.start, stop: expr.stop))
    Stmt.AssertStmt(cond, _) -> some(Frontend.Span(start: cond.start, stop: cond.stop))
    Stmt.RaiseStmt(expr) -> some(Frontend.Span(start: expr.start, stop: expr.stop))
  end
end

# Blanks string literals so word scans never read inside them, keeping
# `#{...}` interpolation as code: `puts("#{x}")` reads `x`, while
# `puts("x")` does not.
def strip_strings(text: String) -> String
  out = ""
  chars = text.split("")
  i = 0
  quote = 0
  escaped = false
  while i < chars.size
    ch = chars[i]
    code = ch.code
    if quote == 0
      if code == 34 or code == 39
        quote = code
        out = "#{out} "
        i += 1
      else
        out = "#{out}#{ch}"
        i += 1
      end
    elsif escaped
      escaped = false
      out = "#{out} "
      i += 1
    elsif code == 92
      escaped = true
      out = "#{out} "
      i += 1
    elsif code == quote
      quote = 0
      out = "#{out} "
      i += 1
    else
      if ch == "#" and i + 1 < chars.size and chars[i + 1] == "{"
        out = "#{out}#{ch}#{chars[i + 1]}"
        i += 2
        depth = 1
        while i < chars.size and depth > 0
          inner = chars[i]
          if inner == "{"
            depth += 1
          end

          if inner == "}"
            depth -= 1
          end

          out = "#{out}#{inner}"
          i += 1
        end
      else
        out = "#{out} "
        i += 1
      end
    end
  end

  out
end

# Splits text into whole identifier words.
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
