"""The RZX player (rtl/debug/nexttang_rzx_player.vhd) against a scripted CPU bus.

The bench plays the part of the CPU: it fetches, reads ports and, at the end
of each instruction, looks at the player's interrupt request as a Z80 does:
it acknowledges if interrupts are enabled, and otherwise carries on. The
script says what the recording's CPU did; the test checks the player asks
for an interrupt exactly where each frame ended, feeds the recorded bytes,
and counts the frames.
"""

from __future__ import annotations

import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PLAYER = REPO_ROOT / "rtl/debug/nexttang_rzx_player.vhd"

BENCH = """
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb is
   generic (CPU_CLOCKS : positive := 8; STREAM_GAP : natural := 0);
end entity;

architecture sim of tb is
   signal clock : std_logic := '0';
   signal reset : std_logic := '1';
   signal start, stop : std_logic := '0';
   signal playing, desync : std_logic;
   signal frames : std_logic_vector(15 downto 0);
   signal m1_n, iorq_n, rd_n : std_logic := '1';
   signal byte_in : std_logic_vector(7 downto 0) := (others => '0');
   signal byte_valid : std_logic := '0';
   signal byte_ready : std_logic;
   signal in_data : std_logic_vector(7 downto 0);
   signal int_request : std_logic;
   signal done : boolean := false;
begin
   clock <= not clock after 5 ns when not done else '0';

   dut : entity work.nexttang_rzx_player
      port map (clock => clock, reset => reset, start => start, stop => stop,
                playing => playing, desync => desync, frames => frames,
                m1_n => m1_n, iorq_n => iorq_n, rd_n => rd_n,
                byte_in => byte_in, byte_valid => byte_valid, byte_ready => byte_ready,
                in_data => in_data, int_request => int_request);

   -- The stream: one byte per line of stream.txt, offered STREAM_GAP clocks
   -- after the previous one was taken.
   feed : process
      file f : text open read_mode is "stream.txt";
      variable l : line;
      variable v : std_logic_vector(7 downto 0);
   begin
      wait until reset = '0';
      while not endfile(f) loop
         readline(f, l); hread(l, v);
         for k in 1 to STREAM_GAP loop wait until rising_edge(clock); end loop;
         byte_in <= v; byte_valid <= '1';
         loop
            wait until rising_edge(clock);
            exit when byte_ready = '1';
         end loop;
         byte_valid <= '0';
      end loop;
      wait;
   end process;

   cpu : process
      file f : text open read_mode is "script.txt";
      file o : text open write_mode is "result.txt";
      variable l, w : line;
      variable op : character;
      variable v : std_logic_vector(7 downto 0);
      variable n : integer;
      procedure tstates(count : natural) is
      begin
         for k in 1 to count * CPU_CLOCKS loop wait until rising_edge(clock); end loop;
      end procedure;
   begin
      for k in 1 to 4 loop wait until rising_edge(clock); end loop;
      reset <= '0';
      wait until rising_edge(clock);
      start <= '1'; wait until rising_edge(clock); start <= '0';
      while not endfile(f) loop
         readline(f, l); read(l, op);
         case op is
            when 'F' =>                       -- opcode fetch
               m1_n <= '0'; tstates(2); m1_n <= '1'; tstates(2);
            when 'I' =>                       -- port read: report the byte the CPU would latch
               hread(l, v);
               tstates(1); iorq_n <= '0'; rd_n <= '0'; tstates(2);
               write(w, string'("I ")); hwrite(w, in_data); writeline(o, w);
               tstates(1); iorq_n <= '1'; rd_n <= '1'; tstates(1);
            when 'E' =>                       -- instruction end: 1 = interrupts enabled
               read(l, n);
               write(w, string'("E ")); write(w, std_logic'image(int_request)); writeline(o, w);
               if int_request = '1' and n = 1 then
                  m1_n <= '0'; tstates(2); iorq_n <= '0'; tstates(2);
                  m1_n <= '1'; iorq_n <= '1'; tstates(3);
               end if;
            when others => null;
         end case;
      end loop;
      tstates(4);
      write(w, string'("END frames ")); write(w, to_integer(unsigned(frames)));
      write(w, string'(" playing ")); write(w, std_logic'image(playing));
      write(w, string'(" desync ")); write(w, std_logic'image(desync));
      writeline(o, w);
      done <= true;
      wait;
   end process;
end architecture;
"""


