## Conditionals and loops for `agc-py` phase 3c lane B: `if`/`elif`/`else`,
## `while`, `for`, `pass`, `break` and `next` become typed `.agc`.
##
## The three 3c lanes never import each other: each one exposes pure emitters
## that take pre-emitted code strings for nested bodies, and the
## coordinator's spine wires the recursion afterwards. This lane owns the
## branching shapes; the coordinator emits every nested body first (with the
## lane that owns its statements) and hands the resulting lines here. These
## functions never parse or emit an inner statement themselves: they only
## emit their own condition or iterable through `EmitExpr.emit` and splice
## the given body lines into the template.
##
## Every emitter answers `EmitCtx.StmtRes`: emitted lines plus the scope and
## temp supply after the statement, or a spanned refusal the assembler
## renders with `EmitCtx.render_refusal`. Conditions must be `Bool`
## (`SUBSET.md` section 6); anything else is `PY-COND-NOT-BOOL` at the
## condition span. A `for` iterates a `List` (element type from the brackets,
## `Unknown` when bare), a `Range` (element `Int`) or a `String`, which
## desugars through `split("")` over Unicode scalar values; anything else is
## `PY-OPERATOR` at the iterable span. `break` and `next` inside a `try` body
## are `PY-TRY-CONTROL`, read off `ctx.in_try`. `pass` emits `nil`, so a body
## never ends up empty.
##
## Every template below was probed with a real `agentica check` before it
## was emitted: `while` with `break`, `for` over a list literal, a `Range`
## and `split("")`, `next` inside both loop kinds, and nested `if`/`else`
## chains all check clean on agentica 0.35.0. `for` binds its target
## implicitly (no declaration line). A first-time target stays inside the
## loop: the backend scopes the loop variable to the loop body, so it never
## enters `StmtOut.scope` (using it afterwards refuses at the use: a narrow
## 3c limitation, documented not defaulted, since no value is invented for
## the empty-iteration case). A target already in scope keeps Python's
## update semantics through a fresh `py_tK` iterator plus `target = py_tK`
## as the first body line, so empty iteration leaves the outer value alone
## and no shadowing error arises; a mismatched element type refuses instead.
## A fresh target the body reassigns (reported by the spine, which sees the
## statements) lowers the same iterator shape: the direct header would make
## the body assign the backend's immutable loop variable (probed
## CHECK-IMMUTABLE-ASSIGNMENT on agentica 0.35.0), while `target = py_tK`
## declares the binding inside the loop body and every later assignment
## rebinds that, Python's semantics. The outgoing scope stays the incoming
## one, so a reassigned fresh target never escapes the loop either.
##
## Temps from a condition preamble (`py_tN`, e.g. a chained comparison that
## evaluates a middle operand once) are shifted by `ctx.next_temp`, so a
## condition never clobbers the coordinator's supply: with a fresh context
## the shift is the identity, and `next_temp` advances past the highest
## preamble temp. The `py_t` prefix stays reserved for generated temps, like
## in phase 3b.

import EmitCtx from "emit_ctx"
import EmitExpr from "emit_expr"
import Frontend from "frontend"
import Tree from "../../src/tree"

## One `if`/`elif` arm: the condition node plus the already-emitted `then`
## lines. The condition node is the `cond` of a `Frontend.CondArm`, sliced
## from `ctx.source` by `EmitExpr.emit`; the `then_code` lines come from the
## coordinator, which emitted the arm body first.
struct IfArm
  cond: Tree.Node
  then_code: List[String]
end

