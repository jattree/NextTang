"""The imported Z80 must boot a real 48K machine ROM.

Our own diagnostic firmware can only prove the processor does what we asked for.
A machine ROM was written against hardware, so booting one tests the memory map,
the frame interrupt and the screen layout against something that does not know
we exist. The ROM sets every attribute to 0x38 when it clears the screen and
then writes its copyright line, so those bytes landing in the right places is
evidence the whole path works.

The ROM is not redistributable and is not in this repository. Point
NEXTTANG_48K_ROM at one to run this; without it the test skips.
"""

from pathlib import Path
import os
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

ROM_ENVIRONMENT = "NEXTTANG_48K_ROM"


HARNESS = r"""
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity testbench is
end entity;

architecture sim of testbench is
    signal clock    : std_logic := '0';
    signal reset_n  : std_logic := '0';
    signal address  : std_logic_vector(15 downto 0);
    signal data_in  : std_logic_vector(7 downto 0) := (others => '0');
    signal data_out : std_logic_vector(7 downto 0);
    signal mreq_n, iorq_n, rd_n, wr_n, m1_n, halt_n, rfsh_n : std_logic;
    signal interrupt_n : std_logic := '1';

    type rom_type is array (0 to 16#4000# - 1) of std_logic_vector(7 downto 0);

    -- The image is read as hex text because VHDL has no portable way to read a
    -- binary file byte by byte.
    impure function load_rom(name : string) return rom_type is
        file source     : text;
        variable status : file_open_status;
        variable row    : line;
        variable value  : integer;
        variable image  : rom_type := (others => (others => '0'));
    begin
        file_open(status, source, name, read_mode);
        assert status = open_ok report "cannot open ROM image" severity failure;
        for index in image'range loop
            exit when endfile(source);
            readline(source, row);
            hread(row, image(index));
        end loop;
        file_close(source);
        return image;
    end function;

    constant rom : rom_type := load_rom("ROM_IMAGE");

    -- RAM from 0x4000 to the top. The ROM sizes memory itself, so it has to be
    -- really there or the machine reports 16K and takes a different path.
    type ram_type is array (0 to 16#C000# - 1) of std_logic_vector(7 downto 0);
    signal ram : ram_type := (others => (others => '0'));

    signal opcode_fetches : natural := 0;
    signal fetch_active   : boolean := false;
    signal halts          : natural := 0;
    signal screen_writes  : natural := 0;
    signal border_writes  : natural := 0;
    signal finished       : boolean := false;

    function is_ram(a : std_logic_vector(15 downto 0)) return boolean is
    begin
        return unsigned(a) >= 16#4000#;
    end function;
begin
    clock <= not clock after 142 ns when not finished else '0';   -- ~3.5 MHz

    reset : process
    begin
        reset_n <= '0';
        wait for 2 us;
        reset_n <= '1';
        wait;
    end process;

    -- A 48K frame is 69888 cycles and the line was held low for 32 of them.
    interrupt : process
    begin
        while not finished loop
            interrupt_n <= '1';
            for i in 1 to 69888 - 32 loop
                wait until rising_edge(clock);
            end loop;
            interrupt_n <= '0';
            for i in 1 to 32 loop
                wait until rising_edge(clock);
            end loop;
        end loop;
        wait;
    end process;

    cpu : entity work.T80Na
        generic map (Mode => 0)
        port map (
            RESET_n => reset_n, CLK_n => clock, WAIT_n => '1',
            INT_n => interrupt_n, NMI_n => '1', BUSRQ_n => '1',
            M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n,
            RD_n => rd_n, WR_n => wr_n, RFSH_n => rfsh_n,
            HALT_n => halt_n, BUSAK_n => open,
            A => address, D_i => data_in, D_o => data_out,
            Z80N_dout_o => open, Z80N_data_o => open, Z80N_command_o => open
        );

    process (all)
    begin
        if iorq_n = '0' then
            if address(0) = '0' then
                data_in <= x"bf";           -- no keys, tape input low
            else
                data_in <= x"ff";
            end if;
        elsif is_ram(address) then
            data_in <= ram(to_integer(unsigned(address)) - 16#4000#);
        else
            data_in <= rom(to_integer(unsigned(address)));
        end if;
    end process;

    process (clock)
    begin
        if rising_edge(clock) then
            if mreq_n = '0' and wr_n = '0' and is_ram(address) then
                ram(to_integer(unsigned(address)) - 16#4000#) <= data_out;
                if unsigned(address) < 16#5B00# then
                    screen_writes <= screen_writes + 1;
                end if;
            end if;
            if iorq_n = '0' and wr_n = '0' and address(0) = '0' then
                border_writes <= border_writes + 1;
            end if;
            -- An opcode fetch holds these low for several cycles, so count
            -- the transition rather than the level or every fetch is counted
            -- four times and the previous address is overwritten by itself.
            if m1_n = '0' and mreq_n = '0' and rfsh_n = '1' then
                if not fetch_active then
                    fetch_active <= true;
                    opcode_fetches <= opcode_fetches + 1;
                end if;
            else
                fetch_active <= false;
            end if;
            if halt_n = '0' then
                halts <= halts + 1;
            end if;
        end if;
    end process;

    stimulus : process
        variable attributes_set : natural := 0;
        variable bitmap_set     : natural := 0;
    begin
        wait for DURATION;
        finished <= true;
        wait for 1 us;

        for index in 16#1800# to 16#1AFF# loop
            if ram(index) = x"38" then
                attributes_set := attributes_set + 1;
            end if;
        end loop;
        for index in 0 to 16#17FF# loop
            if ram(index) /= x"00" then
                bitmap_set := bitmap_set + 1;
            end if;
        end loop;

        report "halt_cycles=" & integer'image(halts);
        report "opcode_fetches=" & integer'image(opcode_fetches);
        report "screen_writes=" & integer'image(screen_writes);
        report "border_writes=" & integer'image(border_writes);
        report "attributes_at_38=" & integer'image(attributes_set);
        report "bitmap_bytes_set=" & integer'image(bitmap_set);

        CHECKS
        wait;
    end process;
end architecture;
"""


