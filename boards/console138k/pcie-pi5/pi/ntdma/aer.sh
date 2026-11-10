#!/bin/sh
# aer.sh: AER status of the root port and the endpoint, plus kernel AER lines.
for d in 0001:00:00.0 0001:01:00.0; do
  echo "$d: $(sudo lspci -vv -s $d | grep -E 'UESta|CESta' | tr -s '\t ' ' ' | tr '\n' ' ')"
done
echo "dmesg AER lines: $(sudo dmesg | grep -c -i -E 'aer|error' )"
sudo dmesg | grep -i -E "aer|pcie bus error|ntdma" | tail -5
