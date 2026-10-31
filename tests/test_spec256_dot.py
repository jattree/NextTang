"""The .SPEC256 dot command must send what send_next.py sends, write the
snapshot z80_from_256.py writes, and fail safely.

firmware/spec256dot/spec256.asm runs on a Z80 emulator (the `z80` Python
package) with the esxDOS calls it makes (RST $08: open, stat, seek, read,
close) and ROM printing (RST $10) answered by the test. NextREG 0x3E reads as
the core's interface ID; every byte written to NextREG 0x3E while the command
owns the loader is collected and must equal send_next.game_colour_stream for
the same .256 and palette: H, S1, U, C, Y, Z, the planes of banks 5, 2 and 0,
the ROM font, Q, B, E and M (BGX1's rules and its backgrounds that have a
pixel), P and W for a 128K game's other coloured banks (bank 4 here has
none), and G, the start taken from the .256 (PC 0x0072 means the
address on the stack, here in bank 3 paged at 0xC000). The file it writes to
/tmp/SPEC256.Z80 on the system drive must equal z80_from_256.py's for the
same .256: a 128K game (all eight banks, 7FFD, the AY state) and a 48K one
(banks 5, 2 and 0, the AY flag). Checked too: a .256 of
the oldest size (no optional blocks); a tagged block after OPT1 is skipped and
a truncated one refused; an OPT1 level above 1, a core without the interface
and a missing palette are refused before anything is sent; a read failing
mid-stream aborts the loader, sends H and releases it; the CPU speed and the
file are always restored and closed; the game's CRD1 credits are printed.
"""

from __future__ import annotations

import random
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE = REPO_ROOT / "firmware" / "spec256dot" / "spec256.asm"
sys.path.insert(0, str(REPO_ROOT / "tools" / "spec256"))
import send_next  # noqa: E402
from z80_from_256 import z80_from_256  # noqa: E402

try:
    import z80
except ImportError:  # optional: pip install z80
    z80 = None

LOAD_AT = 0x2000
ARGS_AT = 0x5D00
RETURN_AT = 0xFFF0
AYS1_AT = 1_383_028
CRD1_AT = 1_383_049
OPT1_AT = 1_383_117
OPT1_END = 1_383_373
GRX1_AT = send_next.GRX1_AT
RUL1_AT = send_next.RUL1_AT
BGX1_AT = send_next.BGX1_AT


def assemble() -> bytes:
    with tempfile.TemporaryDirectory() as directory:
        out = Path(directory) / "SPEC256"
        subprocess.run(["sjasmplus", "--nologo", f"--raw={out}", str(SOURCE)],
                       check=True, capture_output=True)
        return out.read_bytes()


def make_game(seed: int = 1, size: int = OPT1_END, port_7ffd: int = 0x13) -> bytearray:
    rng = random.Random(seed)
    game = bytearray(rng.randrange(256) for _ in range(size))
    regs = send_next.REGISTERS_AT
    # PC 0x0072 with the real start on the stack at 0xFF10, in the bank 7FFD
    # pages at 0xC000 (3 for the 128K default, 0 for a 48K game).
    game[regs + 6:regs + 10] = bytes((0x10, 0xFF, 0x72, 0x00))
    game[send_next.PORT_7FFD_AT] = port_7ffd
    for address, byte in ((0xFF10, 0x5D), (0xFF11, 0xB1)):
        game[((port_7ffd & 7) * 16_384 + (address & 0x3FFF)) * 9 + 8] = byte
    # Bank 4 without colour: every record's planes are its master's byte, so
    # a 128K game's P/W stream skips it.
    for offset in range(16_384):
        at = (4 * 16_384 + offset) * 9
        game[at:at + 8] = bytes((game[at + 8],)) * 8
    if size >= AYS1_AT + 21:
        game[AYS1_AT:AYS1_AT + 21] = b"AYS1" + bytes(range(7, 24))
    if size >= RUL1_AT + 72:
        game[RUL1_AT:RUL1_AT + 8] = b"RUL1" + bytes((1, 0x03, 2, 4))
    if size >= GRX1_AT + 4:
        game[GRX1_AT:GRX1_AT + 4] = b"GRX1"
        # BGX1 with background 2 empty: E, then M1 and M3 only.
        game[BGX1_AT:BGX1_AT + 8] = b"BGX1" + bytes((4, 3, 0xFF, 0))
        image_2 = BGX1_AT + 8 + send_next.BACKGROUND_BYTES
        game[image_2:image_2 + send_next.BACKGROUND_BYTES] = bytes(send_next.BACKGROUND_BYTES)
    if size >= CRD1_AT + 68:
        game[CRD1_AT:CRD1_AT + 68] = b"CRD1" + b"Test Game".ljust(32) + b"Coloured by Someone".ljust(32)
    if size >= OPT1_AT + 256:
        game[OPT1_AT:OPT1_AT + 256] = b"OPT1" + bytes(252)
        game[OPT1_AT + 4] = 1
    return game


