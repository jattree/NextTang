"""The official ZX Spectrum Next Pi debug protocol (core 3.02.04 on).

pi_debug_control in the official core takes commands from a Raspberry Pi over
SPI. One command is one chip select; every byte sent clocks one byte back. This
module builds each command's bytes and reads its answer out of the bytes that
came back, over any transport with an ``exchange(bytes) -> bytes`` method that
runs one command. The byte layouts follow the official readme
(cores/zxnext/src/device/pi_debug_control/readme.txt) and were checked in
simulation against the official logic inside NextTang's core.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Protocol

CMD_NOP = 0xA0
CMD_VERSION = 0xA1
CMD_STATUS = 0xA2
CMD_SYSTEM = 0xA3
CMD_CPU_PAUSE = 0xA4
CMD_CPU_RESUME = 0xA5
CMD_CPU_SSTEP = 0xA6
CMD_SRAM_R = 0xA7
CMD_SRAM_W = 0xA8
CMD_BRAM_R = 0xA9
CMD_BRAM_W = 0xAA
CMD_NEXTREG_R = 0xAB
CMD_NEXTREG_W = 0xAC
CMD_CPU_REG_R = 0xAD
CMD_CPU_REG_W = 0xAE

# CMD_SYSTEM bits.
SYSTEM_SOFT_RESET = 0x01
SYSTEM_HARD_RESET = 0x02
SYSTEM_DIVMMC_NMI = 0x04
SYSTEM_MF_NMI = 0x08
SYSTEM_CTC3_INT = 0x10

# CPU register numbers (official cores/zxnext/src/cpu/readme.txt).
CPU_REGISTERS = {
    "A": 0x00, "F": 0x01, "B": 0x02, "C": 0x03, "D": 0x04, "E": 0x05, "H": 0x06, "L": 0x07,
    "A'": 0x08, "F'": 0x09, "B'": 0x0A, "C'": 0x0B, "D'": 0x0C, "E'": 0x0D, "H'": 0x0E, "L'": 0x0F,
    "IXH": 0x10, "IXL": 0x11, "IYH": 0x12, "IYL": 0x13, "SPH": 0x14, "SPL": 0x15,
    "PCH": 0x16, "PCL": 0x17, "I": 0x18, "R": 0x19,
}
CPU_STATE_READ = 0x1A    # 00 IM(1:0) 0 HALT IFF2 IFF1
CPU_STATE_WRITE = 0x1B   # only HALT, IFF2 and IFF1 are written
PAIRS = {
    "AF": ("A", "F"), "BC": ("B", "C"), "DE": ("D", "E"), "HL": ("H", "L"),
    "AF'": ("A'", "F'"), "BC'": ("B'", "C'"), "DE'": ("D'", "E'"), "HL'": ("H'", "L'"),
    "IX": ("IXH", "IXL"), "IY": ("IYH", "IYL"), "SP": ("SPH", "SPL"), "PC": ("PCH", "PCL"),
}

# A UART frame carries at most 256 bytes: a main-memory read spends seven on
# the command, address, length and the reply's first, undefined byte.
MAX_FRAME = 256
MAX_SRAM_READ = MAX_FRAME - 7
MAX_SRAM_WRITE = MAX_FRAME - 6
MAX_BRAM_READ = MAX_FRAME - 6
MAX_BRAM_WRITE = MAX_FRAME - 5


class Transport(Protocol):
    def exchange(self, sent: bytes) -> bytes: ...


class DebugError(RuntimeError):
    """The slave reported an error or did not do what was asked."""


@dataclass(frozen=True)
class Status:
    raw: int
    hotkeys: int

    @property
    def had_reset(self) -> bool:
        return bool(self.raw & 0x80)

    @property
    def bus(self) -> int:
        """0 running, 1 stopping, 2 paused, 3 releasing for a single step."""
        return (self.raw >> 5) & 0x03

    @property
    def paused(self) -> bool:
        return self.bus == 2

    @property
    def dma_active(self) -> bool:
        return not self.raw & 0x10

    @property
    def halted(self) -> bool:
        return not self.raw & 0x08

    @property
    def error(self) -> bool:
        return bool(self.raw & 0x01)


@dataclass(frozen=True)
class Version:
    version: int
    capabilities: int

    CAPABILITY_NAMES = ("system", "nextreg read", "nextreg write", "main memory",
                        "cpu pause", "bank 5/7 ram", "cpu registers", "tape hotkeys")

    @property
    def names(self) -> list[str]:
        return [name for bit, name in enumerate(self.CAPABILITY_NAMES) if self.capabilities >> bit & 1]


class PiDebug:
    """Commands of the official Pi debug slave over a transport."""

    def __init__(self, transport: Transport) -> None:
        self.transport = transport

    def _command(self, sent: list[int] | bytes) -> bytes:
        sent = bytes(sent)
        reply = self.transport.exchange(sent)
        if len(reply) != len(sent):
            raise DebugError(f"sent {len(sent)} bytes, {len(reply)} came back")
        return reply

    # ------------------------------------------------------------- identity
    def version(self) -> Version:
        reply = self._command([CMD_VERSION, 0, 0, 0])
        return Version(reply[2] >> 4, reply[3])

    def status(self) -> Status:
        reply = self._command([CMD_STATUS, 0, 0, 0])
        return Status(reply[2], reply[3])

    def system(self, bits: int) -> None:
        self._command([CMD_SYSTEM, bits & 0x1F])

    # ------------------------------------------------------------------ CPU
    def pause(self, timeout: float = 1.0) -> Status:
        self._command([CMD_CPU_PAUSE])
        return self.wait_paused(timeout)

    def resume(self) -> None:
        self._command([CMD_CPU_RESUME])

    def step(self, timeout: float = 1.0) -> Status:
        self._command([CMD_CPU_SSTEP])
        return self.wait_paused(timeout)

    def wait_paused(self, timeout: float = 1.0) -> Status:
        deadline = time.monotonic() + timeout
        while True:
            status = self.status()
            if status.paused:
                return status
            if time.monotonic() > deadline:
                raise DebugError(f"CPU did not stop (status {status.raw:02x})")

    def cpu_register(self, number: int) -> int:
        return self._command([CMD_CPU_REG_R, number & 0x1F, 0, 0])[3]

    def set_cpu_register(self, number: int, value: int) -> None:
        self._command([CMD_CPU_REG_W, number & 0x1F, value & 0xFF, 0])

    def registers(self) -> dict[str, int]:
        """Every CPU register; the CPU must be paused."""
        single = {name: self.cpu_register(number) for name, number in CPU_REGISTERS.items()}
        state = self.cpu_register(CPU_STATE_READ)
        result = {pair: single[high] << 8 | single[low] for pair, (high, low) in PAIRS.items()}
        # T80 keeps the mode as the IM instruction's bits 4:3: 00, 10 or 11.
        result.update(I=single["I"], R=single["R"], IM=(0, 0, 1, 2)[state >> 4 & 3],
                      HALT=state >> 2 & 1, IFF2=state >> 1 & 1, IFF1=state & 1)
        return result

    def set_register(self, name: str, value: int) -> None:
        """Set a register or register pair by name; the CPU must be paused."""
        name = name.upper()
        if name in PAIRS:
            high, low = PAIRS[name]
            self.set_cpu_register(CPU_REGISTERS[high], value >> 8)
            self.set_cpu_register(CPU_REGISTERS[low], value)
            if name == "PC":
                # As JNext (debugger_inspect.cpp, design 4.2a): a new PC takes
                # the CPU out of HALT, or it would stay parked there. The
                # interrupt flip-flops are kept.
                state = self.cpu_register(CPU_STATE_READ)
                if state & 0x04:
                    self.set_cpu_register(CPU_STATE_WRITE, state & 0x03)
        elif name in CPU_REGISTERS:
            self.set_cpu_register(CPU_REGISTERS[name], value)
        else:
            raise DebugError(f"no register {name}")

    # ------------------------------------------------------------- NextREGs
    def nextreg(self, register: int) -> int:
        return self._command([CMD_NEXTREG_R, register & 0xFF, 0, 0])[3]

    def set_nextreg(self, register: int, value: int) -> None:
        self._command([CMD_NEXTREG_W, register & 0xFF, value & 0xFF, 0])

    # -------------------------------------------- main memory (2 MB, port C)
    def read_memory(self, address: int, length: int) -> bytes:
        """Bytes of the 2 MB main memory (SRAM address, not a Z80 address)."""
        out = bytearray()
        while length > 0:
            count = min(length, MAX_SRAM_READ)
            sent = [CMD_SRAM_R, address >> 16 & 0x1F, address >> 8 & 0xFF, address & 0xFF,
                    count >> 8, count & 0xFF] + [0] * (count + 1)
            out += self._command(sent)[7:7 + count]
            address += count
            length -= count
        return bytes(out)

    def write_memory(self, address: int, data: bytes) -> None:
        for start in range(0, len(data), MAX_SRAM_WRITE):
            chunk = data[start:start + MAX_SRAM_WRITE]
            at = address + start
            self._command([CMD_SRAM_W, at >> 16 & 0x1F, at >> 8 & 0xFF, at & 0xFF,
                           len(chunk) >> 8, len(chunk) & 0xFF, *chunk])

    # ------------------------------ banks 5 and 7 in block RAM (CPU paused)
    @staticmethod
    def _bram_address(bank: int, offset: int) -> int:
        if bank == 5:
            return offset & 0x3FFF
        if bank == 7:
            return 0x8000 | offset & 0x1FFF
        raise DebugError("block RAM holds banks 5 and 7 only")

    def read_bank_ram(self, bank: int, offset: int, length: int) -> bytes:
        out = bytearray()
        while length > 0:
            count = min(length, MAX_BRAM_READ)
            at = self._bram_address(bank, offset)
            sent = [CMD_BRAM_R, at >> 8, at & 0xFF, count >> 8, count & 0xFF] + [0] * (count + 1)
            out += self._command(sent)[6:6 + count]
            offset += count
            length -= count
        return bytes(out)

    def write_bank_ram(self, bank: int, offset: int, data: bytes) -> None:
        for start in range(0, len(data), MAX_BRAM_WRITE):
            chunk = data[start:start + MAX_BRAM_WRITE]
            at = self._bram_address(bank, offset + start)
            self._command([CMD_BRAM_W, at >> 8, at & 0xFF, len(chunk) >> 8, len(chunk) & 0xFF, *chunk])


# ------------------------------------------------------------ Z80 addresses
RAM_BASE = 0x40000   # 8K RAM page 0 in the 2 MB space (16K bank n is unit n + 16)


def z80_target(page: int, offset: int) -> tuple[str, int, int]:
    """Where the byte at an 8K RAM page and offset lives: ("bram", bank, offset)
    for bank 5 (pages 0A, 0B) and the first half of bank 7 (page 0E), which
    the official core keeps only in block RAM, else ("sram", 0, address)."""
    if page in (0x0A, 0x0B):
        return "bram", 5, (page - 0x0A) * 0x2000 + offset
    if page == 0x0E:
        return "bram", 7, offset
    return "sram", 0, RAM_BASE + page * 0x2000 + offset


class Z80Memory:
    """The Z80's 64K view through the MMU (NextREGs 0x50 to 0x57).

    Banks 5 and 7 are read and written through the slave's block RAM
    commands, which the official interface allows only while the CPU is
    paused. ROM (MMU page FF) is not reachable through the interface; it
    reads as FF and cannot be written.
    """

    def __init__(self, debug: PiDebug) -> None:
        self.debug = debug

    def pages(self) -> list[int]:
        return [self.debug.nextreg(0x50 + slot) for slot in range(8)]

    def _runs(self, address: int, length: int):
        pages = self.pages()
        while length > 0:
            slot, offset = address >> 13 & 7, address & 0x1FFF
            count = min(length, 0x2000 - offset)
            yield address, pages[slot], offset, count
            address = (address + count) & 0xFFFF
            length -= count

    def read(self, address: int, length: int) -> bytes:
        out = bytearray()
        for _, page, offset, count in self._runs(address, length):
            if page == 0xFF:
                out += b"\xFF" * count
                continue
            kind, bank, where = z80_target(page, offset)
            out += (self.debug.read_bank_ram(bank, where, count) if kind == "bram"
                    else self.debug.read_memory(where, count))
        return bytes(out)

    def write(self, address: int, data: bytes) -> None:
        done = 0
        for at, page, offset, count in self._runs(address, len(data)):
            chunk = data[done:done + count]
            done += count
            if page == 0xFF:
                raise DebugError(f"{at:04X} is ROM")
            kind, bank, where = z80_target(page, offset)
            if kind == "bram":
                self.debug.write_bank_ram(bank, where, chunk)
            else:
                self.debug.write_memory(where, chunk)
