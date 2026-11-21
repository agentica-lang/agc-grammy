## The agc-py frontend: `.py` text → parse tree → AST → resolved scopes.
##
## Stages run in order and each refuses before the next starts. `parse_source`
## parses with the owned `py312` grammar; `build` shapes the tree into a
## `Program` (every node keeps its span from the parse tree); `resolve`
## checks scopes and answers every problem as a `Diagnostic`. `check_source`
## runs all three and renders every failure; `untyped_def` spots an
## untyped `def` header when parsing already failed, so that shape refuses
## with `PY-UNTYPED-DEF` instead of the raw engine error (the grammar itself
## demands full annotations, so untyped headers never reach `build`). When a
## generic parse error sits elsewhere in the file, that mapping still wins:
## any untyped `def` anywhere masks the engine error and only `PY-UNTYPED-DEF`
## is reported. `slice_exclusion` spots a stepped or literal-negative slice
## (`xs[1:2:3]`, `xs[-1:2]`) when parsing already failed, so those shapes
## refuse with `PY-SLICE` instead of the raw engine error (the grammar
## itself rejects static negatives and steps, so they never reach `build`).
## TODO(PY-SLICE): the grammar still rejects stepped/literal-negative slices
## at parse time; the frontend fallback owns the `PY-SLICE` code until phase
## 3c threads slice spans through the emitter.
##
## Scopes are module level plus one function level (`SUBSET.md` section 2):
## shadowing an outer name with a fresh binding inside a function is allowed,
## while a second binding in the same scope is `PY-DUPLICATE-BINDING`. A plain
## `x = ...` to a name the current scope never declared is `PY-UNTYPED-NAME`;
## `for` targets and `except ... as` names bind silently (the grammar gives
## them no annotation slot, and the worked example loops with a bare target).
## A `for` target that rebinds an existing name is allowed: it reuses the slot
## instead of redeclaring it. An `except ... as e` name stays bound for the
## rest of the flat function scope after its handler (a divergence from
## CPython, which deletes it). `raise` heads that look class-like (a leading
## uppercase letter, so `ValueError` or a bare `E`) are never resolved
## (section 4: the class is not modeled); any other `raise` head resolves
## like a normal load, so a factory call such as `raise make_error("x")`
## must resolve `make_error`. Imports bind their alias or head name so
## attribute roots like `os` in `os.getcwd()` resolve.
##
## Forward references are a deliberate middle ground. Every `def` name is
## pre-bound up front so mutual recursion keeps working, but each function
## body is checked against the module scope as it stands at that `def`:
## all `def` names plus only the top-level bindings seen so far. A body use
## of a later-bound module variable is `PY-NAME-UNKNOWN`. Top-level
## statements are checked strictly in order, so a call before its `def` is
## `PY-NAME-UNKNOWN` too. The final diagnostics are sorted by start offset,
## so a body problem can surface before a later top-level one.
##
## Annotations are checked against the known-type set (`int`, `str`, `float`,
## `bool`, `None`, `list`, `dict`, `Optional`): an unknown bare or dotted-head
## name is `PY-ANNOTATION-UNKNOWN`, while a bare `Any` (or `object`) and a
## `typing.Any` head are `PY-ANY`. Quoted forward references (`"Fwd"`,
## `list["Fwd"]`) are skipped: their targets are classes, unmodeled in 3a.
##
## `render` prints one diagnostic in the Agentica shape (`file:line:col`
## `error[PY-*]` + explanation + marked source line + `= help:` when known).

import Engine from "../../src/engine"
import Grammar from "../../src/grammar"
import Tree from "../../src/tree"

## A character span in the source, taken from the parse tree node it came from.
struct Span
  start: Int
  stop: Int
end

## One `name` occurrence: what it spells, where it sits and how it binds.
## `kind` is `declare` (annotated binding, parameter, import, `def` name),
## `assign` (a plain `=` or augmented target, which needs a declared name),
## `reuse` (a `for` or `except ... as` target, which binds or reuses silently)
## or `use` (a load).
struct NameOcc
  name: String
  span: Span
  kind: String
end

## One statement shape, with nested bodies kept as statement lists. An
## `Annotated` or `AliasDef` carries its annotation as an `Ann` (text plus
## the span it was sliced from) so `resolve` can check the names inside it.
## Statements that evaluate expressions also carry the parsed expression
## nodes (`cond_expr`, `call`) their emitters need: `resolve` keeps using
## the flat occurrence lists, so these nodes are emission-only.
## `IfStmt` holds one arm per branch (the `if` plus each `elif`) and the
## `else` body; `Other` is only the dataless `pass`/`break`/`next`.
enum Stmt
  Annotated(NameOcc, Ann, Optional[Tree.Node])
  AliasDef(NameOcc, Ann)
  Assigned(NameOcc, Tree.Node)
  AugAssigned(NameOcc, String, Tree.Node)
  ForLoop(NameOcc, Tree.Node, List[Stmt])
  IfStmt(List[CondArm], List[Stmt])
  WhileStmt(Tree.Node, List[Stmt])
  TryStmt(List[Stmt], List[Stmt], Optional[NameOcc])
  ReturnStmt(Optional[Tree.Node], Span)
  ExprStmt(Tree.Node)
  AssertStmt(Tree.Node, Optional[Tree.Node])
  RaiseStmt(Tree.Node)
  Other(Span)
end

## One conditional arm: the condition expression plus its body.
struct CondArm
  cond: Tree.Node
  body: List[Stmt]
end

## One annotation occurrence: the raw text plus the span it covers, so
## `resolve` can point each unknown or excluded name at its own span.
struct Ann
  text: String
  span: Span
end

## One typed `def`: the header facts plus the body as statements and as the
## flat name occurrences `resolve` checks (parameters excluded: they are
## bound before the body walks). Parameter and return annotations travel as
## `Ann` values so `resolve` can check the names inside them.
struct FuncDef
  name: String
  name_span: Span
  span: Span
  params: List[NameOcc]
  param_anns: List[Ann]
  return_type: String
  return_span: Span
  body: List[Stmt]
  body_names: List[NameOcc]
end

