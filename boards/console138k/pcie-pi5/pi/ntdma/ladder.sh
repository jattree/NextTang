#!/bin/sh
# ladder.sh: the DMA test ladder, stopping at the first failure.
cd "$(dirname "$0")"
step() { echo "=== $*"; }
fail() { echo "LADDER STOPPED: $*"; ./aer.sh; exit 1; }
sudo insmod ./ntdma.ko || fail insmod
sudo dmesg | grep ntdma | tail -1
step "1: 64 B";   sudo ./ntdma_test 64 128 0 0x10000000 || fail 64B; ./aer.sh
step "2: 4 KiB";  for p in 128 256 512; do sudo ./ntdma_test 4096 $p 1 0x2000$p || fail 4K-$p; done; ./aer.sh
step "3: 64 KiB"; for p in 128 256 512; do sudo ./ntdma_test 65536 $p 1 0x3000$p 4096 10 || fail 64K-$p; done; ./aer.sh
step "4: 1 MiB";  for p in 128 256 512; do sudo ./ntdma_test 1048576 $p 1 0x4000$p 4096 10 || fail 1M-$p; done; ./aer.sh
step "5: 16 MiB x100"; for p in 128 256 512; do sudo ./ntdma_test 16777216 $p 1 0x5000$p 4096 100 || fail 16M-$p; done; ./aer.sh
step "extra: unaligned start (offset 4100, crosses 4 KiB boundaries mid-payload), odd length"
sudo ./ntdma_test 1000004 512 1 7 4100 10 || fail unaligned; ./aer.sh
step "extra: incrementing pattern 16 MiB"; sudo ./ntdma_test 16777216 512 0 0 4096 10 || fail incr; ./aer.sh
step "extra: hardware refusals"; sudo python3 hw_refusals.py || fail refusals
echo "LADDER PASSED"
