"""Behavioural proofs for the synchronized Spec256 CPU/GPU cluster."""

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


def harness(program: dict[int, int], main_value: int,
            graphics_values: tuple[int, ...], expected: tuple[int, ...],
            message: str,
            graphics_program: dict[int, int] | None = None,
            interrupt_at: int | None = None,
            extra_assertions: str = "") -> str:
    program_assignments = "\n".join(
        f'        result(16#{address:02x}#) := x"{value:02x}";'
        for address, value in sorted(program.items())
    )
    graphics_initializers = "\n".join(
        f'        result({lane}, 16#10#) := x"{value:02x}";'
        for lane, value in enumerate(graphics_values)
    )
    graphics_program_assignments = "\n".join(
        f'            result(lane, 16#{address:02x}#) := x"{value:02x}";'
        for address, value in sorted((graphics_program or {}).items())
    )
    graphics_assertions = "\n".join(
        f'        assert graphics_memory({lane}, 16#20#) = x"{value:02x}" '
        f'report "{message}: lane {lane}" severity failure;'
        for lane, value in enumerate(expected[1:])
    )
    interrupt_logic = ""
    if interrupt_at is not None:
        interrupt_logic = f'''\
    process (clock) begin
        if rising_edge(clock) and reset_n = '1' and
           m1_n = '0' and address = x"{interrupt_at:04x}" then
            interrupt_n <= '0';
        end if;
    end process;
'''
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
    signal interrupt_n : std_logic := '1';
    signal finished : boolean := false;

    type memory_type is array (0 to 255) of std_logic_vector(7 downto 0);
    type graphics_memory_type is array (0 to 7, 0 to 255) of std_logic_vector(7 downto 0);

    function initial_main_memory return memory_type is
        variable result : memory_type := (others => x"00");
    begin
{program_assignments}
        result(16#10#) := x"{main_value:02x}";
        return result;
    end function;

    function initial_graphics_memory return graphics_memory_type is
        variable result : graphics_memory_type := (others => (others => x"00"));
    begin
        for lane in 0 to 7 loop
{program_assignments.replace('result(', 'result(lane, ')}
{graphics_program_assignments}
        end loop;
{graphics_initializers}
        return result;
    end function;

    signal main_memory : memory_type := initial_main_memory;
    signal graphics_memory : graphics_memory_type := initial_graphics_memory;
begin
    clock <= not clock after 142 ns when not finished else '0';

    process begin
        reset_n <= '0'; wait for 2 us; reset_n <= '1'; wait;
    end process;

{interrupt_logic}

    cpu : entity work.nexttang_spec256_cpu_cluster
        port map (
            reset_n => reset_n, clock => clock, sync_enable => '1',
            wait_n => '1', interrupt_n => interrupt_n, nmi_n => '1',
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
                end if;
            end loop;
        end if;
    end process;

    process begin
        wait for 300 us;
        assert main_memory(16#20#) = x"{expected[0]:02x}"
            report "{message}: main" severity failure;
{graphics_assertions}
{extra_assertions}
        report "{message} passed";
        finished <= true;
        wait;
    end process;
end architecture;
'''


def bootstrap_harness() -> str:
    """Prove snapshot restoration seeds every graphical CPU from the main CPU."""
    return '''\
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
    signal mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n : std_logic;
    signal graphics_address : std_logic_vector(127 downto 0);
    signal graphics_data_in, graphics_data_out : std_logic_vector(63 downto 0);
    signal graphics_iorq, graphics_write, graphics_running : std_logic_vector(7 downto 0);
    signal finished : boolean := false;

    type memory_type is array (0 to 255) of std_logic_vector(7 downto 0);
    type graphics_memory_type is array (0 to 7, 0 to 255) of std_logic_vector(7 downto 0);

    signal main_memory : memory_type := (
        16#00# => x"3e", 16#01# => x"5a",             -- LD A,5A
        16#02# => x"32", 16#03# => x"30", 16#04# => x"00", -- LD (0030),A
        16#05# => x"c3", 16#06# => x"10", 16#07# => x"00", -- JP 0010
        16#10# => x"32", 16#11# => x"20", 16#12# => x"00", -- LD (0020),A
        16#13# => x"76", others => x"00"
    );
    function initial_graphics_memory return graphics_memory_type is
        variable result : graphics_memory_type := (others => (others => x"00"));
    begin
        for lane in 0 to 7 loop
            result(lane, 16#10#) := x"32";
            result(lane, 16#11#) := x"20";
            result(lane, 16#12#) := x"00";
            result(lane, 16#13#) := x"76";
        end loop;
        return result;
    end function;
    signal graphics_memory : graphics_memory_type := initial_graphics_memory;
begin
    clock <= not clock after 142 ns when not finished else '0';

    process begin
        reset_n <= '0'; wait for 2 us; reset_n <= '1'; wait;
    end process;

    -- The first game opcode at 0010 is the same hand-off boundary used by the
    -- real snapshot wrapper.  Until then every graphical CPU must consume the
    -- main bootstrap stream and must not mutate its coloured memory plane.
    process (clock) begin
        if rising_edge(clock) and reset_n = '1' and
           m1_n = '0' and mreq_n = '0' and address = x"0010" then
            bootstrap <= '0';
        end if;
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

    data_in <= main_memory(to_integer(unsigned(address(7 downto 0))));

    graphics_reads : process (all)
    begin
        for lane in 0 to 7 loop
            graphics_data_in(lane * 8 + 7 downto lane * 8) <=
                graphics_memory(
                    lane,
                    to_integer(unsigned(
                        graphics_address(lane * 16 + 7 downto lane * 16)
                    ))
                );
        end loop;
    end process;

    process (clock) begin
        if rising_edge(clock) then
            if mreq_n = '0' and wr_n = '0' then
                main_memory(to_integer(unsigned(address(7 downto 0)))) <= data_out;
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
                end if;
            end loop;
        end if;
    end process;

    process begin
        wait for 350 us;
        assert bootstrap = '0'
            report "snapshot bootstrap never reached its hand-off" severity failure;
        assert main_memory(16#20#) = x"5a"
            report "main CPU did not complete the post-bootstrap store" severity failure;
        for lane in 0 to 7 loop
            assert graphics_memory(lane, 16#30#) = x"00"
                report "bootstrap write leaked into graphical memory" severity failure;
            assert graphics_memory(lane, 16#20#) = x"5a"
                report "graphical CPU did not inherit snapshot data registers: lane " &
                    integer'image(lane) & " value " &
                    to_hstring(graphics_memory(lane, 16#20#)) severity failure;
        end loop;
        report "spec256 snapshot bootstrap synchronization passed";
        finished <= true;
        wait;
    end process;
end architecture;
'''


def synchronized_index_harness() -> str:
    """Exercise a DD/FD state injected exactly at an opcode boundary."""
    return '''\
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity testbench is end entity;

architecture sim of testbench is
    signal clock : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal sync_load : std_logic := '0';
    signal address : std_logic_vector(15 downto 0);
    signal data_in, data_out : std_logic_vector(7 downto 0);
    signal mreq_n, iorq_n, rd_n, wr_n, m1_n : std_logic;
    signal finished : boolean := false;
    type memory_type is array (0 to 65535) of std_logic_vector(7 downto 0);
    signal memory : memory_type := (
        16#0000# => x"dd", 16#0001# => x"21",
        16#0002# => x"30", 16#0003# => x"5d", -- LD IX,5D30
        16#0004# => x"21", 16#0005# => x"30",
        16#0006# => x"40", 16#0007# => x"76", -- LD HL,4030; HALT
        16#0010# => x"7e", 16#0011# => x"01", -- injected DD + LD A,(IX+1)
        16#0012# => x"32", 16#0013# => x"00",
        16#0014# => x"60", 16#0015# => x"76",
        16#4030# => x"55", 16#5d31# => x"a8",
        others => x"00"
    );
begin
    clock <= not clock after 142 ns when not finished else '0';
    process begin
        reset_n <= '0'; wait for 2 us; reset_n <= '1'; wait;
    end process;

    -- Wait until IX and HL are established, then reproduce the cluster's
    -- prefix-boundary state transfer: the PC points at the opcode following
    -- DD and XY selects IX before that opcode is decoded.
    process
        alias live_xy is
            << signal .testbench.cpu.z80n.XY_State : std_logic_vector(1 downto 0) >>;
    begin
        wait until reset_n = '1';
        wait until m1_n = '0' and address = x"0007";
        wait until rising_edge(clock);
        sync_load <= '1';
        wait until rising_edge(clock);
        sync_load <= '0';
        wait until falling_edge(clock);
        assert live_xy = "01"
            report "synchronized DD state was not live during opcode fetch"
            severity failure;
        wait;
    end process;

    data_in <= memory(to_integer(unsigned(address)));
    process (clock) begin
        if rising_edge(clock) and mreq_n = '0' and wr_n = '0' then
            memory(to_integer(unsigned(address))) <= data_out;
        end if;
    end process;

    cpu : entity work.T80Na
        generic map (Mode => 0)
        port map (
            RESET_n => reset_n, CLK_n => clock, WAIT_n => '1',
            INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
            M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n,
            RD_n => rd_n, WR_n => wr_n, RFSH_n => open,
            HALT_n => open, BUSAK_n => open, A => address,
            D_i => data_in, D_o => data_out,
            Spec256_sync_load => sync_load,
            Spec256_sync_pc => x"0010", Spec256_sync_sp => x"ffff",
            Spec256_sync_i => x"00", Spec256_sync_r => x"00",
            Spec256_sync_f => x"00", Spec256_sync_iff1 => '0',
            Spec256_sync_iff2 => '0', Spec256_sync_halted => '0',
            Spec256_sync_imode => "00", Spec256_sync_xy => "01",
            Spec256_sync_int_cycle => '0', Spec256_sync_nmi_cycle => '0',
            Spec256_state_pc => open, Spec256_state_sp => open,
            Spec256_state_i => open, Spec256_state_r => open,
            Spec256_state_f => open, Spec256_state_regs => open,
            Spec256_state_iff1 => open, Spec256_state_iff2 => open,
            Spec256_state_halted => open, Spec256_state_imode => open,
            Spec256_state_xy => open, Spec256_state_int_cycle => open,
            Spec256_state_nmi_cycle => open,
            Spec256_state_instruction_boundary => open,
            Z80N_dout_o => open, Z80N_data_o => open,
            Z80N_command_o => open
        );

    process begin
        wait for 120 us;
        assert memory(16#6000#) = x"a8"
            report "synchronized DD state was applied after opcode decode"
            severity failure;
        report "synchronized DD state was live before opcode decode";
        finished <= true;
        wait;
    end process;
end architecture;
'''


class Spec256CpuClusterTests(unittest.TestCase):
    def run_harness(self, source: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            testbench = work / "testbench.vhd"
            testbench.write_text(source, encoding="utf-8")

            for path in CPU_SOURCES + [testbench]:
                result = subprocess.run(
                    ["ghdl", "-a", "--std=08", "-frelaxed",
                     f"--workdir={work}", str(path)],
                    check=False, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

            return subprocess.run(
                ["ghdl", "-r", "--std=08", f"--workdir={work}",
                 "testbench", "--assert-level=error"],
                check=False, capture_output=True, text=True, cwd=work,
            )

    def test_graphical_lanes_use_independent_memory_addresses(self) -> None:
        source = harness(
            {
                0x00: 0x3A, 0x01: 0x10, 0x02: 0x00,
                0x03: 0x32, 0x04: 0x20, 0x05: 0x00, 0x06: 0x76,
            },
            main_value=0x80,
            graphics_values=(0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80),
            expected=(0x80, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80),
            message="spec256 independent graphical memory",
        )
        result = self.run_harness(source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_synchronized_index_state_is_live_before_opcode_decode(self) -> None:
        result = self.run_harness(synchronized_index_harness())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_graphical_lanes_follow_master_noncarry_control_flow(self) -> None:
        source = harness(
            {
                0x00: 0x3A, 0x01: 0x10, 0x02: 0x00,
                0x03: 0xB7, 0x04: 0x20, 0x05: 0x02,
                0x06: 0x3E, 0x07: 0x55,
                0x08: 0x32, 0x09: 0x20, 0x0A: 0x00, 0x0B: 0x76,
            },
            main_value=0x00,
            graphics_values=(0x01,) * 8,
            expected=(0x55,) * 9,
            message="spec256 master-control synchronization",
        )
        result = self.run_harness(source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_graphical_lanes_inherit_master_index_prefix_state(self) -> None:
        source = harness(
            {
                0x00: 0xDD,
                0x01: 0x21, 0x02: 0x10, 0x03: 0x00,
                0x04: 0xDD,
                0x05: 0x7E, 0x06: 0x00,
                0x07: 0x32, 0x08: 0x20, 0x09: 0x00,
                0x0A: 0x76,
            },
            main_value=0x80,
            graphics_values=(0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80),
            expected=(0x80, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80),
            message="spec256 master index-prefix synchronization",
            graphics_program={0x00: 0x00},
        )
        result = self.run_harness(source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ed_second_opcode_stays_inside_the_same_instruction(self) -> None:
        source = harness(
            {
                0x00: 0x3E, 0x01: 0x01,
                0x02: 0xED, 0x03: 0x44,
                0x04: 0x32, 0x05: 0x20, 0x06: 0x00,
                0x07: 0x76,
            },
            main_value=0x00,
            graphics_values=(0x00,) * 8,
            expected=(0xFF,) * 9,
            message="spec256 ED instruction boundary",
        )
        result = self.run_harness(source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_graphical_lanes_follow_the_master_interrupt_cycle(self) -> None:
        stack_assertions = """
        assert main_memory(16#ee#) = x"07" and
               main_memory(16#ef#) = x"00"
            report "main interrupt return address was not stacked" severity failure;
        for lane in 0 to 7 loop
            assert graphics_memory(lane, 16#ee#) = x"07" and
                   graphics_memory(lane, 16#ef#) = x"00"
                report "graphical interrupt cycle did not follow the main CPU: lane " &
                    integer'image(lane) severity failure;
        end loop;
"""
        source = harness(
            {
                0x00: 0x31, 0x01: 0xF0, 0x02: 0x00,  # LD SP,00F0
                0x03: 0xED, 0x04: 0x56,              # IM 1
                0x05: 0xFB,                          # EI
                0x06: 0x00,                          # NOP; interrupt follows
                0x07: 0x3E, 0x08: 0x5A,
                0x09: 0x32, 0x0A: 0x20, 0x0B: 0x00,
                0x0C: 0x76,
                0x38: 0xC9,                          # IM1 handler: RET
            },
            main_value=0x00,
            graphics_values=(0x00,) * 8,
            expected=(0x5A,) * 9,
            message="spec256 master interrupt synchronization",
            graphics_program={0x06: 0xFB},
            interrupt_at=0x06,
            extra_assertions=stack_assertions,
        )
        result = self.run_harness(source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_snapshot_bootstrap_seeds_graphical_data_registers(self) -> None:
        result = self.run_harness(bootstrap_harness())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_sync_cycle_does_not_corrupt_exx_register_bank(self) -> None:
        result = self.run_harness(harness(
            {
                0x00: 0x01, 0x01: 0x34, 0x02: 0x12,  # LD BC,1234
                0x03: 0xD9,                          # EXX
                0x04: 0x01, 0x05: 0xA2, 0x06: 0xA1,  # LD BC,A1A2
                0x07: 0x78,                          # LD A,B
                0x08: 0x32, 0x09: 0x20, 0x0A: 0x00,  # LD (0020),A
                0x0B: 0x76,                          # HALT
            },
            main_value=0x00,
            graphics_values=(0x00,) * 8,
            expected=(0xA1,) * 9,
            message="Spec256 sync corrupted EXX register bank",
        ))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_graphical_fetch_restarts_at_synchronized_pc(self) -> None:
        result = self.run_harness(harness(
            {
                0x00: 0xC3, 0x01: 0x30, 0x02: 0x00,  # main: JP 0030
                0x30: 0x3E, 0x31: 0x5A,              # LD A,5A
                0x32: 0x32, 0x33: 0x20, 0x34: 0x00,  # LD (0020),A
                0x35: 0x76,                          # HALT
            },
            main_value=0x00,
            graphics_values=(0x00,) * 8,
            graphics_program={
                0x00: 0xC3, 0x01: 0x40, 0x02: 0x00,  # graphical: JP 0040
                0x40: 0xAF,                          # stale fetch: XOR A
            },
            expected=(0x5A,) * 9,
            message="graphical CPU executed a stale pre-sync opcode fetch",
        ))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
