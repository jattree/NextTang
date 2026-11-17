"""What the debugger reads after every single step, against known values.

T80 writes an instruction's result into its register on the first clock of
the next cycle, and the debugger stops the CPU before that clock. Until
t80n.vhd applied the pending result at the start of a debugger hold, every
register read at a stop was one instruction old. The bench here is the CPU
alone (T80Na with a 64K memory): it stops it after the first instruction,
clears the registers through the debug interface, then single-steps a short
program, reading all registers after each step.

The expected values were worked out with an independent software Z80 and
checked by hand for the plain loads; they are data, not code from it.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CPU = [REPO_ROOT / "rtl/cpu" / name for name in
       ("t80n_pack.vhd", "t80n_alu.vhd", "t80n_mcode.vhd", "t80n.vhd", "t80na.vhd")]

# (bytes, what it is)
PROGRAM = [
    ("310090", "LD SP,9000"), ("3E10", "LD A,10"), ("3C", "INC A"), ("0622", "LD B,22"), ("80", "ADD A,B"),
    ("213412", "LD HL,1234"), ("23", "INC HL"), ("77", "LD (HL),A"), ("4E", "LD C,(HL)"), ("E5", "PUSH HL"),
    ("D1", "POP DE"), ("EB", "EX DE,HL"), ("09", "ADD HL,BC"), ("DD210080", "LD IX,8000"),
    ("DD360577", "LD (IX+5),77"), ("DD7E05", "LD A,(IX+5)"), ("FE77", "CP 77"), ("37", "SCF"), ("8F", "ADC A,A"),
    ("D9", "EXX"), ("01EFBE", "LD BC,BEEF"), ("D9", "EXX"), ("08", "EX AF,AF'"), ("3E01", "LD A,01"),
    ("08", "EX AF,AF'"), ("F5", "PUSH AF"), ("F1", "POP AF"), ("CB47", "BIT 0,A"), ("ED44", "NEG"),
    ("DBFE", "IN A,(FE)"), ("ED78", "IN A,(C)"), ("EDA0", "LDI"), ("18FE", "JR $"),
]
# After each instruction from LD A,10 to LDI: A F B C D E H L A' F' B' C' D' E' H' L' IXH IXL IYH IYL SPH SPL PCH PCL
EXPECTED = """
100000000000000000000000000000000000000090000005
110000000000000000000000000000000000000090000006
110022000000000000000000000000000000000090000008
332022000000000000000000000000000000000090000009
33202200000012340000000000000000000000009000000c
33202200000012350000000000000000000000009000000d
33202200000012350000000000000000000000009000000e
33202233000012350000000000000000000000009000000f
33202233000012350000000000000000000000008ffe0010
332022331235123500000000000000000000000090000011
332022331235123500000000000000000000000090000012
332022331235346800000000000000000000000090000013
332022331235346800000000000000008000000090000017
33202233123534680000000000000000800000009000001b
77202233123534680000000000000000800000009000001e
776222331235346800000000000000008000000090000020
776122331235346800000000000000008000000090000021
efac22331235346800000000000000008000000090000022
efac00000000000000002233123534688000000090000023
efacbeef0000000000002233123534688000000090000026
efac2233123534680000beef000000008000000090000027
0000223312353468efacbeef000000008000000090000028
0100223312353468efacbeef00000000800000009000002a
efac2233123534680100beef00000000800000009000002b
efac2233123534680100beef00000000800000008ffe002c
efac2233123534680100beef00000000800000009000002d
ef382233123534680100beef00000000800000009000002f
11132233123534680100beef000000008000000090000031
a5132233123534680100beef000000008000000090000033
a5a52233123534680100beef000000008000000090000035
a5852232123634690100beef000000008000000090000037
""".split()
NAMES = "A F B C D E H L A' F' B' C' D' E' H' L' IXH IXL IYH IYL SPH SPL PCH PCL".split()

BENCH = """
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb is
   generic (STEPS : natural := 1);
end entity;

architecture sim of tb is
   signal clock : std_logic := '0';
   signal reset_n : std_logic := '0';
   signal m1_n, mreq_n, iorq_n, rd_n, wr_n, busak_n : std_logic;
   signal a : std_logic_vector(15 downto 0);
   signal d_i, d_o, debug_out : std_logic_vector(7 downto 0);
   signal debug_reg : std_logic_vector(4 downto 0) := (others => '0');
   signal debug_wr, pause : std_logic := '0';
   signal debug_in : std_logic_vector(7 downto 0) := (others => '0');
   type memory_t is array (0 to 65535) of std_logic_vector(7 downto 0);
   signal done : boolean := false;
