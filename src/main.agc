## Runs a rule of a `.grammar` file over an input file and prints the tree.

import Engine from "engine"
import Grammar from "grammar"
import Tree from "tree"

USAGE = "usage: agentica src/main.agc <grammar> <rule> [input-file]"

def main() -> Void
  args = System.args()
  if args.size < 2
    IO.warn(USAGE)
    System.exit(2)
  end

  case read_input(args)
    error(e) -> fail(e.message)
    ok(input) -> show(args[0], args[1], input)
  end
end

def show(grammar_path: String, rule_name: String, input: String) -> Void
  case parse(grammar_path, rule_name, input)
    ok(tree) -> puts(render(tree, input))
    error(e) -> fail(e.message)
  end
end

## Parses `input` with the named rule of the grammar at `grammar_path`.
def parse(grammar_path: String, rule_name: String, input: String) -> Result[Tree.Node]
  grammar = try Grammar.load(grammar_path)
  Engine.run(grammar, rule_name, input)
end

private

# The input file, or standard input when there is none.
def read_input(args: List[String]) -> Result[String]
  return ok(IO.read()) if args.size < 3

  File.read_text(args[2])
end

# One indented line per node: `rule "text"`.
def render(node: Tree.Node, input: String, depth: Int = 0) -> String
  lines = [label(node, input, depth)]
  for child in node.children
    for line in render(child, input, depth + 1).split("\n")
      lines = lines.push(line)
    end
  end

  lines.join("\n")
end

def label(node: Tree.Node, input: String, depth: Int) -> String
  "#{"  " * depth}#{node.rule} #{Tree.snippet(node, input).inspect}"
end

def fail(message: String) -> Void
  IO.warn(message)
  System.exit(1)
end
