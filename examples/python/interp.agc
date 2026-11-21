## A Python subset that runs on Agentica.
##
## The grammar is in `grammars/python.grammar`; this file is the code that uses
## it: it walks the tree grammy builds and evaluates it. Statements are one per
## line and a suite is one statement (or several joined by `;`).

import Grammy from "../../src/grammy"

## The grammar this interpreter runs, relative to the working directory.
GRAMMAR_PATH = "grammars/python.grammar"

## Runs `source` and returns the lines it printed.
def run(source: String) -> Result[List[String]]
  grammar = try Grammy.load(GRAMMAR_PATH)
  run_with(grammar, source)
end

## Runs `source` with an already compiled grammar.
def run_with(grammar: Grammy.Grammar, source: String) -> Result[List[String]]
  tree = try Grammy.run(grammar, "program", source)
  state = try exec_all(tree.children, start_state(source))
  ok(state.out)
end

private

MAX_STEPS = 100_000

# What a Python value holds.
enum Value
  Number(Int)
  Decimal(Float)
  Text(String)
  Flag(Bool)
  Nothing
end

# The interpreter's memory: source text, names, printed lines and work left.
struct State
  source: String
  vars: Map[String, Value]
  out: List[String]
  steps: Int
end

# A value together with the state its evaluation left behind.
struct Evaluated
  value: Value
  state: State
end

def start_state(source: String) -> State = State(source: source, vars: {}, out: [], steps: 0)

def exec_all(nodes: List[Grammy.Node], state: State) -> Result[State]
  current = state
  for node in nodes
    current = try exec(node, current)
  end

  ok(current)
end

def exec(node: Grammy.Node, state: State) -> Result[State]
  case node.rule
    "assign" -> exec_assign(node, state)
    "if_stmt" -> exec_if(node, state)
    "while_loop" -> exec_while(node, state)
    "call_stmt" -> exec_call(node, state)
    _ -> error("python: cannot run #{node.rule}")
  end
end

def exec_assign(node: Grammy.Node, state: State) -> Result[State]
  target = try child_node(node, "name", "python: assignment without a name")
  source = try Grammy.last_child(node).to_result("python: assignment without a value")
  evaluated = try eval(source, state)
  name = Grammy.text(target, state.source)
  ok(evaluated.state.with(vars: evaluated.state.vars.put(name, evaluated.value)))
end

def exec_if(node: Grammy.Node, state: State) -> Result[State]
  return error("python: if without a body") if node.children.size < 2

  condition = try eval(node.children[0], state)
  taken = try truthy(condition.value)
  return exec_all(body_of_if(node.children), condition.state) if taken

  exec_branches(branches_of(node.children), condition.state)
end

def exec_branches(branches: List[Grammy.Node], state: State) -> Result[State]
  for branch in branches
    return exec_all(branch.children, state) if branch.rule == "else_branch"
    condition = try eval(branch.children[0], state)
    taken = try truthy(condition.value)
    return exec_all(branch.children.drop(1), condition.state) if taken
  end

  ok(state)
end

def exec_while(node: Grammy.Node, state: State) -> Result[State]
  return error("python: while without a body") if node.children.size < 2

  body = node.children.drop(1)
  current = state
  running = true
  while running
    condition = try eval(node.children[0], current)
    running = try truthy(condition.value)
    if running
      current = try exec_all(body, condition.state)
    end
  end

  ok(current)
end

def exec_call(node: Grammy.Node, state: State) -> Result[State]
  call = try child_node(node, "call", "python: statement without a call")
  evaluated = try eval(call, state)
  ok(evaluated.state)
end

def eval(node: Grammy.Node, state: State) -> Result[Evaluated]
  spent = try spend(state)
  case node.rule
    "or_expr" -> eval_or(node, spent)
    "and_expr" -> eval_and(node, spent)
    "boolean_not" -> eval_not(node, spent)
    "comparison" -> eval_comparison(node, spent)
    "sum" -> eval_folded(node, spent)
    "term" -> eval_folded(node, spent)
    "minus" -> eval_minus(node, spent)
    "number" -> eval_number(node, spent)
    "text" -> eval_text(node, spent)
    "boolean" -> eval_boolean(node, spent)
    "name" -> eval_name(node, spent)
    "call" -> eval_call(node, spent)
    "group" -> eval(node.children[0], spent)
    _ -> error("python: cannot evaluate #{node.rule}")
  end
end

