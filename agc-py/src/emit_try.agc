## Lane C of phase 3c (exceptions and seams): `try`/`except`, `raise` and
## `assert` become check-clean `.agc` templates.
##
## The three 3c lanes never import each other: like the assign and flow lanes,
## every emitter here is pure and takes pre-emitted code strings for nested
## bodies, so the coordinator's spine wires the recursion afterwards. Scope
## (`name -> Agentica type`) and the temp supply (`next_temp`) thread through
## `EmitCtx`; every failure is a `StmtRes.No` refusal with its span, rendered
## by the assembler through `EmitCtx.render_refusal`.
##
## The shapes below were each verified with a real `agentica check` on a temp
## file before they were written in: the `try` body is outlined into a
## `def py_try_body{N}() -> Result[Void]` helper ending in `ok()` unless it
## already ends with `return` (a trailing `return error(...)` from `raise`
## falls through without an unreachable `ok()`; a lone `ok()` body checks,
## so an empty body still outlines), the call site is a `case` with
## `ok(_) -> nil` and an `error(...)` arm, `raise E("msg")` is
## `return error("msg")` inside `-> Result[T]` (probed), failure paths are
## `IO.warn` plus `System.exit(1)` (probed, also for `break` inside a `case`
## inside a `for`), and `_ = e` marks a bound message read (a bare `error(e)`
## with no read is `CHECK-UNUSED-VARIABLE`, probed). `except E as e`
## hoists `e: String = ""` before the `case` (only when unbound) and
## assigns inside the arm, so later uses see the frontend's flat scope.
##
## Layout contract: `emit_try` answers one `code` list holding the helper
## `def` block first, a blank line, then the `case` dispatch, so the assembler
## hoists the leading `def` through its matching `end` to the top level and
## keeps the rest inline. Helper and error names derive from the incoming
## `next_temp` (`py_try_body{N}`, `py_try_err{N}`), which advances by one.
## `except` classes are accepted syntactically and ignored (classes are not
## modeled): every error value reaches the single handler, and `except E as e`
## binds the message `String` as `e` (hoisted before the `case` and assigned
## from `e.message`, so the handler sees the subset meaning of `e`). `raise` at the top level
## (`func_ret == ""`, where `main` cannot `return`) halts with `IO.warn` plus
## `System.exit(1)`: an uncaught raise prints its message to stderr and exits
## nonzero, like the backend. A bare `return` carries no span through the
## frontend, so its `PY-TRY-CONTROL` reports at the first span of its `try`
## body (else file start).

import EmitCtx from "emit_ctx"
import Frontend from "frontend"
import Tree from "../../src/tree"

## Outlines `try_body` into a `-> Result[Void]` helper and dispatches on it.
## `try_code`/`handler_code` are the pre-emitted body lines; `caught` is the
## `except ... as` name when present (the class is already dropped by the
## frontend). Any `return`, `break` or `next` in the `try` body — including
## inside nested `if`/`while`/`for`, a nested `try` body, or a nested
## `except` handler (handlers stay inline in the outer helper, so they
## cannot decide the caller's control flow either) — is `PY-TRY-CONTROL`
## at the offending span.
def emit_try(
  ctx: EmitCtx.EmitCtx,
  try_body: List[Frontend.Stmt],
  try_code: List[String],
  handler_code: List[String],
  caught: Optional[Frontend.NameOcc],
) -> EmitCtx.StmtRes
  hit = find_control(try_body, control_fallback(try_body), ctx.source)
  case hit
    some(span) ->
      EmitCtx.refuse_at(
        "PY-TRY-CONTROL",
        "return, break and next are not allowed inside a try body",
        some("move it out of the try body; only the except body decides control flow"),
        span.start,
        span.stop,
      )
    none -> ok_try(ctx, try_code, handler_code, caught)
  end
end

