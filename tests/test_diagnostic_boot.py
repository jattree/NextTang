"""Reproducibility and behavioural tests for the open diagnostic boot ROM."""

from importlib import util
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
ASSEMBLY = REPO_ROOT / "firmware" / "diagnostic" / "boot.asm"
BUILDER = REPO_ROOT / "scripts" / "build_diagnostic_boot.py"
BOOTROM = REPO_ROOT / "rtl" / "core" / "nexttang_diagnostic_bootrom.vhd"

SPEC = util.spec_from_file_location("build_diagnostic_boot", BUILDER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load diagnostic boot builder")
BUILDER_MODULE = util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER_MODULE)


def committed_image() -> bytes:
    image = bytearray([0xFF] * 8192)
    for address, value in re.findall(
        r'^\s*(\d+) => x"([0-9a-f]{2})",$',
        BOOTROM.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    ):
        image[int(address)] = int(value, 16)
    return bytes(image)


def run_diagnostic(image: bytes, corrupt_memory: bool = False) -> tuple:
    memory = bytearray(65536)
    ports = []
    registers = {"a": 0, "b": 0, "c": 0, "d": 0, "h": 0, "l": 0, "sp": 0}
    program_counter = 0
    zero = False
    corruption_done = False

    def fetch_byte() -> int:
        nonlocal program_counter
        value = image[program_counter]
        program_counter = (program_counter + 1) & 0xFFFF
        return value

    def fetch_word() -> int:
        low = fetch_byte()
        return low | (fetch_byte() << 8)

    def hl() -> int:
        return (registers["h"] << 8) | registers["l"]

    def set_hl(value: int) -> None:
        registers["h"] = (value >> 8) & 0xFF
        registers["l"] = value & 0xFF

    def bc() -> int:
        return (registers["b"] << 8) | registers["c"]

    def set_bc(value: int) -> None:
        registers["b"] = (value >> 8) & 0xFF
        registers["c"] = value & 0xFF

    for step in range(500_000):
        if corrupt_memory and program_counter == 68 and not corruption_done:
            memory[0x8123] ^= 0x01
            corruption_done = True

        opcode = fetch_byte()
        if opcode == 0xF3:  # DI
            pass
        elif opcode == 0x31:  # LD SP,nn
            registers["sp"] = fetch_word()
        elif opcode == 0xAF:  # XOR A
            registers["a"] = 0
            zero = True
        elif opcode == 0xD3:  # OUT (n),A
            ports.append((fetch_byte(), registers["a"]))
        elif opcode == 0x21:  # LD HL,nn
            set_hl(fetch_word())
        elif opcode == 0x01:  # LD BC,nn
            set_bc(fetch_word())
        elif opcode == 0x16:  # LD D,n
            registers["d"] = fetch_byte()
        elif opcode == 0x7A:  # LD A,D
            registers["a"] = registers["d"]
        elif opcode == 0x77:  # LD (HL),A
            memory[hl()] = registers["a"]
        elif opcode == 0x2F:  # CPL
            registers["a"] ^= 0xFF
        elif opcode == 0x57:  # LD D,A
            registers["d"] = registers["a"]
        elif opcode == 0x23:  # INC HL
            set_hl((hl() + 1) & 0xFFFF)
        elif opcode == 0x0B:  # DEC BC
            set_bc((bc() - 1) & 0xFFFF)
        elif opcode == 0x78:  # LD A,B
            registers["a"] = registers["b"]
        elif opcode == 0xB1:  # OR C
            registers["a"] |= registers["c"]
            zero = registers["a"] == 0
        elif opcode == 0x20:  # JR NZ,e
            displacement = fetch_byte()
            if not zero:
                program_counter = (
                    program_counter
                    + (displacement if displacement < 0x80 else displacement - 0x100)
                ) & 0xFFFF
        elif opcode == 0x14:  # INC D
            registers["d"] = (registers["d"] + 1) & 0xFF
        elif opcode == 0x7E:  # LD A,(HL)
            registers["a"] = memory[hl()]
        elif opcode == 0xBA:  # CP D
            zero = registers["a"] == registers["d"]
        elif opcode == 0x3E:  # LD A,n
            registers["a"] = fetch_byte()
        elif opcode == 0x18:  # JR e
            displacement = fetch_byte()
            program_counter = (
                program_counter
                + (displacement if displacement < 0x80 else displacement - 0x100)
            ) & 0xFFFF
        else:
            raise AssertionError(
                f"unsupported diagnostic opcode 0x{opcode:02x} at "
                f"0x{(program_counter - 1) & 0xffff:04x}"
            )

        if ports and ((program_counter == 85 and ports[-1][1] == 4) or
                      (program_counter == 87 and ports[-1][1] == 2)):
            return memory, ports, program_counter, step + 1

    raise AssertionError("diagnostic did not reach a stable pass or failure loop")


class DiagnosticBootTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("sjasmplus"), "sjasmplus is not installed")
    def test_committed_rom_reproduces_from_assembly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "bootrom.vhd"
            result = subprocess.run(
                [
                    sys.executable,
                    str(BUILDER),
                    "--source",
                    str(ASSEMBLY),
                    "--output",
                    str(output),
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(output.read_bytes(), BOOTROM.read_bytes())

    def test_builder_rejects_assembler_failure_and_wrong_size(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "diagnostic assembly failed"):
            BUILDER_MODULE.assemble("/bin/false", ASSEMBLY)

        with tempfile.TemporaryDirectory() as temporary_directory:
            fake_assembler = Path(temporary_directory) / "fake_assembler.py"
            fake_assembler.write_text(
                """#!/usr/bin/env python3
import pathlib
import sys
output = next(value[6:] for value in sys.argv if value.startswith('--raw='))
pathlib.Path(output).write_bytes(b'bad')
""",
                encoding="utf-8",
            )
            fake_assembler.chmod(0o755)
            with self.assertRaisesRegex(ValueError, "3 bytes; expected 8192"):
                BUILDER_MODULE.assemble(str(fake_assembler), ASSEMBLY)

        with self.assertRaisesRegex(ValueError, "8191 bytes; expected 8192"):
            BUILDER_MODULE.render_vhdl(bytes(8191), ASSEMBLY)

    def test_bootrom_reads_are_synchronous_and_padded(self) -> None:
        testbench = r"""
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity testbench is end entity;

architecture test of testbench is
    signal clock : std_logic := '0';
    signal address : std_logic_vector(12 downto 0) := (others => '0');
    signal data : std_logic_vector(7 downto 0);
begin
    clock <= not clock after 5 ns;

    dut : entity work.bootrom
        port map (CLK => clock, ADDR => address, DATA => data);

    stimulus : process
    begin
        wait until rising_edge(clock);
        wait for 1 ns;
        assert data = x"f3" report "reset opcode was not DI" severity failure;

        address <= std_logic_vector(to_unsigned(1, address'length));
        wait for 2 ns;
        assert data = x"f3" report "ROM output changed without a clock" severity failure;
        wait until rising_edge(clock);
        wait for 1 ns;
        assert data = x"31" report "stack-load opcode was missing" severity failure;

        address <= std_logic_vector(to_unsigned(2, address'length));
        wait until rising_edge(clock);
        wait for 1 ns;
        assert data = x"ff" report "embedded immediate byte was wrong" severity failure;

        address <= std_logic_vector(to_unsigned(8160, address'length));
        wait until rising_edge(clock);
        wait for 1 ns;
        assert data = x"4e" report "diagnostic signature was missing" severity failure;

        address <= std_logic_vector(to_unsigned(8175, address'length));
        wait until rising_edge(clock);
        wait for 1 ns;
        assert data = x"00" report "signature terminator was missing" severity failure;

        address <= std_logic_vector(to_unsigned(8176, address'length));
        wait until rising_edge(clock);
        wait for 1 ns;
        assert data = x"ff" report "unused ROM was not padded" severity failure;

        report "DIAGNOSTIC_BOOTROM_PASS" severity note;
        std.env.finish;
        wait;
    end process;
end architecture;
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.vhd"
            testbench_path.write_text(testbench, encoding="utf-8")
            for command in (
                ["ghdl", "-a", "--std=08", str(BOOTROM), str(testbench_path)],
                ["ghdl", "-e", "--std=08", "testbench"],
                [
                    "ghdl",
                    "-r",
                    "--std=08",
                    "testbench",
                    "--assert-level=error",
                ],
            ):
                result = subprocess.run(
                    command,
                    cwd=temporary_path,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DIAGNOSTIC_BOOTROM_PASS", result.stdout)

    def test_machine_code_reaches_visual_pass_state(self) -> None:
        memory, ports, program_counter, steps = run_diagnostic(committed_image())
        self.assertEqual(ports, [(0xFE, 0), (0xFE, 4)])
        self.assertEqual(program_counter, 85)
        self.assertLess(steps, 500_000)
        self.assertEqual(memory[0x4000:0x4004], bytes([0xAA, 0x55, 0xAA, 0x55]))
        self.assertEqual(memory[0x5800:0x5804], bytes([0x47, 0x48, 0x49, 0x4A]))
        self.assertEqual(memory[0x8000:0x8004], bytes([0x5A, 0xA5, 0x5A, 0xA5]))
        self.assertEqual(memory[0xBFFC:0xC000], bytes([0x5A, 0xA5, 0x5A, 0xA5]))

    def test_machine_code_leaves_red_border_after_readback_failure(self) -> None:
        _, ports, program_counter, steps = run_diagnostic(
            committed_image(), corrupt_memory=True
        )
        self.assertEqual(ports, [(0xFE, 0), (0xFE, 2)])
        self.assertEqual(program_counter, 87)
        self.assertLess(steps, 500_000)


if __name__ == "__main__":
    unittest.main()
