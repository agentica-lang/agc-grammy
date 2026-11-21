## Running the Python subset: grammars/python.grammar plus the interpreter.

import Interp from "../examples/python/interp"

def main() -> Void
  Test.run([
    Test.test("arithmetic follows precedence") do
      try Test.eq(Interp.run("print(1 + 2 * 3)"), ok(["7"]))
      Test.eq(Interp.run("print((1 + 2) * 3)"), ok(["9"]))
    end,
    Test.test("division is true division") do
      try Test.eq(Interp.run("print(7 / 2)"), ok(["3.5"]))
      Test.eq(Interp.run("print(1.5 + 2)"), ok(["3.5"]))
    end,
    Test.test("text concatenates") do Test.eq(Interp.run("print(\"a\" + \"b\")"), ok(["ab"])) end,
    Test.test("print joins its arguments") do Test.eq(Interp.run("print(\"a\", 1, True)"), ok(["a 1 True"])) end,
    Test.test("assignments and a while loop") do
      program = "i = 0\ntotal = 0\nwhile i < 5: total = total + i * 2; i = i + 1\nprint(total)"
      Test.eq(Interp.run(program), ok(["20"]))
    end,
    Test.test("if, elif and else") do
      big = "x = 5\nif x > 10: print(\"big\")\nelif x > 2: print(\"middle\")\nelse: print(\"small\")"
      try Test.eq(Interp.run(big), ok(["middle"]))
      Test.eq(Interp.run("if 1 > 2: print(\"a\")\nelse: print(\"b\")"), ok(["b"]))
    end,
    Test.test("comparisons and booleans") do
      try Test.eq(Interp.run("print(1 < 2, 2 == 2, 3 != 4)"), ok(["True True True"]))
      try Test.eq(Interp.run("print(not False)"), ok(["True"]))
      Test.eq(Interp.run("print(True and False or True)"), ok(["True"]))
    end,
    Test.test("comments and blank lines") do
      Test.eq(Interp.run("# a comment\n\nprint(1)  # trailing\n"), ok(["1"]))
    end,
    Test.test("an undefined name fails") do
      case Interp.run("print(missing)")
        error(e) -> Test.assert(e.message.include?("not defined"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("an unknown function fails") do
      case Interp.run("nope(1)")
        error(e) -> Test.assert(e.message.include?("unknown function nope"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("a syntax error is reported") do
      case Interp.run("x = ")
        error(e) -> Test.assert(e.message.include?("expected program"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
  ])
end
