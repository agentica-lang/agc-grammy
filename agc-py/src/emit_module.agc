## Module assembly for `agc-py` phase 3d (issue #22): a resolved
## `Frontend.Program` becomes one standalone single-file Agentica program.
##
## `EmitStmt.emit_block` emits every statement list; this assembler owns the
## module shape around it: `type` aliases hoist above every `def`
## (`CHECK-DECL-ORDER`), each `def` keeps its source-order position with a
## fully typed signature (`def name(x: Int) -> Int`), the outlined `try`
## helpers hoist next to the `def`s, and the top-level statements run in
## `main` in source order — the module entry point the backend looks for.
## `EmitExpr.helpers` (the `py_pymod`/`py_floor_div`/`py_slice_*` lowering)
## prepends unconditionally, like every phase 3b/3c checked program.
##
## Ordering mirrors `Frontend.resolve` exactly: `def` names join the module
## scope at their own position (a call before its `def` refuses
## `PY-NAME-UNKNOWN`), a `def` body sees every `def` name plus only the
## top-level bindings declared before it, and type aliases are visible from
## their own span on. One module-wide temp supply threads through every body,
## so outlined helpers never collide (`py_try_bodyN` derives from it).
##
## The one-function-level rule (`SUBSET.md` section 2) has no backend form
## for module state: a `def` body that reads a top-level binding refuses
## spanned (the value lives in `main`; passing it as a parameter is the
## spelling). Everything else the backend cannot place refuses spanned too:
## imports (issue #26) and a def that can fall through without
## returning (the backend demands a value on every path).
##
## The call ABI (issue #23) threads one `Sig` per `def` through every
## emission context: parameters, backend types, default-value nodes and the
## mapped return. Signatures build eagerly over all `def`s (annotations
## mapped with the module's full alias set — `resolve` has already refused
## an annotation naming an unknown or later-declared alias), so a `def` body
## sees every signature (mutual recursion) while a `main` call is gated by
## the scope marker, which joins at the def's own position, like resolve.
##
## Generated names are reserved (`main`, the runtime helpers, the
## `py_tN`-shaped counters): any user binding that collides refuses spanned,
## so the emitted file never meets a duplicate or shadowed generated name.
## Two names the backend flags as dead get a discard lowering instead: a
## binding never read emits `_ = <rhs>` (the expression still evaluates,
## like Python), and a name whose only reads feed its own updates keeps them
## and gains one `_ = name` after its last binding line, so the backend's
## liveness sees a real read. An augmented target always reads itself
## (`c += 1` lowers to `c = c + (1)`) even when its right-hand side never
## mentions it, so an update-only variable keeps its declaration and gains
## that discard read instead of disappearing under `c`'s own reference.

import EmitAssign from "emit_assign"
import EmitCtx from "emit_ctx"
import EmitExpr from "emit_expr"
import EmitStmt from "emit_stmt"
import Frontend from "frontend"
import {Stmt} from "frontend"
import Tree from "../../src/tree"

## One assembled module: the full single-file program, one line per entry.
struct ModuleOut
  code: List[String]
end

## A module answer: the assembled program or the first spanned refusal.
enum ModuleRes
  Ok(ModuleOut)
  No(EmitCtx.Refusal)
end

## One assembly step: the advanced state or the refusal that stopped the walk.
enum StepRes
  Ok(Asm)
  No(EmitCtx.Refusal)
end

## The binding states one occurrence stream leaves behind: per name whether
## it is bound with a value (`value`) or only annotated (`bare`), plus the
## rewrite evidence (bound names, every read, and the reads that are not
## self-updates — a self-update read feeds only its own rebinding, which the
## backend discounts as dead).
struct WalkState
  bound: Map[String, String]
  bound_names: List[String]
  read_names: List[String]
  real_names: List[String]
end

## One occurrence-stream answer: the advanced state or a refusal.
enum WalkRes
  Ok(WalkState)
  No(EmitCtx.Refusal)
end

## The source-order assembly state: the module scope (def markers, top-level
## bindings and aliases, in resolve's positional order), the main-body walk,
## the top-level value bindings (reads inside defs refuse), the aliases, the
## call ABI signatures, the def-flush index, the module-wide temp supply and
## the four text buckets.
struct Asm
  scope: Map[String, String]
  walk: WalkState
  top_values: Map[String, String]
  aliases: Map[String, String]
  sigs: Map[String, EmitCtx.Sig]
  defs_done: Int
  next_temp: Int
  alias_lines: List[String]
  def_lines: List[String]
  helper_lines: List[String]
  main_lines: List[String]
end

