"""Leaving bootstrap must not desynchronise the graphical lanes.

During bootstrap every graphical CPU consumes the master's data bus, so all
nine contexts are executing on identical data. `nexttang_spec256_cpu_cluster`
does this with

    graphical_data_input <= data_in when bootstrap = '1' else
        graphics_data_in(lane * 8 + 7 downto lane * 8);

At handoff all eight lanes switch to their own memories in a single event. The
top level deasserts bootstrap from `snapshot_handoff`, which is derived from the
master's bus (`!m1_n && !mreq_n && !in_rom`) and is not aligned to the barrier,
so the switch can land at any phase of a round.

That matters because of what hardware shows: during gameplay all eight lanes are
corrupt and none is clean -- per-plane bit density 21-41% across every plane,
where an intact lane would be sparse. A per-lane wiring fault would hit one or
two. A single shared event that hits all eight at once would look exactly like
this, and the handoff is such an event.

Control flow is forced to the master at every instruction boundary, so the
lanes' *data* is expected to diverge -- that is the whole point of Spec256 --
but their *addresses* must not. Every context runs the identical instruction
stream, so every context must write the identical sequence of addresses. This
sweeps the handoff across the round and checks that invariant.
"""

from __future__ import annotations

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
    REPO_ROOT / "rtl" / "cpu" / "nexttang_spec256_cpu_cluster.vhd",
]

# LD A,(0010h) / LD (0020h),A / LD A,(0011h) / LD (0021h),A / JR back.
# Identical in every context, so every context must write 0x20 then 0x21
# forever, whatever data it reads.
PROGRAM = {
    0x00: 0x3A, 0x01: 0x10, 0x02: 0x00,
    0x03: 0x32, 0x04: 0x20, 0x05: 0x00,
    0x06: 0x3A, 0x07: 0x11, 0x08: 0x00,
    0x09: 0x32, 0x0A: 0x21, 0x0B: 0x00,
    0x0C: 0x18, 0x0D: 0xF2,
}


def handoff_harness(handoff_ns: int) -> str:
    program_main = "\n".join(
        f'        result(16#{a:02x}#) := x"{v:02x}";'
        for a, v in sorted(PROGRAM.items())
    )
    program_lane = "\n".join(
        f'            result(lane, 16#{a:02x}#) := x"{v:02x}";'
        for a, v in sorted(PROGRAM.items())
    )
    return f'''\
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity testbench is end entity;

architecture sim of testbench is
    signal clock : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal bootstrap : std_logic := '1';
    signal address : std_logic_vector(15 downto 0);
    signal data_in, data_out : std_logic_vector(7 downto 0);
    signal main_read_data : std_logic_vector(7 downto 0) := x"00";
    signal mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n : std_logic;
    signal graphics_address : std_logic_vector(127 downto 0);
    signal graphics_data_in, graphics_data_out : std_logic_vector(63 downto 0);
    signal graphics_iorq, graphics_write, graphics_running : std_logic_vector(7 downto 0);
    signal finished : boolean := false;

    type memory_type is array (0 to 255) of std_logic_vector(7 downto 0);
    type graphics_memory_type is array (0 to 7, 0 to 255) of std_logic_vector(7 downto 0);
    type sum_type is array (0 to 7) of natural;

    function initial_main_memory return memory_type is
        variable result : memory_type := (others => x"00");
    begin
{program_main}
        result(16#10#) := x"5a";
        result(16#11#) := x"a5";
        return result;
    end function;

    function initial_graphics_memory return graphics_memory_type is
        variable result : graphics_memory_type := (others => (others => x"00"));
    begin
        for lane in 0 to 7 loop
{program_lane}
            -- Each lane holds different data, exactly as the eight planes do.
            result(lane, 16#10#) := std_logic_vector(to_unsigned(16#11# + lane, 8));
            result(lane, 16#11#) := std_logic_vector(to_unsigned(16#81# + lane, 8));
        end loop;
        return result;
    end function;

    signal main_memory : memory_type := initial_main_memory;
    signal graphics_memory : graphics_memory_type := initial_graphics_memory;

    signal master_addr_sum : natural := 0;
    signal master_writes : natural := 0;
    signal lane_addr_sum : sum_type := (others => 0);
    signal lane_writes : sum_type := (others => 0);
begin
    clock <= not clock after 142 ns when not finished else '0';

    process begin
        reset_n <= '0'; wait for 2 us; reset_n <= '1'; wait;
    end process;

    -- Handoff, at a phase of the barrier round chosen by the sweep. The real
    -- deassertion comes from the master's bus and is not barrier-aligned.
    process begin
        bootstrap <= '1';
        wait for {handoff_ns} ns;
        bootstrap <= '0';
        wait;
    end process;

    cpu : entity work.nexttang_spec256_cpu_cluster
        port map (
            reset_n => reset_n, clock => clock, sync_enable => '1',
            bootstrap => bootstrap,
            wait_n => '1', interrupt_n => '1', nmi_n => '1',
            bus_request_n => '1', m1_n => m1_n, mreq_n => mreq_n,
            iorq_n => iorq_n, rd_n => rd_n, wr_n => wr_n,
            rfsh_n => rfsh_n, halt_n => halt_n, address => address,
            data_in => data_in, data_out => data_out,
            graphics_address => graphics_address,
            graphics_data_in => graphics_data_in,
            graphics_data_out => graphics_data_out,
            graphics_iorq => graphics_iorq,
            graphics_write => graphics_write,
            graphics_running => graphics_running,
            debug_master_pc => open,
            debug_graphics_pc => open,
            debug_master_regs => open,
            debug_graphics_regs => open
        );

    data_in <= main_read_data;

    process (clock) begin
        if rising_edge(clock) then
            main_read_data <= main_memory(to_integer(unsigned(address(7 downto 0))));
            for lane in 0 to 7 loop
                graphics_data_in(lane * 8 + 7 downto lane * 8) <=
                    graphics_memory(
                        lane,
                        to_integer(unsigned(
                            graphics_address(lane * 16 + 7 downto lane * 16)
                        ))
                    );
            end loop;

            if mreq_n = '0' and wr_n = '0' then
                main_memory(to_integer(unsigned(address(7 downto 0)))) <= data_out;
                master_addr_sum <= master_addr_sum
                    + to_integer(unsigned(address(7 downto 0)));
                master_writes <= master_writes + 1;
            end if;

            for lane in 0 to 7 loop
                if graphics_running(lane) = '1' and
                   graphics_write(lane) = '1' and graphics_iorq(lane) = '0' then
                    graphics_memory(
                        lane,
                        to_integer(unsigned(
                            graphics_address(lane * 16 + 7 downto lane * 16)
                        ))
                    ) <= graphics_data_out(lane * 8 + 7 downto lane * 8);
                    lane_addr_sum(lane) <= lane_addr_sum(lane)
                        + to_integer(unsigned(
                            graphics_address(lane * 16 + 7 downto lane * 16)));
                    lane_writes(lane) <= lane_writes(lane) + 1;
                end if;
            end loop;
        end if;
    end process;

    process begin
        wait for 400 us;
        report "MASTERWRITES=" & integer'image(master_writes) severity note;
        for lane in 0 to 7 loop
            if lane_writes(lane) /= master_writes or
               lane_addr_sum(lane) /= master_addr_sum then
                report "DIVERGED lane=" & integer'image(lane) &
                       " writes=" & integer'image(lane_writes(lane)) &
                       " vs " & integer'image(master_writes) &
                       " addrsum=" & integer'image(lane_addr_sum(lane)) &
                       " vs " & integer'image(master_addr_sum) severity note;
            end if;
        end loop;
        report "RESULT=DONE" severity note;
        finished <= true;
        wait;
    end process;
end architecture;
'''


