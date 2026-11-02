"""Expose the Pi debugger to DeZog without putting break instructions in RAM.

Run with PYTHONPATH=host/debug python3 -m nexttang_debug.dzrp. The UART
must also implement RawLink below. One server loop owns all backend access.

Session, reason codes, bank bytes and refusals follow JNext's DZRP server,
the reference DZRP implementation for the Next (github.com/jorgegv/jnext,
doc/design/debug-subsystem/dzrp-frontend.md at 7b245c86, 2026-11-02): INIT
pauses and CLOSE or a dropped socket resumes; a command the bridge cannot
serve gets a sequence-only reply and a warning, never a closed connection;
2.0 and 2.1 clients (DeZog 3.7.4, remoteType "cspect") are served alongside
2.2; NTF_PAUSE gives reason 0 for CONTINUE's temporary breakpoints (checked
first), 1 for a pause, 2 for a breakpoint, and the bank byte of the page at
the PC's slot plus one; a banked breakpoint fires only with that page mapped;
the condition string is DeZog's to evaluate and is ignored here.
"""

# Wire format checked against maziac/DeZog main, DZRP 2.2.0, 2026-11-02:
# https://raw.githubusercontent.com/maziac/DeZog/main/design/DeZogProtocol.md
# https://raw.githubusercontent.com/maziac/DeZog/main/src/remotes/dzrp/dzrpremote.ts
# https://raw.githubusercontent.com/maziac/DeZog/main/src/remotes/dzrptransport/dzrptransportremote.ts
# Checked command IDs, payload fields, register order, little-endian bitmap,
# INIT (error/version/ZXNEXT/name), onConnect's INIT -> supported commands,
# selectMode (bit 40 selects normal mode), sendDzrpCmd* encoders, and
# receivedMsg's NTF_PAUSE decoder. READ_MEM_BLOCKS sizes of zero are empty;
# DeZog splits a 64K read into two 32K blocks.
# GitHub's cached HTML still shows removed CMD_READ_MEM; the raw main spec
# and command enum use CMD_READ_MEM_BLOCKS (28). GET_SLOTS was removed in
# 2.0; slots follow the registers. WRITE_BANK (5) was replaced by (26).
# Some prose lengths/indices are stale (bank read is BHH = five bytes;
# NTF_PAUSE bank follows its two-byte address). Follow the field layouts.
# The web reader did not expose main's commit SHA; do not invent a pin.

from __future__ import annotations

import argparse
import logging
import select
import socket
import struct
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Protocol, cast

from .cli import DEFAULT_PORT
from .protocol import DebugError, PiDebug, Status
from .uart import UartLink

CMD_INIT = 1
CMD_CLOSE = 2
CMD_GET_REGISTERS = 3
CMD_SET_REGISTER = 4
CMD_WRITE_BANK = 5      # removed in 2.2.0, still sent by 2.0/2.1 clients
CMD_CONTINUE = 6
CMD_PAUSE = 7
CMD_READ_MEM = 8        # removed in 2.2.0, still sent by 2.0/2.1 clients
CMD_WRITE_MEM = 9
CMD_SET_SLOT = 10
CMD_GET_NEXTREG = 11
CMD_LOOPBACK = 15
CMD_GET_SUPPORTED_COMMANDS = 24
CMD_READ_BANK_MEM = 25
CMD_WRITE_BANK_MEM = 26
CMD_SET_NEXTREGS = 27
CMD_READ_MEM_BLOCKS = 28
CMD_ADD_BREAKPOINT = 40
CMD_REMOVE_BREAKPOINT = 41
NTF_PAUSE = 1
REASON_STEP = 0          # one of CONTINUE's temporary breakpoints
REASON_MANUAL = 1
REASON_BREAKPOINT = 2
# Served to every client but not advertised, as JNext: removed in 2.2.0.
LEGACY_COMMANDS = frozenset({CMD_WRITE_BANK})

VERSION = bytes([2, 2, 0])
MACHINE_ZXNEXT = 4
PROGRAM_NAME = b"NextTang DZRP 2.2.0\0"
PAGE_SIZE = 0x2000
RAM_BASE = 0x40000
RAM_PAGES = (0x200000 - RAM_BASE) // PAGE_SIZE
MAX_COMMAND = 0x10000 + 4
MAX_RESPONSE = 0x100000
USER_SLOTS = range(8)
TEMP_SLOTS = range(8, 10)
REGISTER_PAIRS = ("PC", "SP", "AF", "BC", "DE", "HL", "IX", "IY",
                  "AF'", "BC'", "DE'", "HL'")