def build(frames, rng):
    """frames: (fetches, in bytes, acknowledged). Returns the stream bytes,
    the CPU script and what the bench should report at each instruction end."""
    stream, script, expect_int = [], [], []
    for fetches, ins, acked in frames:
        stream += [fetches & 0xFF, fetches >> 8, len(ins) & 0xFF, len(ins) >> 8, *ins]
        todo = list(ins)
        for k in range(fetches):
            last = k == fetches - 1
            script.append("F")
            # spread the reads over the frame's instructions, the rest on the last
            while todo and (last or rng.random() < 0.3):
                script.append(f"I {todo.pop(0):02x}")
            script.append(f"E {1 if last and acked else 0}")
            expect_int.append(last)
        if fetches == 0:
            script.append(f"E {1 if acked else 0}")
            expect_int.append(True)
    return stream, script, expect_int


def run(stream, script, cpu_clocks=8, stream_gap=0):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "tb.vhd").write_text(BENCH, encoding="ascii")
        (root / "stream.txt").write_text("".join(f"{b:02x}\n" for b in stream), encoding="ascii")
        (root / "script.txt").write_text("\n".join(script) + "\n", encoding="ascii")
        for command in (["ghdl", "-a", "--std=08", str(PLAYER), "tb.vhd"],
                        ["ghdl", "-e", "--std=08", "tb"],
                        ["ghdl", "-r", "--std=08", "tb", f"-gCPU_CLOCKS={cpu_clocks}",
                         f"-gSTREAM_GAP={stream_gap}"]):
            done = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=600)
            if done.returncode:
                raise AssertionError(done.stdout + done.stderr)
        lines = (root / "result.txt").read_text().splitlines()
    reads = [int(line.split()[1], 16) for line in lines if line.startswith("I ")]
    ints = [line.split()[1] == "'1'" for line in lines if line.startswith("E ")]
    end = lines[-1].split()
    return reads, ints, {"frames": int(end[2]), "playing": end[4] == "'1'", "desync": end[6] == "'1'"}


@unittest.skipUnless(shutil.which("ghdl"), "ghdl not installed")
class RzxPlayerTest(unittest.TestCase):
    def check(self, frames, **options):
        rng = random.Random(13)
        stream, script, expect_int = build(frames, rng)
        reads, ints, end = run(stream, script, **options)
        self.assertEqual(ints, expect_int)
        self.assertEqual(reads, [b for _, ins, _ in frames for b in ins])
        self.assertEqual(end, {"frames": len(frames), "playing": True, "desync": False})

    def test_acknowledged_frames(self) -> None:
        self.check([(5, [0xBF, 0x1F], True), (1, [], True), (7, [0x00], True), (3, [], True)])

    def test_declined_interrupts_end_frames(self) -> None:
        # Interrupts off for three frames in the middle, as during a BEEP.
        self.check([(4, [0xBF], True), (6, [], False), (5, [0x12, 0x34], False),
                    (5, [], False), (3, [0x56], True), (2, [], True)])

    def test_declined_then_first_fetch_reads_a_port(self) -> None:
        # The fetch that follows a declined interrupt is the next frame's
        # first, and its instruction reads a port at once: the next frame's
        # header and byte have to be in by then.
        self.check([(3, [], False), (1, [0xA5], True), (2, [0x5A], False), (1, [0x99], False), (2, [], True)])

    def test_frame_with_no_fetches(self) -> None:
        # A frame with a fetch count of 0 (emulator recordings can hold them):
        # the request is up as soon as the frame is known and, declined, the
        # frame ends at the next fetch.
        self.check([(4, [], True), (0, [], False), (3, [], True)])

    def test_random_frames_at_two_speeds(self) -> None:
        rng = random.Random(7)
        frames = [(rng.randrange(1, 40), [rng.randrange(256) for _ in range(rng.randrange(0, 5))],
                   rng.random() < 0.6) for _ in range(60)]
        for cpu_clocks in (8, 2):
            with self.subTest(cpu_clocks=cpu_clocks):
                self.check(frames, cpu_clocks=cpu_clocks)

    def test_read_with_no_byte_left_is_a_desync(self) -> None:
        rng = random.Random(1)
        stream, script, _ = build([(3, [0x11], True), (4, [0x22, 0x33], True), (2, [], True)], rng)
        del stream[4 + 1 + 4 + 1]            # frame 1's last byte
        stream[4 + 1 + 2] = 1                # and its count: the CPU's second read has none
        _, _, end = run(stream, script)
        self.assertEqual(end, {"frames": 1, "playing": False, "desync": True})

    def test_unused_byte_at_a_declined_interrupt_is_a_desync(self) -> None:
        rng = random.Random(1)
        stream, script, _ = build([(3, [0x11], False), (4, [], True), (2, [], True)], rng)
        script = [line for line in script if not line.startswith("I ")]   # this CPU never reads the port
        _, _, end = run(stream, script)
        self.assertTrue(end["desync"])
        self.assertFalse(end["playing"])


if __name__ == "__main__":
    unittest.main()