## Lowers `raise` with the message expression `expr` to
## `return error(<msg_code>)` (message only: the class is never modeled).
## `msg_code` is the pre-emitted message argument and `msg_type` its
## Agentica type, which must be `String` (`PY-TYPE-MISMATCH` at the message
## span otherwise, like `emit_assert`). A bare name, a call with
## anything but exactly one positional argument, or any other shape is
## `PY-OUT-OF-SUBSET` at the expression span.
def emit_raise(ctx: EmitCtx.EmitCtx, expr: Tree.Node, msg_code: String, msg_type: String) -> EmitCtx.StmtRes
  target = raise_target(expr)
  if target.rule == "call" and single_message_arg?(target)
    msg = List.first(target.children.drop(1))
    if msg_type != "String"
      return EmitCtx.refuse_at(
        "PY-TYPE-MISMATCH",
        "raise message must be str, found #{msg_type}",
        some("pass a string message"),
        msg.start,
        msg.stop,
      )
    end

    if ctx.func_ret == ""
      return EmitCtx.StmtRes.Ok(
        EmitCtx.StmtOut(code: ["IO.warn(#{msg_code})", "System.exit(1)"], scope: ctx.scope, next_temp: ctx.next_temp),
      )
    end

    return EmitCtx.StmtRes.Ok(
      EmitCtx.StmtOut(code: ["return error(#{msg_code})"], scope: ctx.scope, next_temp: ctx.next_temp),
    )
  end

  EmitCtx.refuse_at(
    "PY-OUT-OF-SUBSET",
    raise_message(target),
    some("write raise E(\"msg\") with one message"),
    expr.start,
    expr.stop,
  )
end

## Emits `assert <cond_code>[, <msg>]`: the condition must be `Bool`
## (`PY-COND-NOT-BOOL` at its span otherwise) and the message, when present,
## must be `String` (`PY-TYPE-MISMATCH` at its span otherwise). Failure warns
## on stderr and exits nonzero, and is never catchable. A missing message
## code falls back to `"assert failed"`.
def emit_assert(
  ctx: EmitCtx.EmitCtx,
  cond: Tree.Node,
  msg: Optional[Tree.Node],
  cond_code: String,
  cond_type: String,
  msg_code: Optional[String],
  msg_type: Optional[String],
) -> EmitCtx.StmtRes
  if cond_type != "Bool"
    return EmitCtx.refuse_at(
      "PY-COND-NOT-BOOL",
      "assert needs a bool condition, found #{cond_type}",
      some("compare or convert to a bool first"),
      cond.start,
      cond.stop,
    )
  end

  case msg
    some(node) ->
      case msg_type
        some(found) ->
          if found == "String"
            ok_assert(ctx, cond_code, code_or_default(msg_code))
          else
            EmitCtx.refuse_at(
              "PY-TYPE-MISMATCH",
              "assert message must be str, found #{found}",
              some("pass a string message"),
              node.start,
              node.stop,
            )
          end

        none -> ok_assert(ctx, cond_code, "\"assert failed\"")
      end

    none -> ok_assert(ctx, cond_code, "\"assert failed\"")
  end
end

## Call-shape navigation shared with the coordinator spine, which finds
## the message argument to pre-emit it: the `call` or `name` head under
## single-child wrappers, the single-positional-arg check, and the
## keyword-argument check.
## Descends single-child expression wrappers to the `call` or `name` head.
def raise_target(node: Tree.Node) -> Tree.Node
  cur = node
  while chain_rule?(cur.rule) and cur.children.size == 1
    cur = List.first(cur.children)
  end

  cur
end

## The silent expression spine between a statement and its value.
def chain_rule?(rule: String) -> Bool
  (
    rule == "cond_expr" or
    rule == "or_expr" or
    rule == "and_expr" or
    rule == "comparison" or
    rule == "sum" or
    rule == "term" or
    rule == "minus" or
    rule == "plus" or
    rule == "power" or
    rule == "group"
  )
end

## Exactly one positional argument and no keyword ones.
def single_message_arg?(node: Tree.Node) -> Bool
  args = node.children.drop(1)
  return false if args.size != 1

  !is_kwarg?(List.first(args))
end

## Whether `node` is a keyword argument (bare or `arg`-wrapped).
def is_kwarg?(node: Tree.Node) -> Bool
  return true if node.rule == "kwarg"

  node.rule == "arg" and !node.children.empty? and List.last(node.children).rule == "kwarg"
end

private

