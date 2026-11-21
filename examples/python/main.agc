## Runs a Python-subset file, printing what the program prints.

import Interp from "interp"

def main() -> Void
  args = System.args()
  if args.size != 1
    IO.warn("usage: agentica examples/python/main.agc <program.py>")
    System.exit(2)
  end

  case File.read_text(args[0])
    ok(source) -> show(Interp.run(source))
    error(e) -> fail(e.message)
  end
end

def show(result: Result[List[String]]) -> Void
  case result
    ok(lines) -> lines.each { |line| puts(line) }
    error(e) -> fail(e.message)
  end
end

def fail(message: String) -> Void
  IO.warn(message)
  System.exit(1)
end