## One top-level non-`def` item, in source order: a statement with the names
## it mentions, or an import with the names it binds.
enum TopItem
  StmtItem(Stmt, List[NameOcc])
  ImportItem(List[NameOcc])
end

## A whole module: the `def`s and the top-level items, each in source order.
struct Program
  span: Span
  funcs: List[FuncDef]
  top: List[TopItem]
end

## One frontend problem: a stable `PY-*` code, an explanation, an optional
## fix hint and the offending span.
struct Diagnostic
  code: String
  message: String
  help: Optional[String]
  start: Int
  stop: Int
end

## Runs every stage on `source` (`file` names it in diagnostics): parse, then
## build, then resolve. Every failure is an `error` carrying the rendered
## diagnostics (or the engine message when the text is not Python at all).
def check_source(grammar: Grammar.Grammar, file: String, source: String) -> Result[Void]
  tree = try parse_with_untyped(grammar, source, file)
  program = try build(tree, source)
  diags = resolve(program)
  return ok() if diags.empty?

  error(diags.map { |diag| render(file, source, diag) }.join("\n\n"))
end

## Parses `source` with the owned grammar: the raw parse stage, without the
## `PY-UNTYPED-DEF` mapping `check_source` adds on top.
def parse_source(grammar: Grammar.Grammar, source: String) -> Result[Tree.Node]
  ok(try Engine.run(grammar, "program", source))
end

## Shapes a parsed `program` tree into a `Program`, keeping every span.
def build(tree: Tree.Node, source: String) -> Result[Program]
  return error("agc-py: expected a program tree, found #{tree.rule}") if tree.rule != "program"

  funcs: List[FuncDef] = []
  top: List[TopItem] = []
  for node in tree.children
    case node.rule
      "def_stmt" -> funcs = funcs.push(try build_def(node, source))
      "import_stmt" -> top = top.push(TopItem.ImportItem(collect(node, source)))
      _ -> top = top.push(try build_top_stmt(node, source))
    end
  end

  ok(Program(span: span_of(tree), funcs: funcs, top: top))
end

def build_top_stmt(node: Tree.Node, source: String) -> Result[TopItem]
  case try build_stmt(node, source)
    some(stmt) -> ok(TopItem.StmtItem(stmt, collect(node, source)))
    none -> error("agc-py: unexpected top-level node #{node.rule}")
  end
end

## Checks every scope in `program`: `def` names are pre-bound up front (so
## mutual recursion resolves), top-level items are then checked strictly in
## order with each `def` name joining the module scope at its own position
## (a call before its `def` is `PY-NAME-UNKNOWN`), and each function body is
## checked against its parameters plus the module scope as it stands at that
## `def` (all `def` names plus only the top-level bindings seen so far, so a
## body use of a later-bound module variable is `PY-NAME-UNKNOWN`). Answers
## every problem sorted by start offset; an empty list means the program
## resolved cleanly.
def resolve(program: Program) -> List[Diagnostic]
  all_defs: Set[String] = Set.new([])
  for func_def in program.funcs
    all_defs = all_defs.add(func_def.name)
  end

  def_idx = 0
  module_state = ScopeState(scope: Set.new([]), diags: [])
  for item in program.top
    pos = top_start(item)
    if pos.some?
      at = pos.unwrap!
      while def_idx < program.funcs.size
        candidate = List.first(program.funcs.drop(def_idx))
        break if candidate.span.start >= at

        module_state = bind_def_name(module_state, candidate)
        def_idx += 1
      end
    end

    module_state = check_top_item(module_state, item)
  end

  while def_idx < program.funcs.size
    module_state = bind_def_name(module_state, List.first(program.funcs.drop(def_idx)))
    def_idx += 1
  end

  diags = module_state.diags
  for func_def in program.funcs
    diags = check_func_body(diags, snapshot_scope(program, all_defs, func_def.span.start), func_def)
  end

  diags.sort_by { |diag| diag.start }
end

# The earliest name position in a top-level item, or none when the item
# mentions no names (then ordering does not matter for it).
def top_start(item: TopItem) -> Optional[Int]
  names = top_names(item)
  return none if names.empty?

  earliest = List.first(names).span.start
  for occ in names.drop(1)
    if occ.span.start < earliest
      earliest = occ.span.start
    end
  end

  some(earliest)
end

def top_names(item: TopItem) -> List[NameOcc]
  case item
    TopItem.StmtItem(_, names) -> names
    TopItem.ImportItem(names) -> names
  end
end

# The module scope visible at a `def` at `at`: every `def` name plus the
# top-level bindings (`declare`, `assign` and silent `reuse` targets) whose
# earliest name sits before the `def`.
def snapshot_scope(program: Program, all_defs: Set[String], at: Int) -> Set[String]
  scope = all_defs
  for item in program.top
    pos = top_start(item)
    if pos.some?
      start = pos.unwrap!
      if start < at
        for occ in top_names(item)
          if occ.kind == "declare" or occ.kind == "assign" or occ.kind == "reuse"
            scope = scope.add(occ.name)
          end
        end
      end
    end
  end

  scope
end

## Renders one diagnostic in the Agentica shape: `file:line:col error[PY-*]`,
## the explanation, a blank line, the source line with carets under the span
## and the `= help:` line when a fix is known.
def render(file: String, source: String, diagnostic: Diagnostic) -> String
  pos = Tree.position(source, diagnostic.start)
  width = diagnostic.stop - diagnostic.start
  if width < 1
    width = 1
  end

  text = pos.line_text
  if text.end_with?("\r")
    text = text.slice(0, text.length - 1)
  end

  gutter = " " * "#{pos.line}".length
  marks = " " * (pos.column - 1) + "^" * width
  lines = [
    "#{file}:#{pos.line}:#{pos.column} error[#{diagnostic.code}]",
    diagnostic.message,
    "",
    "#{pos.line} | #{text}",
    "#{gutter} | #{marks}",
  ]

  case diagnostic.help
    some(hint) -> lines.push("= help: #{hint}").join("\n")
    none -> lines.join("\n")
  end
end