REGISTER_NAMES = dict(enumerate(REGISTER_PAIRS)) | dict(enumerate(
    ("F", "A", "C", "B", "E", "D", "L", "H", "IXL", "IXH", "IYL", "IYH",
     "F'", "A'", "C'", "B'", "E'", "D'", "L'", "H'", "R", "I"), 14))
SUPPORTED_COMMANDS = frozenset({
    CMD_INIT, CMD_CLOSE, CMD_GET_REGISTERS, CMD_SET_REGISTER, CMD_CONTINUE,
    CMD_PAUSE, CMD_READ_MEM, CMD_WRITE_MEM, CMD_SET_SLOT, CMD_GET_NEXTREG, CMD_LOOPBACK,
    CMD_GET_SUPPORTED_COMMANDS, CMD_READ_BANK_MEM, CMD_WRITE_BANK_MEM,
    CMD_SET_NEXTREGS, CMD_READ_MEM_BLOCKS, CMD_ADD_BREAKPOINT, CMD_REMOVE_BREAKPOINT,
})
SUPPORTED_BITMAP = sum(1 << command for command in SUPPORTED_COMMANDS).to_bytes(6, "little")


class RawLink(Protocol):
    """Separate UART frames from Pi SPI exchanges; never wrap B in X."""

    def write(self, data: bytes) -> None:
        """Write all bytes, handling short writes and the link timeout."""
        ...

    def read_reply(self, header: bytes, length: int) -> bytes:
        """Scan past status text, consume header, return exactly length bytes.

        Preserve bytes after this reply and raise DebugError on timeout.
        Do not flush input here: the board may already have answered.
        """
        ...


class DebugBackend(Protocol):
    def status(self) -> Status: ...
    def pause(self, timeout: float = 1.0) -> Status: ...
    def resume(self) -> None: ...
    def registers(self) -> dict[str, int]: ...
    def set_register(self, name: str, value: int) -> None: ...
    def nextreg(self, register: int) -> int: ...
    def set_nextreg(self, register: int, value: int) -> None: ...
    def read_memory(self, address: int, length: int) -> bytes: ...
    def write_memory(self, address: int, data: bytes) -> None: ...
    def read_bank_ram(self, bank: int, offset: int, length: int) -> bytes: ...
    def write_bank_ram(self, bank: int, offset: int, data: bytes) -> None: ...


class BreakpointBackend(Protocol):
    def set(self, slot: int, address: int, page: int | None = None) -> None: ...
    def clear(self, slot: int) -> None: ...


@dataclass
class Breakpoints:
    """Program the ten fabric PC comparators and verify their acknowledgement."""

    link: RawLink

    def _send(self, slot: int, flags: int, address: int, page: int) -> None:
        if not 0 <= slot < 10 or not 0 <= address <= 0xFFFF:
            raise ValueError("breakpoint slot/address out of range")
        self.link.write(b"B" + bytes([slot, flags, address >> 8, address & 0xFF, page & 0xFF]))
        if self.link.read_reply(b"\x01b", 1) != bytes([slot]):
            raise DebugError("wrong breakpoint slot in UART reply")

    def set(self, slot: int, address: int, page: int | None = None) -> None:
        """page: fire only while this 8K page is mapped at the address."""
        self._send(slot, 1 if page is None else 3, address, page or 0)

    def clear(self, slot: int) -> None:
        self._send(slot, 0, 0, 0)


@dataclass(frozen=True)
class Reply:
    payload: bytes = b""
    notification: bytes | None = None
    close: bool = False


