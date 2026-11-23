def add(x: int, y: int = 10) -> int:
    return x + y


def greet(name: str, greeting: str = "hi", punct: str = "!") -> str:
    return greeting + " " + name + punct


def total(xs: list[int] = [1, 2, 3]) -> int:
    return sum(xs)


def pick(flag: bool, a: int, b: int) -> int:
    return a if flag else b


def fact(n: int) -> int:
    if n <= 1:
        return 1
    return n * fact(n - 1)


def is_even(n: int) -> bool:
    if n == 0:
        return True
    return is_odd(n - 1)


def is_odd(n: int) -> bool:
    if n == 0:
        return False
    return is_even(n - 1)


def noisy(tag: str) -> int:
    print("noisy", tag)
    return len(tag)


def shout(msg: str) -> None:
    print(msg.upper())


def keep(x: int) -> bool:
    return x % 2 == 1


def double(x: int) -> int:
    return x * 2


def scale(x: float, k: float = 2.0) -> float:
    return x * k


def shadow(x: int) -> int:
    x = x + 1
    y: int = x * 2
    return y


print(add(1), add(1, 2), add(y=5, x=1), add(x=3))
print(greet("bob"), greet("amy", "yo"), greet(punct="?", name="cy"), greet("di", punct="."))
print(total(), total([4, 5]))
print(pick(True, 1, 2), pick(False, 1, 2), pick(b=7, a=8, flag=False))
print(fact(10), "yes" if is_even(10) else "no", "yes" if is_odd(10) else "no")
print(noisy("b") + noisy("a"))
print(add(noisy("k"), y=noisy("kk")))
shout("done")
print(sum(map(double, [1, 2, 3])), sum(filter(keep, [1, 2, 3, 4, 5])))
for v in map(double, [4, 5]):
    print(v)
print(scale(1.5), scale(1.5, 3.0), shadow(4))
