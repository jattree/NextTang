"""The imported Z80 must actually execute the project's diagnostic boot ROM.

Importing a CPU core is not the same as having a working CPU. This drives the
imported T80Na against the project's own boot firmware and the memory it writes
to, and checks the machine reaches states only correct execution can produce.
It deliberately asserts on observable behaviour, the bus cycles and the bytes
that land in display memory, rather than on internal CPU signals.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CPU_SOURCES = [
    REPO_ROOT / "rtl" / "cpu" / "t80n_pack.vhd",
    REPO_ROOT / "rtl" / "cpu" / "t80n_alu.vhd",
    REPO_ROOT / "rtl" / "cpu" / "t80n_mcode.vhd",
    REPO_ROOT / "rtl" / "cpu" / "t80n.vhd",
    REPO_ROOT / "rtl" / "cpu" / "t80na.vhd",
]
BOOTROM = REPO_ROOT / "rtl" / "core" / "nexttang_diagnostic_bootrom.vhd"


# A minimal machine: the CPU, the project's boot ROM at 0x0000, and RAM
# covering the display area the firmware writes to. No DDR3, no ULA, nothing
# that is not needed to prove the processor runs.
HARNESS = r"""
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity testbench is
end entity;

architecture sim of testbench is
    signal clock     : std_logic := '0';
    signal reset_n   : std_logic := '0';
    signal address   : std_logic_vector(15 downto 0);
    signal data_in   : std_logic_vector(7 downto 0) := (others => '0');
    signal data_out  : std_logic_vector(7 downto 0);
    signal mreq_n    : std_logic;
    signal iorq_n    : std_logic;
    signal rd_n      : std_logic;
    signal wr_n      : std_logic;
    signal m1_n      : std_logic;
    signal halt_n    : std_logic;
    signal rfsh_n    : std_logic;

    signal rom_data  : std_logic_vector(7 downto 0);

    -- Display memory, 0x4000 to 0x5AFF, which is what the firmware fills.
    type ram_type is array (0 to 16#1B00# - 1) of std_logic_vector(7 downto 0);
    signal display_ram : ram_type := (others => (others => '0'));

    -- The 16 KiB window at 0x8000 that the diagnostic write/read-back tests.
    -- Without it the firmware always reports a memory fault, so the liveness
    -- half of the diagnostic would never be reached.
    type work_ram_type is array (0 to 16#4000# - 1) of std_logic_vector(7 downto 0);
    signal work_ram : work_ram_type := (others => (others => '0'));
    constant FAULTY_RAM : boolean := FAULT_INJECT;

    function in_work_ram(a : std_logic_vector(15 downto 0)) return boolean is
    begin
        return unsigned(a) >= 16#8000# and unsigned(a) < 16#C000#;
    end function;

    signal writes_seen   : natural := 0;
    signal attribute_writes : natural := 0;
    signal io_writes     : natural := 0;
    signal opcode_fetches : natural := 0;
    signal finished      : boolean := false;

    function in_display(a : std_logic_vector(15 downto 0)) return boolean is
    begin
        return unsigned(a) >= 16#4000# and unsigned(a) < 16#5B00#;
    end function;
begin
    clock <= not clock after 142 ns when not finished else '0';   -- ~3.5 MHz
    RESET_DRIVE

    cpu : entity work.T80Na
        generic map (Mode => 0)
        port map (
            RESET_n => reset_n, CLK_n => clock, WAIT_n => '1',
            INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
            M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n,
            RD_n => rd_n, WR_n => wr_n, RFSH_n => rfsh_n,
            HALT_n => halt_n, BUSAK_n => open,
            A => address, D_i => data_in, D_o => data_out,
            Z80N_dout_o => open, Z80N_data_o => open, Z80N_command_o => open
        );

    rom : entity work.bootrom
        port map (CLK => clock, ADDR => address(12 downto 0), DATA => rom_data);

    -- Reads: boot ROM low, display RAM in its window, 0xFF elsewhere.
    process (all)
    begin
        if in_display(address) then
            data_in <= display_ram(to_integer(unsigned(address)) - 16#4000#);
        elsif in_work_ram(address) then
            data_in <= work_ram(to_integer(unsigned(address)) - 16#8000#);
        elsif unsigned(address) < 16#2000# then
            data_in <= rom_data;
        else
            data_in <= (others => '1');
        end if;
    end process;

    process (clock)
    begin
        if rising_edge(clock) then
            if mreq_n = '0' and wr_n = '0' and in_display(address) then
                display_ram(to_integer(unsigned(address)) - 16#4000#) <= data_out;
                writes_seen <= writes_seen + 1;
                if unsigned(address) >= 16#5800# then
                    attribute_writes <= attribute_writes + 1;
                end if;
            end if;
            if mreq_n = '0' and wr_n = '0' and in_work_ram(address) then
                -- Fault injection corrupts one byte, which is what a real
                -- memory fault looks like to the firmware: everything else
                -- verifies and one location does not.
                if FAULTY_RAM and unsigned(address) = 16#8100# then
                    work_ram(to_integer(unsigned(address)) - 16#8000#) <= x"00";
                else
                    work_ram(to_integer(unsigned(address)) - 16#8000#) <= data_out;
                end if;
            end if;
            if iorq_n = '0' and wr_n = '0' then
                io_writes <= io_writes + 1;
            end if;
            if m1_n = '0' and mreq_n = '0' and rfsh_n = '1' then
                opcode_fetches <= opcode_fetches + 1;
            end if;
        end if;
    end process;

    stimulus : process
    begin
        wait for DURATION;
        finished <= true;

        report "opcode_fetches=" & integer'image(opcode_fetches);
        report "display_writes=" & integer'image(writes_seen);
        report "io_writes=" & integer'image(io_writes);
        report "attribute_writes=" & integer'image(attribute_writes);

        CHECKS
        wait;
    end process;
end architecture;
"""


class CpuExecutesBootRomTest(unittest.TestCase):
    def run_simulation(self, checks: str, duration: str = "900 ms",
                       hold_reset: bool = False, faulty_ram: bool = False) -> str:
        source = (HARNESS
                  .replace("CHECKS", checks)
                  .replace("DURATION", duration)
                  .replace("FAULT_INJECT", "true" if faulty_ram else "false")
                  .replace("RESET_DRIVE",
                           "reset_n <= '0';" if hold_reset
                           else "reset_n <= '0', '1' after 1 us;"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "testbench.vhd").write_text(source, encoding="utf-8")
            analyse = ["ghdl", "-a", "--std=08", "-frelaxed"]
            analyse += [str(f) for f in CPU_SOURCES] + [str(BOOTROM),
                                                        str(path / "testbench.vhd")]
            for command in (
                analyse,
                ["ghdl", "-e", "--std=08", "-frelaxed", "testbench"],
                ["ghdl", "-r", "--std=08", "testbench", "--assert-level=error"],
            ):
                result = subprocess.run(command, cwd=path, check=False,
                                        capture_output=True, text=True)
                if result.returncode:
                    raise AssertionError(
                        f"{' '.join(command[:3])} failed:\n"
                        f"{result.stdout}\n{result.stderr}")
            return result.stdout + result.stderr

    def test_the_cpu_runs_the_whole_diagnostic(self) -> None:
        """One simulation, every claim checked, because each run costs a minute.

        Together these say: the processor executes from ROM, computes the
        pattern and places it through the Spectrum's interleaved layout, drives
        I/O separately from memory, passes a 16 KiB write and read-back, and
        keeps looping afterwards. The specific screen offsets are derived from
        the layout rather than from a previous run, so they would catch address
        arithmetic that is wrong in a self-consistent way.
        """
        output = self.run_simulation(
            'assert opcode_fetches > 100000 '
            'report "CPU is not executing from ROM" severity error;\n'
            '        assert io_writes > 0 '
            'report "no I/O write; OUT (0xfe),A did not execute" severity error;\n'
            '        assert attribute_writes > 1000 '
            'report "attributes not cycled; memory check failed or CPU stalled" '
            'severity error;\n'
            '        assert writes_seen > 6144 '
            'report "no writes beyond the bitmap; diagnostic did not complete" '
            'severity error;\n'
            '        assert display_ram(0) = x"00" report "origin: offset 0x0000 wrong" severity error;\n        assert display_ram(5) = x"05" report "column offset within a row: offset 0x0005 wrong" severity error;\n        assert display_ram(256) = x"01" report "pixel row field, y and 0x07: offset 0x0100 wrong" severity error;\n        assert display_ram(291) = x"0a" report "character row field, y and 0x38: offset 0x0123 wrong" severity error;\n        assert display_ram(2055) = x"47" report "screen third field, y and 0xc0: offset 0x0807 wrong" severity error;\n        assert display_ram(6143) = x"a0" report "last byte of the bitmap: offset 0x17ff wrong" severity error;'
        )
        self.assertIn("opcode_fetches=", output)
        self.assertIn("attribute_writes=", output)

    def test_a_memory_fault_reaches_the_failure_screen(self) -> None:
        """A corrupted byte must produce the distinct failure display.

        This replaces coverage that previously came from a hand-written partial
        Z80 interpreter in test_diagnostic_boot. Running it on the real core
        exercises the same branch without a second, weaker model of the CPU.
        """
        output = self.run_simulation(
            'assert attribute_writes > 0 '
            'report "firmware never wrote attributes at all" severity error;\n'
            '        assert display_ram(16#1800#) = x"42" '
            'report "failure screen did not set bright red on black" '
            'severity error;\n'
            '        assert display_ram(0) = x"ff" '
            'report "failure screen did not fill the bitmap" severity error;',
            duration="600 ms", faulty_ram=True)
        self.assertIn("display_writes=", output)

    def test_the_checks_fail_when_the_cpu_is_held_in_reset(self) -> None:
        # A green test that cannot fail is worth nothing. With RESET_n held low
        # the processor fetches nothing, and the same assertion must fire.
        with self.assertRaises(AssertionError) as raised:
            self.run_simulation(
                'assert opcode_fetches > 100000 '
                'report "CPU is not executing from ROM" severity error;',
                duration="20 ms", hold_reset=True)
        self.assertIn("opcode_fetches=0", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
