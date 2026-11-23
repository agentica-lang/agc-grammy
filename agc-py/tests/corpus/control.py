def classify(n: int) -> str:
    if n < 0:
        return "neg"
    elif n == 0:
        return "zero"
    elif n < 10:
        return "small"
    else:
        return "big"


def collatz(n: int) -> int:
    steps: int = 0
    while n != 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = 3 * n + 1
        steps += 1
    return steps


def first_over(xs: list[int], limit: int) -> int:
    found: int = -1
    for x in xs:
        if x > limit:
            found = x
            break
    return found


def odd_sum(n: int) -> int:
    total: int = 0
    for i in range(n):
        if i % 2 == 0:
            pass
        total += i
    return total


for v in [-3, 0, 4, 99]:
    print(v, classify(v))
print(collatz(27), first_over([1, 5, 9], 4), first_over([1], 4), odd_sum(10))
for i in range(3):
    print("r1", i)
for i in range(2, 5):
    print("r2", i)
for i in range(5, 5):
    print("never")
for ch in "héy":
    print(ch)
j: int = 0
while True:
    j += 1
    if j < 3:
        pass
    if j > 5:
        break
    print("j", j)
n: int = 0
while n < 3:
    for m in range(3):
        if m == 2:
            break
        n += 1
print(n)
last: int = 0
for last in [4, 5, 6]:
    pass
print(last)
assert n > 0
assert n == 4, "n is three"
pass
