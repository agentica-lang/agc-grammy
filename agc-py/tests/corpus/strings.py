def yn(b: bool) -> str:
    return "yes" if b else "no"


s: str = "  Hello, World  "
print(s.strip(), len(s), s.upper(), s.lower())
print(yn(s.strip().startswith("Hello")), yn(s.strip().endswith("x")), yn("World" in s), yn("x" not in s))
print(s.replace("l", "L"), len(s.strip().split(", ")), len("a,b,c".split(",")))
print(",".join(["a"] + ["b"]), "-".join(["a", "b", "c"]), ", ".join(["x"]), "".join(["p", "q"]))
words: list[str] = "the quick brown fox".split(" ")
print(len(words), words[0], words[3], words[-1])
text: str = "héllo wörld"
print(text[0], text[1], text[-1], text[0:4], text[:3], text[4:], text[3:100], yn(text[5:2] == ""))
print(chr(65) + chr(233), ord("A"), ord("é"), chr(ord("a") + 1))
print("ab" * 3 + "!", "x" + "y" + "z", yn("abc" < "abd"), yn("b" > "a"))
print(f"{text}|{len(text)}|{text.upper()}|{words[1][0]}")
print(len("a\tb".split("\t")), "multi\nline".split("\n")[1])
n: int = 42
print("n=" + str(n), str(3.5), str(n * 2))
e: str = ""
print(len(e), yn(e == ""), e + "x", yn("x" in "xyz"))