## Emits a resolved `Program` as one standalone `.agc` file: `type` aliases
## hoist above every `def`, each `def` keeps its source order with a fully
## typed signature, outlined `try` helpers hoist next to the `def`s, and the
## top-level statements run in `main` in source order. The first refusal
## wins, so a program that emits at all answers a single `ModuleOut`.
def emit_program(program: Frontend.Program, source: String, file: String) -> ModuleRes
  case reserved_refusal(program)
    some(ref) -> ModuleRes.No(ref)
    none ->
      sigs = sig_table(program)
      case walk_top(asm_start(sigs), program.top, program, source, file)
        StepRes.No(ref) -> ModuleRes.No(ref)
        StepRes.Ok(done) -> ModuleRes.Ok(ModuleOut(code: assemble(done)))
      end
  end
end

private

def asm_start(sigs: Map[String, EmitCtx.Sig]) -> Asm
  Asm(
    scope: {},
    walk: WalkState(bound: {}, bound_names: [], read_names: [], real_names: []),
    top_values: {},
    aliases: {},
    sigs: sigs,
    defs_done: 0,
    next_temp: 0,
    alias_lines: [],
    def_lines: [],
    helper_lines: [],
    main_lines: [],
  )
end

# One `Sig` per `def`, built over the whole program so a `def` body resolves
# any other `def` (mutual recursion). Annotations map with every alias the
# module declares: `resolve` has already refused an annotation naming an
# unknown or later-declared alias, so the superset changes no verdict, and a
# `def` whose mapping still fails here stays out of the table (its own flush
# refuses with the real span before any call site can matter).
def sig_table(program: Frontend.Program) -> Map[String, EmitCtx.Sig]
  aliases = all_aliases(program)
  sigs: Map[String, EmitCtx.Sig] = {}
  for func_def in program.funcs
    case build_sig(func_def, aliases)
      some(sig) -> sigs = sigs.put(func_def.name, sig)
      none -> sigs = sigs
    end
  end

  sigs
end

# Every `type Alias = T` spelling of the module, mapped in source order (an
# alias may spell another alias declared before it).
def all_aliases(program: Frontend.Program) -> Map[String, String]
  out: Map[String, String] = {}
  for item in program.top
    case item
      Frontend.TopItem.StmtItem(stmt, _) ->
        case stmt
          Stmt.AliasDef(occ, ann) ->
            case EmitAssign.map_annotation(ann.text, out)
              ok(want) -> out = out.put(occ.name, want)
              error(_) -> out = out
            end

          _ -> out = out
        end

      _ -> out = out
    end
  end

  out
end

# One `def` signature, or `none` when an annotation or the return type does
# not map (the def's own flush refuses with the real span).
def build_sig(func_def: Frontend.FuncDef, aliases: Map[String, String]) -> Optional[EmitCtx.Sig]
  types: List[String] = []
  for ann in func_def.param_anns
    case EmitAssign.map_annotation(ann.text, aliases)
      ok(ty) -> types = types.push(ty)
      error(_) -> return none
    end
  end

  case mapped_return(func_def, aliases)
    ok(ret) ->
      some(
        EmitCtx.Sig(
          name: func_def.name,
          params: func_def.params.map { |param| param.name },
          types: types,
          defaults: func_def.param_default_nodes,
          ret: ret,
        ),
      )
    error(_) -> none
  end
end

# Emits the top items in order, flushing each def whose span starts before
# the item's earliest name (resolve's positional rule: the def name joins the
# module scope at its own position), then every remaining def.
def walk_top(
  asm: Asm,
  items: List[Frontend.TopItem],
  program: Frontend.Program,
  source: String,
  file: String,
) -> StepRes
  current = asm
  for item in items
    pos = Frontend.top_start(item)
    if pos.some?
      case flush_defs(current, program, some(pos.unwrap!), source, file)
        StepRes.No(ref) -> return StepRes.No(ref)
        StepRes.Ok(next) -> current = next
      end
    end

    case step_item(current, item, program, source, file)
      StepRes.No(ref) -> return StepRes.No(ref)
      StepRes.Ok(next) -> current = next
    end
  end

  flush_defs(current, program, none, source, file)
end

# Emits defs while their span starts before `at` (`none` flushes the rest).
def flush_defs(asm: Asm, program: Frontend.Program, at: Optional[Int], source: String, file: String) -> StepRes
  current = asm
  while current.defs_done < program.funcs.size
    func_def = List.first(program.funcs.drop(current.defs_done))
    break if at.some? and func_def.span.start >= at.unwrap!

    case emit_def(current, program, func_def, source, file)
      StepRes.No(ref) -> return StepRes.No(ref)
      StepRes.Ok(next) -> current = next
    end
  end

  StepRes.Ok(current)
end

def step_item(asm: Asm, item: Frontend.TopItem, program: Frontend.Program, source: String, file: String) -> StepRes
  case item
    Frontend.TopItem.ImportItem(decls) ->
      span = import_span(decls, program)
      StepRes.No(
        EmitCtx.Refusal(
          code: "PY-OUT-OF-SUBSET",
          message: "imports need linked-module emission; issue #26 owns it",
          help: some("inline the values you need for now"),
          start: span.start,
          stop: span.stop,
        ),
      )
    Frontend.TopItem.StmtItem(stmt, names) -> step_stmt_item(asm, stmt, names, source, file)
  end
