def yn(b: bool) -> str:
    return "yes" if b else "no"


def is_big(x: int) -> bool:
    return x > 4


xs: list[int] = [5, 3, 8, 1]
print(len(xs), xs[0], xs[-1], xs[1:3], xs[:2], xs[2:], xs[1:100], xs[3:1])
ys: list[int] = xs + [9, 9]
print(ys, len(ys), yn(9 in ys), yn(4 not in ys), yn(4 in ys))
xs = xs + [7]
print(xs, sorted(xs), sum(xs), len(sorted(xs)))
print(abs(-4), abs(-2.5), abs(3))
fs: list[float] = [1.5, 2.5, 3.0]
print(sum(fs), sorted(fs), len(fs))
ss: list[str] = ["pear", "apple", "fig"]
print(yn(sorted(ss) == ["apple", "fig", "pear"]), len(sorted(ss)))
empty: list[int] = []
print(len(empty), sum(empty), yn(empty == []), yn([1] == [1]), yn([1] != [2]))
d: dict[str, int] = {"a": 1, "b": 2}
print(d["a"], d["b"], yn("a" in d), yn("z" not in d), len(d))
print(len(d), d.get("a", 0), d.get("zz", -1))
got: int | None = d.get("a")
miss: int | None = d.get("q")
print("none" if got is None else "some", "none" if miss is None else "some")
m: dict[int, str] = {1: "one", 2: "two"}
print(m[1] + m[2], yn(1 in m), yn(3 in m))
grid: list[list[int]] = [[1, 2], [3, 4]]
print(grid[1][0], len(grid), len(grid[0]), grid[0] + grid[1])
tally: int = 0
for w in "a b a c b a".split(" "):
    if w == "a":
        tally += 1
print(tally)
print(yn(all([True, True])), yn(any([False, True])), yn(all([1 < 2, 2 < 3])), yn(any([1 > 2])))
flags: list[bool] = [True, False]
if any(flags):
    print("some")
if all(flags):
    print("every")
else:
    print("not every")
if any(map(is_big, xs)) and not all(map(is_big, xs)):
    print("mixed")
rest: list[int] = xs
while all(map(is_big, rest)) or any(flags):
    print("loop")
    flags = [False]
    rest = [1]
for big in filter(is_big, xs):
    print("big", big)