## Spots an untyped `def` header in `source`, so a failed parse can still
## refuse with `PY-UNTYPED-DEF` at the header. Only single-line headers are
## judged (a header with unbalanced parentheses continues on the next line,
## so a multi-line untyped header stays a generic engine error); anything
## else stays a parse error.
def untyped_def(source: String) -> Optional[Diagnostic]
  lines = source.split("\n")
  offset = 0
  for line in lines
    found = scan_def_line(line, offset)
    return found if found.some?

    offset = offset + line.length + 1
  end

  none
end

private

# Python 3.12 keywords except the soft `match`/`case`, which stay usable as
# names (`SUBSET.md` section 8).
RESERVED_WORDS = Set.new([
  "False",
  "None",
  "True",
  "and",
  "as",
  "assert",
  "async",
  "await",
  "break",
  "class",
  "continue",
  "def",
  "del",
  "elif",
  "else",
  "except",
  "finally",
  "for",
  "from",
  "global",
  "if",
  "import",
  "in",
  "is",
  "lambda",
  "nonlocal",
  "not",
  "or",
  "pass",
  "raise",
  "return",
  "try",
  "while",
  "with",
  "yield",
])

# Builtins the subset maps (`SUBSET.md` section 5): usable without an import.
KNOWN_NAMES = Set.new([
  "abs",
  "all",
  "any",
  "bool",
  "chr",
  "dict",
  "enumerate",
  "filter",
  "float",
  "int",
  "len",
  "list",
  "map",
  "max",
  "min",
  "ord",
  "print",
  "range",
  "reversed",
  "round",
  "sorted",
  "str",
  "sum",
])

# Annotation names the subset accepts (`SUBSET.md` section 1): anything else
# is `PY-ANNOTATION-UNKNOWN`, while `Any` (or `object`) is `PY-ANY`.
KNOWN_TYPES = Set.new(["bool", "dict", "float", "int", "list", "None", "Optional", "str"])

# A scope under construction: the names bound so far and the problems found.
struct ScopeState
  scope: Set[String]
  diags: List[Diagnostic]
end

# Parses, mapping an untyped `def` header to its rendered diagnostic,
# then a stepped or literal-negative slice to `PY-SLICE`.
def parse_with_untyped(grammar: Grammar.Grammar, source: String, file: String) -> Result[Tree.Node]
  case Engine.run(grammar, "program", source)
    ok(tree) -> ok(tree)
    error(e) ->
      case untyped_def(source)
        some(diag) -> error(render(file, source, diag))
        none ->
          case slice_exclusion(source)
            some(slice_diag) -> error(render(file, source, slice_diag))
            none -> error(e.message)
          end
      end
  end
end

# Spots a stepped or literal-negative slice when parsing already failed, so
# `xs[1:2:3]` and `xs[-1:2]` refuse with `PY-SLICE` instead of the raw
# engine error. Only `[...:...:...]` (a step) or a bound starting with a
# literal `-number` counts; dynamic bounds like `xs[-a:b]` stay parseable
# elsewhere and never trigger this fallback. Strings and comments mask out
# first (same length, so spans still line up): `"[1:2:3]"` in a string or
# `# xs[::-1]` in a comment keeps the real parse error instead of a
# misattributed `PY-SLICE`.
def slice_exclusion(source: String) -> Optional[Diagnostic]
  masked = mask_strings_comments(source)
  chars = masked.split("")
  i = 0
  while i < chars.size
    if chars[i] == "["
      close = slice_close(chars, i)
      if close.some?
        stop = close.unwrap!
        inner = masked.slice(i + 1, stop - i - 1)
        if inner.include?(":")
          if is_step_slice?(inner)
            return some(
              Diagnostic(
                code: "PY-SLICE",
                message: "slice `#{source.slice(i, stop - i + 1)}` with step is excluded",
                help: some("write `xs[a:b]` with dynamic bounds"),
                start: i,
                stop: stop + 1,
              ),
            )
          end

          if has_literal_neg_bound?(inner)
            return some(
              Diagnostic(
                code: "PY-SLICE",
                message: "slice `#{source.slice(i, stop - i + 1)}` with negative bound is excluded",
                help: some("use dynamic bounds; static negatives halt"),
                start: i,
                stop: stop + 1,
              ),
            )
          end
        end
      end
    end

    i += 1
  end

  none
end

def slice_close(chars: List[String], at: Int) -> Optional[Int]
  depth = 1
  j = at + 1
  while j < chars.size
    if chars[j] == "["
      depth += 1
    end

    if chars[j] == "]"
      depth -= 1
      return some(j) if depth == 0
    end

    j += 1
  end

  none
end

def is_step_slice?(inner: String) -> Bool
  count = 0
  for ch in inner.split("")
    if ch == ":"
      count += 1
    end
  end

  count >= 2
end

def has_literal_neg_bound?(inner: String) -> Bool
  parts = inner.split(":")
  lower = List.first(parts)
  upper = ""
  if parts.size > 1
    upper = List.first(parts.drop(1))
  end

  is_literal_neg_bound?(lower) or is_literal_neg_bound?(upper)
end

def is_literal_neg_bound?(text: String) -> Bool
  chars = text.split("")
  i = 0
  while i < chars.size and slice_blank?(chars[i])
    i += 1
  end

  return false if i >= chars.size or chars[i] != "-"
  i += 1
  while i < chars.size and slice_blank?(chars[i])
    i += 1
  end

  return false if i >= chars.size
  ch = chars[i]
  code = ch.code
  (code >= 48 and code <= 57) or ch == "."
end

def slice_blank?(ch: String) -> Bool = ch == " " or ch == "\t" or ch == "\n" or ch == "\r" or ch == "("

