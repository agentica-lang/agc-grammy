## The `agc-py` pipeline skeleton: stages fail loudly until phases 1-3 land.

import Py2Agc from "../src/py2agc"

def main() -> Void
  Test.run([
    Test.test("the skeleton has a version") do Test.eq(Py2Agc.version(), "0.0.0") end,
    Test.test("an empty program is refused") do
      case Py2Agc.translate("")
        error(e) -> Test.assert(e.message.include?("nothing to translate"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
    Test.test("translation waits for the grammar and the emitter") do
      case Py2Agc.translate("print(1)")
        error(e) -> Test.assert(e.message.include?("not implemented yet"), e.message)
        ok(_) -> Test.assert(false, "expected an error")
      end
    end,
  ])
end
