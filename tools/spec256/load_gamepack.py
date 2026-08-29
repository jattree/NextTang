#!/usr/bin/env python3
"""Send a validated NextTang Spec256 game pack to the runtime FPGA core."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import select
import sys
import termios
import time

from tools.spec256.gamepack import parse_gamepack


UART_BAUD = 230_400
CHUNK_BYTES = 4096
STATUS_LINE = re.compile(rb"NT V[+!\-] M[+!\-] R[+!\-] C[+!\-] P([+!\-]) Y([+!\-])")


def configure_serial(descriptor: int, baud: int) -> None:
    speed_name = f"B{baud}"
    if not hasattr(termios, speed_name):
        raise RuntimeError(f"this system does not expose termios {speed_name}")
    speed = getattr(termios, speed_name)
    attributes = termios.tcgetattr(descriptor)
    attributes[0] = 0
    attributes[1] = 0
    attributes[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
    attributes[3] = 0
    attributes[4] = speed
    attributes[5] = speed
    attributes[6][termios.VMIN] = 0
    attributes[6][termios.VTIME] = 1
    termios.tcsetattr(descriptor, termios.TCSANOW, attributes)


def send_pack(port: Path, content: bytes, status_timeout: float) -> bytes:
    descriptor = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_serial(descriptor, UART_BAUD)
        termios.tcflush(descriptor, termios.TCIOFLUSH)
        sent = 0
        while sent < len(content):
            _, writable, _ = select.select([], [descriptor], [], 2.0)
            if not writable:
                raise TimeoutError("serial transmitter stopped accepting data")
            written = os.write(descriptor, content[sent : sent + CHUNK_BYTES])
            if written <= 0:
                raise OSError("serial write made no progress")
            sent += written
            if sent == len(content) or sent // 65536 != (sent - written) // 65536:
                print(f"sent {sent}/{len(content)} bytes", file=sys.stderr)
        termios.tcdrain(descriptor)

        termios.tcflush(descriptor, termios.TCIFLUSH)
        deadline = time.monotonic() + status_timeout
        received = bytearray()
        while time.monotonic() < deadline:
            readable, _, _ = select.select([descriptor], [], [], 0.25)
            if not readable:
                continue
            received.extend(os.read(descriptor, 4096))
            for line in received.splitlines():
                match = STATUS_LINE.search(line)
                if not match:
                    continue
                if match.group(2) == b"+":
                    raise RuntimeError(
                        f"FPGA rejected the pack: {line.decode('ascii', 'replace')}"
                    )
                if match.group(1) == b"+":
                    return bytes(line)
            if len(received) > 16384:
                del received[:-4096]
        raise TimeoutError("no accepted-pack status arrived from the FPGA")
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pack", type=Path)
    parser.add_argument("--port", type=Path)
    parser.add_argument("--status-timeout", type=float, default=4.0)
    parser.add_argument("--check-only", action="store_true")
    arguments = parser.parse_args()

    content = arguments.pack.read_bytes()
    pack = parse_gamepack(content)
    print(
        f"valid Spec256 pack: {len(pack.payload)} payload bytes, "
        f"{len(pack.key_indices)} launch key(s)",
        file=sys.stderr,
    )
    if arguments.check_only:
        return 0
    if arguments.port is None:
        parser.error("--port is required unless --check-only is used")
    status = send_pack(arguments.port, content, arguments.status_timeout)
    print(status.decode("ascii", "replace"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