## Emits an `if` chain: one `if` per arm, each later arm nested in the
## previous `else`, the `else_code` lines in the innermost `else`. A
## condition preamble runs right before its own `if`, never hoisted across
## an `else`, so a later guard only evaluates when the earlier arms fail. An
## empty arm list degrades to the bare `else_code` lines (Python always has
## an arm; the coordinator never sends none). An empty `then_code` or
## `else_code` emits `nil`, never an empty block.
def emit_if(ctx: EmitCtx.EmitCtx, arms: List[IfArm], else_code: List[String]) -> EmitCtx.StmtRes
  if arms.empty?
    return EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: else_code, scope: ctx.scope, next_temp: ctx.next_temp))
  end

  current = ctx
  conds: List[CondOut] = []
  for arm in arms
    made = emit_cond(current, arm.cond, "if")
    case made
      error(e) -> return refusal_from_emit(e.message, arm.cond)
      ok(done) ->
        conds = conds.push(done)
        current = current.with(next_temp: done.next_temp)
    end
  end

  lines: List[String] = []
  count = arms.size
  for i in 0...count
    arm = List.first(arms.drop(i))
    done = List.first(conds.drop(i))
    lines = lines + EmitCtx.indented(done.pre, i)
    lines = lines.push(pad(i) + "if #{done.code}")
    lines = lines + EmitCtx.indented(body_or_nil(arm.then_code), i + 1)
    if i < count - 1 or !else_code.empty?
      lines = lines.push(pad(i) + "else")
    end
  end

  lines = lines + EmitCtx.indented(else_code, count)
  for k in 0...count
    lines = lines.push(pad(count - 1 - k) + "end")
  end

  EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: lines, scope: ctx.scope, next_temp: current.next_temp))
end

## Emits `while <cond>` over the pre-emitted `body_code` lines, desugared
## so the guard preamble re-evaluates every iteration: `while true` plus
## the preamble plus `if !(guard): break` plus the body, uniformly even
## when the preamble is empty (a user `break` and the guard `break` both
## exit correctly; `next` re-runs the preamble plus the guard). An empty
## body emits `nil`.
def emit_while(ctx: EmitCtx.EmitCtx, cond: Tree.Node, body_code: List[String]) -> EmitCtx.StmtRes
  made = emit_cond(ctx, cond, "while")
  case made
    error(e) -> refusal_from_emit(e.message, cond)
    ok(done) ->
      lines = ["while true"]
      lines = lines + EmitCtx.indented(done.pre, 1)
      lines = lines.push("  if !(#{done.code})")
      lines = lines.push("    break")
      lines = lines.push("  end")
      lines = lines + EmitCtx.indented(body_or_nil(body_code), 1)
      lines = lines.push("end")
      EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: lines, scope: ctx.scope, next_temp: done.next_temp))
  end
end

## Emits `for <target> in <iterable>` over the pre-emitted `body_code`
## lines. A first-time target emits the direct header (`for <target> in
## ...`): the backend binds the loop variable itself and keeps it inside
## the loop, so the outgoing scope is the incoming one. A prebound target
## emits a fresh iterator (`for py_tK in ...` plus `<target> = py_tK` as
## the first body line), updating the outer slot like Python instead of
## shadowing it; the iterator temp sits past the iterable preamble and the
## body (the spine hands a `next_temp` beyond the body), so it collides
## with neither. The spine also reports (`assigned`) when a first-time
## target is reassigned anywhere in the body, and that shape lowers like
## the prebound one (see `emit_fresh_assigned_for`). A `String` iterable
## maps to `(<code>).split("")`, the parens keeping a concatenated source
## from binding to the last piece only. An empty body emits `nil`.
def emit_for(
  ctx: EmitCtx.EmitCtx,
  target: Frontend.NameOcc,
  iterable: Tree.Node,
  body_code: List[String],
  assigned: Bool,
) -> EmitCtx.StmtRes
  made = EmitExpr.emit(iterable, ctx.source, ctx.scope)
  case made
    error(e) -> refusal_from_emit(e.message, iterable)
    ok(out) ->
      elem = elem_type(out.type)
      case elem
        none ->
          EmitCtx.refuse_at(
            "PY-OPERATOR",
            "for needs a List, Range or String iterable, found #{out.type}",
            some("use a list, a range, or a string"),
            iterable.start,
            iterable.stop,
          )
        some(item) ->
          existing = ctx.scope.get(target.name, "")
          if existing == ""
            if assigned
              emit_fresh_assigned_for(ctx, out, target, body_code)
            else
              emit_first_for(ctx, out, target.name, body_code)
            end
          else
            emit_reuse_for(ctx, out, target, existing, item, body_code)
          end
      end
  end
