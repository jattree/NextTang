"""Spec256's graphical lanes must keep the Next's master CPU in lockstep.

rtl/cpu/nexttang_zxnext_spec256_lanes.vhd runs eight T80N lanes on the master's
28 MHz clock and enables. The testbench drives a master T80Na and the lanes
with the Next's enables at 3.5, 7 or 14 MHz. Its program is built so that a
lane deciding from its own data would leave the master at every control
decision: JR C after an ADD whose carry differs per lane, DJNZ with B loaded
from the colour plane, LDIR with BC from the plane, CPIR finding its byte only
in the master's memory, and CALL Z, CALL NC and RET C on data-dependent flags.

Checked:
- every lane's bus strobes equal the master's on every 28 MHz edge (the
  lanes' desync flag stays clear), with nothing ever holding the master;
- each lane computed with its own plane data at the master's addresses and
  the master's loop counts (LDIR copied the master's count of the lane's own
  bytes; the last store holds the lane's own result);
- follow mode keeps every lane's registers equal to the master's;
- with master control off, the same program loses lockstep, so the check can
  fail.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [REPO_ROOT / "rtl" / "cpu" / f for f in (
    "t80n_pack.vhd", "t80n_alu.vhd", "t80n_mcode.vhd", "t80n.vhd", "t80na.vhd",
    "nexttang_zxnext_spec256_lanes.vhd")]
FLAGS = ("--std=08", "-frelaxed")

# Hand-assembled; addresses on the left.
PROGRAM = {
    0x0000: [0x31, 0x00, 0xFF],        # LD SP,FF00
    0x0003: [0x21, 0x00, 0x80],        # LD HL,8000      graphics mode from here
    0x0006: [0x7E],                    # LD A,(HL)
    0x0007: [0x87],                    # ADD A,A         carry: master 0, lanes 1
    0x0008: [0x38, 0x01],              # JR C,+1
    0x000A: [0x00],                    # NOP
    0x000B: [0x46],                    # LD B,(HL)       master 0x40, lanes 0x80+k
    0x000C: [0x10, 0xFE],              # DJNZ $
    0x000E: [0xED, 0x4B, 0x02, 0x80],  # LD BC,(8002)    master 4, lanes 2+k
    0x0012: [0x21, 0x10, 0x80],        # LD HL,8010
    0x0015: [0x11, 0x00, 0x90],        # LD DE,9000
    0x0018: [0xED, 0xB0],              # LDIR
    0x001A: [0x21, 0x20, 0x80],        # LD HL,8020
    0x001D: [0x01, 0x08, 0x00],        # LD BC,0008
    0x0020: [0x3E, 0x55],              # LD A,55
    0x0022: [0xED, 0xB1],              # CPIR            found in the master only
    0x0024: [0xD4, 0x40, 0x00],        # CALL NC,0040
    0x0027: [0x3A, 0x30, 0x80],        # LD A,(8030)     master 0, lanes k+1
    0x002A: [0xB7],                    # OR A
    0x002B: [0xCC, 0x40, 0x00],        # CALL Z,0040
    0x002E: [0x32, 0x00, 0xA0],        # LD (A000),A
    0x0031: [0x18, 0xFE],              # JR $
    0x0040: [0x3A, 0x31, 0x80],        # LD A,(8031)     master 1, lanes 0
    0x0043: [0x0F],                    # RRCA
    0x0044: [0xD8],                    # RET C
    0x0045: [0xC9],                    # RET
}


def testbench(divide: int, graphics_from: int, control: bool) -> str:
    code = "\n".join(
        f"        m(16#{address + i:04x}#) := x\"{byte:02x}\";"
        for address, data in PROGRAM.items() for i, byte in enumerate(data))
    return f'''
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity testbench is end entity;

architecture sim of testbench is
    type memory_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    type planes_t is array (0 to 7) of memory_t;

    function master_image return memory_t is
        variable m : memory_t := (others => x"00");
    begin
{code}
        m(16#8000#) := x"40";
        m(16#8002#) := x"04"; m(16#8003#) := x"00";
        for i in 0 to 15 loop m(16#8010# + i) := std_logic_vector(to_unsigned(16#11# + i, 8)); end loop;
        m(16#8023#) := x"55";
        m(16#8030#) := x"00"; m(16#8031#) := x"01";
        return m;
    end function;

    function plane_images return planes_t is
        variable p : planes_t := (others => (others => x"00"));
    begin
        for k in 0 to 7 loop
            p(k)(16#8000#) := std_logic_vector(to_unsigned(16#80# + k, 8));
            p(k)(16#8002#) := std_logic_vector(to_unsigned(2 + k, 8));
            for i in 0 to 15 loop p(k)(16#8010# + i) := std_logic_vector(to_unsigned(16#30# + 16 * k + i, 8)); end loop;
            p(k)(16#8030#) := std_logic_vector(to_unsigned(k + 1, 8));
            p(k)(16#8031#) := x"00";
        end loop;
        return p;
    end function;

    signal clock : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal cen_r, cen_f : std_logic := '0';
    signal phase : natural range 0 to {divide - 1} := 0;
    signal m1_n, mreq_n, iorq_n, rd_n, wr_n : std_logic;
    signal address : std_logic_vector(15 downto 0);
    signal data_in, data_out : std_logic_vector(7 downto 0);
    signal memory : memory_t := master_image;
    signal planes : planes_t := plane_images;
    signal pc, sp : std_logic_vector(15 downto 0);
    signal i_reg, r_reg, f_reg : std_logic_vector(7 downto 0);
    signal regs : std_logic_vector(159 downto 0);
    signal iff1, iff2, halted, int_cycle, nmi_cycle, boundary, incdecz : std_logic;
    signal imode, xy : std_logic_vector(1 downto 0);
    signal graphics : std_logic := '0';
    signal g_address : std_logic_vector(127 downto 0);
    signal g_in, g_out : std_logic_vector(63 downto 0);
    signal g_write, g_iorq : std_logic_vector(7 downto 0);
    signal desync : std_logic;
    signal lane_pc : std_logic_vector(127 downto 0);
    signal lane_regs : std_logic_vector(1279 downto 0);
    signal control : std_logic := '{1 if control else 0}';
    signal done : boolean := false;
begin
    clock <= not clock after 17857 ps when not done;

    -- The Next's enables at 28/{divide} MHz: a rising CPU edge every {divide}
    -- 28 MHz edges, its falling edge half way.
    process (clock) begin
        if rising_edge(clock) then
            phase <= (phase + 1) mod {divide};
        end if;
    end process;
    cen_r <= '1' when phase = {divide - 1} else '0';
    cen_f <= '1' when phase = {divide // 2 - 1} else '0';

    data_in <= memory(to_integer(unsigned(address))) when mreq_n = '0' and rd_n = '0' else x"ff";
    process (clock) begin
        if rising_edge(clock) then
            if mreq_n = '0' and wr_n = '0' then
                memory(to_integer(unsigned(address))) <= data_out;
            end if;
            for k in 0 to 7 loop
                if g_write(k) = '1' then
                    planes(k)(to_integer(unsigned(g_address(16 * k + 15 downto 16 * k)))) <= g_out(8 * k + 7 downto 8 * k);
                end if;
            end loop;
        end if;
    end process;
    planes_read : for k in 0 to 7 generate
        g_in(8 * k + 7 downto 8 * k) <= planes(k)(to_integer(unsigned(g_address(16 * k + 15 downto 16 * k))));
    end generate;

    master : entity work.T80Na
        generic map (Mode => 0)
        port map (
            RESET_n => reset_n, CLK_n => clock, CEN_R => cen_r, CEN_F => cen_f,
            WAIT_n => '1', INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
            M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n, RD_n => rd_n, WR_n => wr_n,
            RFSH_n => open, HALT_n => open, BUSAK_n => open,
            A => address, D_i => data_in, D_o => data_out,
            Spec256_state_pc => pc, Spec256_state_sp => sp, Spec256_state_i => i_reg,
            Spec256_state_r => r_reg, Spec256_state_f => f_reg, Spec256_state_regs => regs,
            Spec256_state_iff1 => iff1, Spec256_state_iff2 => iff2, Spec256_state_halted => halted,
            Spec256_state_imode => imode, Spec256_state_xy => xy,
            Spec256_state_int_cycle => int_cycle, Spec256_state_nmi_cycle => nmi_cycle,
            Spec256_state_instruction_boundary => boundary, Spec256_state_incdecz => incdecz,
            Z80N_dout_o => open, Z80N_data_o => open, Z80N_command_o => open);

    lanes : entity work.nexttang_zxnext_spec256_lanes
        port map (
            clock_28 => clock, cen_r => cen_r, cen_f => cen_f, reset_n => reset_n,
            graphics => graphics, master_control => control,
            master_m1_n => m1_n, master_mreq_n => mreq_n, master_iorq_n => iorq_n,
            master_rd_n => rd_n, master_wr_n => wr_n, master_wait_n => '1',
            master_int_n => '1', master_nmi_n => '1', master_busrq_n => '1',
            master_data_in => data_in, master_pc => pc, master_sp => sp, master_i => i_reg,
            master_r => r_reg, master_f => f_reg, master_regs => regs,
            master_iff1 => iff1, master_iff2 => iff2, master_halted => halted,
            master_imode => imode, master_xy => xy, master_int_cycle => int_cycle,
            master_nmi_cycle => nmi_cycle, master_instruction_boundary => boundary,
            master_incdecz => incdecz,
            graphics_address => g_address, graphics_data_in => g_in,
            graphics_data_out => g_out, graphics_write => g_write, graphics_iorq => g_iorq,
            desync => desync, debug_lane_pc => lane_pc, debug_lane_regs => lane_regs);

    -- Graphics mode from the M1 of the instruction at {graphics_from:#06x}, on
    -- the edge that M1 begins: an instruction boundary.
    process (clock)
        variable previous_m1 : std_logic := '1';
    begin
        if rising_edge(clock) then
            if previous_m1 = '1' and m1_n = '0' and boundary = '1' and
               address = x"{graphics_from:04x}" then
                graphics <= '1';
            end if;
            previous_m1 := m1_n;
        end if;
    end process;

    process
        variable boundaries, mismatched : natural := 0;
        variable previous_m1 : std_logic := '1';
        variable reached : boolean := false;
    begin
        wait for 100 ns;
        reset_n <= '1';
        for cycle in 0 to 120000 loop
            wait until rising_edge(clock);
            -- In follow mode every lane is the master, register for register.
            if graphics = '0' and previous_m1 = '1' and m1_n = '0' and boundary = '1' then
                boundaries := boundaries + 1;
                for k in 0 to 7 loop
                    if lane_regs(160 * k + 159 downto 160 * k) /= regs then
                        mismatched := mismatched + 1;
                    end if;
                end loop;
            end if;
            previous_m1 := m1_n;
            if address = x"0031" and m1_n = '0' and graphics = '1' then
                reached := true;
                exit;
            end if;
        end loop;
        for k in 0 to 9 loop wait until rising_edge(clock); end loop;
        report "DESYNC " & std_logic'image(desync);
        report "FOLLOW_BOUNDARIES " & integer'image(boundaries) & " MISMATCHED " & integer'image(mismatched);
        report "MASTER_A000 " & integer'image(to_integer(unsigned(memory(16#A000#)))) &
               " MASTER_9000_9004 " & integer'image(to_integer(unsigned(memory(16#9000#)))) & " " &
               integer'image(to_integer(unsigned(memory(16#9003#)))) & " " &
               integer'image(to_integer(unsigned(memory(16#9004#))));
        for k in 0 to 7 loop
            report "LANE " & integer'image(k) &
                   " A000 " & integer'image(to_integer(unsigned(planes(k)(16#A000#)))) &
                   " 9000 " & integer'image(to_integer(unsigned(planes(k)(16#9000#)))) &
                   " 9003 " & integer'image(to_integer(unsigned(planes(k)(16#9003#)))) &
                   " 9004 " & integer'image(to_integer(unsigned(planes(k)(16#9004#))));
        end loop;
        report "REACHED_END " & boolean'image(reached);
        done <= true;
        wait;
    end process;
end architecture;
'''


def run(divide: int, graphics_from: int = 0x0003, control: bool = True) -> str:
    with tempfile.TemporaryDirectory() as directory:
        work = f"--workdir={directory}"
        bench = Path(directory) / "testbench.vhd"
        bench.write_text(testbench(divide, graphics_from, control))
        for step in (("-a", *FLAGS, work, *map(str, SOURCES), str(bench)),
                     ("-e", *FLAGS, work, "testbench"),
                     ("-r", *FLAGS, work, "testbench", "--ieee-asserts=disable")):
            result = subprocess.run(["ghdl", *step], capture_output=True, text=True, cwd=directory)
            if result.returncode:
                raise AssertionError(result.stdout + result.stderr)
        return result.stdout + result.stderr


@unittest.skipUnless(shutil.which("ghdl"), "ghdl is not installed")
class Spec256LanesTest(unittest.TestCase):
    def check_graphics_run(self, output: str) -> None:
        self.assertIn("DESYNC '0'", output, output)
        self.assertIn("REACHED_END true", output, output)
        # The master: no JR, DJNZ 64 times, LDIR of 4 bytes, CALL Z taken, RET C.
        self.assertIn("MASTER_A000 128 MASTER_9000_9004 17 20 0", output, output)
        for k in range(8):
            # Each lane: its own bytes, the master's count of four, and its
            # own RRCA result (plane 8031 is 0) in the final store.
            self.assertIn(f"LANE {k} A000 0 9000 {0x30 + 16 * k} 9003 {0x33 + 16 * k} 9004 0", output, output)

    def test_lanes_hold_lockstep_at_3_5_mhz(self) -> None:
        self.check_graphics_run(run(8))

    def test_lanes_hold_lockstep_at_7_mhz(self) -> None:
        self.check_graphics_run(run(4))

    def test_lanes_hold_lockstep_at_14_mhz(self) -> None:
        self.check_graphics_run(run(2))

    def test_follow_mode_lanes_equal_the_master(self) -> None:
        output = run(8, graphics_from=0xFFFF)
        self.assertIn("DESYNC '0'", output, output)
        boundaries = int(output.split("FOLLOW_BOUNDARIES ")[1].split()[0])
        self.assertGreater(boundaries, 100, output)
        self.assertIn("MISMATCHED 0", output, output)

    def test_without_master_control_lockstep_is_lost(self) -> None:
        self.assertIn("DESYNC '1'", run(8, control=False))


if __name__ == "__main__":
    unittest.main()
