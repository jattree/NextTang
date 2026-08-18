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

    signal writes_seen   : natural := 0;
    signal io_writes     : natural := 0;
    signal opcode_fetches : natural := 0;
    signal finished      : boolean := false;

    function in_display(a : std_logic_vector(15 downto 0)) return boolean is
    begin
        return unsigned(a) >= 16#4000# and unsigned(a) < 16#5B00#;
    end function;
begin
    clock <= not clock after 142 ns when not finished else '0';   -- ~3.5 MHz
    reset_n <= '0', '1' after 1 us;

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
        wait for 200 ms;
        finished <= true;

        report "opcode_fetches=" & integer'image(opcode_fetches);
        report "display_writes=" & integer'image(writes_seen);
        report "io_writes=" & integer'image(io_writes);

        CHECKS
        wait;
    end process;
end architecture;
"""


class CpuExecutesBootRomTest(unittest.TestCase):
    def run_simulation(self, checks: str) -> str:
        source = HARNESS.replace("CHECKS", checks)
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

    def test_the_cpu_fetches_and_executes_from_the_boot_rom(self) -> None:
        # Opcode fetches prove the processor is running code from the ROM
        # rather than sitting in reset or spinning on a bus fault.
        output = self.run_simulation(
            'assert opcode_fetches > 100\n'
            '    report "CPU did not fetch opcodes; it is not executing"\n'
            '    severity error;'
        )
        self.assertIn("opcode_fetches=", output)

    def test_the_firmware_writes_the_display_pattern(self) -> None:
        # The firmware fills 0x4000 upward with an alternating byte pattern.
        # Reaching those writes means the CPU executed a loop with arithmetic,
        # memory addressing and conditional branching correctly.
        output = self.run_simulation(
            'assert writes_seen > 100\n'
            '    report "no display writes; the firmware loop did not run"\n'
            '    severity error;\n'
            '        assert display_ram(0) = x"aa" or display_ram(0) = x"55"\n'
            '            report "first display byte is neither aa nor 55"\n'
            '            severity error;\n'
            '        assert display_ram(1) /= display_ram(0)\n'
            '            report "pattern does not alternate between adjacent bytes"\n'
            '            severity error;'
        )
        self.assertIn("display_writes=", output)

    def test_the_border_is_set_through_an_io_write(self) -> None:
        # The firmware starts with OUT (0xFE),A. An I/O write proves the CPU
        # drives IORQ separately from MREQ, which a memory-only test misses.
        self.run_simulation(
            'assert io_writes > 0\n'
            '    report "no I/O write; OUT (0xfe),A did not execute"\n'
            '    severity error;'
        )


if __name__ == "__main__":
    unittest.main()
