type Count = int
type Names = list[str]


def label(n: Count, names: Names) -> str:
    return names[n] + "!"


def has(x: int | None) -> str:
    if x is None:
        return "none"
    return "some"


def has2(x: "Optional[int]") -> str:
    return "none" if x is None else "some"


def noop(n: int) -> None:
    print("noop", n)
    return


def fwd(x: "Count") -> "Count":
    return x * 2


i: int = 7
s: str = "héllo"
f: float = 2.5
b: bool = False
xs: list[int] = [3, 1, 2]
d: dict[str, int] = {"a": 1, "b": 2}
di: dict[int, str] = {1: "x"}
nested: dict[str, list[int]] = {"k": [1, 2]}
o: int | None = d.get("a")
p: "Optional[int]" = d.get("zz")
print(i, s, f, len(xs), len(d))
print(label(1, ["a", "b"]), has(None), has(4), has2(None), has2(5))
noop(3)
print(fwd(21), di[1], nested["k"][1])
print(xs)
print(len(d))
print("none" if o is None else "some", "none" if p is None else "some")