end

def import_span(decls: List[Frontend.ImportDecl], program: Frontend.Program) -> Frontend.Span
  for decl in decls
    return Frontend.decl_span(decl)
  end

  program.span
end

def step_stmt_item(asm: Asm, stmt: Stmt, names: List[Frontend.NameOcc], source: String, file: String) -> StepRes
  # `type Alias = T` is a declaration, not a value binding: the lane hoists
  # its line and the alias joins the module scope for the annotations after it.
  case stmt
    Stmt.AliasDef(_, _) ->
      case EmitStmt.emit_block(item_ctx(asm, source, file), [stmt])
        EmitStmt.BlockRes.No(ref) -> StepRes.No(ref)
        EmitStmt.BlockRes.Ok(out) ->
          name = alias_name(stmt)
          StepRes.Ok(
            asm.with(
              scope: out.scope,
              aliases: asm.aliases.put(name, out.scope.get(name, "")),
              next_temp: out.next_temp,
              alias_lines: join_block(asm.alias_lines, out.helpers),
            ),
          )
      end

    _ ->
      case main_walk(asm, names, stmt, source)
        WalkRes.No(ref) -> StepRes.No(ref)
        WalkRes.Ok(walked) ->
          stepped = asm.with(walk: walked)
          case EmitStmt.emit_block(item_ctx(stepped, source, file), [stmt])
            EmitStmt.BlockRes.No(ref) -> StepRes.No(ref)
            EmitStmt.BlockRes.Ok(out) ->
              top_values = stepped.top_values
              for occ in names
                if occ.kind != "use" and out.scope.get(occ.name, "") != ""
                  top_values = top_values.put(occ.name, out.scope.get(occ.name, ""))
                end
              end

              StepRes.Ok(
                stepped.with(
                  scope: out.scope,
                  top_values: top_values,
                  next_temp: out.next_temp,
                  main_lines: asm.main_lines + out.code,
                  helper_lines: join_block(asm.helper_lines, out.helpers),
                ),
              )
          end
      end
  end
end

# The alias a `type Alias = T` item declares: the item's first name.
def alias_name(stmt: Stmt) -> String
  case stmt
    Stmt.AliasDef(occ, _) -> occ.name
    _ -> ""
  end
end

# The `EmitCtx` one main-body statement emits under: the module scope as it
# stands, no enclosing `def` (`main` cannot `return`) and the threaded temps.
def item_ctx(asm: Asm, source: String, file: String) -> EmitCtx.EmitCtx
  EmitCtx.EmitCtx(
    source: source,
    file: file,
    scope: asm.scope,
    func_ret: "",
    in_try: false,
    next_temp: asm.next_temp,
    sigs: asm.sigs,
  )
end

# Emits one `def`: typed parameters and return, the positional body scope,
# the occurrence walk, then `EmitStmt.emit_block` over the body.
def emit_def(asm: Asm, program: Frontend.Program, func_def: Frontend.FuncDef, source: String, file: String) -> StepRes
  param_types: List[String] = []
  for ann in func_def.param_anns
    case EmitAssign.map_annotation(ann.text, asm.aliases)
      error(e) -> return StepRes.No(split_at(ann.span.start, ann.span.stop, e))
      ok(ty) -> param_types = param_types.push(ty)
    end
  end

  case mapped_return(func_def, asm.aliases)
    error(e) -> StepRes.No(split_at(func_def.return_span.start, func_def.return_span.stop, e))
    ok(ret) -> emit_def_body(asm, program, func_def, param_types, ret, source, file)
  end
end

# `-> None` maps to the backend's `Void` (a bare `return` checks there),
# `-> Result[T]` to the backend's fallible signature; anything else maps like
# an annotation.
def mapped_return(func_def: Frontend.FuncDef, aliases: Map[String, String]) -> Result[String]
  if func_def.return_type == "None" or func_def.return_type == "none"
    ok("Void")
  else
    EmitAssign.map_return(func_def.return_type, aliases)
  end
end

