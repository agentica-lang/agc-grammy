def yn(b: bool) -> str:
    return "yes" if b else "no"


a: int = 17
b: int = -5
print(a + b, a - b, a * b, a % 5, b % 3, a % -4, -7 % 2)
print(a // 5, b // 3, -7 // 2, 7 // -2, 6 // 3, 0 // 5)
print(a / 4, 7 / 2, -7 / 2, 6 / 3)
print(2 ** 10, 3 ** 0, (-2) ** 3, 2 ** 3 ** 2, -2 ** 2)
x: float = 7.5
y: float = 2.0
print(x + y, x - y, x * y, x / y)
print(1 + 2 * 3 - 4, 1.0 + 2.0 * 3.0 - 4.0 / 2.0, (1 + 2) * 3, -(2 + 3), +4)
c: int = 10
c += 5
c -= 3
c *= 2
c %= 7
print(c)
f: float = 9.0
f /= 2.0
f += 1.0
f *= 3.0
f -= 0.5
print(f)
k: int = 20
k = k // 4
print(k)
print(yn(10 > 3), yn(3 >= 3), yn(2 < 1), yn(2 <= 2), yn(1 == 1))
print(yn(1 < 2 < 3), yn(1 < 3 < 2), yn(1 <= 1 <= 1 < 2))
print(yn("a" < "b"), yn("b" <= "a"), yn("abc" > "abd"), yn("z" >= "z"))
print("ab" + "cd", "ab" * 3, "x" * 0)
print([1, 2] + [3], len([1, 2] + [3]))
t: bool = True
u: bool = False
print(yn(t and u), yn(t or u), yn(not t), yn(not u and t))