# Builds the outlined-helper plus dispatch lines for a control-clean body.
# The helper ends with `ok()` unless its last line already returns (a
# trailing `return error(...)` from `raise` falls through to the caller
# without an unreachable `ok()`). An `except ... as e` name is hoisted:
# it is declared once before the `case` (only when not already bound)
# and assigned inside the arm, so later uses see the frontend's flat
# scope instead of a case-local that never escapes. Rebinding an
# already-bound non-`String` name is refused.
def ok_try(
  ctx: EmitCtx.EmitCtx,
  try_code: List[String],
  handler_code: List[String],
  caught: Optional[Frontend.NameOcc],
) -> EmitCtx.StmtRes
  helper = "py_try_body#{ctx.next_temp}"
  err = "py_try_err#{ctx.next_temp}"
  body = try_code
  if body.empty?
    body = ["nil"]
  end

  tail: List[String] = ["  ok()"]
  last = List.last(body).strip
  if last == "return" or last.start_with?("return ")
    tail = []
  end

  helper_lines = ["def #{helper}() -> Result[Void]"] + EmitCtx.indented(body, 1) + tail + ["end"]
  arm_head = "  error(_) ->"
  arm_body = handler_or_nil(handler_code)
  scope = ctx.scope
  pre: List[String] = []
  case caught
    some(occ) ->
      existing = ctx.scope.get(occ.name, "")
      if existing != "" and existing != "String" and existing != "Unknown"
        return EmitCtx.refuse_at(
          "PY-TYPE-MISMATCH",
          "except as `#{occ.name}` needs str, found #{existing}",
          some("pick another name for the message"),
          occ.span.start,
          occ.span.stop,
        )
      end

      arm_head = "  error(#{err}) ->"
      arm_body = ["#{occ.name} = #{err}.message"] + read_mark(handler_code, occ.name) + handler_or_nil(handler_code)
      if existing == ""
        pre = ["#{occ.name}: String = \"\""]
      end

      scope = Map.put(scope, occ.name, "String")
    none -> scope = scope
  end

  code = (
    helper_lines +
    [""] +
    pre +
    ["case #{helper}()", "  ok(_) -> nil", arm_head] +
    EmitCtx.indented(arm_body, 2) +
    ["end"]
  )

  EmitCtx.StmtRes.Ok(EmitCtx.StmtOut(code: code, scope: scope, next_temp: ctx.next_temp + 1))
end

# The arm body: the pre-emitted handler lines, or `nil` so the arm never
# ends up empty (`pass` handlers arrive as `["nil"]` anyway).
def handler_or_nil(handler_code: List[String]) -> List[String]
  return ["nil"] if handler_code.empty?

  handler_code
end

# Marks a bound message read when the handler never names it, so the arm
# stays check-clean without changing what it prints.
def read_mark(handler_code: List[String], name: String) -> List[String]
  return [] if uses_name?(handler_code, name)

  ["_ = #{name}"]
end

# Whether any handler line names `name` as a whole word. String literals
# are stripped first, so `puts("e")` never counts as a read of `e`.
def uses_name?(lines: List[String], name: String) -> Bool
  return false if name == ""

  words_in(strip_strings(lines.join("\n"))).include?(name)
end

# Blanks the contents of string literals (both quote styles,
# backslash-aware) so word scans never read inside them; each literal
# becomes spaces, keeping word boundaries outside intact.
def strip_strings(text: String) -> String
  out = ""
  quote = 0
  escaped = false
  for ch in text.split("")
    code = ch.code
    if quote == 0
      if code == 34 or code == 39
        quote = code
        out = "#{out} "
      else
        out = "#{out}#{ch}"
      end
    elsif escaped
      escaped = false
      out = "#{out} "
    elsif code == 92
      escaped = true
      out = "#{out} "
    elsif code == quote
      quote = 0
      out = "#{out} "
    else
      out = "#{out} "
    end
  end

  out
end

# Splits text into whole identifier words (the runner-facing twin lives in
# the test harness).
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

# The first `return`/`break`/`next` in `stmts`, in source order, or none.
# `fallback` is where a spanless `return` reports: the first span of the
# outer `try` body, seeded once by `emit_try` and threaded unchanged
# through every nested body below.
def find_control(stmts: List[Frontend.Stmt], fallback: Frontend.Span, source: String) -> Optional[Frontend.Span]
  for stmt in stmts
    hit = control_in(stmt, fallback, source)
    case hit
      some(_) -> return hit
      none -> hit = hit
    end
  end

  none
end

