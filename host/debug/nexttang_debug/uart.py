"""The debug UART link to rtl/debug/nexttang_pi_debug_uart_link.vhd.

A command goes out as the letter X, its length (0 for 256) and its bytes; the
board answers 0x01, x, the same length and the bytes its Pi debug slave
clocked back. Status lines the board was sending before the first frame may
still arrive, so the reader skips everything up to that header. Standard
library only: termios sets the port to raw 8N1.
"""

from __future__ import annotations

import os
import select
import termios
import time

from .protocol import DebugError

BAUD_RATES = {115200: termios.B115200, 230400: termios.B230400, 460800: termios.B460800,
              921600: termios.B921600}


class UartLink:
    def __init__(self, device: str, baud: int = 115200, timeout: float = 1.0) -> None:
        self.timeout = timeout
        self.fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        attributes = termios.tcgetattr(self.fd)
        attributes[0] = 0                                   # iflag
        attributes[1] = 0                                   # oflag
        attributes[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attributes[3] = 0                                   # lflag
        attributes[4] = attributes[5] = BAUD_RATES[baud]
        termios.tcsetattr(self.fd, termios.TCSANOW, attributes)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.pending = bytearray()

    def close(self) -> None:
        os.close(self.fd)

    def __enter__(self) -> "UartLink":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _read_some(self, deadline: float) -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise DebugError("no reply from the board (is the debugger core loaded?)")
        ready, _, _ = select.select([self.fd], [], [], remaining)
        if ready:
            self.pending += os.read(self.fd, 4096)

    def write(self, data: bytes) -> None:
        view = memoryview(data)
        deadline = time.monotonic() + self.timeout
        while view:
            try:
                view = view[os.write(self.fd, view):]
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise DebugError("the debug UART would not take the frame")
                select.select([], [self.fd], [], 0.05)

    def read_reply(self, header: bytes, length: int) -> bytes:
        """The bytes after the next header, skipping status text before it."""
        deadline = time.monotonic() + self.timeout
        while True:
            at = self.pending.find(header)
            if at >= 0 and len(self.pending) >= at + len(header) + length:
                start = at + len(header)
                reply = bytes(self.pending[start:start + length])
                del self.pending[:start + length]
                return reply
            self._read_some(deadline)

    def exchange(self, sent: bytes) -> bytes:
        if not 1 <= len(sent) <= 256:
            raise ValueError("a command is 1 to 256 bytes")
        length = len(sent) & 0xFF
        self.pending.clear()
        termios.tcflush(self.fd, termios.TCIFLUSH)
        os.write(self.fd, b"X" + bytes([length]) + sent)
        deadline = time.monotonic() + self.timeout
        header = bytes([0x01, ord("x"), length])
        while True:
            at = self.pending.find(header)
            if at >= 0 and len(self.pending) >= at + 3 + len(sent):
                reply = bytes(self.pending[at + 3:at + 3 + len(sent)])
                del self.pending[:at + 3 + len(sent)]
                return reply
            self._read_some(deadline)
