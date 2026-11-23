def parse(s: str) -> "Result[int]":
    n: int = int(s)
    if n < 0:
        raise ValueError("negative")
    return n


def check(n: int) -> "Result[None]":
    if n > 100:
        raise ValueError("too big")


def chain(a: str, b: str) -> "Result[int]":
    return parse(a) + parse(b)


def safe(s: str) -> None:
    try:
        got: int = parse(s) + 1
        print("parsed", got)
    except ValueError:
        print("failed")


safe("41")
safe("-3")
safe("zzz")
try:
    total: int = chain("1", "2")
    print("total", total)
    check(total)
    check(500)
    print("unreachable")
except:
    print("caught")
try:
    check(5)
    print("fine")
except Exception:
    print("no")
try:
    x: float = float("2.5") * 2.0
    print(x)
    y: int = int("abc")
    print("unreachable", y)
except ValueError as err:
    print("bad int")
try:
    check(101)
except ValueError as why:
    print("why:", why)
