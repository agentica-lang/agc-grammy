## Shared statement-emission context for phase 3c.
##
## The three 3c lanes (assign, flow, try) never import each other: each one
## exposes pure emitters that take pre-emitted code strings for nested
## bodies, and the coordinator's spine wires the recursion afterwards. Every
## lane shares this module for the context type, the refusal shape (a
## `PY-*` code with its span, rendered through `Frontend.render` by the
## assembler) and small formatting helpers. Tests follow the 3b pattern:
## tiny programs (at most three lines, one line for attribute-heavy ones —
## the runner step budget dies on bigger batches), fragments accumulated per
## file, a single aggregated `agentica check` at the end.

import Frontend from "frontend"
import Tree from "../../src/tree"

## What an emitter threads: the source being sliced, the file name for
## diagnostics, the visible names with their types, the enclosing `def`
## return annotation ("" at top level), whether the statement sits inside a
## `try` body, and the next free temp number.
struct EmitCtx
  source: String
  file: String
  scope: Map[String, String]
  func_ret: String
  in_try: Bool
  next_temp: Int
end

## One emitted statement: code lines plus the scope and temp supply after it.
struct StmtOut
  code: List[String]
  scope: Map[String, String]
  next_temp: Int
end

## A refusal with its span; the assembler renders it with `Frontend.render`.
struct Refusal
  code: String
  message: String
  help: Optional[String]
  start: Int
  stop: Int
end

## An emitter answer: emitted lines or a spanned refusal.
enum StmtRes
  Ok(StmtOut)
  No(Refusal)
end

## `take_temp` answer: the fresh name plus the advanced context.
struct TempTake
  name: String
  ctx: EmitCtx
end

## Refuses with the span of `node`.
def refuse(code: String, message: String, help: Optional[String], node: Tree.Node) -> StmtRes
  refusal = Refusal(code: code, message: message, help: help, start: node.start, stop: node.stop)
  StmtRes.No(refusal)
end

## Refuses with an explicit span (for `NameOcc`/`Span` positions).
def refuse_at(code: String, message: String, help: Optional[String], start: Int, stop: Int) -> StmtRes
  refusal = Refusal(code: code, message: message, help: help, start: start, stop: stop)
  StmtRes.No(refusal)
end

## Renders a refusal exactly like a frontend diagnostic.
def render_refusal(file: String, source: String, refusal: Refusal) -> String
  Frontend.render(
    file,
    source,
    Frontend.Diagnostic(
      code: refusal.code,
      message: refusal.message,
      help: refusal.help,
      start: refusal.start,
      stop: refusal.stop,
    ),
  )
end

## Indents every non-empty line by `level` steps.
def indented(lines: List[String], level: Int) -> List[String]
  pad = "  " * level
  out: List[String] = []
  for line in lines
    if line.empty?
      out = out.push(line)
    else
      out = out.push(pad + line)
    end
  end

  out
end

def take_temp(ctx: EmitCtx) -> TempTake
  TempTake(name: "py_t#{ctx.next_temp}", ctx: ctx.with(next_temp: ctx.next_temp + 1))
end