def emit_def_body(
  asm: Asm,
  program: Frontend.Program,
  func_def: Frontend.FuncDef,
  param_types: List[String],
  ret: String,
  source: String,
  file: String,
) -> StepRes
  case def_walk(asm, func_def, source)
    WalkRes.No(ref) -> StepRes.No(ref)
    WalkRes.Ok(walked) ->
      ctx = EmitCtx.EmitCtx(
        source: source,
        file: file,
        scope: def_scope(asm, program, func_def, param_types),
        func_ret: ret,
        in_try: false,
        next_temp: asm.next_temp,
        sigs: asm.sigs,
      )

      case EmitStmt.emit_block(ctx, func_def.body)
        EmitStmt.BlockRes.No(ref) -> StepRes.No(ref)
        EmitStmt.BlockRes.Ok(out) ->
          if ret != "Void" and ret != "Result[Void]" and !returns_everywhere?(func_def.body)
            return StepRes.No(
              EmitCtx.Refusal(
                code: "PY-OUT-OF-SUBSET",
                message: (
                  "the body of `#{func_def.name}` can reach the end without returning `#{func_def.return_type}`"
                ),
                help: some("end the body with a `return`, or annotate `-> None`"),
                start: func_def.name_span.start,
                stop: func_def.name_span.stop,
              ),
            )
          end

          body = rewrite_unused(out.code, unused_names(walked))
          body = append_self_reads(body, self_only_names(walked))
          if body.empty?
            body = ["nil"]
          end

          if ret == "Result[Void]" and !ends_with_return?(func_def.body)
            body = body.push("ok()")
          end

          header = "def #{func_def.name}(#{params_text(func_def.params, param_types)}) -> #{ret}"
          StepRes.Ok(
            asm.with(
              scope: asm.scope.put(func_def.name, EmitCtx.def_marker()),
              defs_done: asm.defs_done + 1,
              next_temp: out.next_temp,
              def_lines: join_block(asm.def_lines, [header] + EmitCtx.indented(body, 1) + ["end"]),
              helper_lines: join_block(asm.helper_lines, out.helpers),
            ),
          )
      end
  end
end

# The scope one def body emits under: every def name as the callable marker
# (a body may call any def, like resolve's snapshot), the aliases declared
# before it (annotations resolve through them), and the parameters last so a
# parameter shadows a same-named def or alias instead of the reverse.
def def_scope(
  asm: Asm,
  program: Frontend.Program,
  func_def: Frontend.FuncDef,
  param_types: List[String],
) -> Map[String, String]
  scope: Map[String, String] = {}
  for other in program.funcs
    scope = scope.put(other.name, EmitCtx.def_marker())
  end

  for name in asm.aliases.keys()
    scope = scope.put(name, asm.aliases.get(name, ""))
  end

  index = 0
  for param in func_def.params
    scope = scope.put(param.name, List.first(param_types.drop(index)))
    index += 1
  end

  scope
end

# The occurrence walk over one def body: parameters bind first, then the
# flat body occurrences in source order. Module-value reads and alias uses
# refuse (both are accepted by resolve's flat set but have no backend form).
def def_walk(asm: Asm, func_def: Frontend.FuncDef, source: String) -> WalkRes
  bound: Map[String, String] = {}
  for param in func_def.params
    bound = bound.put(param.name, "value")
  end

  walk_stream(
    WalkState(bound: bound, bound_names: [], read_names: [], real_names: []),
    func_def.body_names,
    bare_ann_starts(func_def.body),
    self_keys(func_def.body, source),
    asm.top_values,
    asm.aliases,
    true,
  )
end

# The main-body occurrence walk over one item's names, threaded through the
# assembly state so an annotated declaration in one item binds for the next.
def main_walk(asm: Asm, names: List[Frontend.NameOcc], stmt: Stmt, source: String) -> WalkRes
  walk_stream(asm.walk, names, bare_ann_starts([stmt]), self_keys([stmt], source), {}, asm.aliases, false)
end

def walk_stream(
  start: WalkState,
  occs: List[Frontend.NameOcc],
  bare: List[Int],
  selfs: List[String],
  module_values: Map[String, String],
  aliases: Map[String, String],
  def_mode: Bool,
) -> WalkRes
  current = start
  for occ in occs
    case walk_occ(current, occ, bare, selfs, module_values, aliases, def_mode)
      WalkRes.No(ref) -> return WalkRes.No(ref)
      WalkRes.Ok(next) -> current = next
    end
  end

  WalkRes.Ok(current)
end

def walk_occ(
  walk: WalkState,
  occ: Frontend.NameOcc,
  bare: List[Int],
  selfs: List[String],
  module_values: Map[String, String],
  aliases: Map[String, String],
  def_mode: Bool,
) -> WalkRes
  name = occ.name
  case occ.kind
    "declare" ->
      state = "value"
      if bare.include?(occ.span.start)
        state = "bare"
      end

      WalkRes.Ok(advance(walk, name, state))
    "assign" ->
      implicit = selfs.include?("#{name}:#{occ.span.start}:#{occ.span.stop}")
      if walk.bound.get(name, "none") == "bare"
        # An augmented target is a read (`c += 1` is `c = c + (1)`); a plain
        # assignment only writes, so each gets its own message.
        if implicit
          WalkRes.No(unbound_refusal(occ))
        else
          WalkRes.No(uninitialized_refusal(occ))
        end
      else
        stepped = advance(walk, name, "value")
        # The aug target's implicit read of itself feeds only its own
        # rebinding, so it is recorded but never real: the self-only rewrite
        # turns it into the one real `_ = c` read after the last binding.
        if implicit
          WalkRes.Ok(read_step(stepped, name, false))
        else
          WalkRes.Ok(stepped)
        end
      end

    "reuse" -> WalkRes.Ok(advance(walk, name, "value"))
    _ -> walk_use(walk, occ, selfs, module_values, aliases, def_mode)
  end
