"""Behavioural tests for the portable RAM entities used by the ZXNext core."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
DPRAM_RTL = REPO_ROOT / "rtl" / "core" / "memory" / "nexttang_dpram2.vhd"
SDPRAM_RTL = REPO_ROOT / "rtl" / "core" / "memory" / "nexttang_sdpram.vhd"


class CoreRamTest(unittest.TestCase):
    def run_ghdl(self, testbench: str) -> str:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.vhd"
            testbench_path.write_text(testbench, encoding="utf-8")

            for command in (
                [
                    "ghdl", "-a", "--std=08", str(DPRAM_RTL),
                    str(SDPRAM_RTL), str(testbench_path),
                ],
                ["ghdl", "-e", "--std=08", "testbench"],
                [
                    "ghdl", "-r", "--std=08", "testbench",
                    "--assert-level=error",
                ],
            ):
                result = subprocess.run(
                    command,
                    cwd=temporary_path,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def run_ghdl_expect_failure(self, testbench: str, expected: str) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.vhd"
            testbench_path.write_text(testbench, encoding="utf-8")
            for command in (
                [
                    "ghdl", "-a", "--std=08", str(DPRAM_RTL),
                    str(SDPRAM_RTL), str(testbench_path),
                ],
                ["ghdl", "-e", "--std=08", "testbench"],
            ):
                result = subprocess.run(
                    command,
                    cwd=temporary_path,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run(
                [
                    "ghdl", "-r", "--std=08", "testbench",
                    "--assert-level=error",
                ],
                cwd=temporary_path,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stdout + result.stderr)

    def test_synchronous_dual_port_read_first_behaviour(self) -> None:
        output = self.run_ghdl(
            r"""
library ieee;
use ieee.std_logic_1164.all;

entity testbench is end entity;

architecture test of testbench is
    signal clock_a : std_logic := '0';
    signal write_a : std_logic := '0';
    signal address_a : std_logic_vector(3 downto 0) := (others => '0');
    signal input_a : std_logic_vector(7 downto 0) := (others => '0');
    signal output_a : std_logic_vector(7 downto 0);
    signal clock_b : std_logic := '0';
    signal address_b : std_logic_vector(3 downto 0) := (others => '0');
    signal output_b : std_logic_vector(7 downto 0);
begin
    clock_a <= not clock_a after 5 ns;
    clock_b <= not clock_b after 7 ns;

    dut : entity work.dpram2
        generic map (addr_width_g => 4, data_width_g => 8)
        port map (
            clk_a_i => clock_a, we_i => write_a, addr_a_i => address_a,
            data_a_i => input_a, data_a_o => output_a,
            clk_b_i => clock_b, addr_b_i => address_b, data_b_o => output_b
        );

    stimulus : process
    begin
        wait until rising_edge(clock_a);
        wait for 1 ns;
        assert output_a = x"00" report "blank port A was not zero" severity failure;

        address_a <= x"3";
        input_a <= x"a5";
        write_a <= '1';
        wait until rising_edge(clock_a);
        wait for 1 ns;
        assert output_a = x"00" report "port A was not read-first" severity failure;

        write_a <= '0';
        wait until rising_edge(clock_a);
        wait for 1 ns;
        assert output_a = x"a5" report "port A did not return stored data" severity failure;

        address_b <= x"3";
        wait until rising_edge(clock_b);
        wait for 1 ns;
        assert output_b = x"a5" report "port B did not return stored data" severity failure;

        address_b <= x"4";
        wait for 2 ns;
        assert output_b = x"a5" report "port B read changed without its clock" severity failure;
        wait until rising_edge(clock_b);
        wait for 1 ns;
        assert output_b = x"00" report "port B did not capture its new address" severity failure;

        report "CORE_DPRAM_PASS" severity note;
        std.env.finish;
        wait;
    end process;
end architecture;
"""
        )
        self.assertIn("CORE_DPRAM_PASS", output)

    def test_asynchronous_read_and_fixed_core_wrappers(self) -> None:
        output = self.run_ghdl(
            r"""
library ieee;
use ieee.std_logic_1164.all;

entity testbench is end entity;

architecture test of testbench is
    signal clock : std_logic := '0';
    signal write_enable : std_logic := '0';
    signal write_address : std_logic_vector(3 downto 0) := (others => '0');
    signal read_address : std_logic_vector(3 downto 0) := (others => '0');
    signal write_data : std_logic_vector(8 downto 0) := (others => '0');
    signal read_data : std_logic_vector(8 downto 0);

    signal address_128 : std_logic_vector(6 downto 0) := (others => '0');
    signal data_128 : std_logic_vector(7 downto 0);
    signal address_320 : std_logic_vector(8 downto 0) := (others => '0');
    signal data_320 : std_logic_vector(8 downto 0);
    signal address_64 : std_logic_vector(5 downto 0) := (others => '0');
    signal data_64 : std_logic_vector(8 downto 0);