class Machine:
    """The dot command on a Z80 with esxDOS and the core's NextREGs faked."""

    def __init__(self, binary: bytes, files: dict[str, bytes], interface_id: int = 0xA1,
                 fail_read: int | None = None) -> None:
        self.files = {name.lower(): data for name, data in files.items()}
        self.interface_id = interface_id
        self.fail_read = fail_read
        self.reads = 0
        self.handles: dict[int, list] = {}
        self.written: dict[str, bytearray] = {}
        self.next_handle = 3
        self.selected = 0
        self.nextregs = {0x07: 0}
        self.nr_writes: list[tuple[int, int]] = []
        self.owned = False
        self.stream = bytearray()
        self.printed = bytearray()
        m = z80.Z80Machine()
        self.m = m
        m.set_memory_block(LOAD_AT, binary)
        m.set_memory_block(RETURN_AT, bytes((0x76,)))
        m.set_output_callback(self.output)
        m.set_input_callback(self.input)
        m.set_breakpoint(0x0008)
        m.set_breakpoint(0x0010)
        m.set_breakpoint(RETURN_AT)

    def output(self, port: int, value: int) -> None:
        if port == 0x243B:
            self.selected = value
        elif port == 0x253B:
            self.nr_writes.append((self.selected, value))
            if self.selected == 0x3F:
                self.owned = bool(value & 1)
            elif self.selected == 0x3E and self.owned:
                self.stream.append(value)
            else:
                self.nextregs[self.selected] = value

    def input(self, port: int) -> int:
        if port == 0x253B:
            if self.selected == 0x3E:
                return self.interface_id
            return self.nextregs.get(self.selected, 0)
        return 0xFF

    def string(self, address: int) -> str:
        out = bytearray()
        while self.m.memory[address]:
            out.append(self.m.memory[address])
            address += 1
        return out.decode()

    def esxdos(self, function: int) -> bool:
        """Answer one call; True for carry (error)."""
        m = self.m
        if function == 0x9A:  # F_OPEN
            name = self.string(m.hl).lower()
            key = name if m.a != ord("$") else "$" + name
            if m.b & 0x02:  # write: create or truncate
                self.written[key] = bytearray()
                handle = self.next_handle
                self.next_handle += 1
                self.handles[handle] = [self.written[key], 0]
                m.a = handle
                return False
            if key not in self.files:
                m.a = 5
                return True
            handle = self.next_handle
            self.next_handle += 1
            self.handles[handle] = [self.files[key], 0]
            m.a = handle
            return False
        entry = self.handles.get(m.a)
        if entry is None:
            return True
        if function == 0xA1:  # F_FSTAT
            stat = bytes(7) + len(entry[0]).to_bytes(4, "little")
            m.set_memory_block(m.hl, stat)
        elif function == 0x9F:  # F_SEEK
            assert m.l == 0
            entry[1] = m.bc << 16 | m.de
        elif function == 0x9D:  # F_READ
            self.reads += 1
            if self.fail_read is not None and self.reads == self.fail_read:
                return True
            data = entry[0][entry[1]:entry[1] + m.bc]
            m.set_memory_block(m.hl, data)
            entry[1] += len(data)
            m.bc = len(data)
        elif function == 0x9E:  # F_WRITE
            data = bytes(m.memory[m.hl:m.hl + m.bc])
            entry[0][entry[1]:entry[1] + len(data)] = data
            entry[1] += len(data)
        elif function == 0x9B:  # F_CLOSE
            del self.handles[m.a]
        else:
            raise AssertionError(f"esxDOS call {function:#x}")
        return False

    def run(self, argument: str) -> tuple[bool, str]:
        m = self.m
        m.set_memory_block(ARGS_AT, argument.encode() + b"\r")
        m.hl = ARGS_AT
        m.pc = LOAD_AT
        m.sp = 0xFF00
        m.sp -= 2
        m.set_memory_block(m.sp, RETURN_AT.to_bytes(2, "little"))
        runs = 0
        while True:
            # run() also returns at the end of each emulated frame.
            runs += 1
            if runs > 200_000:
                raise AssertionError(f"no return after {runs} runs, at {m.pc:#06x}")
            m.ticks_to_stop = 50_000_000
            m.run()
            if m.pc == RETURN_AT:
                break
            if m.pc == 0x0010:
                self.printed.append(m.a)
                m.pc = m.memory[m.sp] | m.memory[m.sp + 1] << 8
                m.sp += 2
                continue
            if m.pc == 0x0008:
                back = m.memory[m.sp] | m.memory[m.sp + 1] << 8
                m.sp += 2
                carry = self.esxdos(m.memory[back])
                m.f = (m.f | 1) if carry else (m.f & ~1)
                m.pc = back + 1
                continue
        message = ""
        if m.f & 1:
            address = m.hl
            while True:
                byte = m.memory[address]
                message += chr(byte & 0x7F)
                address += 1
                if byte & 0x80:
                    break
        return bool(m.f & 1), message


