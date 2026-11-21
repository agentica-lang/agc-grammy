# A small program in the subset: one statement per line, one suite per line.

i = 0
total = 0
while i < 5: total = total + i * 2; i = i + 1
print("total", total)

if total > 10: print("big")
elif total == 10: print("ten")
else: print("small")

name = "agentica"
print(name + " runs Python", 7 / 2)
print(not False, 1 < 2 and 2 < 3)