end

# A use of a name the stream never bound: while only annotated it is the
# Python unbound read, a module value has no form inside a def, an alias is
# a type and never a value; def markers and builtins pass through (a bare
# use of a def name keeps the callable marker and refuses at the value
# emission: `EmitExpr.emit_name` refuses `Function` values, since the
# backend has no function values).
def walk_use(
  walk: WalkState,
  occ: Frontend.NameOcc,
  selfs: List[String],
  module_values: Map[String, String],
  aliases: Map[String, String],
  def_mode: Bool,
) -> WalkRes
  state = walk.bound.get(occ.name, "none")
  return WalkRes.No(unbound_refusal(occ)) if state == "bare"

  if state != "value"
    if def_mode and module_values.get(occ.name, "") != ""
      return WalkRes.No(
        EmitCtx.Refusal(
          code: "PY-OUT-OF-SUBSET",
          message: "module variable `#{occ.name}` cannot be read inside a def: top-level bindings live in main",
          help: some("pass it as a parameter; the full call ABI is issue #23"),
          start: occ.span.start,
          stop: occ.span.stop,
        ),
      )
    end

    if aliases.get(occ.name, "") != ""
      return WalkRes.No(
        EmitCtx.Refusal(
          code: "PY-OUT-OF-SUBSET",
          message: "type alias `#{occ.name}` is not a value",
          help: some("annotate with it, for example `x: #{occ.name} = ...`"),
          start: occ.span.start,
          stop: occ.span.stop,
        ),
      )
    end
  end

  real = !selfs.include?("#{occ.name}:#{occ.span.start}:#{occ.span.stop}")
  WalkRes.Ok(read_step(walk, occ.name, real))
end

# Adds one binding state and records the name as bound for the rewrite pass.
def advance(walk: WalkState, name: String, state: String) -> WalkState
  WalkState(
    bound: walk.bound.put(name, state),
    bound_names: push_once(walk.bound_names, name),
    read_names: walk.read_names,
    real_names: walk.real_names,
  )
end

def read_step(walk: WalkState, name: String, real: Bool) -> WalkState
  reals = walk.real_names
  if real
    reals = push_once(walk.real_names, name)
  end

  WalkState(
    bound: walk.bound,
    bound_names: walk.bound_names,
    read_names: push_once(walk.read_names, name),
    real_names: reals,
  )
end

def push_once(names: List[String], name: String) -> List[String]
  return names if names.include?(name)

  names.push(name)
end

# The span starts of valueless annotated declarations (`x: T`), so the walk
# knows a `declare` binds without a value.
def bare_ann_starts(stmts: List[Stmt]) -> List[Int]
  out: List[Int] = []
  for stmt in stmts
    case stmt
      Stmt.Annotated(occ, _, none) -> out = out.push(occ.span.start)
      Stmt.ForLoop(_, _, body) -> out = out + bare_ann_starts(body)
      Stmt.IfStmt(arms, else_body) ->
        for arm in arms
          out = out + bare_ann_starts(arm.body)
        end

        out = out + bare_ann_starts(else_body)
      Stmt.WhileStmt(_, body) -> out = out + bare_ann_starts(body)
      Stmt.TryStmt(try_body, handler, _) -> out = out + bare_ann_starts(try_body) + bare_ann_starts(handler)
      _ -> out = out
    end
  end

  out
end

def unbound_refusal(occ: Frontend.NameOcc) -> EmitCtx.Refusal
  EmitCtx.Refusal(
    code: "PY-NAME-UNKNOWN",
    message: "`#{occ.name}` is read before it is assigned",
    help: some("assign it first, for example `#{occ.name} = 0`"),
    start: occ.span.start,
    stop: occ.span.stop,
  )
end

# A plain assignment to a name only annotated (`c: int` then `c = 5`): the
# valueless annotation has no backend form, so nothing of `c` exists yet.
# The span stays on the assignment, where the program fails.
def uninitialized_refusal(occ: Frontend.NameOcc) -> EmitCtx.Refusal
  EmitCtx.Refusal(
    code: "PY-NAME-UNKNOWN",
    message: "`#{occ.name}` is annotated without a value; initialize it in its declaration",
    help: some("write `#{occ.name}: int = 0` instead of `#{occ.name}: int`"),
    start: occ.span.start,
    stop: occ.span.stop,
  )