@unittest.skipUnless(shutil.which("sjasmplus"), "sjasmplus is not installed")
@unittest.skipUnless(z80 is not None, "the z80 package is not installed (pip install z80)")
class Spec256DotCommandTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = assemble()
        rng = random.Random(7)
        cls.palette = bytes(rng.randrange(256) for _ in range(512))

    def machine(self, game: bytes, **options) -> Machine:
        files = {"game.256": bytes(game), "spec256.rgb": self.palette}
        files.update(options.pop("files", {}))
        return Machine(self.binary, files, **options)

    def check_clean(self, machine: Machine) -> None:
        self.assertEqual(machine.handles, {}, "a file was left open")
        self.assertFalse(machine.owned, "the loader was left owned")
        self.assertEqual(machine.nextregs[0x07], 0, "the CPU speed was not restored")

    def test_full_game_matches_send_next(self) -> None:
        game = make_game()
        machine = self.machine(game)
        failed, message = machine.run('"game.256"')
        self.assertFalse(failed, message)
        expected = send_next.game_colour_stream(bytes(game), self.palette)
        self.assertTrue(expected.endswith(b"Gb15d"))
        self.assertIn(b"Y", expected[:20])
        self.assertEqual(bytes(machine.stream), expected)
        self.assertIn(b"Test Game", machine.printed)
        self.assertIn(b"Coloured by Someone", machine.printed)
        self.assertIn((0x07, 3), machine.nr_writes)
        self.assertEqual(bytes(machine.written["$/tmp/spec256.z80"]), z80_from_256(bytes(game)))
        self.check_clean(machine)

    def test_48k_game_snapshot(self) -> None:
        game = make_game(seed=10, port_7ffd=0x30)
        machine = self.machine(game)
        failed, message = machine.run('"game.256"')
        self.assertFalse(failed, message)
        self.assertEqual(bytes(machine.stream), send_next.game_colour_stream(bytes(game), self.palette))
        snapshot = bytes(machine.written["$/tmp/spec256.z80"])
        self.assertEqual(snapshot, z80_from_256(bytes(game)))
        self.assertEqual(len(snapshot), 86 + 3 * (3 + 16_384))
        self.check_clean(machine)

    def test_oldest_size_without_blocks(self) -> None:
        game = make_game(seed=2, size=1_179_680)
        machine = self.machine(game)
        failed, message = machine.run("game.256")
        self.assertFalse(failed, message)
        self.assertEqual(bytes(machine.stream), send_next.game_colour_stream(bytes(game), self.palette))
        self.assertEqual(bytes(machine.written["$/tmp/spec256.z80"]), z80_from_256(bytes(game)))
        self.check_clean(machine)

    def test_tagged_blocks_after_opt1(self) -> None:
        game = make_game(seed=3) + b"NXT1" + (5).to_bytes(4, "little") + b"12345"
        machine = self.machine(game)
        failed, message = machine.run('"game.256"')
        self.assertFalse(failed, message)
        self.assertEqual(bytes(machine.stream), send_next.game_colour_stream(bytes(game), self.palette))
        cut = make_game(seed=3) + b"NXT1" + (9).to_bytes(4, "little") + b"1234"
        machine = self.machine(cut)
        failed, message = machine.run('"game.256"')
        self.assertTrue(failed)
        self.assertEqual(message, ".256 block cut short")
        self.assertEqual(machine.stream, b"")
        self.check_clean(machine)

    def test_newer_level_is_refused(self) -> None:
        game = make_game(seed=4)
        game[OPT1_AT + 4] = 2
        machine = self.machine(game)
        failed, message = machine.run('"game.256"')
        self.assertTrue(failed)
        self.assertEqual(message, "Needs a newer Spec256 core")
        self.assertEqual(machine.stream, b"")
        self.check_clean(machine)

    def test_core_without_the_interface(self) -> None:
        machine = self.machine(make_game(seed=5), interface_id=0)
        failed, message = machine.run('"game.256"')
        self.assertTrue(failed)
        self.assertEqual(message, "No Spec256 core")
        self.assertEqual(machine.nr_writes, [])

    def test_missing_palette(self) -> None:
        machine = Machine(self.binary, {"game.256": bytes(make_game(seed=6))})
        failed, message = machine.run('"game.256"')
        self.assertTrue(failed)
        self.assertEqual(message, "SPEC256.RGB not found")
        self.assertEqual(machine.stream, b"")
        self.check_clean(machine)

    def test_system_palette(self) -> None:
        game = make_game(seed=8)
        machine = Machine(self.binary, {"game.256": bytes(game), "$/dot/spec256.rgb": self.palette})
        failed, message = machine.run('"game.256"')
        self.assertFalse(failed, message)
        self.assertEqual(bytes(machine.stream), send_next.game_colour_stream(bytes(game), self.palette))

    def test_read_failure_aborts_the_loader(self) -> None:
        machine = self.machine(make_game(seed=9), fail_read=40)
        failed, message = machine.run('"game.256"')
        self.assertTrue(failed)
        self.assertEqual(message, ".256 read error")
        self.assertTrue(machine.stream.startswith(b"HS1U"))
        self.assertEqual(machine.stream[-1:], b"H")
        self.assertIn((0x3F, 0x81), machine.nr_writes[-4:])
        self.check_clean(machine)


if __name__ == "__main__":
    unittest.main()
