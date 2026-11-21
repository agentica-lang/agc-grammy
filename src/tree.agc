## The parse tree the engine builds, and the queries user code runs on it.

## A matched rule: its name, the characters it covered, the nodes inside it and
## the tag the grammar gave it (`#name = term`).
struct Node
  rule: String
  start: Int
  stop: Int
  children: List[Node]
  tag: Optional[String]
end

## A place in the input, counted from 1.
struct Position
  line: Int
  column: Int
  line_text: String
end

## The text a node covered.
def text(node: Node, input: String) -> String = input.slice(node.start, node.stop - node.start)

## The text a node covered, shortened to fit in one message line.
def snippet(node: Node, input: String) -> String = clip(text(node, input))

## Whether a node covered no characters.
def empty?(node: Node) -> Bool = node.stop == node.start

## Direct children whose rule is `name`, in source order.
def children_of(node: Node, name: String) -> List[Node] = node.children.select { |child| child.rule == name }

## The first direct child whose rule is `name`.
def first_child(node: Node, name: String) -> Optional[Node]
  found: Optional[Node] = none
  for child in node.children
    if child.rule == name
      found = some(child)
      break
    end
  end

  found
end

## The last direct child, if any.
def last_child(node: Node) -> Optional[Node]
  return none if node.children.empty?

  some(node.children[node.children.size - 1])
end

## The first node at any depth whose rule is `name`, depth first.
def first(node: Node, name: String) -> Optional[Node]
  found: Optional[Node] = none
  for child in node.children
    if child.rule == name
      found = some(child)
    else
      found = first(child, name)
    end

    break if found.some?
  end

  found
end

## Every node at any depth whose rule is `name`, depth first.
def find_all(node: Node, name: String) -> List[Node]
  found: List[Node] = []
  for child in node.children
    if child.rule == name
      found = found.push(child)
    end

    for match in find_all(child, name)
      found = found.push(match)
    end
  end

  found
end

## The first node at any depth tagged `name`, depth first.
def first_tagged(node: Node, name: String) -> Optional[Node]
  found: Optional[Node] = none
  for child in node.children
    if child.tag == some(name)
      found = some(child)
    else
      found = first_tagged(child, name)
    end

    break if found.some?
  end

  found
end

## Every node at any depth tagged `name`, depth first.
def tagged(node: Node, name: String) -> List[Node]
  found: List[Node] = []
  for child in node.children
    if child.tag == some(name)
      found = found.push(child)
    end

    for match in tagged(child, name)
      found = found.push(match)
    end
  end

  found
end

## The tree as JSON, following pest's `Pair::to_json` shape: each node carries
## `pos`/`rule` (plus grammy-only `tag` when the grammar set one), and `inner`
## is the covered text for a leaf or the nested pairs for a node with children.
## Array layout matches `serde_json::to_string_pretty` one element per line, so
## an untagged tree diffs clean against pest's output. Positions are character
## offsets into `input` (the engine is char-based), where pest reports byte
## offsets; they agree on ASCII input.
def to_json(node: Node, input: String) -> String = json_node(node, input, 0)

## A string as a JSON string literal, with the control characters escaped.
def json_string(value: String) -> String = "\"#{json_escape(value)}\""

## Where `offset` falls in `input`.
def position(input: String, offset: Int) -> Position
  chars = input.split("")
  limit = offset.clamp(0, chars.size)
  line = 1
  column = 1
  line_start = 0
  for i in 0...limit
    if chars[i] == "\n"
      line += 1
      column = 1
      line_start = i + 1
    else
      column += 1
    end
  end

  Position(line: line, column: column, line_text: clip(line_from(chars, line_start)))
end

private

LINE_LIMIT = 60

# One array element per line, as `serde_json::to_string_pretty` prints them.
def json_pos(start: Int, stop: Int, pad: String) -> String
  content = "#{pad}  "
  "[\n#{content}#{start},\n#{content}#{stop}\n#{pad}]"
end

def json_node(node: Node, input: String, depth: Int) -> String
  pad = "  " * depth
  inner_pad = "  " * (depth + 1)
  lines = ["#{pad}{"]
  lines = lines.push("#{inner_pad}\"pos\": #{json_pos(node.start, node.stop, inner_pad)},")
  lines = lines.push("#{inner_pad}\"rule\": #{json_string(node.rule)},")
  case node.tag
    none -> lines = lines
    some(tag) -> lines = lines.push("#{inner_pad}\"tag\": #{json_string(tag)},")
  end

  if node.children.empty?
    lines = lines.push("#{inner_pad}\"inner\": #{json_string(text(node, input))}")
  else
    lines = lines.push("#{inner_pad}\"inner\": #{json_pairs(node.children, input, depth + 1)}")
  end

  lines.push("#{pad}}").join("\n")
end

# `children` must not be empty; only `json_node` calls this, guarded above.
def json_pairs(children: List[Node], input: String, depth: Int) -> String
  pad = "  " * depth
  inner_pad = "  " * (depth + 1)
  first = List.first(children)
  last = List.last(children)
  lines = ["{"]
  pos = json_pos(first.start, last.stop, inner_pad)
  lines = lines.push("#{inner_pad}\"pos\": #{pos},")
  lines = lines.push("#{inner_pad}\"pairs\": [")
  rendered = children.map { |child| json_node(child, input, depth + 2) }
  lines = lines.push(rendered.join(",\n"))
  lines = lines.push("#{inner_pad}]")
  lines.push("#{pad}}").join("\n")
end

def json_escape(value: String) -> String = value.split("").map { |ch| json_char(ch) }.join("")

def json_char(ch: String) -> String
  case ch
    "\"" -> "\\\""
    "\\" -> "\\\\"
    "\n" -> "\\n"
    "\r" -> "\\r"
    "\t" -> "\\t"
    _ -> json_control(ch)
  end
end

def json_control(ch: String) -> String
  code = ch.code
  return ch if code >= 32
  return "\\b" if code == 8
  return "\\f" if code == 12
  "\\u#{format("%04x", code)}"
end

def clip(text: String) -> String
  return text if text.length <= LINE_LIMIT

  "#{text.slice(0, LINE_LIMIT)}..."
end

# The characters from `start` to the next newline.
def line_from(chars: List[String], start: Int) -> String
  text = ""
  i = start
  while i < chars.size and chars[i] != "\n"
    text = "#{text}#{chars[i]}"
    i += 1
  end

  text
end