def eval_or(node: Grammy.Node, state: State) -> Result[Evaluated]
  current = try eval(node.children[0], state)
  at = 1
  while at < node.children.size
    decided = try truthy(current.value)
    break if decided
    current = try eval(node.children[at], current.state)
    at += 1
  end

  ok(current)
end

def eval_and(node: Grammy.Node, state: State) -> Result[Evaluated]
  current = try eval(node.children[0], state)
  at = 1
  while at < node.children.size
    decided = try truthy(current.value)
    break if !decided
    current = try eval(node.children[at], current.state)
    at += 1
  end

  ok(current)
end

def eval_not(node: Grammy.Node, state: State) -> Result[Evaluated]
  inner = try eval(node.children[0], state)
  flag = try truthy(inner.value)
  ok(Evaluated(value: Value.Flag(!flag), state: inner.state))
end

def eval_comparison(node: Grammy.Node, state: State) -> Result[Evaluated]
  left = try eval(node.children[0], state)
  return ok(left) if node.children.size < 3

  op_node = node.children[1]
  right = try eval(node.children[2], left.state)
  value = try compare_values(Grammy.text(op_node, right.state.source), left.value, right.value)
  ok(Evaluated(value: value, state: right.state))
end

# Folds `value op value op value` children left to right.
def eval_folded(node: Grammy.Node, state: State) -> Result[Evaluated]
  current = try eval(node.children[0], state)
  at = 1
  while at + 1 < node.children.size
    op_node = node.children[at]
    right = try eval(node.children[at + 1], current.state)
    value = try apply_operator(Grammy.text(op_node, right.state.source), current.value, right.value)
    current = Evaluated(value: value, state: right.state)
    at += 2
  end

  ok(current)
end

def eval_minus(node: Grammy.Node, state: State) -> Result[Evaluated]
  inner = try eval(node.children[0], state)
  case inner.value
    Value.Number(n) -> ok(Evaluated(value: Value.Number(-n), state: inner.state))
    Value.Decimal(f) -> ok(Evaluated(value: Value.Decimal(-f), state: inner.state))
    _ -> error("python: cannot negate #{render(inner.value)}")
  end
end

def eval_number(node: Grammy.Node, state: State) -> Result[Evaluated]
  text = Grammy.text(node, state.source)
  if text.include?(".")
    decimal = try text.to_f
    ok(Evaluated(value: Value.Decimal(decimal), state: state))
  else
    whole = try text.to_i
    ok(Evaluated(value: Value.Number(whole), state: state))
  end
end

def eval_text(node: Grammy.Node, state: State) -> Result[Evaluated]
  ok(Evaluated(value: Value.Text(unquote(Grammy.text(node, state.source))), state: state))
end

def eval_boolean(node: Grammy.Node, state: State) -> Result[Evaluated]
  ok(Evaluated(value: Value.Flag(Grammy.text(node, state.source) == "True"), state: state))
end

def eval_name(node: Grammy.Node, state: State) -> Result[Evaluated]
  name = Grammy.text(node, state.source)
  case Map.get(state.vars, name)
    some(value) -> ok(Evaluated(value: value, state: state))
    none -> error("python: name #{name} is not defined")
  end
end

def eval_call(node: Grammy.Node, state: State) -> Result[Evaluated]
  target = try child_node(node, "name", "python: call without a name")
  current = state
  values: List[Value] = []
  for arg in node.children.drop(1)
    evaluated = try eval(arg, current)
    values = values.push(evaluated.value)
    current = evaluated.state
  end

  dispatch_call(Grammy.text(target, state.source), values, current)
end

def dispatch_call(name: String, values: List[Value], state: State) -> Result[Evaluated]
  return error("python: unknown function #{name}") if name != "print"

  line = values.map { |value| render(value) }.join(" ")
  ok(Evaluated(value: Value.Nothing, state: state.with(out: state.out.push(line))))
end

def apply_operator(op: String, left: Value, right: Value) -> Result[Value]
  case op
    "+" -> add_values(left, right)
    "-" -> numeric_op("-", left, right)
    "*" -> numeric_op("*", left, right)
    "/" -> divide_values(left, right)
    _ -> error("python: unknown operator #{op}")
  end
end

def add_values(left: Value, right: Value) -> Result[Value]
  return text_add(left, right) if text?(left) or text?(right)

  numeric_op("+", left, right)
end

def text_add(left: Value, right: Value) -> Result[Value]
  return error("python: cannot add #{render(left)} and #{render(right)}") if !(text?(left) and text?(right))

  ok(Value.Text("#{render(left)}#{render(right)}"))
