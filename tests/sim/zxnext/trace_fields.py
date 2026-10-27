#!/usr/bin/env python3
"""Decode the change log written by tb_zxnext_trace.vhd.

Each line is a 28 MHz cycle number and the observed outputs as one hex word,
most significant field first, in the order the testbench concatenates them.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Name and width of each field, most significant first. Must match the
# concatenation in tb_zxnext_trace.vhd.
FIELDS = (
    ("ram_a_addr", 21), ("ram_a_req", 1), ("ram_a_req2", 1), ("ram_a_rd_n", 1), ("ram_a_do", 8),
    ("ram_b_addr", 21),
    ("rgb", 9), ("vs_n", 1), ("hs_n", 1), ("vb_n", 1), ("hb_n", 1), ("hdmi_pixel", 1), ("hdmi_lock", 1),
    ("spi_sd0_n", 1), ("spi_sck", 1), ("spi_mosi", 1), ("kbd_row", 8),
    ("audio_l", 13), ("audio_r", 13),
    ("cpu_speed", 2), ("cpu_contend", 1), ("cpu_lsb", 1),
    ("bus_addr", 16), ("bus_do", 8), ("bus_mreq_n", 1), ("bus_iorq_n", 1), ("bus_rd_n", 1), ("bus_wr_n", 1),
    ("bus_m1_n", 1), ("bus_rfsh_n", 1), ("bus_halt_n", 1), ("uart_tx", 1),
)
WIDTH = sum(width for _, width in FIELDS)


def decode(word: str) -> dict[str, int | None]:
    """Field values from one hex word; None where any bit is not 0 or 1."""
    bits = "".join(format(int(c, 16), "04b") if c in "0123456789ABCDEFabcdef" else "xxxx" for c in word)
    bits = bits[len(bits) - WIDTH:]
    values: dict[str, int | None] = {}
    position = 0
    for name, width in FIELDS:
        chunk = bits[position:position + width]
        values[name] = None if "x" in chunk else int(chunk, 2)
        position += width
    return values


def read(path: Path):
    """(cycle, fields) for every line of a trace."""
    with path.open() as trace:
        for line in trace:
            cycle, word = line.split()
            yield int(cycle), decode(word)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("trace", type=Path)
    parser.add_argument("--writes", action="store_true", help="list CPU memory and I/O writes")
    args = parser.parse_args()

    previous_wr = 1
    speeds = {}
    for cycle, fields in read(args.trace):
        speed = fields["cpu_speed"]
        if speed is not None and speed not in speeds:
            speeds[speed] = cycle
        wr = fields["bus_wr_n"]
        if args.writes and wr == 0 and previous_wr == 1:
            kind = "io " if fields["bus_iorq_n"] == 0 else "mem"
            print(f"{cycle:9d} {kind} {fields['bus_addr']:04x} <- {fields['bus_do']:02x}"
                  if fields["bus_addr"] is not None and fields["bus_do"] is not None
                  else f"{cycle:9d} {kind} undefined")
        if wr is not None:
            previous_wr = wr
    print("first cycle at each CPU speed:", {k: v for k, v in sorted(speeds.items())}, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
