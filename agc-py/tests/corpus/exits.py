import sys


def finish(code: int) -> None:
    print("exiting with", code)
    sys.exit(code)


print("start")
finish(3)
print("unreachable")
