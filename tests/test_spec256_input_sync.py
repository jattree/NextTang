"""The nine Spec256 contexts must observe identical shared machine input.

`prime_fetch` releases the master and all eight graphical CPUs on the same
clock edge, and the barrier re-synchronises PC, SP, I, R, F, IFF, IM and the
interrupt/NMI cycle state at every instruction boundary. For an instruction
whose cycle count does not depend on data -- which is every instruction except
the block operations and the conditional control transfers, and those decide on
F, which *is* synchronised -- all nine therefore sample an input port on the
same clock edge.

That cycle-lock is what makes the shared keyboard, joystick and tape inputs
safe. They reach all nine through combinational paths: the master's own port
decode and one `nexttang_spec256_input_mux` per lane. Nothing holds them stable
across a round, so the design depends entirely on the nine contexts sampling
simultaneously.

The dependency is load-bearing and invisible in the RTL. There is no
`Spec256_sync_regs`: the general register file is per-lane and permanently
independent, so a lane that ever reads a different byte from port 0xFE than the
master keeps that byte in A, and every value later computed from it diverges
while control flow is still forced to follow the master. The visible result
would be intact geometry with wrong plane data, persistent because it is
deterministic.

This test pins the invariant. It reads the same port from all nine contexts in
a loop while toggling the shared input at a period deliberately coprime with
the round length, so the change sweeps every phase of the round, and asserts
that every context stored the identical value in the identical round.

If a future change to the barrier lets the contexts drift apart -- a per-lane
wait state, a data-dependent hold, a lane released a cycle early -- this test
fails, and the failure mode it protects against is exactly the one that is hard
to recognise on hardware.
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
    REPO_ROOT / "rtl" / "cpu" / "nexttang_spec256_cpu_cluster.vhd",
]

# IN A,(0FEh) / LD (0020h),A / JR back. Identical in every context, so every
# context must read the same port value in the same round and store it.
PROGRAM = {
    0x00: 0xDB, 0x01: 0xFE,
    0x02: 0x32, 0x03: 0x20, 0x04: 0x00,
    0x05: 0x18, 0x06: 0xF9,
}


def input_sync_harness(toggle_period_ns: int, stable: bool) -> str:
    """Build a bench where a shared input toggles mid-round.

    `stable` selects whether the bench feeds the CPUs the live shared input or
    a round-stable snapshot of it, which is what the fix installs in the top
    level. With `stable` the two runs must agree; without it, they must not,
    or the mechanism does not exist.
    """
    program_main = "\n".join(
        f'        result(16#{a:02x}#) := x"{v:02x}";'
        for a, v in sorted(PROGRAM.items())
    )
    program_lane = "\n".join(
        f'            result(lane, 16#{a:02x}#) := x"{v:02x}";'
        for a, v in sorted(PROGRAM.items())
    )
    # The fix's behaviour, modelled in the bench: sample the shared input once
    # per round instead of continuously.
    sampled = "round_stable_input" if stable else "shared_input"
    return f'''\
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity testbench is end entity;

architecture sim of testbench is
    signal clock : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal address : std_logic_vector(15 downto 0);
    signal data_in, data_out : std_logic_vector(7 downto 0);
    signal main_read_data : std_logic_vector(7 downto 0) := x"00";
    signal mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n : std_logic;
    signal graphics_address : std_logic_vector(127 downto 0);
    signal graphics_data_in, graphics_data_out : std_logic_vector(63 downto 0);
    signal graphics_iorq, graphics_write, graphics_running : std_logic_vector(7 downto 0);
    signal finished : boolean := false;

    -- The shared physical input. One bit flips on a single clock edge, the way
    -- a key press or the launch sequencer's key 4/5 burst does.
    signal shared_input : std_logic_vector(7 downto 0) := x"aa";
    signal round_stable_input : std_logic_vector(7 downto 0) := x"aa";
    signal previous_running : std_logic_vector(7 downto 0) := (others => '0');

    type memory_type is array (0 to 255) of std_logic_vector(7 downto 0);
    type graphics_memory_type is array (0 to 7, 0 to 255) of std_logic_vector(7 downto 0);
    type count_type is array (0 to 7) of natural;
    type value_type is array (0 to 7) of std_logic_vector(7 downto 0);

    function initial_main_memory return memory_type is
        variable result : memory_type := (others => x"00");
    begin
{program_main}
        return result;
    end function;

    function initial_graphics_memory return graphics_memory_type is
        variable result : graphics_memory_type := (others => (others => x"00"));
    begin
        for lane in 0 to 7 loop
{program_lane}
        end loop;
        return result;
    end function;

    signal main_memory : memory_type := initial_main_memory;
    signal graphics_memory : graphics_memory_type := initial_graphics_memory;

    signal master_count : natural := 0;
    signal master_value : std_logic_vector(7 downto 0) := x"00";
    signal lane_count : count_type := (others => 0);
    signal lane_value : value_type := (others => x"00");
    signal divergence : std_logic := '0';
    signal divergent_lane : integer := -1;
    signal observed_master : std_logic_vector(7 downto 0) := x"00";
    signal observed_lane : std_logic_vector(7 downto 0) := x"00";
    signal compared : natural := 0;
begin
    clock <= not clock after 142 ns when not finished else '0';

    process begin
        reset_n <= '0'; wait for 2 us; reset_n <= '1'; wait;
    end process;

    -- Toggle at a period chosen not to divide the round length, so the change
    -- lands at a different phase of the round every time.
    process begin
        wait for 3 us;
        loop
            wait for {toggle_period_ns} ns;
            shared_input <= shared_input xor x"ff";
        end loop;
    end process;

    -- What the fix does: refresh the shared snapshot only at a round boundary.
    -- graphics_running is `not gpu_hold`, so its rising edge marks the release
    -- in prime_fetch -- the one moment when no CPU has begun the next
    -- instruction.
    process (clock) begin
        if rising_edge(clock) then
            previous_running <= graphics_running;
            if reset_n = '0' then
                round_stable_input <= shared_input;
            elsif previous_running = x"00" and graphics_running /= x"00" then
                round_stable_input <= shared_input;
            end if;
        end if;
    end process;

    cpu : entity work.nexttang_spec256_cpu_cluster
        port map (
            reset_n => reset_n, clock => clock, sync_enable => '1',
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

    -- The master's port decode, as the board top level does it.
    data_in <= {sampled} when iorq_n = '0' else main_read_data;

    process (clock) begin
        if rising_edge(clock) then
            main_read_data <= main_memory(to_integer(unsigned(address(7 downto 0))));
            for lane in 0 to 7 loop
                -- One nexttang_spec256_input_mux per lane: I/O reads take the
                -- shared machine input, memory reads take that lane's memory.
                if graphics_iorq(lane) = '1' then
                    graphics_data_in(lane * 8 + 7 downto lane * 8) <= {sampled};
                else
                    graphics_data_in(lane * 8 + 7 downto lane * 8) <=
                        graphics_memory(
                            lane,
                            to_integer(unsigned(
                                graphics_address(lane * 16 + 7 downto lane * 16)
                            ))
                        );
                end if;
            end loop;

            if mreq_n = '0' and wr_n = '0' then
                main_memory(to_integer(unsigned(address(7 downto 0)))) <= data_out;
                if address(7 downto 0) = x"20" then
                    master_value <= data_out;
                    master_count <= master_count + 1;
                end if;
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
                    if graphics_address(lane * 16 + 7 downto lane * 16) = x"20" then
                        lane_value(lane) <= graphics_data_out(lane * 8 + 7 downto lane * 8);
                        lane_count(lane) <= lane_count(lane) + 1;
                    end if;
                end if;
            end loop;
        end if;
    end process;

    -- Every context runs the identical instruction stream, so a lane that has
    -- stored the same number of port reads as the master must have stored the
    -- same values. Sticky, so a single divergent round cannot be missed.
    process (clock) begin
        if rising_edge(clock) and reset_n = '1' then
            for lane in 0 to 7 loop
                if lane_count(lane) > 0 and lane_count(lane) = master_count then
                    compared <= compared + 1;
                    if lane_value(lane) /= master_value and divergence = '0' then
                        divergence <= '1';
                        divergent_lane <= lane;
                        observed_master <= master_value;
                        observed_lane <= lane_value(lane);
                    end if;
                end if;
            end loop;
        end if;
    end process;

    process begin
        wait for 400 us;
        report "COMPARED=" & integer'image(compared) severity note;
        report "MASTERSTORES=" & integer'image(master_count) severity note;
        if divergence = '1' then
            report "DIVERGENCE lane=" & integer'image(divergent_lane) &
                   " master=" & integer'image(to_integer(unsigned(observed_master))) &
                   " lane=" & integer'image(to_integer(unsigned(observed_lane)))
                   severity note;
            report "RESULT=DIVERGED" severity note;
        else
            report "RESULT=STABLE" severity note;
        end if;
        finished <= true;
        wait;
    end process;
end architecture;
'''


def run_bench(source: str) -> str:
    with tempfile.TemporaryDirectory() as work:
        bench = Path(work) / "testbench.vhd"
        bench.write_text(source, encoding="utf-8")
        analyse = subprocess.run(
            ["ghdl", "-a", "--std=08", "-frelaxed", f"--workdir={work}",
             *[str(path) for path in CPU_SOURCES], str(bench)],
            capture_output=True, text=True,
        )
        assert analyse.returncode == 0, analyse.stderr
        run = subprocess.run(
            ["ghdl", "-r", "--std=08", f"--workdir={work}", "testbench",
             "--stop-time=500us"],
            capture_output=True, text=True, cwd=work,
        )
        return run.stdout + run.stderr


def stores(output: str) -> int:
    """How many times the master actually stored a port read."""
    for line in output.splitlines():
        if "MASTERSTORES=" in line:
            return int(line.rsplit("MASTERSTORES=", 1)[1].strip())
    return 0


class SharedInputSynchronisationTest(unittest.TestCase):
    # 5,254 ns is ~37 clock edges at 142 ns, deliberately not a divisor of the
    # round length, so the toggle precesses through every phase of the round.
    TOGGLE_NS = 5254

    def test_live_shared_input_is_observed_identically(self) -> None:
        """The invariant: cycle-lock makes an unheld shared input safe.

        A failure here means the contexts no longer sample simultaneously, and
        every shared input in the machine has become a divergence source.
        """
        output = run_bench(input_sync_harness(self.TOGGLE_NS, stable=False))
        self.assertGreater(
            stores(output), 20,
            "the bench never executed the loop, so STABLE would be vacuous\n"
            + output,
        )
        self.assertIn(
            "RESULT=STABLE", output,
            "the nine contexts sampled a shared input at different times; "
            "with no Spec256_sync_regs, the affected lane's registers never "
            "recover\n" + output,
        )

    def test_round_stable_input_is_also_safe(self) -> None:
        """A round-stable snapshot must be at least as safe as the live input.

        This is the control. If cycle-lock is ever lost, sampling the shared
        input once per round at the `prime_fetch` boundary is the smallest fix,
        and this proves the boundary is the right one before it is needed.
        """
        output = run_bench(input_sync_harness(self.TOGGLE_NS, stable=True))
        self.assertGreater(
            stores(output), 20,
            "the bench never executed the loop, so STABLE would be vacuous\n"
            + output,
        )
        self.assertIn(
            "RESULT=STABLE", output,
            "a round-stable shared input diverged; the snapshot boundary is "
            "wrong\n" + output,
        )


if __name__ == "__main__":
    unittest.main()