end

## Emits `pass` as `nil`, so a body never ends up empty. `pass` never fails;
## the span stays for coordinator symmetry with `break` and `next`.
def pass_stmt(ctx: EmitCtx.EmitCtx, span: Frontend.Span) -> EmitCtx.StmtRes
  EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: ["nil"], scope: ctx.scope, next_temp: ctx.next_temp))
end

## Emits `break`. Inside a `try` body the loop cannot be left across the
## outlined handler, so that shape is `PY-TRY-CONTROL` at the span.
def emit_break(ctx: EmitCtx.EmitCtx, span: Frontend.Span) -> EmitCtx.StmtRes
  if ctx.in_try
    return EmitCtx.refuse_at(
      "PY-TRY-CONTROL",
      "break inside a try body cannot cross the handler",
      some("move the loop out of the try body"),
      span.start,
      span.stop,
    )
  end

  EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: ["break"], scope: ctx.scope, next_temp: ctx.next_temp))
end

## Emits `next` (the subset spelling of `continue`: the backend has no
## `continue`, verified by probe). Inside a `try` body it is
## `PY-TRY-CONTROL` at the span, like `break`.
def emit_next(ctx: EmitCtx.EmitCtx, span: Frontend.Span) -> EmitCtx.StmtRes
  if ctx.in_try
    return EmitCtx.refuse_at(
      "PY-TRY-CONTROL",
      "next inside a try body cannot cross the handler",
      some("move the loop out of the try body"),
      span.start,
      span.stop,
    )
  end

  EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: ["next"], scope: ctx.scope, next_temp: ctx.next_temp))
end

## The element type a `for` binds, or none when the iterable has no loop
## form. Shared with the coordinator spine, which seeds the body scope
## before handing the pre-emitted body over. `Unknown` stays verbal.
def elem_type(found: String) -> Optional[String]
  return some("Unknown") if found == "Unknown"

  base = base_of(found)
  return some(inner_of(found)) if base == "List"

  return some("Int") if base == "Range"

  return some("String") if base == "String"

  none
end

private

# One emitted condition: the shifted code, its shifted preamble lines, and
# the temp supply past them.
struct CondOut
  code: String
  pre: List[String]
  next_temp: Int
end

# Emits one branch guard and insists on `Bool`, shifting every preamble
# temp by the incoming supply. Failures are `CODE: message = help: hint`
# strings; the caller renders them into spanned refusals.
def emit_cond(ctx: EmitCtx.EmitCtx, node: Tree.Node, owner: String) -> Result[CondOut]
  out = try EmitExpr.emit(node, ctx.source, ctx.scope)
  if out.type != "Bool"
    return error(
      "PY-COND-NOT-BOOL: `#{owner}` condition must be bool, found #{out.type} = help: compare or convert to a bool first",
    )
  end

  pre = out.pre.map { |line| shift_code(line, ctx.next_temp) }
  code = shift_code(out.code, ctx.next_temp)
  ok(CondOut(code: code, pre: pre, next_temp: advance_temp(ctx.next_temp, out.pre + [out.code])))
end

# Renders an emitter failure (`CODE: message = help: hint`, or a bare
# internal `agc-py` message) as a refusal at the node span.
def refusal_from_emit(message: String, node: Tree.Node) -> EmitCtx.StmtRes
  code = "agc-py"
  rest = message
  cut = message.index_of(":")
  case cut
    some(at) ->
      head = message.slice(0, at).strip
      if !head.empty? and !head.include?(" ")
        code = head
        rest = message.slice(at + 1, message.length - at - 1).strip
      end

    none -> rest = message
  end

  text = rest
  help: Optional[String] = none
  mark = rest.index_of("= help:")
  case mark
    some(at) ->
      text = rest.slice(0, at).strip
      help = some(rest.slice(at + 7, rest.length - at - 7).strip)
    none -> text = rest
  end

  EmitCtx.StmtRes.No(EmitCtx.Refusal(code: code, message: text, help: help, start: node.start, stop: node.stop))
