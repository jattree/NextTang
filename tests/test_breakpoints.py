"""The fabric breakpoints (rtl/debug/nexttang_breakpoints.vhd).

A slot matches when it is enabled, the next PC is its address and, for a paged
slot, the 8K page mapped at that address (the MMU register for the address's
top three bits) is the slot's page. The page test is registered, so it is
looked at a clock after the MMU or the slot changes.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl/debug/nexttang_breakpoints.vhd"

BENCH = """
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb is end entity;

architecture sim of tb is
   signal clock : std_logic := '0';
   signal reset : std_logic := '1';
   signal strobe, enable, paged_in, stopped : std_logic := '0';
   signal slot, page : std_logic_vector(7 downto 0) := (others => '0');
   signal address, pc : std_logic_vector(15 downto 0) := (others => '0');
   signal mmu : std_logic_vector(63 downto 0) := x"0706050403020100";
   signal break_now, hit : std_logic;
   signal done : boolean := false;
begin
   clock <= not clock after 5 ns when not done;
   dut : entity work.nexttang_breakpoints generic map (SLOTS => 2) port map (
      clock => clock, reset => reset, write_strobe => strobe, write_slot => slot,
      write_enable => enable, write_address => address, write_paged => paged_in,
      write_page => page, mmu => mmu, next_pc => pc, cpu_stopped => stopped,
      break_now => break_now, hit => hit);
   process
      procedure set(s : natural; on_off : std_logic; a : std_logic_vector(15 downto 0);
                    p : std_logic; pg : std_logic_vector(7 downto 0)) is
      begin
         wait until rising_edge(clock);
         slot <= std_logic_vector(to_unsigned(s, 8)); enable <= on_off; address <= a;
         paged_in <= p; page <= pg; strobe <= '1';
         wait until rising_edge(clock);
         strobe <= '0';
         wait until rising_edge(clock); wait until rising_edge(clock);
      end procedure;
      procedure expect(want : std_logic; what : string) is
      begin
         wait for 1 ns;
         assert break_now = want report "FAIL " & what severity failure;
      end procedure;
   begin
      wait for 22 ns; reset <= '0';
      -- unpaged slot 0 at 1234
      set(0, '1', x"1234", '0', x"00");
      pc <= x"1234"; expect('1', "unpaged match");
      pc <= x"1235"; expect('0', "unpaged other address");
      -- paged slot 1 at each 8K slot in turn, page = the MMU byte there
      for region in 0 to 7 loop
         set(1, '1', std_logic_vector(to_unsigned(region * 8192 + 16#0100#, 16)), '1',
             std_logic_vector(to_unsigned(region, 8)));
         pc <= std_logic_vector(to_unsigned(region * 8192 + 16#0100#, 16));
         expect('1', "paged match in region " & integer'image(region));
         set(1, '1', std_logic_vector(to_unsigned(region * 8192 + 16#0100#, 16)), '1',
             std_logic_vector(to_unsigned((region + 1) mod 8, 8)));
         expect('0', "paged with another region's page, region " & integer'image(region));
      end loop;
      -- the page test follows the MMU
      set(1, '1', x"8100", '1', x"2a");
      pc <= x"8100"; expect('0', "page not mapped");
      mmu(39 downto 32) <= x"2a";
      wait until rising_edge(clock); wait until rising_edge(clock);
      expect('1', "page mapped later");
      -- a disabled slot never matches; hit pulses once when the CPU stops on a match
      set(1, '0', x"8100", '1', x"2a"); expect('0', "disabled");
      pc <= x"1234"; stopped <= '1';
      wait until rising_edge(clock); wait for 1 ns;
      assert hit = '1' report "FAIL no hit pulse" severity failure;
      wait until rising_edge(clock); wait for 1 ns;
      assert hit = '0' report "FAIL hit not a single pulse" severity failure;
      report "PASS";
      done <= true;
      wait;
   end process;
end architecture;
"""


@unittest.skipUnless(shutil.which("ghdl"), "ghdl not installed")
class BreakpointsTest(unittest.TestCase):
    def test_paged_and_unpaged_slots(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bench = Path(directory) / "tb.vhd"
            bench.write_text(BENCH)
            for step in (["ghdl", "-a", "--std=08", str(RTL), str(bench)], ["ghdl", "-e", "--std=08", "tb"]):
                subprocess.run(step, cwd=directory, check=True, capture_output=True, text=True)
            result = subprocess.run(["ghdl", "-r", "--std=08", "tb"], cwd=directory, capture_output=True, text=True)
            self.assertIn("PASS", result.stdout + result.stderr, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