@dataclass
class DzrpBridge:
    """Keep session state beside the injectable hardware APIs."""

    debug: DebugBackend
    breakpoints: BreakpointBackend
    initialized: bool = field(default=False, init=False)
    running: bool = field(default=False, init=False)
    legacy: bool = field(default=False, init=False)        # a 2.0/2.1 client
    active: dict[int, int] = field(default_factory=dict, init=False)    # slot -> address
    pages: dict[int, int] = field(default_factory=dict, init=False)     # slot -> page, banked only
    ids: dict[int, int] = field(default_factory=dict, init=False)       # DZRP id -> slot
    next_id: int = field(default=1, init=False)

    @staticmethod
    def _size(data: bytes, length: int) -> None:
        if len(data) != length:
            raise ValueError(f"expected {length} payload bytes, got {len(data)}")

    def _paused(self) -> None:
        if self.running or not self.debug.status().paused:
            raise DebugError("pause the CPU before accessing registers or memory")

    def _clear(self, slots: range) -> None:
        for slot in slots:
            self.breakpoints.clear(slot)
            self.active.pop(slot, None)
            self.pages.pop(slot, None)

    def finish(self, resume: bool = True) -> None:
        """Detach cleanly: breakpoints cleared and the machine running again,
        for CLOSE and for a dropped socket alike (as JNext does)."""
        if not self.initialized:
            return
        self.debug.pause()
        self._clear(range(10))
        self.ids.clear()
        if resume:
            self.debug.resume()
        self.running = False
        self.initialized = False

    def _stop_notification(self, reason: int | None = None) -> bytes:
        pc = self.debug.registers()["PC"]
        page = self.debug.nextreg(0x50 + (pc >> 13))
        if reason is None:
            # A banked breakpoint counts only with its page mapped, as the
            # hardware decides.
            if any(self.active.get(slot) == pc for slot in TEMP_SLOTS):
                reason = REASON_STEP
            elif any(self.active.get(slot) == pc and self.pages.get(slot, page) == page
                     for slot in USER_SLOTS):
                reason = REASON_BREAKPOINT
            else:
                reason = REASON_MANUAL
        self._clear(TEMP_SLOTS)
        self.running = False
        # bank + 1 of the page at the PC; ROM (FF) does not fit and reads 0.
        return struct.pack("<BBHB", NTF_PAUSE, reason, pc, (page + 1) & 0xFF) + b"\0"

    def poll(self) -> bytes | None:
        if self.running and self.debug.status().paused:
            return self._stop_notification()
        return None

    def _segments(self, address: int, length: int) -> list[tuple[int | None, int]]:
        """Split before mapping so neither MMU boundaries nor 64K wrap leak through."""
        segments = []
        while length:
            address &= 0xFFFF
            offset = address & (PAGE_SIZE - 1)
            count = min(length, PAGE_SIZE - offset)
            page = self.debug.nextreg(0x50 + (address >> 13))
            if page == 0xFF:
                sram = None  # PiDebug does not expose the currently selected ROM.
            elif page < RAM_PAGES:
                sram = RAM_BASE + page * PAGE_SIZE + offset
            else:
                raise DebugError(f"MMU page {page:02X} is outside the 2 MB SRAM")
            segments.append((sram, count))
            address += count
            length -= count
        return segments

    def _read_z80(self, address: int, length: int) -> bytes:
        return b"".join(b"\xFF" * count if sram is None else self._read_ram(sram, count)
                        for sram, count in self._segments(address, length))

    @staticmethod
    def _bram_target(sram: int) -> tuple[int, int] | None:
        """Banks 5 and the lower half of 7 live only in the official core's BRAM."""
        page, offset = divmod(sram - RAM_BASE, PAGE_SIZE)
        if page in (0x0A, 0x0B):
            return 5, (page - 0x0A) * PAGE_SIZE + offset
        if page == 0x0E:
            return 7, offset
        return None

    def _read_ram(self, sram: int, length: int) -> bytes:
        target = self._bram_target(sram)
        if target is not None:
            return self.debug.read_bank_ram(*target, length)
        return self.debug.read_memory(sram, length)

    def _write_ram(self, sram: int, data: bytes) -> None:
        target = self._bram_target(sram)
        if target is not None:
            self.debug.write_bank_ram(*target, data)
        else:
            self.debug.write_memory(sram, data)

    @staticmethod
    def _bank_address(bank: int, offset: int, length: int) -> int | None:
        if offset > PAGE_SIZE or offset + length > PAGE_SIZE:
            raise ValueError("bank transfer crosses an 8K bank boundary")
        if bank == 0xFF:
            return None
        if bank >= RAM_PAGES:
            raise ValueError("bank is outside the 2 MB SRAM")
        return RAM_BASE + bank * PAGE_SIZE + offset

    def command(self, command: int, data: bytes) -> Reply:
        """Return wire payloads; the server sends each response before its notification."""
        if command == CMD_INIT:
            # DZRP frames on the length: bytes after the name's NUL are part of
            # the command and are consumed with it (dezogif_ng conformance C9).
            if len(data) < 4 or b"\0" not in data[3:]:
                raise ValueError("INIT requires version and a zero-terminated name")
            error = int(data[0] != 2)
            if not error:
                self.legacy = data[1] < 2
                self.initialized = True  # Ensure cleanup even if a UART command fails.
                self.debug.pause()
                self.running = False
                self._clear(range(10))
                self.ids.clear()
                self.next_id = 1
            return Reply(bytes([error]) + VERSION + bytes([MACHINE_ZXNEXT]) + PROGRAM_NAME,
                         close=bool(error))
        if not self.initialized:
            # Before INIT, or after CLOSE on a connection that stays open.
            logging.getLogger(__name__).warning("DZRP command %d before INIT", command)
            return Reply()
        if command not in SUPPORTED_COMMANDS and command not in LEGACY_COMMANDS:
            # As JNext: the frame is consumed, the reply carries only the
            # sequence number, and the log names the command.
            logging.getLogger(__name__).warning("unsupported DZRP command %d", command)
            return Reply()
        if command in {CMD_CLOSE, CMD_GET_REGISTERS, CMD_PAUSE, CMD_GET_SUPPORTED_COMMANDS}:
            self._size(data, 0)
        if command == CMD_CLOSE:
            # The session ends and the machine runs; the connection stays open
            # for another INIT, as JNext serves it (conformance C15).
            self.finish(resume=True)
            return Reply()
        if command == CMD_GET_SUPPORTED_COMMANDS:
            return Reply(SUPPORTED_BITMAP)
        if command == CMD_LOOPBACK:
            if len(data) > 8192:
                raise ValueError("LOOPBACK is limited to 8192 bytes")
            return Reply(data)
        if command == CMD_GET_REGISTERS:
            self._paused()
            regs = self.debug.registers()
            payload = struct.pack("<12H", *(regs[name] for name in REGISTER_PAIRS))
            payload += bytes([regs["R"], regs["I"], regs["IM"], 0, 8])
            return Reply(payload + bytes(self.debug.nextreg(0x50 + slot) for slot in range(8)))
        if command == CMD_SET_REGISTER:
            self._size(data, 3)
            self._paused()
            number, value = struct.unpack("<BH", data)
            if number not in REGISTER_NAMES:
                # PiDebug cannot write IM (13); do not acknowledge a fictitious change.
                raise DebugError(f"PiDebug cannot set DZRP register {number}")
            self.debug.set_register(REGISTER_NAMES[number], value if number < 12 else value & 0xFF)
        elif command == CMD_CONTINUE:
            # JNext accepts five bytes or more: what is missing reads as zero.
            if len(data) < 5:
                raise ValueError("CONTINUE needs at least five bytes")
            self._paused()
            enabled1, address1, enabled2, address2, alternate, _, _ = struct.unpack(
                "<BHBHBHH", data[:11].ljust(11, b"\0"))
            if enabled1 > 1 or enabled2 > 1 or alternate > 2:
                raise ValueError("invalid CONTINUE flags")
            # Alternates are optional optimizations; use the supplied breakpoints.
            for slot, enabled, address in ((8, enabled1, address1), (9, enabled2, address2)):
                if enabled:
                    self.breakpoints.set(slot, address)
                    self.active[slot] = address
                else:
                    self._clear(range(slot, slot + 1))
            self.debug.resume()
            self.running = True
        elif command == CMD_PAUSE:
            if self.running or not self.debug.status().paused:
                self.debug.pause()
                return Reply(notification=self._stop_notification(REASON_MANUAL))
        elif command == CMD_ADD_BREAKPOINT:
            if len(data) < 4 or data[-1] != 0 or b"\0" in data[3:-1]:
                raise ValueError("breakpoint condition must be zero-terminated")
            # The condition string is DeZog's to evaluate (as JNext). A bank
            # byte other than 0 makes the comparator page-qualified. ID 0 is
            # the refusal when all eight user comparators are taken.
            slot = next((slot for slot in USER_SLOTS if slot not in self.active), None)
            if slot is None or self.next_id > 0xFFFF:
                # Ids are never reused within a session (JNext 3.1).
                return Reply(b"\0\0")
            address = int.from_bytes(data[:2], "little")
            page = data[2] - 1 if data[2] not in (0, 0xFF + 1 & 0xFF) else None
            self.breakpoints.set(slot, address, page)
            self.active[slot] = address
            if page is not None:
                self.pages[slot] = page
            bp_id = self.next_id
            self.next_id += 1
            self.ids[bp_id] = slot
            return Reply(struct.pack("<H", bp_id))
        elif command == CMD_REMOVE_BREAKPOINT:
            self._size(data, 2)
            slot = self.ids.pop(int.from_bytes(data, "little"), None)
            if slot is None:
                logging.getLogger(__name__).warning("REMOVE_BREAKPOINT: unknown id")
            else:
                self._clear(range(slot, slot + 1))
        elif command == CMD_GET_NEXTREG:
            self._size(data, 1)
            return Reply(bytes([self.debug.nextreg(data[0])]))
        elif command == CMD_SET_SLOT:
            self._size(data, 2)
            self._paused()
            slot, bank = data
            if slot == 0 and bank == 0xFE:
                bank = 0xFF  # Compatibility with DeZog <= 2.7.
            if slot >= 8 or (bank >= RAM_PAGES and bank != 0xFF):
                return Reply(b"\x01")
            self.debug.set_nextreg(0x50 + slot, bank)
            return Reply(b"\0")
        elif command == CMD_SET_NEXTREGS:
            self._paused()
            if len(data) % 2:
                raise ValueError("NEXTREG requires register/value pairs")
            for register, value in struct.iter_unpack("BB", data):
                self.debug.set_nextreg(register, value)
        elif command == CMD_READ_MEM_BLOCKS:
            self._paused()
            if len(data) < 4 or len(data) % 4:
                raise ValueError("READ_MEM_BLOCKS requires response size and address/size pairs")
            blocks = list(struct.iter_unpack("<HH", data[4:]))
            if sum(length for _, length in blocks) + 1 > MAX_RESPONSE:
                raise ValueError("memory response is too large")
            # resp_length is an allocation hint, not a second source of block sizes.
            return Reply(b"".join(self._read_z80(address, length) for address, length in blocks))
        elif command == CMD_READ_MEM:
            self._size(data, 5)
            self._paused()
            _, address, count = struct.unpack("<BHH", data)
            return Reply(self._read_z80(address, count))
        elif command == CMD_WRITE_BANK:
            self._paused()
            if len(data) != 1 + PAGE_SIZE:
                return Reply(b"\x01length must be 8192\0")
            sram = self._bank_address(data[0], 0, PAGE_SIZE) if data[0] < RAM_PAGES else None
            if sram is None:
                return Reply(b"\x01bank out of range\0")
            self._write_ram(sram, data[1:])
            return Reply(b"\0\0")
        elif command == CMD_WRITE_MEM:
            self._paused()
            if len(data) < 3 or data[0] != 0:
                raise ValueError("WRITE_MEM requires reserved zero, address and bytes")
            segments = self._segments(int.from_bytes(data[1:3], "little"), len(data) - 3)
            if any(sram is None for sram, _ in segments):
                raise DebugError("cannot write the selected ROM")
            start = 3
            for sram, count in segments:
                assert sram is not None
                self._write_ram(sram, data[start:start + count])
                start += count
        elif command in {CMD_READ_BANK_MEM, CMD_WRITE_BANK_MEM}:
            self._paused()
            if command == CMD_READ_BANK_MEM:
                self._size(data, 5)
                bank, offset, count = struct.unpack("<BHH", data)
                sram = self._bank_address(bank, offset, count)
                return Reply(b"\xFF" * count if sram is None else self._read_ram(sram, count))
            if len(data) < 3:
                raise ValueError("WRITE_BANK_MEM requires bank, offset and bytes")
            bank, offset = struct.unpack("<BH", data[:3])
            sram = self._bank_address(bank, offset, len(data) - 3)
            if sram is None:
                raise DebugError("cannot write ROM")
            self._write_ram(sram, data[3:])
        return Reply()