# Blanks string literals and comments to spaces (newlines kept, so spans
# still line up): the slice fallback scans bracket structure, never text.
# An unterminated single-line quote ends at its newline, like Python.
def mask_strings_comments(source: String) -> String
  chars = source.split("")
  out: List[String] = []
  quote = ""
  escaped = false
  comment = false
  i = 0
  while i < chars.size
    ch = chars[i]
    if comment
      if ch == "\n"
        comment = false
        out = out.push(ch)
      else
        out = out.push(" ")
      end

      i += 1
    else
      if quote != ""
        if escaped
          escaped = false
          out = out.push(keep_break(ch))
          i += 1
        else
          if ch == "\\"
            escaped = true
            out = out.push(" ")
            i += 1
          else
            if starts_quote?(chars, i, quote)
              for _ in 0...quote.length
                out = out.push(" ")
              end

              i += quote.length
              quote = ""
            else
              if ch == "\n" and quote.length == 1
                quote = ""
              end

              out = out.push(keep_break(ch))
              i += 1
            end
          end
        end
      else
        if ch == "#"
          comment = true
          out = out.push(" ")
          i += 1
        else
          found = quote_at(chars, i)
          case found
            some(q) ->
              for _ in 0...q.length
                out = out.push(" ")
              end

              i += q.length
              quote = q
            none ->
              out = out.push(ch)
              i += 1
          end
        end
      end
    end
  end

  out.join("")
end

# A newline survives masking (line numbers feed `render`); anything else in
# a string or comment blanks out.
def keep_break(ch: String) -> String
  if ch == "\n"
    "\n"
  else
    " "
  end
end

# The quote opening at `at`, longest first (`'''` before `'`).
def quote_at(chars: List[String], at: Int) -> Optional[String]
  if at + 2 < chars.size
    triple = chars[at] + chars[at + 1] + chars[at + 2]
    return some(triple) if triple == "'''" or triple == "\"\"\""
  end

  return some(chars[at]) if chars[at] == "\"" or chars[at] == "'"

  none
end

# Whether `quote` opens or closes at `at`.
def starts_quote?(chars: List[String], at: Int, quote: String) -> Bool
  window = ""
  index = 0
  while index < quote.length and at + index < chars.size
    window = window + chars[at + index]
    index += 1
  end

  window == quote
end

def build_def(node: Tree.Node, source: String) -> Result[FuncDef]
  name_node = try Tree.first_child(node, "name").to_result("agc-py: def without a name")
  params = try build_params(node, source)
  param_anns = try build_param_anns(node, source)
  return_ann = try ann_of(node, "annotation", source)

  ok(
    FuncDef(
      name: Tree.text(name_node, source),
      name_span: span_of(name_node),
      span: span_of(node),
      params: params,
      param_anns: param_anns,
      return_type: return_ann.text,
      return_span: return_ann.span,
      body: try build_body(node.children, source),
      body_names: collect_def_body(node, source),
    ),
  )
end

# The `param` nodes hide one level down: `params` is a real parse node.
def build_params(node: Tree.Node, source: String) -> Result[List[NameOcc]]
  found = Tree.first_child(node, "params")
  case found
    some(listing) ->
      params: List[NameOcc] = []
      for param in Tree.children_of(listing, "param")
        params = params.push(try build_param(param, source))
      end

      ok(params)
    none -> ok([])
  end
end

def build_param(node: Tree.Node, source: String) -> Result[NameOcc]
  name_node = try Tree.first_child(node, "name").to_result("agc-py: parameter without a name")
  ok(occ_of(name_node, source, "declare"))
end

def build_param_anns(node: Tree.Node, source: String) -> Result[List[Ann]]
  found = Tree.first_child(node, "params")
  case found
    some(listing) ->
      anns: List[Ann] = []
      for param in Tree.children_of(listing, "param")
        anns = anns.push(try ann_of(param, "annotation", source))
      end

      ok(anns)
    none -> ok([])
  end
end

# Shapes one tree node into a statement. Expression debris (names, calls and
# operators inside conditions or iterations) is not a statement and maps to
# none; only `build` treats that as an error, bodies skip it.
def build_stmt(node: Tree.Node, source: String) -> Result[Optional[Stmt]]
  case node.rule
    "annotated" ->
      ok(
        some(
          Stmt.Annotated(
            try binding_occ(node, source, "declare"),
            try ann_of(node, "annotation", source),
            Tree.first_child(node, "cond_expr"),
          ),
        ),
      )
    "type_alias" ->
      ok(some(Stmt.AliasDef(try binding_occ(node, source, "declare"), try ann_of(node, "annotation", source))))
    "assign" -> ok(some(Stmt.Assigned(try binding_occ(node, source, "assign"), try expr_child(node, "assign"))))
    "augmented_assign" ->
      ok(
        some(
          Stmt.AugAssigned(
            try binding_occ(node, source, "assign"),
            try aug_op_text(node, source),
            try expr_child(node, "assign"),
          ),
        ),
      )
    "for_loop" ->
      ok(
        some(
          Stmt.ForLoop(
            try binding_occ(node, source, "reuse"),
            try expr_child(node, "for"),
            try build_body(node.children, source),
          ),
        ),
      )
    "if_stmt" ->
      arms = [CondArm(cond: try expr_child(node, "if"), body: try build_body(node.children, source))]
      for arm in try build_arms(node, source)
        arms = arms.push(arm)
      end

      ok(some(Stmt.IfStmt(arms, try build_else(node, source))))
    "while_loop" -> ok(some(Stmt.WhileStmt(try expr_child(node, "while"), try build_body(node.children, source))))
    "try_stmt" -> build_try(node, source)
    "return_stmt" -> ok(some(Stmt.ReturnStmt(Tree.first_child(node, "cond_expr"), span_of(node))))
    "pass_stmt" -> ok(some(Stmt.Other(span_of(node))))
    "break_stmt" -> ok(some(Stmt.Other(span_of(node))))
    "next_stmt" -> ok(some(Stmt.Other(span_of(node))))
    "raise_stmt" -> ok(some(Stmt.RaiseStmt(try expr_child(node, "raise"))))
    "assert_stmt" ->
      cond = try expr_child(node, "assert")
      rest = Tree.children_of(node, "cond_expr").drop(1)
      msg: Optional[Tree.Node] = none
      if !rest.empty?
        msg = some(List.first(rest))
      end

      ok(some(Stmt.AssertStmt(cond, msg)))
    "call_stmt" ->
      callee = try Tree.first_child(node, "call").to_result("agc-py: call without a call in #{node.rule}")
      ok(some(Stmt.ExprStmt(callee)))
    "expr_stmt" -> ok(some(Stmt.ExprStmt(try expr_child(node, "expression statement"))))
    _ -> ok(none)
  end
