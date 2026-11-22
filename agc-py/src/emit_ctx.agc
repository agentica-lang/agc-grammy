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
## `try` body, whether the statement sits inside a `for`/`while` body (the
## spine sets it, so `break`/`next` refuse with a span outside a loop), the
## next free temp number, and the call ABI signatures (one `Sig` per `def`,
## so a user call checks its arguments and lowers defaults in place).
struct EmitCtx
  source: String
  file: String
  scope: Map[String, String]
  func_ret: String
  in_try: Bool
  in_loop: Bool = false
  next_temp: Int
  sigs: Map[String, Sig] = {}
end

## One `def` signature for the call ABI: parameter names and their backend
## types in order, each parameter's default-value expression node (`none`
## when the parameter has none), and the mapped return type.
struct Sig
  name: String
  params: List[String]
  types: List[String]
  defaults: List[Optional[Tree.Node]]
  ret: String
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

struct ErrorParts
  code: String
  message: String
  help: Optional[String]
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

## The scope spelling recorded for a `def` name: functions are not values
## (probed CHECK-UNKNOWN-NAME), so the scope keeps them callable-only. A
## call site reads the entry only for existence, while a bare use of the
## name flows the marker into a type position and refuses downstream
## (`PY-TYPE-MISMATCH`) instead of compiling. The try-capture scan skips
## marker entries, so calling a def inside a try body never invents a
## `name: Function` helper parameter.
def def_marker() -> String = "Function"

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

# Renames every `py_tN` temp in `text` to `py_t{base+N}`. The identity when
# the supply is fresh. String-aware: occurrences inside `"..."` literals
# pass through untouched (interpolated code is scanned, literal text with
# a `\` escape is skipped as a pair). Mirrors the lane B helpers; unify
# on a rainy day.
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
        if shift_temp_at?(chars, i)
          num = shift_temp_num(chars, i + 4)
          out = "#{out}py_t#{base + num}"
          i = shift_temp_end(chars, i + 4)
        else
          out = "#{out}#{chars[i]}"
          i += 1
        end
      end
    end
  end

  out
end

# The highest `py_tN` index in `texts`, or -1 when there is none.
# String-aware like `shift_code`.
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
          if shift_temp_at?(chars, i)
            num = shift_temp_num(chars, i + 4)
            if num > found
              found = num
            end

            i = shift_temp_end(chars, i + 4)
          else
            i += 1
          end
        end
      end
    end
  end

  found
end

# Advances `base` past the highest temp in `texts`.
def advance_temp(base: Int, texts: List[String]) -> Int
  top = max_temp_index(texts)
  return base if top < 0

  base + top + 1
end

# Whether a `py_tN` temp starts at `chars[i]`: the `py_t` letters plus at
# least one digit.
def shift_temp_at?(chars: List[String], i: Int) -> Bool
  return false if i + 4 >= chars.size

  return false if chars[i] != "p"

  return false if chars[i + 1] != "y"

  return false if chars[i + 2] != "_"

  return false if chars[i + 3] != "t"

  shift_digit?(chars[i + 4])
end

def shift_digit?(ch: String) -> Bool
  code = ch.code
  code >= 48 and code <= 57
end

def shift_temp_num(chars: List[String], from: Int) -> Int
  num = 0
  j = from
  while j < chars.size
    break if !shift_digit?(chars[j])

    num = num * 10 + (chars[j].code - 48)
    j += 1
  end

  num
end

def shift_temp_end(chars: List[String], from: Int) -> Int
  j = from
  while j < chars.size
    break if !shift_digit?(chars[j])

    j += 1
  end

  j
end

# Splits an emitter `PY-*` failure into a spanned refusal; anything without
# a `PY-*` code refuses as `PY-OUT-OF-SUBSET`.
def refusal_from_error(start: Int, stop: Int, err: Error) -> StmtRes
  parts = split_error_parts(err.message)
  StmtRes.No(Refusal(code: parts.code, message: parts.message, help: parts.help, start: start, stop: stop))
end

def split_error_parts(msg: String) -> ErrorParts
  colon = msg.index_of(":")
  case colon
    none -> ErrorParts(code: "PY-OUT-OF-SUBSET", message: msg, help: none)
    some(at) ->
      code = msg.slice(0, at).strip
      rest = msg.slice(at + 1, msg.length - at - 1).strip
      if code.start_with?("PY-")
        marker = rest.index_of("= help:")
        case marker
          none -> ErrorParts(code: code, message: rest, help: none)
          some(found) ->
            ErrorParts(
              code: code,
              message: rest.slice(0, found).strip,
              help: some(rest.slice(found + 7, rest.length - found - 7).strip),
            )
        end
      else
        ErrorParts(code: "PY-OUT-OF-SUBSET", message: msg, help: none)
      end
  end
end