end

def numeric_op(op: String, left: Value, right: Value) -> Result[Value]
  if whole?(left) and whole?(right)
    whole_op(op, try as_int(left), try as_int(right))
  else
    decimal_op(op, try as_float(left), try as_float(right))
  end
end

def whole_op(op: String, left: Int, right: Int) -> Result[Value]
  case op
    "+" -> ok(Value.Number(left + right))
    "-" -> ok(Value.Number(left - right))
    "*" -> ok(Value.Number(left * right))
    _ -> error("python: unknown operator #{op}")
  end
end

def decimal_op(op: String, left: Float, right: Float) -> Result[Value]
  case op
    "+" -> ok(Value.Decimal(left + right))
    "-" -> ok(Value.Decimal(left - right))
    "*" -> ok(Value.Decimal(left * right))
    _ -> error("python: unknown operator #{op}")
  end
end

def divide_values(left: Value, right: Value) -> Result[Value]
  numerator = try as_float(left)
  denominator = try as_float(right)
  return error("python: division by zero") if denominator == 0.0

  ok(Value.Decimal(numerator / denominator))
end

def compare_values(op: String, left: Value, right: Value) -> Result[Value]
  case op
    "==" -> ok(Value.Flag(equal?(left, right)))
    "!=" -> ok(Value.Flag(!equal?(left, right)))
    _ -> ordered(op, left, right)
  end
end

def ordered(op: String, left: Value, right: Value) -> Result[Value]
  a = try as_float(left)
  b = try as_float(right)
  case op
    "<" -> ok(Value.Flag(a < b))
    "<=" -> ok(Value.Flag(a <= b))
    ">" -> ok(Value.Flag(a > b))
    ">=" -> ok(Value.Flag(a >= b))
    _ -> error("python: unknown comparison #{op}")
  end
end

def equal?(left: Value, right: Value) -> Bool
  return number_equal?(left, right) if numeric?(left) and numeric?(right)
  return false if numeric?(left) or numeric?(right)

  left == right
end

def truthy(value: Value) -> Result[Bool]
  case value
    Value.Flag(flag) -> ok(flag)
    Value.Number(n) -> ok(n != 0)
    Value.Decimal(f) -> ok(f != 0.0)
    Value.Text(text) -> ok(text.length > 0)
    Value.Nothing -> ok(false)
  end
end

def render(value: Value) -> String
  case value
    Value.Number(n) -> "#{n}"
    Value.Decimal(f) -> "#{f}"
    Value.Text(text) -> text
    Value.Flag(flag) ->
      if flag
        "True"
      else
        "False"
      end

    Value.Nothing -> "None"
  end
end

def as_int(value: Value) -> Result[Int]
  case value
    Value.Number(n) -> ok(n)
    _ -> error("python: expected a whole number, found #{render(value)}")
  end
end

def as_float(value: Value) -> Result[Float]
  case value
    Value.Number(n) -> ok(n.to_f)
    Value.Decimal(f) -> ok(f)
    _ -> error("python: expected a number, found #{render(value)}")
  end
end

def numeric?(value: Value) -> Bool
  case value
    Value.Number(_) -> true
    Value.Decimal(_) -> true
    _ -> false
  end
end

def whole?(value: Value) -> Bool
  case value
    Value.Number(_) -> true
    _ -> false
  end
end

def text?(value: Value) -> Bool
  case value
    Value.Text(_) -> true
    _ -> false
  end
end

# Both sides are numbers, so the conversion cannot fail.
def number_equal?(left: Value, right: Value) -> Bool = as_float(left).unwrap! == as_float(right).unwrap!

def spend(state: State) -> Result[State]
  return error("python: step limit reached") if state.steps >= MAX_STEPS

  ok(state.with(steps: state.steps + 1))
end

def child_node(node: Grammy.Node, rule: String, message: String) -> Result[Grammy.Node]
  Grammy.first_child(node, rule).to_result(message)
end

def is_branch?(node: Grammy.Node) -> Bool = node.rule == "elif_branch" or node.rule == "else_branch"

def body_of_if(children: List[Grammy.Node]) -> List[Grammy.Node]
  children.drop(1).take_while { |child| !is_branch?(child) }
end

def branches_of(children: List[Grammy.Node]) -> List[Grammy.Node] = children.select { |child| is_branch?(child) }

# Drops the quotes of a `text` node; escapes are not decoded yet.
def unquote(text: String) -> String = text.slice(1, text.length - 2)