end

# The `+=`-style operator spelling of an augmented assignment.
def aug_op_text(node: Tree.Node, source: String) -> Result[String]
  op = try Tree.first_child(node, "aug_op").to_result("agc-py: augmented assignment without an operator")
  ok(Tree.text(op, source))
end

# condition of an `if`/`while`, the iterable of a `for`, the message of a
# `raise`. `expr` itself is silent, so the child is the `cond_expr` node an
# emitter takes.
def expr_child(node: Tree.Node, owner: String) -> Result[Tree.Node]
  Tree.first_child(node, "cond_expr").to_result("agc-py: #{owner} without a value")
end

def build_body(nodes: List[Tree.Node], source: String) -> Result[List[Stmt]]
  stmts: List[Stmt] = []
  for node in nodes
    built = try build_stmt(node, source)
    # `build_stmt` maps branch headers and expression debris to none.
    if built.some?
      stmts = stmts.push(built.unwrap!)
    end
  end

  ok(stmts)
end

def build_arms(node: Tree.Node, source: String) -> Result[List[CondArm]]
  arms: List[CondArm] = []
  for child in Tree.children_of(node, "elif_branch")
    arms = arms.push(CondArm(cond: try expr_child(child, "elif"), body: try build_body(child.children, source)))
  end

  ok(arms)
end

def build_else(node: Tree.Node, source: String) -> Result[List[Stmt]]
  found = Tree.first_child(node, "else_branch")
  case found
    some(branch) -> build_body(branch.children, source)
    none -> ok([])
  end
end

def build_try(node: Tree.Node, source: String) -> Result[Optional[Stmt]]
  found = Tree.first_child(node, "except_handler")
  case found
    some(handler) ->
      names = Tree.children_of(handler, "name")
      caught: Optional[NameOcc] = none
      if names.size == 2
        second = List.first(names.drop(1))
        caught = some(occ_of(second, source, "reuse"))
      end

      ok(some(Stmt.TryStmt(try build_body(node.children, source), try build_body(handler.children, source), caught)))
    none -> error("agc-py: try without a handler")
  end
end

def binding_occ(node: Tree.Node, source: String, kind: String) -> Result[NameOcc]
  name_node = try Tree.first_child(node, "name").to_result("agc-py: binding without a name in #{node.rule}")
  ok(occ_of(name_node, source, kind))
end

def child_text(node: Tree.Node, rule: String, source: String) -> Result[String]
  child = try Tree.first_child(node, rule).to_result("agc-py: #{node.rule} without #{rule}")
  ok(Tree.text(child, source))
end

def ann_of(node: Tree.Node, rule: String, source: String) -> Result[Ann]
  child = try Tree.first_child(node, rule).to_result("agc-py: #{node.rule} without #{rule}")
  ok(Ann(text: Tree.text(child, source), span: span_of(child)))
end

def occ_of(node: Tree.Node, source: String, kind: String) -> NameOcc
  NameOcc(name: Tree.text(node, source), span: span_of(node), kind: kind)
end

def span_of(node: Tree.Node) -> Span = Span(start: node.start, stop: node.stop)

# Every `name` in a subtree, in source order, tagged with how it binds. The
# target of a binding form is always its first direct `name` child; the
# annotation subtrees hold only `ident` nodes, never `name` ones, so the rest
# of the children collect as loads.
def collect(node: Tree.Node, source: String) -> List[NameOcc]
  case node.rule
    "def_stmt" -> collect_def_body(node, source)
    "params" -> collect_param_defaults(node, source)
    "param" -> collect_binding(node, source, "declare")
    "annotated" -> collect_binding(node, source, "declare")
    "type_alias" -> collect_binding(node, source, "declare")
    "assign" -> collect_binding(node, source, "assign")
    "augmented_assign" -> collect_binding(node, source, "assign")
    "for_loop" -> collect_binding(node, source, "reuse")
    "kwarg" -> collect_rest(node, source)
    "except_handler" -> collect_handler(node, source)
    "import_module" -> collect_import_name(node, source)
    "import_item" -> collect_import_name(node, source)
    "raise_stmt" -> collect_raise(node, source)
    "name" -> [occ_of(node, source, "use")]
    _ -> collect_all(node.children, source)
  end
end

def collect_all(nodes: List[Tree.Node], source: String) -> List[NameOcc]
  out: List[NameOcc] = []
  for node in nodes
    out = out + collect(node, source)
  end

  out
end

def collect_binding(node: Tree.Node, source: String, kind: String) -> List[NameOcc]
  names = Tree.children_of(node, "name")
  return collect_all(node.children, source) if names.empty?

  [occ_of(List.first(names), source, kind)] + collect_after(node, List.first(names), source)
end

def collect_rest(node: Tree.Node, source: String) -> List[NameOcc]
  names = Tree.children_of(node, "name")
  return collect_all(node.children, source) if names.empty?

  collect_after(node, List.first(names), source)
end

# Collects a `def` body: every child except the `def` name itself. Parameter
# bindings live in `FuncDef.params`, so `params` only contributes the
# default-value loads (see `collect_param_defaults`).
def collect_def_body(node: Tree.Node, source: String) -> List[NameOcc]
  names = Tree.children_of(node, "name")
  return collect_all(node.children, source) if names.empty?

  collect_after(node, List.first(names), source)
end

# A `params` node only contributes default-value loads; each `param` binding
# is skipped because `FuncDef.params` already declares it.
def collect_param_defaults(node: Tree.Node, source: String) -> List[NameOcc]
  out: List[NameOcc] = []
  for child in node.children
    if child.rule == "param"
      out = out + collect_rest(child, source)
    else
      out = out + collect(child, source)
    end
  end

  out
end

def collect_after(node: Tree.Node, skip: Tree.Node, source: String) -> List[NameOcc]
  rest: List[Tree.Node] = []
  skipped = false
  for child in node.children
    if !skipped and child.rule == skip.rule and child.start == skip.start and child.stop == skip.stop
      skipped = true
    else
      rest = rest.push(child)
    end
  end

  collect_all(rest, source)
