# Soak the Tang BAR2 completer: random 32-bit values into its 16 words,
# read back, for N rounds. Exactly 4-byte accesses.
# Part of NextTang: https://github.com/jattree/NextTang (GPL-3.0-or-later).
import ctypes, mmap, os, random, sys, time
n = int(sys.argv[1]) if len(sys.argv) > 1 else 100000
fd = os.open("/sys/bus/pci/devices/0001:01:00.0/resource2", os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
w = [ctypes.c_uint32.from_buffer(mm, 4 * i) for i in range(16)]
rng = random.Random(20261102); bad = 0; t = time.perf_counter()
for k in range(n):
    vals = [rng.getrandbits(32) for _ in range(16)]
    for i, v in enumerate(vals): w[i].value = v
    for i, v in enumerate(vals):
        r = w[i].value
        if r != v:
            bad += 1
            if bad <= 5: print(f"round {k} word {i}: wrote {v:08X} read {r:08X}")
dt = time.perf_counter() - t
print(f"{n} rounds, {n*16} writes + {n*16} reads in {dt:.1f} s, mismatches {bad}")