begin
    clock <= not clock after 5 ns;

    generic_ram : entity work.sdpram
        generic map (addr_width_g => 4, data_width_g => 9)
        port map (
            clk_a_i => clock, we_a_i => write_enable,
            addr_a_i => write_address, data_a_i => write_data,
            addr_b_i => read_address, data_b_o => read_data
        );

    wrapper_128 : entity work.sdpram_128_8
        port map (
            DPRA => address_128, DPO => data_128, CLK => clock,
            WE => '0', A => address_128, D => (others => '0')
        );
    wrapper_320 : entity work.spram_320_9
        port map (
            CLK => clock, WE => '0', SPO => data_320,
            A => address_320, D => (others => '0')
        );
    wrapper_16 : entity work.sdpram_16_9
        port map (
            DPRA => read_address, DPO => open, CLK => clock,
            WE => '0', A => write_address, D => (others => '0')
        );
    wrapper_64 : entity work.sdpram_64_9
        port map (
            DPRA => address_64, DPO => data_64, CLK => clock,
            WE => '0', A => address_64, D => (others => '0')
        );

    stimulus : process
    begin
        wait for 1 ns;
        assert read_data = "000000000" report "blank async RAM was not zero" severity failure;
        assert data_128 = x"00" and data_320 = "000000000" and
               data_64 = "000000000"
            report "a fixed core RAM wrapper did not elaborate blank" severity failure;

        write_address <= x"2";
        write_data <= "101010101";
        write_enable <= '1';
        wait until rising_edge(clock);
        wait for 1 ns;
        write_enable <= '0';
        assert read_data = "000000000"
            report "async read used the write address" severity failure;

        read_address <= x"2";
        wait for 1 ns;
        assert read_data = "101010101"
            report "async read did not follow its address" severity failure;

        read_address <= x"3";
        wait for 1 ns;
        assert read_data = "000000000"
            report "async read did not change without a clock" severity failure;

        report "CORE_SDPRAM_PASS" severity note;
        std.env.finish;
        wait;
    end process;
end architecture;
"""
        )
        self.assertIn("CORE_SDPRAM_PASS", output)

    def test_same_clock_true_dual_port_fifo_ram(self) -> None:
        output = self.run_ghdl(
            r"""
library ieee;
use ieee.std_logic_1164.all;

entity testbench is end entity;

architecture test of testbench is
    signal clock : std_logic := '0';
    signal write_a : std_logic := '0';
    signal address_a : std_logic_vector(3 downto 0) := (others => '0');
    signal input_a : std_logic_vector(8 downto 0) := (others => '0');
    signal output_a : std_logic_vector(8 downto 0);
    signal write_b : std_logic := '0';
    signal address_b : std_logic_vector(3 downto 0) := (others => '0');
    signal input_b : std_logic_vector(8 downto 0) := (others => '0');
    signal output_b : std_logic_vector(8 downto 0);
begin
    clock <= not clock after 5 ns;

    dut : entity work.tdpram
        generic map (addr_width_g => 4, data_width_g => 9)
        port map (
            clk_a_i => clock, we_a_i => write_a, addr_a_i => address_a,
            data_a_i => input_a, data_a_o => output_a,
            clk_b_i => clock, we_b_i => write_b, addr_b_i => address_b,
            data_b_i => input_b, data_b_o => output_b
        );

    stimulus : process
    begin
        address_a <= x"2";
        input_a <= "101010101";
        write_a <= '1';
        address_b <= x"a";
        input_b <= "010101010";
        write_b <= '1';
        wait until rising_edge(clock);
        wait for 1 ns;
        assert output_a = "000000000" and output_b = "000000000"
            report "true dual-port RAM was not read-first" severity failure;

        write_a <= '0';
        write_b <= '0';
        wait until rising_edge(clock);
        wait for 1 ns;
        assert output_a = "101010101" and output_b = "010101010"
            report "independent FIFO halves did not retain their writes"
            severity failure;

        address_a <= x"a";
        address_b <= x"2";
        wait until rising_edge(clock);
        wait for 1 ns;
        assert output_a = "010101010" and output_b = "101010101"
            report "both ports could not read the opposite FIFO half"
            severity failure;

        report "CORE_TDPRAM_PASS" severity note;
        std.env.finish;
        wait;
    end process;
end architecture;
"""
        )
        self.assertIn("CORE_TDPRAM_PASS", output)

    def test_sprite_pattern_ram_independent_clocks_and_enable(self) -> None:
        output = self.run_ghdl(
            r"""
