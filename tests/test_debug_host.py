"""The host debugger must speak the official Pi debug protocol over the UART.

host/debug/nexttang_debug drives the official pi_debug_control through the
board's UART framing (rtl/debug/nexttang_pi_debug_uart_link.vhd). Here a
pseudo-terminal stands in for the FT232R and a small model of the slave
answers each frame with the byte layout the core simulation checked
(tests/sim/zxnext/tb_zxnext_trace.vhd with PI_DEBUG): which reply byte carries
the answer for each command, and how many bytes a memory read clocks.
"""

from __future__ import annotations

import os
import pty
import sys
import threading
import tty
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "host" / "debug"))

from nexttang_debug.protocol import PiDebug  # noqa: E402
from nexttang_debug.uart import UartLink  # noqa: E402


class SlaveModel:
    """The official slave's replies, by byte position, for whole commands."""

    def __init__(self) -> None:
        self.sram = bytearray(0x200000)
        self.bram = {5: bytearray(0x4000), 7: bytearray(0x2000)}
        self.nextregs = bytearray(256)
        self.nextregs[0] = 0x0A
        self.cpu = bytearray(0x1C)
        self.paused = False

    def reply(self, sent: bytes) -> bytes:
        out = bytearray(len(sent))
        command = sent[0]
        if command == 0xA1:
            out[2], out[3] = 0x10, 0xFF
        elif command == 0xA2:
            out[2] = (0x40 if self.paused else 0x00) | 0x18
        elif command == 0xA4:
            self.paused = True
        elif command == 0xA5:
            self.paused = False
        elif command == 0xA7:
            address = sent[1] << 16 | sent[2] << 8 | sent[3]
            count = max(sent[4] << 8 | sent[5], 1)
            out[7:7 + count] = self.sram[address:address + count]
        elif command == 0xA8:
            address = sent[1] << 16 | sent[2] << 8 | sent[3]
            data = sent[6:]
            self.sram[address:address + len(data)] = data
        elif command == 0xA9:
            address = sent[1] << 8 | sent[2]
            bank, offset = (7, address & 0x1FFF) if address & 0x8000 else (5, address & 0x3FFF)
            count = max(sent[3] << 8 | sent[4], 1)
            out[6:6 + count] = self.bram[bank][offset:offset + count]
        elif command == 0xAA:
            address = sent[1] << 8 | sent[2]
            bank, offset = (7, address & 0x1FFF) if address & 0x8000 else (5, address & 0x3FFF)
            data = sent[5:]
            self.bram[bank][offset:offset + len(data)] = data
        elif command == 0xAB:
            out[3] = self.nextregs[sent[1]]
        elif command == 0xAC:
            self.nextregs[sent[1]] = sent[2]
        elif command == 0xAD:
            out[3] = self.cpu[sent[1]]
        elif command == 0xAE:
            self.cpu[sent[1]] = sent[2]
        return bytes(out)


def board(fd: int, model: SlaveModel, stop: threading.Event) -> None:
    """The board's UART link: X, length, bytes in; 0x01, x, length, replies out."""
    buffer = bytearray()
    os.write(fd, b"status line 0123\r\n")   # left over from before the session
    while not stop.is_set():
        try:
            buffer += os.read(fd, 1024)
        except OSError:
            return
        while len(buffer) >= 2:
            start = buffer.find(b"X")
            if start < 0:
                buffer.clear()
                break
            length = buffer[start + 1] or 256
            if len(buffer) < start + 2 + length:
                break
            sent = bytes(buffer[start + 2:start + 2 + length])
            del buffer[:start + 2 + length]
            os.write(fd, bytes([0x01, ord("x"), length & 0xFF]) + model.reply(sent))


class DebugHostTest(unittest.TestCase):
    def setUp(self) -> None:
        self.master, slave = pty.openpty()
        tty.setraw(self.master)
        self.model = SlaveModel()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=board, args=(self.master, self.model, self.stop), daemon=True)
        self.thread.start()
        self.link = UartLink(os.ttyname(slave))
        os.close(slave)
        self.debug = PiDebug(self.link)

    def tearDown(self) -> None:
        self.stop.set()
        self.link.close()
        os.close(self.master)

    def test_identity_and_status(self) -> None:
        version = self.debug.version()
        self.assertEqual((version.version, version.capabilities), (1, 0xFF))
        self.assertIn("cpu registers", version.names)
        self.assertFalse(self.debug.status().paused)
        self.assertTrue(self.debug.pause().paused)
        self.debug.resume()
        self.assertFalse(self.debug.status().paused)

    def test_main_memory_round_trip_across_frames(self) -> None:
        data = bytes(range(256)) * 3
        self.debug.write_memory(0x41F00, data)
        self.assertEqual(self.debug.read_memory(0x41F00, len(data)), data)
        self.assertEqual(self.model.sram[0x41F00:0x41F00 + len(data)], data)

    def test_bank_ram_and_nextregs(self) -> None:
        self.debug.write_bank_ram(7, 0x1F00, b"\xDE\xAD")
        self.assertEqual(self.debug.read_bank_ram(7, 0x1F00, 2), b"\xDE\xAD")
        self.assertEqual(self.debug.nextreg(0x00), 0x0A)
        self.debug.set_nextreg(0x07, 3)
        self.assertEqual(self.debug.nextreg(0x07), 3)

    def test_registers_by_pair(self) -> None:
        self.debug.set_register("PC", 0x8123)
        self.debug.set_register("IX", 0x5A5B)
        registers = self.debug.registers()
        self.assertEqual(registers["PC"], 0x8123)
        self.assertEqual(registers["IX"], 0x5A5B)


if __name__ == "__main__":
    unittest.main()