end

# A first-time target: the direct header binds the loop variable in the
# backend, which keeps it inside the loop, so the outgoing scope is the
# incoming one. Post-loop uses refuse at the use (a narrow 3c limitation:
# no default is invented for the empty-iteration case).
def emit_first_for(ctx: EmitCtx.EmitCtx, out: EmitExpr.Out, name: String, body_code: List[String]) -> EmitCtx.StmtRes
  shifted_pre = out.pre.map { |line| shift_code(line, ctx.next_temp) }
  shifted = shift_code(out.code, ctx.next_temp)
  advanced = advance_temp(ctx.next_temp, out.pre + [out.code])
  lines = EmitCtx.indented(shifted_pre, 0)
  lines = lines.push(for_header(name, out.type, shifted))
  lines = lines + EmitCtx.indented(body_or_nil(body_code), 1)
  lines = lines.push("end")
  EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: lines, scope: ctx.scope, next_temp: advanced))
end

# A fresh target the body reassigns: the same iterator shape as the
# prebound case (`for py_tK in ...` plus `target = py_tK` as the first
# body line). There is no element-type check here: the body scope was
# seeded with the element type itself, and the direct header would make
# every body assignment hit the backend's immutable loop variable. The
# outgoing scope stays the incoming one, so the target never escapes.
def emit_fresh_assigned_for(
  ctx: EmitCtx.EmitCtx,
  out: EmitExpr.Out,
  target: Frontend.NameOcc,
  body_code: List[String],
) -> EmitCtx.StmtRes
  shifted_pre = out.pre.map { |line| shift_code(line, ctx.next_temp) }
  shifted = shift_code(out.code, ctx.next_temp)
  advanced = advance_temp(ctx.next_temp, out.pre + [out.code])
  iter = "py_t#{advanced}"
  lines = EmitCtx.indented(shifted_pre, 0)
  lines = lines.push(for_header(iter, out.type, shifted))
  lines = lines.push("  #{target.name} = #{iter}")
  lines = lines + EmitCtx.indented(body_or_nil(body_code), 1)
  lines = lines.push("end")
  EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: lines, scope: ctx.scope, next_temp: advanced + 1))
end

# A prebound target: a fresh iterator plus an assignment keeps Python's
# update semantics (empty iteration leaves the outer value alone, `break`
# keeps the current element) without shadowing the outer slot. A
# mismatched element type refuses as `PY-TYPE-MISMATCH` at the target span.
def emit_reuse_for(
  ctx: EmitCtx.EmitCtx,
  out: EmitExpr.Out,
  target: Frontend.NameOcc,
  existing: String,
  item: String,
  body_code: List[String],
) -> EmitCtx.StmtRes
  if !for_types_match?(existing, item)
    return EmitCtx.refuse_at(
      "PY-TYPE-MISMATCH",
      "cannot bind #{item} to `#{target.name}: #{existing}`",
      some("convert the value explicitly or fix the annotation"),
      target.span.start,
      target.span.stop,
    )
  end

  shifted_pre = out.pre.map { |line| shift_code(line, ctx.next_temp) }
  shifted = shift_code(out.code, ctx.next_temp)
  advanced = advance_temp(ctx.next_temp, out.pre + [out.code])
  iter = "py_t#{advanced}"
  lines = EmitCtx.indented(shifted_pre, 0)
  lines = lines.push(for_header(iter, out.type, shifted))
  lines = lines.push("  #{target.name} = #{iter}")
  lines = lines + EmitCtx.indented(body_or_nil(body_code), 1)
  lines = lines.push("end")
  EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: lines, scope: ctx.scope, next_temp: advanced + 1))
end

# The `for` header line for iterator `name` over emitted iterable code of
# static type `found` (a `String` iterable desugars through `split("")`).
def for_header(name: String, found: String, code: String) -> String
  if base_of(found) == "String"
    "for #{name} in (#{code}).split(\"\")"
  else
    "for #{name} in #{code}"
  end
end

