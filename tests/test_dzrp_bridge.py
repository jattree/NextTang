"""Check DZRP bytes over TCP, plus commands and framing when sockets are forbidden."""

from __future__ import annotations

import select
import socket
import struct
import sys
import threading
import time
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "host" / "debug"))

from nexttang_debug.dzrp import Breakpoints, DzrpBridge, DzrpServer  # noqa: E402
from nexttang_debug.protocol import DebugError, PAIRS, Status  # noqa: E402


@dataclass
class FakePiDebug:
    """SRAM and MMU are separate, just as in the real Pi debug API."""

    sram: bytearray = field(default_factory=lambda: bytearray(0x200000))
    bram: dict[int, bytearray] = field(default_factory=lambda: {5: bytearray(0x4000), 7: bytearray(0x2000)})
    nextregs: bytearray = field(default_factory=lambda: bytearray(256))
    regs: dict[str, int] = field(default_factory=lambda: {
        "PC": 0x8123, "SP": 0xFEDC, "AF": 0x1234, "BC": 0x5678,
        "DE": 0x9ABC, "HL": 0xDEF0, "IX": 0x1357, "IY": 0x2468,
        "AF'": 0xA1B2, "BC'": 0xC3D4, "DE'": 0xE5F6, "HL'": 0x0718,
        "R": 0x92, "I": 0xAB, "IM": 2, "IFF1": 1, "IFF2": 1, "HALT": 0,
    })
    paused: bool = False
    slots: dict[int, int] = field(default_factory=dict)
    pages: dict[int, int] = field(default_factory=dict)
    frames: list[bytes] = field(default_factory=list)
    reads: list[tuple[int, int]] = field(default_factory=list)
    writes: list[tuple[int, bytes]] = field(default_factory=list)
    reply: bytes = b""
    status_calls: int = 0
    lock: threading.RLock = field(default_factory=threading.RLock)

    def __post_init__(self) -> None:
        self.nextregs[0x50:0x58] = bytes([0, 1, 12, 29, 4, 5, 6, 7])

    def status(self) -> Status:
        with self.lock:
            self.status_calls += 1
            return Status((0x40 if self.paused else 0) | 0x18, 0)

    def pause(self, timeout: float = 1.0) -> Status:
        with self.lock:
            self.paused = True
            return self.status()

    def resume(self) -> None:
        with self.lock:
            self.paused = False

    def step(self, timeout: float = 1.0) -> Status:
        with self.lock:
            self.regs["PC"] = (self.regs["PC"] + 1) & 0xFFFF
            return self.pause(timeout)

    def registers(self) -> dict[str, int]:
        with self.lock:
            assert self.paused, "register reads require the official PAUSE"
            return self.regs.copy()

    def set_register(self, name: str, value: int) -> None:
        assert self.paused
        if name in PAIRS:
            self.regs[name] = value & 0xFFFF
        elif name in {"I", "R"}:
            self.regs[name] = value & 0xFF
        else:
            for pair, (high, low) in PAIRS.items():
                if name == high:
                    self.regs[pair] = (value & 0xFF) << 8 | (self.regs[pair] & 0xFF)
                    return
                if name == low:
                    self.regs[pair] = (self.regs[pair] & 0xFF00) | (value & 0xFF)
                    return
            raise DebugError(f"no register {name}")

    def nextreg(self, register: int) -> int:
        return self.nextregs[register]

    def set_nextreg(self, register: int, value: int) -> None:
        self.nextregs[register] = value

    def read_memory(self, address: int, length: int) -> bytes:
        assert 0 <= address <= address + length <= len(self.sram)
        self.reads.append((address, length))
        return bytes(self.sram[address:address + length])

    def write_memory(self, address: int, data: bytes) -> None:
        assert 0 <= address <= address + len(data) <= len(self.sram)
        self.writes.append((address, data))
        self.sram[address:address + len(data)] = data

    def read_bank_ram(self, bank: int, offset: int, length: int) -> bytes:
        assert self.paused and 0 <= offset <= offset + length <= len(self.bram[bank])
        return bytes(self.bram[bank][offset:offset + length])

    def write_bank_ram(self, bank: int, offset: int, data: bytes) -> None:
        assert self.paused and 0 <= offset <= offset + len(data) <= len(self.bram[bank])
        self.bram[bank][offset:offset + len(data)] = data

    def write(self, data: bytes) -> None:
        """Model the new board frame independently of Breakpoints' encoder."""
        with self.lock:
            assert len(data) == 6 and data[0] == ord("B")
            slot, flags, high, low, page = data[1:]
            assert slot < 10 and flags in (0, 1, 3)
            self.frames.append(data)
            self.pages.pop(slot, None)
            if flags & 1:
                self.slots[slot] = high * 256 + low
                if flags & 2:
                    self.pages[slot] = page
            else:
                self.slots.pop(slot, None)
            self.reply = bytes([1, ord("b"), slot])

    def read_reply(self, header: bytes, length: int) -> bytes:
        assert self.reply.startswith(header)
        assert len(self.reply) == len(header) + length
        result = self.reply[len(header):]
        self.reply = b""
        return result

    def run_to(self, address: int) -> None:
        """Stop before executing the target instruction, including its PC value."""
        with self.lock:
            assert not self.paused
            self.regs["PC"] = address
            page = self.nextregs[0x50 + (address >> 13)]
            if any(target == address and (slot not in self.pages or self.pages[slot] == page)
                   for slot, target in self.slots.items()):
                self.paused = True


def command_frame(sequence: int, command: int, data: bytes = b"") -> bytes:
    # Request length excludes BOTH sequence and command; response length does not.
    return struct.pack("<I", len(data)) + bytes([sequence, command]) + data


def continue_payload(first: int | None = None, second: int | None = None) -> bytes:
    return struct.pack("<BHBHBHH", int(first is not None), first or 0,
                       int(second is not None), second or 0, 0, 0, 0)


class DzrpBridgeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.model = FakePiDebug()
        self.bridge = DzrpBridge(self.model, Breakpoints(self.model))
        try:
            self.server = DzrpServer(self.bridge, port=0, poll_interval=0.01)
        except PermissionError as error:
            self.skipTest(f"localhost TCP sockets unavailable: {error}")
        self.failures: list[BaseException] = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.client = socket.create_connection(self.server.address, timeout=1)
        self.client.settimeout(1)
        self.sequence = 0

    def serve(self) -> None:
        try:
            self.server.serve_forever()
        except BaseException as error:
            self.failures.append(error)

    def tearDown(self) -> None:
        self.client.close()
        self.server.shutdown()
        self.thread.join(2)
        self.server.close()
        self.assertFalse(self.thread.is_alive(), "server failed to shut down")
        self.assertEqual(self.failures, [])

    def read_exact(self, count: int) -> bytes:
        result = bytearray()
        while len(result) < count:
            chunk = self.client.recv(count - len(result))
            if not chunk:
                self.fail("unexpected connection close")
            result += chunk
        return bytes(result)

    def receive(self) -> bytes:
        length = int.from_bytes(self.read_exact(4), "little")
        self.assertGreaterEqual(length, 1)
        self.assertLessEqual(length, 0x100000)
        return self.read_exact(length)

    def request(self, command: int, data: bytes = b"") -> bytes:
        self.sequence = self.sequence % 255 + 1
        self.client.sendall(command_frame(self.sequence, command, data))
        response = self.receive()
        self.assertEqual(response[0], self.sequence)
        return response[1:]

    def initialize(self, minor: int = 2) -> None:
        response = self.request(1, bytes([2, minor, 0]) + b"DeZog test\0")
        self.assertEqual(response, b"\0\x02\x02\0\x04NextTang DZRP 2.2.0\0")

    def add_breakpoint(self, address: int, bank: int = 0, condition: bytes = b"") -> int:
        response = self.request(40, struct.pack("<HB", address, bank) + condition + b"\0")
        self.assertEqual(len(response), 2)
        return int.from_bytes(response, "little")

    def assert_quiet(self) -> None:
        ready, _, _ = select.select([self.client], [], [], 0.06)
        self.assertEqual(ready, [], "duplicate or unsolicited notification")

    def reconnect(self) -> None:
        self.client.close()
        self.client = socket.create_connection(self.server.address, timeout=1)
        self.client.settimeout(1)
        self.sequence = 0

    def test_init_supported_commands_and_sequence_rollover(self) -> None:
        self.initialize()
        self.assertTrue(self.model.paused)
        self.assertEqual(self.model.frames, [b"B" + bytes([slot, 0, 0, 0, 0]) for slot in range(10)])
        bitmap = self.request(24)
        supported = {bit for bit in range(8 * len(bitmap)) if bitmap[bit // 8] & (1 << (bit % 8))}
        self.assertEqual(supported, {1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 15, 24, 25, 26, 27, 28, 40, 41})
        for _ in range(270):
            self.assertEqual(self.request(15, b"\0\xFF\x01hello"), b"\0\xFF\x01hello")
        self.assertEqual(self.sequence, 17)  # INIT + bitmap + 270 echoes, wrapping at 255.
        self.assert_quiet()

    def test_incompatible_init_reports_error_without_touching_cpu(self) -> None:
        self.assertEqual(self.request(1, b"\x03\0\0new client\0")[:5], b"\x01\x02\x02\0\x04")
        self.assertEqual(self.client.recv(1), b"")
        self.assertFalse(self.model.paused)
        self.assertEqual(self.model.frames, [])
        self.reconnect()
        self.initialize()

    def test_register_wire_layout_including_slots(self) -> None:
        self.initialize()
        payload = self.request(3)
        self.assertEqual(len(payload), 37)  # 38 including sequence.
        self.assertEqual(payload[:24], bytes.fromhex(
            "2381 dcfe 3412 7856 bc9a f0de 5713 6824 b2a1 d4c3 f6e5 1807"))
        self.assertEqual(payload[24:], bytes([0x92, 0xAB, 2, 0, 8, 0, 1, 12, 29, 4, 5, 6, 7]))

    def test_register_writes_use_dzrp_numbers_and_low_byte(self) -> None:
        self.initialize()
        for number, value in ((0, 0x1234), (8, 0x5678), (15, 0xABCD), (22, 0xEF), (34, 0x129A), (35, 0x67)):
            self.assertEqual(self.request(4, struct.pack("<BH", number, value)), b"")
        regs = self.model.registers()
        self.assertEqual((regs["PC"], regs["AF'"], regs["AF"], regs["IX"], regs["R"], regs["I"]),
                         (0x1234, 0x5678, 0xCD34, 0x13EF, 0x9A, 0x67))

    def test_read_blocks_crosses_mmu_boundary_and_preserves_block_order(self) -> None:
        self.initialize()
        first = 0x40000 + 12 * 0x2000 + 0x1FFE
        second = 0x40000 + 29 * 0x2000
        self.model.sram[first:first + 2] = b"ab"
        self.model.sram[second:second + 3] = b"cde"
        payload = struct.pack("<IHHHH", 8, 0x5FFE, 5, 0x6001, 2)
        self.assertEqual(self.request(28, payload), b"abcde" + b"de")
        self.assertEqual(self.model.reads, [(first, 2), (second, 3), (second + 1, 2)])

    def test_read_wraps_64k_and_rom_reads_are_ff(self) -> None:
        self.initialize()
        self.model.nextregs[0x50] = 0xFF
        last = 0x40000 + 7 * 0x2000 + 0x1FFE
        self.model.sram[last:last + 2] = b"xy"
        self.assertEqual(self.request(28, struct.pack("<IHH", 6, 0xFFFE, 5)), b"xy\xFF\xFF\xFF")
        self.assertEqual(self.model.reads, [(last, 2)])
        self.assertEqual(self.request(25, struct.pack("<BHH", 0xFF, 0, 4)), b"\xFF" * 4)

    def test_write_crosses_mmu_boundary_and_wraps_64k(self) -> None:
        self.initialize()
        self.assertEqual(self.request(9, b"\0\xFE\x5Fabcde"), b"")
        self.assertEqual(self.model.writes, [(0x40000 + 12 * 0x2000 + 0x1FFE, b"ab"),
                                           (0x40000 + 29 * 0x2000, b"cde")])
        self.request(9, b"\0\xFF\xFFxy")
        self.assertEqual(self.model.writes[-2:], [(0x40000 + 7 * 0x2000 + 0x1FFF, b"x"), (0x40000, b"y")])

    def test_bank_memory_and_nextregs(self) -> None:
        self.initialize()
        self.request(26, struct.pack("<BH", 223, 0x1FFD) + b"ram")
        self.assertEqual(self.model.sram[-3:], b"ram")
        self.assertEqual(self.request(25, struct.pack("<BHH", 223, 0x1FFD, 3)), b"ram")
        self.assertEqual(self.request(10, bytes([2, 223])), b"\0")
        self.assertEqual(self.request(11, b"\x52"), b"\xDF")
        self.assertEqual(self.request(10, bytes([8, 0])), b"\x01")
        self.assertEqual(self.request(10, bytes([0, 254])), b"\0")
        self.assertEqual(self.request(11, b"\x50"), b"\xFF")
        self.request(27, bytes([7, 3, 0x52, 29, 7, 1]))
        self.assertEqual(self.request(11, b"\x07"), b"\x01")
        self.assertEqual(self.request(11, b"\x52"), b"\x1D")

    def test_bram_pages_use_the_official_bank_ram_commands(self) -> None:
        self.initialize()
        self.model.nextregs[0x52:0x54] = bytes([10, 11])
        self.request(9, b"\0\xFF\x5Fab")
        self.assertEqual(self.model.bram[5][0x1FFF:0x2001], b"ab")
        self.assertEqual(self.request(28, struct.pack("<IHH", 3, 0x5FFF, 2)), b"ab")
        self.request(26, struct.pack("<BH", 14, 0x100) + b"video")
        self.assertEqual(self.model.bram[7][0x100:0x105], b"video")
        self.assertEqual(self.request(25, struct.pack("<BHH", 14, 0x100, 5)), b"video")
        self.assertEqual(self.model.writes, [])
        self.assertEqual(self.model.reads, [])

    def test_add_remove_and_capacity_reserves_two_temporary_slots(self) -> None:
        self.initialize()
        ids = [self.add_breakpoint(0x8000 + i, bank=42) for i in range(8)]
        self.assertEqual(ids, list(range(1, 9)))
        self.assertEqual(self.add_breakpoint(0x9000), 0)
        self.assertEqual(self.model.frames[-8:], [b"B" + bytes([i, 3, 0x80, i, 41]) for i in range(8)])
        self.assertEqual(self.request(41, struct.pack("<H", 4)), b"")
        self.assertNotIn(3, self.model.slots)
        self.assertEqual(self.model.frames[-1], b"B\x03\0\0\0\0")
        self.assertEqual(self.add_breakpoint(0x9000), 9)  # New ID, reused hardware slot 3.
        self.assertEqual(self.request(40, b"\0\x90\0A==1\0"), b"\0\0")
        self.request(6, continue_payload(0xA000, 0xB000))
        self.assertEqual(self.model.slots[8], 0xA000)
        self.assertEqual(self.model.slots[9], 0xB000)
        self.request(41, struct.pack("<H", 9))  # ID 9 removes user slot 3, not temp slot 8.
        self.assertNotIn(3, self.model.slots)
        self.assertEqual(self.model.slots[8], 0xA000)

    def test_continue_user_breakpoint_sends_one_notification_and_clears_temporaries(self) -> None:
        self.initialize()
        self.add_breakpoint(0x8123)
        self.assertEqual(self.request(6, continue_payload(0x9000, 0xA000)), b"")
        self.assertFalse(self.model.paused)
        self.model.run_to(0x8123)
        self.assertEqual(self.receive(), b"\0\x01\x02\x23\x81\x05\0")
        self.assertEqual(self.model.slots, {0: 0x8123})
        self.assertEqual(self.request(3)[:2], b"\x23\x81")
        self.assert_quiet()

    def test_temporary_breakpoint_at_zero_and_second_temporary_breakpoint(self) -> None:
        self.initialize()
        for target, bank in ((0, 1), (0xA234, 6)):
            self.request(6, continue_payload(0, 0xA234))
            self.model.run_to(target)
            self.assertEqual(self.receive(), b"\0\x01\0" + struct.pack("<HB", target, bank) + b"\0")
            self.assertEqual(self.model.slots, {})

    def test_manual_pause_acknowledges_before_notification_even_at_breakpoint_pc(self) -> None:
        self.initialize()
        self.add_breakpoint(0x8123)
        self.request(6, continue_payload(0x9000))
        self.assertEqual(self.request(7), b"")
        self.assertEqual(self.receive(), b"\0\x01\x01\x23\x81\x05\0")
        self.assertTrue(self.model.paused)
        self.assertEqual(self.model.slots, {0: 0x8123})
        self.assertEqual(self.request(7), b"")  # Already paused: ACK only.
        self.assert_quiet()

    def test_external_pause_without_matching_pc_is_manual(self) -> None:
        self.initialize()
        self.request(6, continue_payload())
        self.model.pause()
        self.assertEqual(self.receive(), b"\0\x01\x01\x23\x81\x05\0")

    def test_fragmented_and_coalesced_commands(self) -> None:
        init = command_frame(1, 1, b"\x02\x02\0DeZog\0")
        for byte in init[:7]:
            self.client.sendall(bytes([byte]))
        self.client.sendall(init[7:] + command_frame(2, 15, b"hello") + command_frame(3, 24))
        self.assertEqual(self.receive()[:6], b"\x01\0\x02\x02\0\x04")
        self.assertEqual(self.receive(), b"\x02hello")
        self.assertEqual(self.receive()[0], 3)

    def test_incomplete_command_does_not_block_status_polling(self) -> None:
        self.initialize()
        self.add_breakpoint(0x9234)
        self.request(6, continue_payload())
        packet = command_frame(15, 15, b"split")
        self.client.sendall(packet[:7])
        self.model.run_to(0x9234)
        self.assertEqual(self.receive(), b"\0\x01\x02\x34\x92\x05\0")
        self.client.sendall(packet[7:])
        self.assertEqual(self.receive(), b"\x0Fsplit")

    def test_close_clears_breakpoints_resumes_and_allows_reconnect(self) -> None:
        self.initialize()
        self.add_breakpoint(0x9234)
        self.assertEqual(self.request(2), b"")
        # CLOSE ends the session but not the connection (JNext; conformance C15).
        self.assertEqual(self.model.slots, {})
        self.assertFalse(self.model.paused)
        self.initialize()
        self.assertEqual(self.add_breakpoint(0x1234), 1)
        self.reconnect()
        self.initialize()
        self.assertEqual(self.add_breakpoint(0x5678), 1)  # ids are per session (JNext 3.1)

    def test_abrupt_disconnect_resumes_and_cleans_up(self) -> None:
        self.initialize()
        self.add_breakpoint(0x9234)
        self.request(6, continue_payload(0xA000, 0xB000))
        self.client.shutdown(socket.SHUT_RDWR)
        self.client.close()
        deadline = time.monotonic() + 1
        while self.bridge.initialized and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertFalse(self.bridge.initialized)
        self.assertEqual(self.model.slots, {})
        self.assertFalse(self.model.paused)
        self.assertEqual(self.model.pages, {})
        self.assertEqual(self.bridge.ids, {})
        self.reconnect()
        self.initialize()

    def test_second_client_is_rejected_without_disrupting_first(self) -> None:
        self.initialize()
        with socket.create_connection(self.server.address, timeout=1) as other:
            other.settimeout(1)
            self.assertEqual(other.recv(1), b"")
        self.assertEqual(self.request(15, b"still here"), b"still here")

    def test_malformed_frame_closes_only_that_session(self) -> None:
        self.initialize()
        with self.assertLogs("nexttang_debug.dzrp", level="WARNING"):
            self.client.sendall(struct.pack("<IBB", 0xFFFFFFFF, 1, 15))
            self.assertEqual(self.client.recv(1), b"")
        self.assertFalse(self.model.paused)
        self.reconnect()
        self.initialize()

    def test_unwritable_im_warns_and_replies_without_disconnect(self) -> None:
        self.initialize()
        with self.assertLogs("nexttang_debug.dzrp", level="WARNING") as logs:
            self.assertEqual(self.request(4, struct.pack("<BH", 13, 1)), b"")
        self.assertIn("cannot set DZRP register 13", logs.output[0])
        self.assertEqual(self.model.regs["IM"], 2)
        self.assertEqual(self.request(15, b"still here"), b"still here")

    def test_rom_write_rejected_before_partial_ram_write(self) -> None:
        self.initialize()
        self.model.nextregs[0x53] = 0xFF
        with self.assertLogs("nexttang_debug.dzrp", level="WARNING"):
            self.assertEqual(self.request(9, b"\0\xFF\x5Fab"), b"")
        self.assertEqual(self.model.writes, [])
        self.assertEqual(self.request(15, b"still here"), b"still here")


class ServerFramesTest(unittest.TestCase):
    """Run the real frame parser without OS sockets; TCP tests above remain separate."""

    def setUp(self) -> None:
        self.model = FakePiDebug()
        self.bridge = DzrpBridge(self.model, Breakpoints(self.model))
        # Only listener construction is bypassed. _serve_client and _send are real.
        self.server = DzrpServer.__new__(DzrpServer)
        self.server.bridge = self.bridge
        self.server.listener = object()
        self.server.poll_interval = 0.01
        self.server.stop = threading.Event()

    def serve_frames(self, chunks: list[bytes]) -> list[bytes]:
        class Client:
            def __init__(self) -> None:
                self.chunks = iter(chunks)
                self.sent = bytearray()

            def settimeout(self, timeout: float) -> None:
                pass

            def recv(self, count: int) -> bytes:
                chunk = next(self.chunks, b"")
                assert len(chunk) <= count
                return chunk

            def sendall(self, data: bytes) -> None:
                self.sent.extend(data)

        client = Client()

        def ready(readers, writers, errors, timeout):
            # The listener never accepts another client; queued input is always ready.
            return ([client] if client in readers else []), [], []

        with patch("nexttang_debug.dzrp.select.select", side_effect=ready):
            self.server._serve_client(client)
        replies = []
        pending = bytes(client.sent)
        while pending:
            self.assertGreaterEqual(len(pending), 4)
            length = int.from_bytes(pending[:4], "little")
            self.assertGreaterEqual(length, 1)
            self.assertGreaterEqual(len(pending), 4 + length)
            replies.append(pending[4:4 + length])
            pending = pending[4 + length:]
        return replies

    def test_all_nonzero_sequences_and_255_to_1_wrap(self) -> None:
        for minor in (0, 1, 2):
            with self.subTest(minor=minor):
                chunks = [command_frame(1, 1, bytes([2, minor, 0]) + b"test\0")]
                sequences = list(range(2, 256)) + [1, 2]
                chunks.extend(command_frame(sequence, 15, b"echo") for sequence in sequences)
                replies = self.serve_frames(chunks)
                self.assertEqual(replies[0], b"\x01\0\x02\x02\0\x04NextTang DZRP 2.2.0\0")
                self.assertEqual(replies[1:], [bytes([sequence]) + b"echo" for sequence in sequences])

    def test_sequence_zero_is_rejected_even_after_init(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid DZRP frame length or sequence"):
            self.serve_frames([command_frame(1, 1, b"\x02\x02\0test\0"), command_frame(0, 15, b"bad")])

    def test_command_before_init_gets_a_sequence_only_reply(self) -> None:
        # As after CLOSE: logged and answered, the connection stays in sync.
        with self.assertLogs("nexttang_debug.dzrp", level="WARNING"):
            replies = self.serve_frames([command_frame(1, 15, b"early"), command_frame(2, 1, b"\x02\x02\0test\0")])
        self.assertEqual(replies[0], bytes([1]))
        self.assertTrue(self.bridge.initialized)   # the INIT after it was served

    def test_unsupported_commands_reply_sequence_only_warn_and_stay_in_sync(self) -> None:
        stream = command_frame(1, 1, b"\x02\x02\0test\0")
        expected = []
        commands = (12, 13, 14, 22, 99, 255)
        for index, command in enumerate(commands):
            sequence = 2 + index * 2
            # A payload resembling a command must be consumed as payload, not dispatched.
            stream += command_frame(sequence, command, command_frame(200, 2))
            stream += command_frame(sequence + 1, 15, b"alive")
            expected.extend((bytes([sequence]), bytes([sequence + 1]) + b"alive"))
        with self.assertLogs("nexttang_debug.dzrp", level="WARNING") as logs:
            replies = self.serve_frames([stream])
        self.assertEqual(replies[1:], expected)
        self.assertEqual(len(logs.output), len(commands))
        for command, message in zip(commands, logs.output):
            self.assertIn(f"unsupported DZRP command {command}", message)
        self.assertTrue(self.bridge.initialized)
        self.assertTrue(self.model.paused)
        self.assertEqual(self.model.writes, [])

    def test_value_errors_and_debug_errors_reply_sequence_only_and_keep_session(self) -> None:
        stream = command_frame(1, 1, b"\x02\x02\0test\0")
        invalid = ((3, b"extra"), (4, b"\0"), (27, b"\x50"),
                   (1, b"\x02\x02\0unterminated"),
                   (4, struct.pack("<BH", 13, 1)), (26, b"\xFF\0\0rom"))
        expected = []
        for index, (command, payload) in enumerate(invalid):
            sequence = 2 + index * 2
            stream += command_frame(sequence, command, payload) + command_frame(sequence + 1, 15, b"alive")
            expected.extend((bytes([sequence]), bytes([sequence + 1]) + b"alive"))
        with self.assertLogs("nexttang_debug.dzrp", level="WARNING") as logs:
            replies = self.serve_frames([stream])
        self.assertEqual(replies[1:], expected)
        self.assertEqual(len(logs.output), len(invalid))
        for (command, _), message in zip(invalid, logs.output):
            self.assertIn(f"DZRP command {command}:", message)
        self.assertTrue(self.bridge.initialized)
        self.assertTrue(self.model.paused)
        self.assertEqual(self.model.regs["IM"], 2)
        self.assertEqual(self.model.nextregs[0x50], 0)
        self.assertEqual(self.model.writes, [])

    def test_backend_debug_error_warns_and_connection_remains_usable(self) -> None:
        chunks = [command_frame(1, 1, b"\x02\x02\0test\0"),
                  command_frame(2, 11, b"\x50"), command_frame(3, 11, b"\x50")]
        with patch.object(self.model, "nextreg", side_effect=[DebugError("UART timeout"), 12]):
            with self.assertLogs("nexttang_debug.dzrp", level="WARNING") as logs:
                replies = self.serve_frames(chunks)
        self.assertEqual(replies[1:], [b"\x02", b"\x03\x0C"])
        self.assertIn("DZRP command 11: UART timeout", logs.output[0])

    def test_fragmented_repeated_init_and_pause_reply_precedes_notification(self) -> None:
        stream = command_frame(1, 1, b"\x02\0\0legacy\0")
        stream += command_frame(2, 1, b"\x02\xFF\0newer\0")
        stream += command_frame(3, 6, continue_payload(0x9000))
        stream += command_frame(4, 7) + command_frame(5, 7) + command_frame(6, 15, b"done")
        replies = self.serve_frames([bytes([byte]) for byte in stream[:9]] + [stream[9:]])
        self.assertEqual(replies[:2], [bytes([seq]) + b"\0\x02\x02\0\x04NextTang DZRP 2.2.0\0"
                                      for seq in (1, 2)])
        self.assertEqual(replies[2:], [b"\x03", b"\x04", b"\0\x01\x01\x23\x81\x05\0",
                                      b"\x05", b"\x06done"])
        self.assertFalse(self.bridge.legacy)
        self.assertEqual(self.model.slots, {})


class BreakpointsTest(unittest.TestCase):
    def test_raw_uart_encoding_and_acknowledgement(self) -> None:
        model = FakePiDebug()
        breakpoints = Breakpoints(model)
        breakpoints.set(9, 0xABCD)
        self.assertEqual(model.frames[-1], b"B\x09\x01\xAB\xCD\0")
        self.assertEqual(model.slots, {9: 0xABCD})
        breakpoints.clear(9)
        self.assertEqual(model.frames[-1], b"B\x09\0\0\0\0")
        self.assertEqual(model.slots, {})
        for slot, address in ((-1, 0), (10, 0), (0, -1), (0, 0x10000)):
            with self.assertRaises(ValueError):
                breakpoints.set(slot, address)

    def test_page_qualified_frames_include_page_zero_and_clear_qualification(self) -> None:
        model = FakePiDebug()
        breakpoints = Breakpoints(model)
        for page in (0, 41, 254):
            with self.subTest(page=page):
                breakpoints.set(2, 0xABCD, page=page)
                self.assertEqual(model.frames[-1], b"B\x02\x03\xAB\xCD" + bytes([page]))
                self.assertEqual(model.pages, {2: page})
        breakpoints.set(2, 0xABCD)
        self.assertEqual(model.frames[-1], b"B\x02\x01\xAB\xCD\0")
        self.assertEqual(model.pages, {})
        breakpoints.set(2, 0xABCD, page=0)
        breakpoints.clear(2)
        self.assertEqual(model.frames[-1], b"B\x02\0\0\0\0")
        self.assertEqual(model.slots, {})
        self.assertEqual(model.pages, {})

    def test_wrong_slot_reply_is_an_error(self) -> None:
        class WrongReply(FakePiDebug):
            def read_reply(self, header: bytes, length: int) -> bytes:
                return b"\x09"

        with self.assertRaises(DebugError):
            Breakpoints(WrongReply()).set(0, 0x1234)


class BridgeCommandsTest(unittest.TestCase):
    """Check backend side effects even where the test runner forbids TCP sockets."""

    def setUp(self) -> None:
        self.model = FakePiDebug()
        self.bridge = DzrpBridge(self.model, Breakpoints(self.model))
        self.bridge.command(1, b"\x02\x02\0test\0")

    def test_repeated_init_accepts_any_minor_and_clears_running_session(self) -> None:
        for minor in (0, 1, 2, 3, 255):
            with self.subTest(minor=minor):
                self.bridge.command(40, b"\x23\x81\x05\0")
                self.bridge.command(6, continue_payload(0x9000, 0xA000))
                reply = self.bridge.command(1, bytes([2, minor, 255]) + b"client\0")
                self.assertEqual(reply.payload, b"\0\x02\x02\0\x04NextTang DZRP 2.2.0\0")
                self.assertFalse(reply.close)
                self.assertIsNone(reply.notification)
                self.assertTrue(self.bridge.initialized)
                self.assertEqual(self.bridge.legacy, minor < 2)
                self.assertTrue(self.model.paused)
                self.assertFalse(self.bridge.running)
                self.assertEqual(self.model.slots, {})
                self.assertEqual(self.model.pages, {})
                self.assertEqual(self.bridge.active, {})
                self.assertEqual(self.bridge.pages, {})
                self.assertEqual(self.bridge.ids, {})
                self.assertEqual(self.model.frames[-10:],
                                 [b"B" + bytes([slot, 0, 0, 0, 0]) for slot in range(10)])
                self.assertIsNone(self.bridge.poll())

    def test_legacy_read_mem_uses_live_mmu_wrap_and_zero_size(self) -> None:
        self.model.sram[0x59FFE:0x5A000] = b"ab"
        self.model.sram[0x7A000:0x7A003] = b"cde"
        self.model.sram[0x4FFFE:0x50000] = b"xy"
        self.model.nextregs[0x50] = 0xFF
        for minor in (0, 1):
            with self.subTest(minor=minor):
                self.bridge.command(1, bytes([2, minor, 0]) + b"legacy\0")
                self.assertEqual(self.bridge.command(8, struct.pack("<BHH", 0, 0x5FFE, 5)).payload,
                                 b"abcde")
                self.assertEqual(self.bridge.command(8, struct.pack("<BHH", 0, 0xFFFE, 4)).payload,
                                 b"xy\xFF\xFF")
                reads = self.model.reads.copy()
                self.assertEqual(self.bridge.command(8, struct.pack("<BHH", 0, 0x4000, 0)).payload, b"")
                self.assertEqual(self.model.reads, reads)

    def test_legacy_write_bank_writes_full_sram_and_bram_pages(self) -> None:
        data = bytes(range(256)) * 32
        for minor in (0, 1):
            self.bridge.command(1, bytes([2, minor, 0]) + b"legacy\0")
            for page in (10, 11, 14, 223):
                with self.subTest(minor=minor, page=page):
                    self.assertEqual(self.bridge.command(5, bytes([page]) + data).payload, b"\0\0")
                    self.assertEqual(self.bridge.command(25, struct.pack("<BHH", page, 0, 8192)).payload,
                                     data)
            self.assertEqual(self.model.bram[5], data * 2)
            self.assertEqual(self.model.bram[7], data)
            self.assertEqual(self.model.sram[-8192:], data)

    def test_legacy_write_bank_errors_have_error_byte_and_string(self) -> None:
        self.bridge.command(1, b"\x02\x01\0legacy\0")
        for payload in (b"", b"\0", b"\0" + b"x" * 8191, b"\0" + b"x" * 8193):
            with self.subTest(length=len(payload)):
                self.assertEqual(self.bridge.command(5, payload).payload, b"\x01length must be 8192\0")
        for page in (224, 254, 255):
            with self.subTest(page=page):
                self.assertEqual(self.bridge.command(5, bytes([page]) + b"x" * 8192).payload,
                                 b"\x01bank out of range\0")
        self.assertEqual(self.model.writes, [])

    def test_modern_init_still_serves_read_mem_and_unadvertised_write_bank(self) -> None:
        self.bridge.command(1, b"\x02\0\0legacy\0")
        self.bridge.command(1, b"\x02\x02\0modern\0")
        self.assertFalse(self.bridge.legacy)
        self.assertEqual(self.bridge.command(5, b"\x0C" + b"x" * 8192).payload, b"\0\0")
        self.assertEqual(self.bridge.command(8, struct.pack("<BHH", 0, 0x4000, 1)).payload, b"x")
        bitmap = int.from_bytes(self.bridge.command(24, b"").payload, "little")
        self.assertFalse(bitmap & (1 << 5))
        self.assertTrue(bitmap & (1 << 8))
        self.assertTrue(self.bridge.initialized)

    def test_condition_is_ignored_and_bank_byte_encodes_page_plus_one(self) -> None:
        for slot, bank in enumerate((0, 1, 42, 255)):
            with self.subTest(bank=bank):
                reply = self.bridge.command(40, struct.pack("<HB", 0x8123, bank) + b"A == 3\0")
                self.assertEqual(reply.payload, struct.pack("<H", slot + 1))
                flags, page = (1, 0) if bank == 0 else (3, bank - 1)
                self.assertEqual(self.model.frames[-1], b"B" + bytes([slot, flags, 0x81, 0x23, page]))
        self.assertEqual(self.model.pages, {1: 0, 2: 41, 3: 254})
        # AF's A is 0x12, not 3: the remote leaves condition evaluation to DeZog.
        self.bridge.command(6, continue_payload())
        self.model.run_to(0x8123)
        self.assertEqual(self.bridge.poll(), b"\x01\x02\x23\x81\x05\0")

    def test_duplicate_addresses_have_distinct_ids_and_removal_is_by_id(self) -> None:
        for bp_id in (1, 2):
            self.assertEqual(self.bridge.command(40, b"\x23\x81\0\0").payload,
                             struct.pack("<H", bp_id))
        self.bridge.command(41, b"\x01\0")
        self.assertEqual(self.model.slots, {1: 0x8123})
        self.assertEqual(self.bridge.command(40, b"\x34\x92\0\0").payload, b"\x03\0")
        self.assertEqual(self.model.slots, {0: 0x9234, 1: 0x8123})
        for unknown_id in (0, 1, 65535):
            with self.subTest(unknown_id=unknown_id), self.assertLogs("nexttang_debug.dzrp", level="WARNING") as logs:
                self.assertEqual(self.bridge.command(41, struct.pack("<H", unknown_id)).payload, b"")
            self.assertIn("unknown id", logs.output[0])
            self.assertEqual(self.model.slots, {0: 0x9234, 1: 0x8123})
        self.bridge.command(41, b"\x03\0")
        self.assertEqual(self.model.slots, {1: 0x8123})

    def test_banked_breakpoint_only_hits_with_its_page_mapped(self) -> None:
        self.bridge.command(40, b"\x23\x81\x2A\0")  # Wire bank 42 = MMU page 41.
        self.bridge.command(6, continue_payload())
        self.model.run_to(0x8123)  # Slot 4 currently maps page 4.
        self.assertFalse(self.model.paused)
        self.assertIsNone(self.bridge.poll())
        self.model.set_nextreg(0x54, 41)
        self.model.run_to(0x8123)
        self.assertTrue(self.model.paused)
        self.assertEqual(self.bridge.poll(), b"\x01\x02\x23\x81\x2A\0")
        self.bridge.command(41, b"\x01\0")
        self.assertEqual(self.model.pages, {})
        self.assertEqual(self.bridge.pages, {})

    def test_unqualified_breakpoint_hits_across_page_changes_including_rom(self) -> None:
        self.bridge.command(40, b"\x23\x81\0\0")
        for page, bank in ((0, 1), (41, 42), (255, 0)):
            with self.subTest(page=page):
                self.model.set_nextreg(0x54, page)
                self.bridge.command(6, continue_payload())
                self.model.run_to(0x8123)
                self.assertEqual(self.bridge.poll(), b"\x01\x02\x23\x81" + bytes([bank, 0]))
                self.assertIsNone(self.bridge.poll())

    def test_temporary_breakpoints_take_priority_over_user_breakpoint(self) -> None:
        self.bridge.command(40, b"\x23\x81\x05\0")
        for first, second in ((0x8123, 0x9234), (0x9234, 0x8123)):
            with self.subTest(first=first, second=second):
                self.bridge.command(6, continue_payload(first, second))
                self.model.run_to(0x8123)
                self.assertEqual(self.bridge.poll(), b"\x01\0\x23\x81\x05\0")
                self.assertEqual(self.model.slots, {0: 0x8123})
                self.assertEqual(self.model.pages, {0: 4})
                self.assertIsNone(self.bridge.poll())

    def test_external_pause_bank_uses_pcs_slot_and_rom_overflows_to_zero(self) -> None:
        pages = (255, 0, 12, 29, 4, 100, 223, 255)
        self.model.nextregs[0x50:0x58] = bytes(pages)
        for slot, bank in enumerate((0, 1, 13, 30, 5, 101, 224, 0)):
            with self.subTest(slot=slot):
                pc = slot * 0x2000 + 0x123
                self.bridge.command(6, continue_payload(0xFFFF))
                self.model.run_to(pc)
                self.model.pause()
                self.assertEqual(self.bridge.poll(), b"\x01\x01" + struct.pack("<HB", pc, bank) + b"\0")
                self.assertEqual(self.model.slots, {})
                self.assertIsNone(self.bridge.poll())

    def test_explicit_pause_is_manual_even_at_user_and_temporary_pc(self) -> None:
        self.bridge.command(40, b"\x23\x81\0\0")
        self.bridge.command(6, continue_payload(0x8123, 0x9234))
        reply = self.bridge.command(7, b"")
        self.assertEqual(reply.notification, b"\x01\x01\x23\x81\x05\0")
        self.assertEqual(self.model.slots, {0: 0x8123})
        self.assertIsNone(self.bridge.command(7, b"").notification)
        self.assertIsNone(self.bridge.poll())

    def test_close_and_socket_cleanup_clear_all_breakpoints_and_resume(self) -> None:
        for close_command, running in ((False, False), (False, True), (True, False), (True, True)):
            with self.subTest(close_command=close_command, running=running):
                self.bridge.command(1, b"\x02\x02\0test\0")
                self.bridge.command(40, b"\x23\x81\x05\0")
                self.bridge.command(6, continue_payload(0x9000, 0xA000))
                if not running:
                    self.bridge.command(7, b"")
                if close_command:
                    reply = self.bridge.command(2, b"")
                    self.assertEqual(reply.payload, b"")
                    self.assertFalse(reply.close)
                else:
                    self.bridge.finish()  # serve_forever's dropped-socket cleanup.
                self.assertFalse(self.model.paused)
                self.assertFalse(self.bridge.initialized)
                self.assertFalse(self.bridge.running)
                for state in (self.model.slots, self.model.pages, self.bridge.active,
                              self.bridge.pages, self.bridge.ids):
                    self.assertEqual(state, {})
                frames = self.model.frames.copy()
                self.bridge.finish()  # CLOSE is followed by the same finally cleanup.
                self.assertEqual(self.model.frames, frames)

    def test_registers_and_supported_bitmap(self) -> None:
        self.assertTrue(self.model.paused)
        self.assertEqual(self.bridge.command(24, b"").payload, bytes.fromhex("de 8f 00 1f 00 03"))
        self.bridge.command(4, struct.pack("<BH", 0, 0x1234))
        self.bridge.command(4, struct.pack("<BH", 34, 0x1256))
        registers = self.bridge.command(3, b"").payload
        self.assertEqual(registers[:2], b"\x34\x12")
        self.assertEqual(registers[24:], bytes([0x56, 0xAB, 2, 0, 8, 0, 1, 12, 29, 4, 5, 6, 7]))

    def test_memory_boundaries_and_rom(self) -> None:
        self.bridge.command(9, b"\0\xFE\x5Fabcde")
        self.assertEqual(self.model.writes, [(0x59FFE, b"ab"), (0x7A000, b"cde")])
        self.assertEqual(self.bridge.command(28, struct.pack("<IHH", 6, 0x5FFE, 5)).payload, b"abcde")
        self.bridge.command(9, b"\0\xFE\xFFwxyz")
        self.assertEqual(self.bridge.command(28, struct.pack("<IHH", 5, 0xFFFE, 4)).payload, b"wxyz")
        self.model.nextregs[0x50] = 0xFF
        self.assertEqual(self.bridge.command(28, struct.pack("<IHH", 5, 0xFFFE, 4)).payload, b"wx\xFF\xFF")
        writes = self.model.writes.copy()
        with self.assertRaises(DebugError):
            self.bridge.command(9, b"\0\xFF\xFFpq")
        self.assertEqual(self.model.writes, writes)

    def test_bank_ranges_and_slot_updates(self) -> None:
        self.bridge.command(26, struct.pack("<BH", 223, 0x1FFE) + b"ab")
        self.assertEqual(self.bridge.command(25, struct.pack("<BHH", 223, 0x1FFE, 2)).payload, b"ab")
        self.assertEqual(self.model.sram[-2:], b"ab")
        for bank, offset, length in ((224, 0, 1), (0, 0x1FFF, 2), (0, 0x2001, 0)):
            with self.assertRaises(ValueError):
                self.bridge.command(25, struct.pack("<BHH", bank, offset, length))
        self.assertEqual(self.bridge.command(10, bytes([2, 223])).payload, b"\0")
        self.assertEqual(self.bridge.command(11, b"\x52").payload, b"\xDF")
        self.assertEqual(self.bridge.command(10, bytes([9, 0])).payload, b"\x01")
        self.bridge.command(27, bytes([7, 3, 7, 1]))
        self.assertEqual(self.bridge.command(11, b"\x07").payload, b"\x01")

    def test_bram_pages_and_empty_blocks(self) -> None:
        self.model.nextregs[0x52:0x54] = bytes([10, 11])
        self.bridge.command(9, b"\0\xFF\x5Fab")
        self.assertEqual(self.model.bram[5][0x1FFF:0x2001], b"ab")
        self.assertEqual(self.bridge.command(28, struct.pack("<IHH", 3, 0x5FFF, 2)).payload, b"ab")
        self.bridge.command(26, struct.pack("<BH", 14, 0x123) + b"c")
        self.assertEqual(self.model.bram[7][0x123], ord("c"))
        self.assertEqual(self.bridge.command(25, struct.pack("<BHH", 14, 0x123, 1)).payload, b"c")
        self.assertEqual(self.model.writes, [])
        self.assertEqual(self.model.reads, [])
        self.assertEqual(self.bridge.command(28, struct.pack("<IHH", 1, 0x4000, 0)).payload, b"")

    def test_breakpoint_lifetime_capacity_and_poll(self) -> None:
        for i in range(8):
            self.assertEqual(self.bridge.command(40, struct.pack("<HB", 0x8000 + i, 42) + b"\0").payload,
                             struct.pack("<H", i + 1))
        self.assertEqual(self.bridge.command(40, b"\0\x90\0\0").payload, b"\0\0")
        self.bridge.command(6, continue_payload(0, 0x9234))
        self.assertEqual(len(self.model.slots), 10)
        self.model.run_to(0x9234)
        self.assertEqual(self.bridge.poll(), b"\x01\0\x34\x92\x05\0")
        self.assertEqual(len(self.model.slots), 8)
        self.assertIsNone(self.bridge.poll())
        self.bridge.command(41, struct.pack("<H", 3))
        self.assertNotIn(2, self.model.slots)
        self.model.nextregs[0x54] = 41
        self.bridge.command(6, continue_payload())
        self.model.run_to(0x8000)
        self.assertEqual(self.bridge.poll(), b"\x01\x02\0\x80\x2A\0")

    def test_pause_and_detach_policy(self) -> None:
        self.bridge.command(6, continue_payload(0x9000))
        reply = self.bridge.command(7, b"")
        self.assertEqual(reply.payload, b"")
        self.assertEqual(reply.notification, b"\x01\x01\x23\x81\x05\0")
        self.assertEqual(self.model.slots, {})
        self.assertIsNone(self.bridge.command(7, b"").notification)
        self.bridge.command(6, continue_payload())
        self.bridge.finish()
        self.assertFalse(self.model.paused)
        self.assertFalse(self.bridge.initialized)
        self.bridge.command(1, b"\x02\x02\0test\0")
        self.assertFalse(self.bridge.command(2, b"").close)
        self.assertFalse(self.model.paused)

    def test_invalid_payloads_fail_before_backend_changes(self) -> None:
        for command, payload in ((6, b""), (4, b"\0"), (3, b"\0"), (28, b"\0"),
                                 (9, b"\x01\0\0"), (40, b"\0\x80\0"), (27, b"\x50")):
            with self.subTest(command=command), self.assertRaises(ValueError):
                self.bridge.command(command, payload)
        with self.assertRaises(DebugError):
            self.bridge.command(4, struct.pack("<BH", 13, 1))
        self.assertTrue(self.model.paused)
        self.assertEqual(self.model.writes, [])
        self.assertEqual(self.model.slots, {})


if __name__ == "__main__":
    unittest.main()