end

# Splits an emitter `PY-*` failure into a spanned refusal.
def split_at(start: Int, stop: Int, err: Error) -> EmitCtx.Refusal
  case EmitCtx.refusal_from_error(start, stop, err)
    EmitCtx.StmtRes.No(ref) -> ref
    EmitCtx.StmtRes.Ok(_) ->
      EmitCtx.Refusal(code: "PY-OUT-OF-SUBSET", message: err.message, help: none, start: start, stop: stop)
  end
end

# The backend demands a value on every path (`CHECK-MISSING-RETURN`): the
# last statement must return, or be an `if`/`else` chain every leaf of which
# returns — the backend's own rule, so a def that can fall through refuses
# spanned instead of failing backend check.
def returns_everywhere?(body: List[Stmt]) -> Bool
  return false if body.empty?

  last = List.first(body.drop(body.size - 1))
  case last
    Stmt.ReturnStmt(some(_), _) -> true
    Stmt.RaiseStmt(_) -> true
    Stmt.IfStmt(arms, else_body) -> every_arm_returns?(arms) and returns_everywhere?(else_body)
    _ -> false
  end
end

# Whether the last statement already leaves the def, so no closing `ok()`
# follows it (a `Result[None]` def otherwise ends with its success): a
# `return`, a `raise`, or an `if` chain with an `else` that every arm ends so.
def ends_with_return?(body: List[Stmt]) -> Bool
  return false if body.empty?

  case List.first(body.drop(body.size - 1))
    Stmt.ReturnStmt(_, _) -> true
    Stmt.RaiseStmt(_) -> true
    Stmt.IfStmt(arms, else_body) -> every_arm_ends?(arms) and ends_with_return?(else_body)
    _ -> false
  end
end

def every_arm_ends?(arms: List[Frontend.CondArm]) -> Bool
  for arm in arms
    return false if !ends_with_return?(arm.body)
  end

  true
end

def every_arm_returns?(arms: List[Frontend.CondArm]) -> Bool
  for arm in arms
    return false if !returns_everywhere?(arm.body)
  end

  true
end

# Joins two text blocks with one blank line, so top-level `def`s stay
# separated like `blank_line_after_end` wants.
def join_block(left: List[String], right: List[String]) -> List[String]
  return right if left.empty?

  return left if right.empty?

  left + [""] + right
end

def params_text(params: List[Frontend.NameOcc], types: List[String]) -> String
  out = ""
  index = 0
  for param in params
    piece = "#{param.name}: #{List.first(types.drop(index))}"
    if out == ""
      out = piece
    else
      out = "#{out}, #{piece}"
    end

    index += 1
  end

  out
end

# The names bound but never read: their bindings lower to discards.
def unused_names(walk: WalkState) -> List[String]
  out: List[String] = []
  for name in walk.bound_names
    if !walk.read_names.include?(name) and !out.include?(name)
      out = out.push(name)
    end
  end

  out
end

# The names whose every read feeds their own update: the backend discounts
# those as dead, so one discard read after the last binding keeps the chain.
def self_only_names(walk: WalkState) -> List[String]
  out: List[String] = []
  for name in walk.read_names
    if !walk.real_names.include?(name) and !out.include?(name)
      out = out.push(name)
    end
  end

  out
end

# `_ = <rhs>` for a binding of an unused name, `for _ in` for its loop
# target: the backend's discard keeps every right-hand side evaluating
# (Python still runs the expression) while the variable itself disappears.
def rewrite_unused(lines: List[String], unused: List[String]) -> List[String]
  out: List[String] = []
  for line in lines
    out = out.push(rewrite_line(line, unused))
  end

  out
end

def rewrite_line(line: String, unused: List[String]) -> String
  return line if unused.empty?

  indent = indent_of(line)
  rest = line.slice(indent.length, line.length - indent.length)
  if rest.start_with?("for ")
    name = word_after(rest, 4)
    if name != "" and unused.include?(name)
      after = rest.slice(4 + name.length, rest.length - 4 - name.length)
      return "#{indent}for _#{after}"
    end

    return line
  end

  # The read mark of a handler message the def never uses: its binding became
  # `_`, so the mark would name a variable that no longer exists.
  return "#{indent}nil" if rest.start_with?("_ = ") and unused.include?(rest.slice(4, rest.length - 4))

  eq = rest.index_of("=")
  case eq
    none -> line
    some(at) ->
      name = lhs_name(rest.slice(0, at).strip)
      if unused.include?(name)
        "#{indent}_ =#{rest.slice(at + 1, rest.length - at - 1)}"
      else
        line
      end
  end
end

# The bound name of a binding LHS: `x`, or `x` of `x: Int`.
def lhs_name(lhs: String) -> String
  colon = lhs.index_of(":")
  case colon
    some(at) -> lhs.slice(0, at).strip
    none -> lhs
  end