# Checks one statement: `return` always, `break`/`next` by source slice
# (`Other` also covers `pass`, which stays legal), nested bodies
# recursively with the same outer `fallback`. A nested `except` handler
# counts too: it stays inline in the outer helper, so it cannot decide
# the caller's control flow either.
def control_in(stmt: Frontend.Stmt, fallback: Frontend.Span, source: String) -> Optional[Frontend.Span]
  case stmt
    Frontend.Stmt.ReturnStmt(value, span) ->
      case value
        some(node) -> some(Frontend.Span(start: node.start, stop: node.stop))
        none -> some(span)
      end

    Frontend.Stmt.Other(span) ->
      word = source.slice(span.start, span.stop - span.start)
      if word == "break" or word == "next"
        some(span)
      else
        none
      end

    Frontend.Stmt.ForLoop(_, _, body) -> find_control(body, fallback, source)
    Frontend.Stmt.WhileStmt(_, body) -> find_control(body, fallback, source)
    Frontend.Stmt.IfStmt(arms, else_body) -> control_in_arms(arms, else_body, fallback, source)
    Frontend.Stmt.TryStmt(inner_try, handler, _) -> find_control(inner_try + handler, fallback, source)
    _ -> none
  end
end

# `bare return` fallback: the frontend keeps no span for it, so report at
# the first span of its `try` body (file start when the body has none).
def control_fallback(stmts: List[Frontend.Stmt]) -> Frontend.Span
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
def stmt_span(stmt: Frontend.Stmt) -> Optional[Frontend.Span]
  case stmt
    Frontend.Stmt.ReturnStmt(value, span) ->
      case value
        some(node) -> some(Frontend.Span(start: node.start, stop: node.stop))
        none -> some(span)
      end

    Frontend.Stmt.Other(span) -> some(span)
    Frontend.Stmt.Annotated(occ, _, _) -> some(occ.span)
    Frontend.Stmt.AliasDef(occ, _) -> some(occ.span)
    Frontend.Stmt.Assigned(occ, _) -> some(occ.span)
    Frontend.Stmt.AugAssigned(occ, _, _) -> some(occ.span)
    Frontend.Stmt.ForLoop(occ, _, _) -> some(occ.span)
    Frontend.Stmt.WhileStmt(cond, _) -> some(Frontend.Span(start: cond.start, stop: cond.stop))
    Frontend.Stmt.IfStmt(arms, else_body) -> arm_span(arms, else_body)
    Frontend.Stmt.TryStmt(inner_try, handler, _) -> some(control_fallback(inner_try + handler))
    Frontend.Stmt.ExprStmt(expr) -> some(Frontend.Span(start: expr.start, stop: expr.stop))
    Frontend.Stmt.AssertStmt(cond, _) -> some(Frontend.Span(start: cond.start, stop: cond.stop))
    Frontend.Stmt.RaiseStmt(expr) -> some(Frontend.Span(start: expr.start, stop: expr.stop))
  end
end

# The first span across the arms of an `if`, else included.
def arm_span(arms: List[Frontend.CondArm], else_body: List[Frontend.Stmt]) -> Optional[Frontend.Span]
  for arm in arms
    return some(Frontend.Span(start: arm.cond.start, stop: arm.cond.stop))
  end

  found = control_fallback(else_body)
  some(found)
end

def control_in_arms(
  arms: List[Frontend.CondArm],
  else_body: List[Frontend.Stmt],
  fallback: Frontend.Span,
  source: String,
) -> Optional[Frontend.Span]
  for arm in arms
    hit = find_control(arm.body, fallback, source)
    case hit
      some(_) -> return hit
      none -> hit = hit
    end
  end

  find_control(else_body, fallback, source)
end

# The refusal message for a `raise` shape that carries no message.
def raise_message(target: Tree.Node) -> String
  if target.rule == "name"
    "raise needs a message: write E(\"msg\"), the class is not modeled"
  else
    "raise takes exactly one message argument"
  end
end

# Builds the `if !cond / warn / exit` lines for a checked condition.
def ok_assert(ctx: EmitCtx.EmitCtx, cond_code: String, text: String) -> EmitCtx.StmtRes
  EmitCtx.StmtRes.Ok(
    EmitCtx.StmtOut(
      code: ["if !(#{cond_code})", "  IO.warn(#{text})", "  System.exit(1)", "end"],
      scope: ctx.scope,
      next_temp: ctx.next_temp,
    ),
  )
end

# The message code when the coordinator pre-emitted one, else the default.
def code_or_default(msg_code: Optional[String]) -> String
  case msg_code
    some(code) -> code
    none -> "\"assert failed\""
  end
end