class DzrpServer:
    """Serialize requests and polling so the shared UART never has two readers."""

    def __init__(self, bridge: DzrpBridge, host: str = "127.0.0.1", port: int = 11000,
                 poll_interval: float = 0.03) -> None:
        if not 0 < poll_interval <= 1:
            raise ValueError("poll interval must be between zero and one second")
        self.bridge = bridge
        self.poll_interval = poll_interval
        self.stop = threading.Event()
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.listener.bind((host, port))
            self.listener.listen(1)
        except OSError:
            self.listener.close()
            raise
        self.address = self.listener.getsockname()

    def __enter__(self) -> DzrpServer:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def shutdown(self) -> None:
        """Signal from another thread; join serve_forever before closing the socket."""
        self.stop.set()

    def close(self) -> None:
        self.shutdown()
        self.listener.close()

    @staticmethod
    def _send(client: socket.socket, sequence: int, payload: bytes) -> None:
        client.sendall(struct.pack("<IB", len(payload) + 1, sequence) + payload)

    def _serve_client(self, client: socket.socket) -> None:
        pending = bytearray()
        next_poll = time.monotonic() + self.poll_interval
        client.settimeout(1.0)  # Bound a stalled client's sendall.
        while not self.stop.is_set():
            if len(pending) >= 6:
                length, sequence, command = struct.unpack_from("<IBB", pending)
                if length > MAX_COMMAND or sequence == 0:
                    raise ValueError("invalid DZRP frame length or sequence")
                if len(pending) >= 6 + length:
                    data = bytes(pending[6:6 + length])
                    del pending[:6 + length]
                    try:
                        reply = self.bridge.command(command, data)
                    except (ValueError, DebugError) as error:
                        # One bad command must not end the session: answer
                        # with the sequence number alone and log why.
                        logging.getLogger(__name__).warning("DZRP command %d: %s", command, error)
                        if not self.bridge.initialized:
                            raise
                        reply = Reply()
                    self._send(client, sequence, reply.payload)
                    if reply.notification is not None:
                        self._send(client, 0, reply.notification)
                    if reply.close:
                        return
            now = time.monotonic()
            if now >= next_poll:
                notification = self.bridge.poll()
                if notification is not None:
                    self._send(client, 0, notification)
                next_poll = time.monotonic() + self.poll_interval
            # Process coalesced frames without waiting; partial frames still allow polling.
            complete = len(pending) >= 6 and len(pending) >= 6 + struct.unpack_from("<I", pending)[0]
            timeout = 0 if complete else min(0.05, max(0.0, next_poll - time.monotonic()))
            # Drain buffered requests before receiving another TCP chunk.
            readers = [self.listener] if complete else [client, self.listener]
            ready, _, _ = select.select(readers, [], [], timeout)
            # The current client first: a reconnecting client's hang-up must be
            # seen before its new connection is taken for a second client (the
            # race JNext fixed in its transport).
            if client in ready:
                chunk = client.recv(4096)
                if not chunk:
                    return
                pending += chunk
            if self.listener in ready:
                extra, _ = self.listener.accept()
                extra.close()

    def serve_forever(self) -> None:
        while not self.stop.is_set():
            ready, _, _ = select.select([self.listener], [], [], 0.05)
            if not ready:
                continue
            client, _ = self.listener.accept()
            with client:
                try:
                    self._serve_client(client)
                except (OSError, ValueError, DebugError) as error:
                    logging.getLogger(__name__).warning("DZRP client disconnected: %s", error)
                finally:
                    # A cleanup failure propagates: accepting a new owner of unknown
                    # hardware breakpoint state would make the session misleading.
                    self.bridge.finish()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--port", default=DEFAULT_PORT, help="serial device of the debug UART")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--listen", default="127.0.0.1", help="TCP bind address")
    parser.add_argument("--tcp-port", type=int, default=11000)   # CSpect's and JNext's port
    parser.add_argument("--poll-interval", type=float, default=0.03, help="status poll interval in seconds")
    args = parser.parse_args(argv)
    try:
        with UartLink(args.port, args.baud) as link:
            if not callable(getattr(link, "write", None)) or not callable(getattr(link, "read_reply", None)):
                raise DebugError("UartLink needs write(data) and read_reply(header, length); see dzrp.RawLink")
            bridge = DzrpBridge(PiDebug(link), Breakpoints(cast(RawLink, link)))
            with DzrpServer(bridge, args.listen, args.tcp_port, args.poll_interval) as server:
                print(f"NextTang DZRP listening on {server.address[0]}:{server.address[1]}", flush=True)
                server.serve_forever()
    except KeyboardInterrupt:
        return 0
    except (DebugError, OSError, ValueError) as error:
        print(f"nexttang-dzrp: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