def run(handoff_ns: int) -> str:
    with tempfile.TemporaryDirectory() as work:
        bench = Path(work) / "testbench.vhd"
        bench.write_text(handoff_harness(handoff_ns), encoding="utf-8")
        analyse = subprocess.run(
            ["ghdl", "-a", "--std=08", "-frelaxed", f"--workdir={work}",
             *[str(p) for p in CPU_SOURCES], str(bench)],
            capture_output=True, text=True,
        )
        assert analyse.returncode == 0, analyse.stderr
        done = subprocess.run(
            ["ghdl", "-r", "--std=08", f"--workdir={work}", "testbench",
             "--stop-time=500us"],
            capture_output=True, text=True, cwd=work,
        )
        return done.stdout + done.stderr


def writes(output: str) -> int:
    for line in output.splitlines():
        if "MASTERWRITES=" in line:
            return int(line.rsplit("MASTERWRITES=", 1)[1].strip())
    return 0


class BootstrapHandoffTest(unittest.TestCase):
    """Sweep the handoff across a barrier round.

    A round is a few clocks at 142 ns, so stepping in 43 ns increments over
    ~1.3 us lands the deassertion at every phase, including inside an
    instruction and on the boundary itself.
    """

    PHASES = [3000 + step * 43 for step in range(24)]

    def test_lanes_keep_the_masters_write_addresses_across_handoff(self) -> None:
        failures = []
        for handoff_ns in self.PHASES:
            output = run(handoff_ns)
            if writes(output) < 5:
                self.fail(f"handoff at {handoff_ns} ns: the program never ran\n{output}")
            if "DIVERGED" in output:
                detail = [l.strip() for l in output.splitlines() if "DIVERGED" in l]
                failures.append((handoff_ns, detail))
        self.assertEqual(
            failures, [],
            "leaving bootstrap at these phases desynchronised the lanes from "
            "the master's write addresses:\n" + "\n".join(
                f"  handoff {ns} ns: {d}" for ns, d in failures),
        )


if __name__ == "__main__":
    unittest.main()