# Whether a prebound loop target of type `want` accepts an element of type
# `got`: exact names, `Unknown` either side, or a bare `List`/`Map`
# against the same base (mirrors the lane A binding rule).
def for_types_match?(want: String, got: String) -> Bool
  return true if want == got

  return true if want == "Unknown" or got == "Unknown"

  if base_of(want) == base_of(got) and (base_of(want) == "List" or base_of(want) == "Map")
    return true if want == base_of(want) or got == base_of(got)
  end

  false
end

# The head of a type name: `List` for `List[Int]`, the name itself when bare.
def base_of(found: String) -> String
  cut = found.index_of("[")
  case cut
    some(at) -> found.slice(0, at)
    none -> found
  end
end

# The element of `List[E]` (or `Unknown` for a bare `List`).
def inner_of(found: String) -> String
  cut = found.index_of("[")
  case cut
    some(at) -> found.slice(at + 1, found.length - at - 2)
    none -> "Unknown"
  end
end

# The temp supply past every `py_tN` in `texts`, shifted by `base`: no temp
# keeps the supply, otherwise one past the highest index.
def advance_temp(base: Int, texts: List[String]) -> Int
  top = max_temp_index(texts)
  return base if top < 0

  base + top + 1
end

# The highest `py_tN` index in `texts`, or -1 when there is none.
# String-aware: occurrences inside `"..."` literals never count (quoted
# interpolations flow through preamble code, so a literal `"py_t0"` must
# not bump the supply). `EmitExpr` threads its temps through `Cx` instead
# of scanning text, so no parallel fix is needed there.
def max_temp_index(texts: List[String]) -> Int
  found = -1
  for text in texts
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
          end

          i += 1
        end
      else
        if ch == "\""
          in_string = true
          i += 1
        else
          if temp_at?(chars, i)
            num = 0
            j = i + 4
            while j < chars.size
              break if !digit?(chars[j])

              num = num * 10 + (chars[j].code - 48)
              j += 1
            end

            if num > found
              found = num
            end

            i = j
          else
            i += 1
          end
        end
      end
    end
  end

  found
end

# Renames every `py_tN` temp in `text` to `py_t{base+N}`. The identity when
# the supply is fresh, so exact-shape tests read plainly. String-aware
# like `max_temp_index`: `"..."` literals pass through untouched.
def shift_code(text: String, base: Int) -> String
  return text if base == 0

  out = ""
  chars = text.split("")
  i = 0
  in_string = false
  while i < chars.size
    ch = chars[i]
    if in_string
      if ch == "\\" and i + 1 < chars.size
        out = "#{out}#{ch}#{chars[i + 1]}"
        i += 2
      else
        if ch == "\""
          in_string = false
        end

        out = "#{out}#{ch}"
        i += 1
      end
    else
      if ch == "\""
        in_string = true
        out = "#{out}#{ch}"
        i += 1
      else
        if temp_at?(chars, i)
          num = 0
          j = i + 4
          while j < chars.size
            break if !digit?(chars[j])

            num = num * 10 + (chars[j].code - 48)
            j += 1
          end

          fresh = base + num
          out = "#{out}py_t#{fresh}"
          i = j
        else
          out = "#{out}#{chars[i]}"
          i += 1
        end
      end
    end
  end

  out
end

# Whether a `py_tN` temp starts at `chars[i]`: the `py_t` letters plus at
# least one digit. A bare `py_t` (or a longer name that merely contains
# those letters elsewhere) never matches: the digit is required.
def temp_at?(chars: List[String], i: Int) -> Bool
  return false if i + 4 >= chars.size

  return false if chars[i] != "p"

  return false if chars[i + 1] != "y"

  return false if chars[i + 2] != "_"

  return false if chars[i + 3] != "t"

  digit?(chars[i + 4])
end

def digit?(ch: String) -> Bool
  code = ch.code
  code >= 48 and code <= 57
end

# `level` steps of two-space indentation.
def pad(level: Int) -> String = "  " * level

# A body that never ends up empty: `pass` arrives here as `nil`.
def body_or_nil(body: List[String]) -> List[String]
  if body.empty?
    ["nil"]
  else
    body
  end
end
