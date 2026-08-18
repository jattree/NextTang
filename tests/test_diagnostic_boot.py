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


if __name__ == "__main__":
    unittest.main()