library ieee;
use ieee.std_logic_1164.all;

entity testbench is end entity;

architecture test of testbench is
    signal write_clock : std_logic := '0';
    signal read_clock : std_logic := '0';
    signal write_enable : std_logic_vector(0 downto 0) := "0";
    signal write_address : std_logic_vector(13 downto 0) := (others => '0');
    signal write_data : std_logic_vector(7 downto 0) := (others => '0');
    signal read_enable : std_logic := '0';
    signal read_address : std_logic_vector(13 downto 0) := (others => '0');
    signal read_data : std_logic_vector(7 downto 0);
begin
    write_clock <= not write_clock after 5 ns;
    read_clock <= not read_clock after 7 ns;

    dut : entity work.sdpbram_16k_8
        port map (
            WEA => write_enable, ADDRA => write_address, DINA => write_data,
            CLKA => write_clock, ENB => read_enable, ADDRB => read_address,
            DOUTB => read_data, CLKB => read_clock
        );

    stimulus : process
    begin
        write_address <= "00000000000101";
        write_data <= x"c3";
        write_enable <= "1";
        wait until rising_edge(write_clock);
        wait for 1 ns;
        write_enable <= "0";

        read_address <= "00000000000101";
        read_enable <= '1';
        wait until rising_edge(read_clock);
        wait for 1 ns;
        assert read_data = x"c3"
            report "sprite pattern read did not return written data"
            severity failure;

        read_enable <= '0';
        read_address <= "00000000000110";
        wait until rising_edge(read_clock);
        wait for 1 ns;
        assert read_data = x"c3"
            report "disabled sprite pattern read changed its output"
            severity failure;

        read_enable <= '1';
        wait until rising_edge(read_clock);
        wait for 1 ns;
        assert read_data = x"00"
            report "re-enabled sprite pattern read missed its address"
            severity failure;

        report "CORE_SDPBRAM_PASS" severity note;
        std.env.finish;
        wait;
    end process;
end architecture;
"""
        )
        self.assertIn("CORE_SDPBRAM_PASS", output)

    def test_invalid_initialisation_clock_and_collision_fail_closed(self) -> None:
        self.run_ghdl_expect_failure(
            r"""
library ieee;
use ieee.std_logic_1164.all;
entity testbench is end entity;
architecture test of testbench is
    signal clock : std_logic := '0';
    signal address : std_logic_vector(3 downto 0) := (others => '0');
begin
    clock <= not clock after 5 ns;
    dut : entity work.dpram2
        generic map (
            addr_width_g => 4, data_width_g => 8,
            init_file_g => "unsupported.hex"
        )
        port map (
            clk_a_i => clock, we_i => '0', addr_a_i => address,
            data_a_i => (others => '0'), data_a_o => open,
            clk_b_i => clock, addr_b_i => address, data_b_o => open
        );
end architecture;
""",
            "dpram2 supports blank initialisation only",
        )

        self.run_ghdl_expect_failure(
            r"""
library ieee;
use ieee.std_logic_1164.all;
entity testbench is end entity;
architecture test of testbench is
    signal clock_a : std_logic := '0';
    signal clock_b : std_logic := '0';
    signal address : std_logic_vector(3 downto 0) := (others => '0');
begin
    clock_a <= not clock_a after 5 ns;
    clock_b <= not clock_b after 7 ns;
    dut : entity work.tdpram
        generic map (addr_width_g => 4, data_width_g => 8)
        port map (
            clk_a_i => clock_a, we_a_i => '0', addr_a_i => address,
            data_a_i => (others => '0'), data_a_o => open,
            clk_b_i => clock_b, we_b_i => '0', addr_b_i => address,
            data_b_i => (others => '0'), data_b_o => open
        );
end architecture;
""",
            "tdpram requires both ports to share one clock",
        )

        self.run_ghdl_expect_failure(
            r"""
library ieee;
use ieee.std_logic_1164.all;
entity testbench is end entity;
architecture test of testbench is
    signal clock : std_logic := '0';
    signal address : std_logic_vector(3 downto 0) := (others => '0');
begin
    clock <= not clock after 5 ns;
    dut : entity work.tdpram
        generic map (addr_width_g => 4, data_width_g => 8)
        port map (
            clk_a_i => clock, we_a_i => '1', addr_a_i => address,
            data_a_i => x"aa", data_a_o => open,
            clk_b_i => clock, we_b_i => '1', addr_b_i => address,
            data_b_i => x"55", data_b_o => open
        );
end architecture;
""",
            "tdpram simultaneous writes selected one address",
        )


if __name__ == "__main__":
    unittest.main()
