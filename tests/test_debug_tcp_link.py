"""The debug link over the network: UartLink("tcp:HOST:PORT").

A relay that holds the board's serial line (Project Slipstream's linkd) carries
the same byte stream over TCP. The test stands in for relay and board: it
answers each framed command as the board's UART link does (01, 'x', the length,
then one reply byte for each command byte) after some stray status text.
"""

from __future__ import annotations

import socket
import sys
import threading
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "host" / "debug"))

from nexttang_debug.protocol import DebugError  # noqa: E402
from nexttang_debug.uart import UartLink  # noqa: E402


class FakeBoard:
    def __init__(self, answer: bool = True) -> None:
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.answer = answer
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        try:
            client, _ = self.listener.accept()
        except OSError:
            return
        with client:
            client.sendall(b"H 01 status text before any frame\n")
            buffer = b""
            while True:
                more = client.recv(4096)
                if not more:
                    return
                buffer += more
                while len(buffer) >= 2 and buffer[0:1] == b"X":
                    length = buffer[1] or 256
                    if len(buffer) < 2 + length:
                        break
                    command, buffer = buffer[2:2 + length], buffer[2 + length:]
                    if self.answer:
                        client.sendall(bytes([0x01, ord("x"), length & 0xFF]) + bytes(b ^ 0xFF for b in command))

    def close(self) -> None:
        self.listener.close()


class TcpLinkTest(unittest.TestCase):
    def test_commands_are_framed_and_replies_found_after_stray_text(self) -> None:
        board = FakeBoard()
        self.addCleanup(board.close)
        with UartLink(f"tcp:127.0.0.1:{board.port}", timeout=2.0) as link:
            self.assertEqual(link.exchange(b"\xa1\x00\x00"), b"\x5e\xff\xff")
            whole = bytes(range(256))
            self.assertEqual(link.exchange(whole), bytes(b ^ 0xFF for b in whole))

    def test_a_silent_board_times_out(self) -> None:
        board = FakeBoard(answer=False)
        self.addCleanup(board.close)
        with UartLink(f"tcp:127.0.0.1:{board.port}", timeout=0.3) as link:
            with self.assertRaises(DebugError):
                link.exchange(b"\xa1")


if __name__ == "__main__":
    unittest.main()