end

# An `except` clause binds only its `as` name; the class is not modeled, so a
# lone class name is skipped rather than resolved.
def collect_handler(node: Tree.Node, source: String) -> List[NameOcc]
  names = Tree.children_of(node, "name")
  return collect_all(node.children, source) if names.empty? or names.size > 2

  body = collect_non_names(node, source)
  return body if names.size == 1

  [occ_of(List.first(names.drop(1)), source, "reuse")] + body
end

def collect_non_names(node: Tree.Node, source: String) -> List[NameOcc]
  rest: List[Tree.Node] = []
  for child in node.children
    if child.rule != "name"
      rest = rest.push(child)
    end
  end

  collect_all(rest, source)
end

# An import binds its alias, or the head of its dotted path (`import os.path`
# binds `os`); the dotted segments themselves are `ident` nodes, not loads.
def collect_import_name(node: Tree.Node, source: String) -> List[NameOcc]
  alias = Tree.first_child(node, "import_alias")
  case alias
    some(found) -> first_name_occ(found, source)
    none ->
      if node.rule == "import_item"
        first_name_occ(node, source)
      else
        [import_head_occ(node, source)]
      end
  end
end

def first_name_occ(node: Tree.Node, source: String) -> List[NameOcc]
  found = Tree.first_child(node, "name")
  case found
    some(name_node) -> [occ_of(name_node, source, "declare")]
    none -> []
  end
end

def import_head_occ(node: Tree.Node, source: String) -> NameOcc
  dotted = Tree.first_child(node, "dotted")
  case dotted
    some(found) ->
      full = Tree.text(found, source)
      head = List.first(full.split("."))
      NameOcc(name: head, span: Span(start: found.start, stop: found.start + head.length), kind: "declare")
    none -> NameOcc(name: "", span: span_of(node), kind: "declare")
  end
end

# `raise E("msg")` lowers to the message alone: a class-like head (a leading
# uppercase letter, so `ValueError` or a bare `E`) is skipped rather than
# resolved, while the arguments still collect as loads. Any other head — a
# factory call such as `raise make_error("x")` — resolves like a normal load.
# The head hides behind the single-child expression chain (`cond_expr`,
# `or_expr`, `comparison` and friends), so it is found by descent and only
# filtered out when it looks class-like.
def collect_raise(node: Tree.Node, source: String) -> List[NameOcc]
  all = collect_all(node.children, source)
  case raise_head(node)
    some(head) ->
      if class_like?(Tree.text(head, source))
        all.select { |occ| occ.span.start != head.start or occ.span.stop != head.stop }
      else
        all
      end

    none -> all
  end
end

def raise_head(node: Tree.Node) -> Optional[Tree.Node]
  start = node
  if node.rule == "raise_stmt" and !node.children.empty?
    start = List.first(node.children)
  end

  current = start
  while chain_rule?(current.rule) and current.children.size == 1
    current = List.first(current.children)
  end

  case current.rule
    "call" -> call_head(current)
    "name" -> some(current)
    _ -> none
  end
end

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

def call_head(node: Tree.Node) -> Optional[Tree.Node]
  return none if node.children.empty?

  head = List.first(node.children)
  return Tree.first_child(head, "name") if head.rule == "attr"

  return some(head) if head.rule == "name"

  none
end

def bind_def_name(state: ScopeState, func_def: FuncDef) -> ScopeState
  declare_name(state, NameOcc(name: func_def.name, span: func_def.name_span, kind: "declare"))
end

def check_top_item(state: ScopeState, item: TopItem) -> ScopeState
  case item
    TopItem.StmtItem(stmt, names) ->
      check_top_names(ScopeState(scope: state.scope, diags: state.diags + stmt_ann_diags(stmt)), names)
    TopItem.ImportItem(names) -> declare_all(state, names)
  end
end

def check_top_names(state: ScopeState, names: List[NameOcc]) -> ScopeState
  current = state
  for occ in names
    current = check_body_occ(current, current.scope, occ)
  end

  current
end

def declare_all(state: ScopeState, names: List[NameOcc]) -> ScopeState
  current = state
  for occ in names
    current = declare_name(current, occ)
  end

  current
end

def check_func_body(diags: List[Diagnostic], module: Set[String], func_def: FuncDef) -> List[Diagnostic]
  state = ScopeState(
    scope: Set.new([]),
    diags: (
      diags +
      anns_diags(func_def.param_anns) +
      ann_diags(func_def.return_type, func_def.return_span) +
      stmts_ann_diags(func_def.body)
    ),
  )

  for param in func_def.params
    state = declare_name(state, param)
  end

  for occ in func_def.body_names
    state = check_body_occ(state, module, occ)
  end

  state.diags
end

def check_body_occ(state: ScopeState, module: Set[String], occ: NameOcc) -> ScopeState
  if RESERVED_WORDS.include?(occ.name)
    return ScopeState(scope: state.scope.add(occ.name), diags: state.diags.push(reserved_diag(occ)))
  end

  case occ.kind
    "declare" -> declare_name(state, occ)
    "assign" -> assign_name(state, occ)
    "reuse" -> ScopeState(scope: state.scope.add(occ.name), diags: state.diags)
    _ -> check_use(state, module, occ)
  end
end

# Every binding path runs through here, so keywords in `def` names,
# parameter names and import bindings are rejected alongside ordinary
# declares (`check_body_occ` also rejects reserved words in the other
# positions before dispatching here for `declare`).
def declare_name(state: ScopeState, occ: NameOcc) -> ScopeState
  if RESERVED_WORDS.include?(occ.name)
    return ScopeState(scope: state.scope.add(occ.name), diags: state.diags.push(reserved_diag(occ)))
  end

  return ScopeState(scope: state.scope, diags: state.diags.push(duplicate_diag(occ))) if state.scope.include?(occ.name)

  ScopeState(scope: state.scope.add(occ.name), diags: state.diags)
end

