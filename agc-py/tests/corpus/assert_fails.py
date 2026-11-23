def positive(n: int) -> int:
    assert n > 0, "not positive"
    return n


print(positive(2))
print(positive(-1))
print("unreachable")