end

# The identifier after `from` characters of `text` (loop targets).
def word_after(text: String, from: Int) -> String
  out = ""
  index = from
  while index < text.length
    ch = text.slice(index, 1)
    break if !word_char?(ch)

    out = "#{out}#{ch}"
    index += 1
  end

  out
end

def word_char?(ch: String) -> Bool
  code = ch.code
  (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or (code >= 48 and code <= 57) or code == 95
end

# `_ = name` after the last binding line of every self-only name, at that
# line's own indentation (same block, so the name is in scope there).
def append_self_reads(lines: List[String], self_only: List[String]) -> List[String]
  out = lines
  for name in self_only
    out = insert_read(out, name)
  end

  out
end

def insert_read(lines: List[String], name: String) -> List[String]
  at = -1
  index = 0
  for line in lines
    if binding_for?(line, name)
      at = index
    end

    index += 1
  end

  return lines if at < 0

  anchor = List.first(lines.drop(at))
  read = "#{indent_of(anchor)}_ = #{name}"
  lines.take(at + 1) + [read] + lines.drop(at + 1)
end

# Whether the line binds `name`: `name: T = ...` or `name = ...`. A
# comparison is not a binding, so `==` never counts (`name == 1`).
def binding_for?(line: String, name: String) -> Bool
  indent = indent_of(line)
  rest = line.slice(indent.length, line.length - indent.length)
  return false if !rest.start_with?(name)

  after = rest.slice(name.length, rest.length - name.length)
  return true if after.start_with?(":")

  return true if after.start_with?(" =") and !after.slice(2, after.length - 2).start_with?("=")

  after.start_with?("=") and !after.slice(1, after.length - 1).start_with?("=")
end

def indent_of(line: String) -> String
  out = ""
  for ch in line.split("")
    break if ch != " "

    out = "#{out} "
  end

  out
end

# Refuses any user binding whose name collides with the generated namespace:
# the module entry point (`main`), the runtime helpers (`py_pymod`,
# `py_floor_div`, `py_slice_list`, `py_slice_str`) and the counter-shaped
# temps (`py_tN`, `py_xN`, `py_try_bodyN`, `py_try_errN`). A module-level
# binding collides with the helper defs and `main`; a local one with the
# temps generated inside its own function.
def reserved_refusal(program: Frontend.Program) -> Optional[EmitCtx.Refusal]
  for func_def in program.funcs
    hit = reserved_occ(Frontend.NameOcc(name: func_def.name, span: func_def.name_span, kind: "declare"))
    return hit if hit.some?

    for occ in func_def.params
      hit = reserved_occ(occ)
      return hit if hit.some?
    end

    for occ in func_def.body_names
      if occ.kind == "declare" or occ.kind == "assign" or occ.kind == "reuse"
        hit = reserved_occ(occ)
        return hit if hit.some?
      end
    end
  end

  for item in program.top
    for occ in Frontend.top_names(item)
      if occ.kind == "declare" or occ.kind == "assign" or occ.kind == "reuse"
        hit = reserved_occ(occ)
        return hit if hit.some?
      end
    end
  end

  none
end

def reserved_occ(occ: Frontend.NameOcc) -> Optional[EmitCtx.Refusal]
  if generated_name?(occ.name)
    some(
      EmitCtx.Refusal(
        code: "PY-OUT-OF-SUBSET",
        message: (
          "`#{occ.name}` is reserved for the emitter's generated names (the `main` entry point, its runtime helpers and the `py_tN`-shaped counters)"
        ),
        help: some("rename it"),
        start: occ.span.start,
        stop: occ.span.stop,
      ),
    )
  else
    none
  end
end

def generated_name?(name: String) -> Bool
  return true if name == "main"

  return true if name == "py_pymod" or name == "py_floor_div"

  return true if name == "py_slice_list" or name == "py_slice_str"

  counted?("py_t", name) or counted?("py_x", name) or counted?("py_try_body", name) or counted?("py_try_err", name)
end

# Whether `name` is `prefix` followed by nothing but digits.
def counted?(prefix: String, name: String) -> Bool
  return false if !name.start_with?(prefix)

  rest = name.slice(prefix.length, name.length - prefix.length)
  return false if rest.empty?

  digits?(rest)
end

def digits?(text: String) -> Bool
  for ch in text.split("")
    code = ch.code
    return false if code < 48 or code > 57
  end

  true
end

# The final program: aliases, the expression helpers, the defs, the outlined
# try helpers, then `main` over the top-level statements with the rewrite
# passes applied.
def assemble(asm: Asm) -> List[String]
  main_body = rewrite_unused(asm.main_lines, unused_names(asm.walk))
  main_body = append_self_reads(main_body, self_only_names(asm.walk))
  if main_body.empty?
    main_body = ["nil"]
  end

  out: List[String] = []
  if !asm.alias_lines.empty?
    out = out + asm.alias_lines
    out = out.push("")
  end

  out = out + expr_helper_lines()
  out = out.push("")
  if !asm.def_lines.empty?
    out = out + asm.def_lines
    out = out.push("")
  end

  if !asm.helper_lines.empty?
    out = out + asm.helper_lines
    out = out.push("")
  end

  style_ends(out + ["def main() -> Void"] + EmitCtx.indented(main_body, 1) + ["end"])
end

# `agentica.toml` sets `blank_line_after_end = true`, so the emitted file
# must check clean under the repo's own style: a line holding only `end`
# takes an empty line after it, unless the next line closes another block
# (`end`, `else`, `elsif`) or continues a wrapped expression (`)`, `]`, `}`
# or `.name`), and never before a blank line or the end of the file.
def style_ends(lines: List[String]) -> List[String]
  out: List[String] = []
  count = lines.size
  index = 0
  while index < count
    line = List.first(lines.drop(index))
    out = out.push(line)
    if only_end?(line) and index + 1 < count
      next_line = List.first(lines.drop(index + 1))
      if next_line.strip != "" and !closes_or_continues?(next_line)
        out = out.push("")
      end
    end

    index += 1
  end

  out
end

def only_end?(line: String) -> Bool = line.strip == "end"

# Whether the line after an `end` may stay right below it under
# `blank_line_after_end`.
def closes_or_continues?(line: String) -> Bool
  rest = line.strip
  return true if rest.start_with?(")") or rest.start_with?("]") or rest.start_with?("}") or rest.start_with?(".")

  word = word_after(rest, 0)
  word == "end" or word == "else" or word == "elsif"
end

def expr_helper_lines() -> List[String] = trim_blank_tail(EmitExpr.helpers().split("\n"))

def trim_blank_tail(lines: List[String]) -> List[String]
  keep = lines.size
  index = lines.size - 1
  while index >= 0
    if List.first(lines.drop(index)) == ""
      keep = index
      index -= 1
    else
      index = -1
    end
  end

  lines.take(keep)
end

# The self-update reads of one statement subtree: uses of an assignment
# target inside its own right-hand side, plus the implicit read every
# augmented target makes of itself (its lowering reads the name even when
# the right-hand side never mentions it) — the reads the backend discounts
# as dead. Kwarg names are skipped (they name nothing).
def self_keys(stmts: List[Stmt], source: String) -> List[String]
  out: List[String] = []
  for stmt in stmts
    case stmt
      Stmt.Assigned(occ, value) -> out = out + target_keys(occ.name, value, source)
      Stmt.AugAssigned(occ, _, value) ->
        out = out.push("#{occ.name}:#{occ.span.start}:#{occ.span.stop}")
        out = out + target_keys(occ.name, value, source)
      Stmt.ForLoop(_, _, body) -> out = out + self_keys(body, source)
      Stmt.IfStmt(arms, else_body) ->
        for arm in arms
          out = out + self_keys(arm.body, source)
        end

        out = out + self_keys(else_body, source)
      Stmt.WhileStmt(_, body) -> out = out + self_keys(body, source)
      Stmt.TryStmt(try_body, handler, _) -> out = out + self_keys(try_body, source) + self_keys(handler, source)
      _ -> out = out
    end
  end

  out
end

def target_keys(name: String, value: Tree.Node, source: String) -> List[String]
  out: List[String] = []
  for occ in names_in(value, source)
    if occ.name == name
      out = out.push("#{name}:#{occ.span.start}:#{occ.span.stop}")
    end
  end

  out
end

# Every `name` occurrence in an expression subtree; annotation subtrees hold
# `ident` nodes, so they never appear.
def names_in(node: Tree.Node, source: String) -> List[Frontend.NameOcc]
  if node.rule == "name"
    occ = Frontend.NameOcc(
      name: Tree.text(node, source),
      span: Frontend.Span(start: node.start, stop: node.stop),
      kind: "use",
    )

    [occ]
  else
    if node.rule == "kwarg"
      skip = Tree.first_child(node, "name")
      case skip
        some(found) -> kwarg_rest(node, found, source)
        none -> names_all(node.children, source)
      end
    else
      names_all(node.children, source)
    end
  end
end

def kwarg_rest(node: Tree.Node, skip: Tree.Node, source: String) -> List[Frontend.NameOcc]
  out: List[Frontend.NameOcc] = []
  for child in node.children
    if child.rule != "name" or child.start != skip.start or child.stop != skip.stop
      out = out + names_in(child, source)
    end
  end

  out
end

def names_all(nodes: List[Tree.Node], source: String) -> List[Frontend.NameOcc]
  out: List[Frontend.NameOcc] = []
  for node in nodes
    out = out + names_in(node, source)
  end

  out
end
