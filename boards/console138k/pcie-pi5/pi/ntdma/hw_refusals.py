#!/usr/bin/env python3
"""Exercise the engine's hardware GO refusals through BAR2 (32-bit accesses
only). ADDR_LO/HI must already hold the ntdma buffer address (left there by
ntdma_test), so even a wrongly accepted GO would land inside that buffer."""
import ctypes, mmap, os
fd = os.open("/sys/bus/pci/devices/0001:01:00.0/resource2", os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
def rd(o): return ctypes.c_uint32.from_buffer(mm, o).value
def wr(o, v): ctypes.c_uint32.from_buffer(mm, o).value = v
assert rd(0x40) == 0x4E54444D
addr = rd(0x48) | rd(0x4C) << 32
print(f"ADDR={addr:#x} LEN={rd(0x50)} PAYLOAD={rd(0x54)}")
cases = [("len 0", 0, 128, 1), ("len 16MiB+4", 0x1000004, 128, 2),
         ("len not /4", 62, 128, 3), ("payload 300", 64, 300, 5),
         ("payload 1024", 64, 1024, 5)]
ok = True
for name, ln, pay, code in cases:
    wr(0x44, 2)                 # CLEAR
    wr(0x50, ln); wr(0x54, pay)
    wr(0x44, 1)                 # GO
    st = rd(0x5C)
    got = (st >> 8) & 0xFF
    sent = rd(0x64), rd(0x68)
    good = (st & 7) == 4 and got == code and sent == (0, 0)
    ok &= good
    print(f"{name:14s} status={st:08x} code={got} bytes,tlps={sent} {'OK' if good else 'FAIL'}")
wr(0x44, 2); wr(0x50, 64); wr(0x54, 128)
print("ALL OK" if ok else "FAILURES")