begin
   clock <= not clock after 5 ns when not done else '0';

   cpu : entity work.T80Na
      port map (
         RESET_n => reset_n, CLK_n => clock, WAIT_n => '1', INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
         M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n, RD_n => rd_n, WR_n => wr_n, BUSAK_n => busak_n,
         A => a, D_i => d_i, D_o => d_o,
         i_debug_reg => debug_reg, i_debug_wr => debug_wr, i_debug_dat => debug_in, o_debug_dat => debug_out,
         i_debug_pause => pause);

   memory : process (clock)
      file f : text open read_mode is "program.txt";
      variable l : line;
      variable b : std_logic_vector(7 downto 0);
      variable m : memory_t := (others => x"00");
      variable loaded : boolean := false;
      variable at : natural := 0;
   begin
      if not loaded then
         while not endfile(f) loop readline(f, l); hread(l, b); m(at) := b; at := at + 1; end loop;
         loaded := true;
      end if;
      if rising_edge(clock) then
         if mreq_n = '0' and wr_n = '0' then
            m(to_integer(unsigned(a))) := d_o;
         end if;
      end if;
      if falling_edge(clock) or rising_edge(clock) then
         if iorq_n = '0' and m1_n = '1' then
            d_i <= x"A5";                       -- every port reads A5
         else
            d_i <= m(to_integer(unsigned(a)));
         end if;
      end if;
   end process;

   script : process
      file o : text open write_mode is "result.txt";
      variable w : line;
      procedure clocks(n : natural) is
      begin
         for k in 1 to n loop wait until rising_edge(clock); end loop;
      end procedure;
      procedure stop is                          -- wait for the hold
      begin
         loop
            wait until rising_edge(clock);
            exit when busak_n = '0';
         end loop;
         clocks(3);
      end procedure;
      procedure dump is
      begin
         for r in 0 to 23 loop
            debug_reg <= std_logic_vector(to_unsigned(r, 5));
            clocks(2);
            hwrite(w, debug_out);
         end loop;
         writeline(o, w);
      end procedure;
   begin
      pause <= '1';
      clocks(4);
      reset_n <= '1';
      stop;                                      -- after LD SP,nn
      for r in 0 to 19 loop                      -- clear A to IYL through the debugger
         debug_reg <= std_logic_vector(to_unsigned(r, 5));
         debug_in <= x"00";
         debug_wr <= '1';
         clocks(1);
         debug_wr <= '0';
         clocks(1);
      end loop;
      for step in 1 to STEPS loop
         pause <= '0';                           -- a single step: let go for a clock
         loop
            wait until rising_edge(clock);
            exit when busak_n = '1';
         end loop;
         pause <= '1';
         stop;
         dump;
      end loop;
      done <= true;
      wait;
   end process;
end architecture;
"""


@unittest.skipUnless(shutil.which("ghdl"), "ghdl not installed")
class DebugStepRegistersTest(unittest.TestCase):
    def test_registers_after_every_step(self) -> None:
        self.assertEqual(len(EXPECTED), len(PROGRAM) - 2)
        program = bytes.fromhex("".join(code for code, _ in PROGRAM))
        flags = ["--std=08", "-frelaxed", "-fsynopsys"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tb.vhd").write_text(BENCH, encoding="ascii")
            (root / "program.txt").write_text("".join(f"{b:02x}\n" for b in program), encoding="ascii")
            for command in (["ghdl", "-a", *flags, *map(str, CPU), "tb.vhd"],
                            ["ghdl", "-e", *flags, "tb"],
                            ["ghdl", "-r", *flags, "tb", f"-gSTEPS={len(EXPECTED)}", "--ieee-asserts=disable"]):
                done = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=600)
                if done.returncode:
                    raise AssertionError(done.stdout + done.stderr)
            got = (root / "result.txt").read_text().split()
        self.assertEqual(len(got), len(EXPECTED))
        for (code, what), have, want in zip(PROGRAM[1:], got, EXPECTED):
            have = have.lower()
            if have != want:
                wrong = [f"{name} {have[2 * k:2 * k + 2]} (should be {want[2 * k:2 * k + 2]})"
                         for k, name in enumerate(NAMES) if have[2 * k:2 * k + 2] != want[2 * k:2 * k + 2]]
                self.fail(f"after {what}: " + ", ".join(wrong))


if __name__ == "__main__":
    unittest.main()