def rom_path() -> Path | None:
    configured = os.environ.get(ROM_ENVIRONMENT)
    if not configured:
        return None
    path = Path(configured)
    return path if path.is_file() else None


class Spectrum48BootTest(unittest.TestCase):
    def run_boot(self, checks: str, duration: str) -> str:
        source = rom_path()
        if source is None:
            self.skipTest(f"set {ROM_ENVIRONMENT} to a 48K ROM image to run this")

        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            image = work / "rom.hex"
            convert = subprocess.run(
                ["python3", str(REPO_ROOT / "scripts" / "rom_to_mem.py"),
                 str(source), str(image), "--expect-bytes", "16384"],
                capture_output=True, text=True, check=False)
            if convert.returncode:
                raise AssertionError(convert.stderr)

            body = (HARNESS
                    .replace("ROM_IMAGE", str(image))
                    .replace("DURATION", duration)
                    .replace("CHECKS", checks))
            (work / "testbench.vhd").write_text(body, encoding="utf-8")

            for vhdl in CPU_SOURCES + [work / "testbench.vhd"]:
                analyse = subprocess.run(
                    ["ghdl", "-a", "--std=08", f"--workdir={work}", str(vhdl)],
                    capture_output=True, text=True, check=False)
                if analyse.returncode:
                    raise AssertionError(f"{vhdl.name}: {analyse.stderr}")

            run = subprocess.run(
                ["ghdl", "-r", "--std=08", f"--workdir={work}", "testbench"],
                capture_output=True, text=True, check=False, cwd=work)
            output = run.stdout + run.stderr
            if run.returncode:
                raise AssertionError(output)
            return output

    def test_the_rom_clears_the_screen_and_draws(self) -> None:
        # Clearing the screen sets all 768 attributes to 0x38, black ink on
        # white paper. That the ROM got that far means it sized memory, set up
        # its system variables and addressed the screen correctly.
        output = self.run_boot("""
        assert attributes_set = 768
            report "expected all 768 attributes at 0x38, got "
                   & integer'image(attributes_set) severity failure;
        assert bitmap_set > 0
            report "nothing was drawn into the bitmap" severity failure;
        assert border_writes > 0
            report "the ROM never set the border" severity failure;
        """, duration="3000 ms")
        self.assertIn("attributes_at_38=768", output)


if __name__ == "__main__":
    unittest.main()