# A plain assignment needs a name the current scope declared; the first
# binding always carries its annotation (`SUBSET.md` section 2).
def assign_name(state: ScopeState, occ: NameOcc) -> ScopeState
  return state if state.scope.include?(occ.name)

  ScopeState(scope: state.scope.add(occ.name), diags: state.diags.push(untyped_name_diag(occ)))
end

def check_use(state: ScopeState, module: Set[String], occ: NameOcc) -> ScopeState
  return state if state.scope.include?(occ.name) or module.include?(occ.name) or KNOWN_NAMES.include?(occ.name)

  ScopeState(scope: state.scope, diags: state.diags.push(unknown_diag(occ)))
end

def reserved_diag(occ: NameOcc) -> Diagnostic
  Diagnostic(
    code: "PY-RESERVED-NAME",
    message: "reserved word `#{occ.name}` cannot be used as a name",
    help: some("pick another name"),
    start: occ.span.start,
    stop: occ.span.stop,
  )
end

# A second binding of one name in one scope re-declares it; shadowing an
# outer scope stays allowed because each function body starts fresh.
def duplicate_diag(occ: NameOcc) -> Diagnostic
  Diagnostic(
    code: "PY-DUPLICATE-BINDING",
    message: "duplicate binding of `#{occ.name}` in the same scope",
    help: some("rename one of the bindings; a function may shadow a module-level name"),
    start: occ.span.start,
    stop: occ.span.stop,
  )
end

def unknown_diag(occ: NameOcc) -> Diagnostic
  Diagnostic(
    code: "PY-NAME-UNKNOWN",
    message: "unknown name `#{occ.name}`",
    help: some("bind it first, for example `#{occ.name}: int = ...`"),
    start: occ.span.start,
    stop: occ.span.stop,
  )
end

def untyped_name_diag(occ: NameOcc) -> Diagnostic
  Diagnostic(
    code: "PY-UNTYPED-NAME",
    message: "first binding of `#{occ.name}` needs an annotation",
    help: some("write `#{occ.name}: <type> = ...` for the first binding"),
    start: occ.span.start,
    stop: occ.span.stop,
  )
end

def ann_unknown_diag(name: String, start: Int, stop: Int) -> Diagnostic
  Diagnostic(
    code: "PY-ANNOTATION-UNKNOWN",
    message: "unknown annotation `#{name}`",
    help: some("use one of int, str, float, bool, None, list, dict, Optional"),
    start: start,
    stop: stop,
  )
end

def any_diag(name: String, start: Int, stop: Int) -> Diagnostic
  Diagnostic(
    code: "PY-ANY",
    message: "annotation `#{name}` is excluded; annotate with a concrete type",
    help: some("write a concrete type such as int, str, or list[int]"),
    start: start,
    stop: stop,
  )
end

# Class-like means a leading uppercase letter: exception names such as
# `ValueError` (or a bare `E`) are skipped as `raise` heads, while factory
# names such as `make_error` resolve like normal loads.
def class_like?(name: String) -> Bool
  return false if name == ""

  code = name.slice(0, 1).code
  code >= 65 and code <= 90
end

