def yn(b: bool) -> str:
    return "yes" if b else "no"


a: int = 3
b: int = 10
x: float = 2.5
xs: list[int] = [3, 1]
ys: list[int] = [2]
s: str = "4"
t: str = "5"
print(abs(a - b), abs(-a), abs(-x), round(x * 2.5))
print(sorted(xs + ys), sum(xs + ys), len(xs + ys), len(s + t), len(s * 3))
print(float(a + b), float(a) / 2.0, (a + b) / 4, (a + b) ** 2, -a ** 2, (-a) ** 2)
print((a + b) // 4, (a - b) % 4, yn(a - b in xs + ys), yn((s + t) == "45"))
print(chr(a + 62), ord("a") + 1, ord(s + "z") if False else 0)
print((s + t).upper(), ("a" + "b").join(["x", "y"]), (s + t).replace("4", "z"))
for i in range(2):
    print(i)
for i in range(2):
    print("again")
for i in range(a - 1, a + 1):
    print("i" + str(i))
