def yn(b: bool) -> str:
    return "yes" if b else "no"


print(0xFF, 0o17, 0b101, 1_000_000, 0x_ff, 0)
print(1.5, 2e3, 1.25e-2, 3.0, 1_0.5, 5.0 / 2.0)
print('single', "double", """triple
lines""", '''also
triple''')
print(r"raw\n", r'a\tb', "tab:\t|", "q\"q", 'q\'q', "back\\slash")
print(yn("\x41é\0\a\b\f\v" == "Aé\x00\x07\x08\x0c\x0b"))
print(f"{1 + 2} and {'x' * 3} {{braces}}")
name: str = "w"
n: int = 3
print(f"{name}={n} {n * 2} {yn(n > 2 and n < 5)}")
print(yn(True), yn(False), yn(1 == 1), yn("a" != "b"))
print("é" + "ü", len("héllo"), "日本語"[1])