def ident_start?(ch: String) -> Bool
  code = ch.code
  (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code == 95
end

def ident_char?(ch: String) -> Bool = ident_start?(ch) or (ch.code >= 48 and ch.code <= 57)

def blank_char?(ch: String) -> Bool = ch == " " or ch == "\t" or ch == "\n" or ch == "\r"

# Whether the identifier starting at `at` follows a dot (skipping blanks),
# making it an attribute segment rather than a head to check.
def dotted_attr?(chars: List[String], at: Int) -> Bool
  j = at - 1
  while j >= 0
    if blank_char?(chars[j])
      j -= 1
    else
      return chars[j] == "."
    end
  end

  false
end

def anns_diags(anns: List[Ann]) -> List[Diagnostic]
  out: List[Diagnostic] = []
  for ann in anns
    out = out + ann_diags(ann.text, ann.span)
  end

  out
end

def stmt_ann_diags(stmt: Stmt) -> List[Diagnostic]
  case stmt
    Stmt.Annotated(_, ann, _) -> ann_diags(ann.text, ann.span)
    Stmt.AliasDef(_, ann) -> ann_diags(ann.text, ann.span)
    Stmt.ForLoop(_, _, body) -> stmts_ann_diags(body)
    Stmt.IfStmt(arms, else_body) -> if_ann_diags(arms, else_body)
    Stmt.WhileStmt(_, body) -> stmts_ann_diags(body)
    Stmt.TryStmt(try_body, handler_body, _) -> stmts_ann_diags(try_body) + stmts_ann_diags(handler_body)
    _ -> []
  end
end

def if_ann_diags(arms: List[CondArm], else_body: List[Stmt]) -> List[Diagnostic]
  out: List[Diagnostic] = []
  for arm in arms
    out = out + stmts_ann_diags(arm.body)
  end

  out + stmts_ann_diags(else_body)
end

def stmts_ann_diags(stmts: List[Stmt]) -> List[Diagnostic]
  out: List[Diagnostic] = []
  for stmt in stmts
    out = out + stmt_ann_diags(stmt)
  end

  out
end

# Checks every head identifier in an annotation against the known-type set.
# Only dotted heads are checked (`nosuch.X` points at `nosuch`); a `typing`
# head followed by `Any` (or `object`) is `PY-ANY`, like a bare `Any`.
# Quoted segments (`"Fwd"`, `list["Fwd"]`) are skipped entirely: string
# forward references resolve like bare names per `SUBSET.md` section 1, and
# their targets are classes, unmodeled in 3a (same rationale as the
# class-like `raise` skip).
def ann_diags(text: String, span: Span) -> List[Diagnostic]
  chars = text.split("")
  diags: List[Diagnostic] = []
  i = 0
  while i < chars.size
    if chars[i] == "\"" or chars[i] == "'"
      quote = chars[i]
      i += 1
      while i < chars.size and chars[i] != quote
        i += 1
      end

      if i < chars.size
        i += 1
      end
    else
      if ident_start?(chars[i])
        start_i = i
        pieces: List[String] = []
        while i < chars.size and ident_char?(chars[i])
          pieces = pieces.push(chars[i])
          i += 1
        end

        word = pieces.join("")

        if !dotted_attr?(chars, start_i)
          if word == "Any" or word == "object"
            diags = diags.push(any_diag(word, span.start + start_i, span.start + i))
          else
            if word == "typing"
              diags = diags + typing_head_diags(chars, span, start_i, i)
              i = typing_head_end(chars, i)
            else
              if !KNOWN_TYPES.include?(word)
                diags = diags.push(ann_unknown_diag(word, span.start + start_i, span.start + i))
              end
            end
          end
        end
      else
        i += 1
      end
    end
  end

  diags
end

# The diagnostic for a `typing` head: `typing.Any` (or `typing.object`) is
# `PY-ANY` over the whole dotted spelling, anything else is an unknown
# `typing` head.
def typing_head_diags(chars: List[String], span: Span, start_i: Int, end_i: Int) -> List[Diagnostic]
  found = typing_second(chars, end_i)
  case found
    some(second) ->
      if second == "Any" or second == "object"
        [any_diag("typing." + second, span.start + start_i, span.start + typing_head_end(chars, end_i))]
      else
        [ann_unknown_diag("typing", span.start + start_i, span.start + end_i)]
      end

    none -> [ann_unknown_diag("typing", span.start + start_i, span.start + end_i)]
  end
end

# The end offset (into the annotation text) of a `typing` head: past the
# second segment when one follows a dot, otherwise the head end itself.
def typing_head_end(chars: List[String], end_i: Int) -> Int
  j = end_i
  while j < chars.size and blank_char?(chars[j])
    j += 1
  end

  return end_i if j >= chars.size or chars[j] != "."

  k = j + 1
  while k < chars.size and blank_char?(chars[k])
    k += 1
  end

  return end_i if k >= chars.size or !ident_start?(chars[k])

  m = k
  while m < chars.size and ident_char?(chars[m])
    m += 1
  end

  m
end

def typing_second(chars: List[String], end_i: Int) -> Optional[String]
  j = end_i
  while j < chars.size and blank_char?(chars[j])
    j += 1
  end

  return none if j >= chars.size or chars[j] != "."

  k = j + 1
  while k < chars.size and blank_char?(chars[k])
    k += 1
  end

  return none if k >= chars.size or !ident_start?(chars[k])

  parts: List[String] = []
  m = k
  while m < chars.size and ident_char?(chars[m])
    parts = parts.push(chars[m])
    m += 1
  end

  some(parts.join(""))
end

def scan_def_line(line: String, offset: Int) -> Optional[Diagnostic]
  stripped = line.strip
  return none if !def_line?(stripped)
  return none if unbalanced?(stripped)

  case line.index_of("def")
    some(at) -> check_header(stripped, offset + at)
    none -> none
  end
end

def def_line?(stripped: String) -> Bool
  stripped == "def" or stripped.start_with?("def ") or stripped.start_with?("def\t") or stripped.start_with?("def(")
end

def unbalanced?(header: String) -> Bool = header.split("(").size != header.split(")").size

def check_header(header: String, start: Int) -> Optional[Diagnostic]
  stop = start + header.length
  name = def_name(header)
  if !header.include?("->")
    return some(
      Diagnostic(
        code: "PY-UNTYPED-DEF",
        message: untyped_def_message(name),
        help: some("annotate every parameter and the return, for example `def f(x: int) -> int:`"),
        start: start,
        stop: stop,
      ),
    )
  end

  check_params(header, start, name)
end

def untyped_def_message(name: String) -> String
  return "def header needs full annotations" if name == ""

  "def `#{name}` needs full annotations"
end

def def_name(header: String) -> String
  before = List.first(header.split("("))
  words = before.split(" ").select { |word| word != "" }
  return "" if words.empty?

  tail = List.last(words)
  return "" if tail == "def"

  return tail.slice(0, tail.length - 1) if tail.end_with?(":")

  tail
end

def check_params(header: String, start: Int, name: String) -> Optional[Diagnostic]
  open = header.index_of("(")
  case open
    some(at) -> check_param_list(param_text(header, at), header, start, name, at)
    none -> none
  end
end

# The text between the opening paren at `at` and its match; none when the
# header never closes (then this is not an untyped-`def` shape at all).
def param_text(header: String, at: Int) -> Optional[String]
  inner = header.slice(at + 1, header.length - at - 1)
  chars = inner.split("")
  depth = 1
  i = 0
  while i < chars.size
    if chars[i] == "("
      depth += 1
    end

    if chars[i] == ")"
      depth -= 1
      return some(inner.slice(0, i)) if depth == 0
    end

    i += 1
  end

  none
end

def check_param_list(
  params: Optional[String],
  header: String,
  start: Int,
  name: String,
  open: Int,
) -> Optional[Diagnostic]
  case params
    some(text) ->
      search_from = open + 1
      for part in text.split(",")
        trimmed = part.strip
        if trimmed != "" and !trimmed.include?(":")
          bare = List.first(trimmed.split("=")).strip
          found = param_diag(header, start, name, bare, search_from)
          return found if found.some?
        end

        search_from = advance_past(header, part, search_from)
      end

      none
    none -> none
  end
end

def param_diag(header: String, start: Int, name: String, param: String, search_from: Int) -> Optional[Diagnostic]
  case index_from(header, param, search_from)
    some(at) ->
      some(
        Diagnostic(
          code: "PY-UNTYPED-DEF",
          message: untyped_param_message(name, param),
          help: some("write `#{param}: <type>` in the `def` header"),
          start: start + at,
          stop: start + at + param.length,
        ),
      )
    none -> none
  end
end

def untyped_param_message(name: String, param: String) -> String
  return "parameter `#{param}` needs an annotation" if name == ""

  "parameter `#{param}` of def `#{name}` needs an annotation"
end

def index_from(header: String, part: String, from: Int) -> Optional[Int]
  return none if from > header.length

  tail = header.slice(from, header.length - from)
  case tail.index_of(part)
    some(at) -> some(from + at)
    none -> none
  end
end

def advance_past(header: String, part: String, from: Int) -> Int
  case index_from(header, part, from)
    some(at) -> at + part.length
    none -> header.length
  end
end
