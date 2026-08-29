-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- Spec256 CPU/GPU execution cluster.
--
-- The ordinary Z80 owns I/O and machine control. Eight graphical Z80s keep
-- independent data registers, carry flags and memory address spaces. At each
-- instruction boundary they are synchronized to the ordinary CPU's control
-- state, matching the execution contract used by current Spec256 software.

library ieee;
use ieee.std_logic_1164.all;

entity nexttang_spec256_cpu_cluster is
    port (
        reset_n       : in  std_logic;
        clock         : in  std_logic;
        sync_enable   : in  std_logic;
        bootstrap     : in  std_logic := '0';
        wait_n        : in  std_logic;
        interrupt_n   : in  std_logic;
        nmi_n         : in  std_logic;
        bus_request_n : in  std_logic;

        m1_n          : out std_logic;
        mreq_n        : out std_logic;
        iorq_n        : out std_logic;
        rd_n          : out std_logic;
        wr_n          : out std_logic;
        rfsh_n        : out std_logic;
        halt_n        : out std_logic;
        address       : out std_logic_vector(15 downto 0);
        data_in       : in  std_logic_vector(7 downto 0);
        data_out      : out std_logic_vector(7 downto 0);

        graphics_address  : out std_logic_vector(127 downto 0);
        graphics_data_in  : in  std_logic_vector(63 downto 0);
        graphics_data_out : out std_logic_vector(63 downto 0);
        graphics_iorq     : out std_logic_vector(7 downto 0);
        graphics_write    : out std_logic_vector(7 downto 0);
        graphics_running  : out std_logic_vector(7 downto 0);

        debug_master_pc   : out std_logic_vector(15 downto 0);
        debug_graphics_pc : out std_logic_vector(127 downto 0);
        debug_master_regs : out std_logic_vector(159 downto 0);
        debug_graphics_regs : out std_logic_vector(1279 downto 0)
    );
end entity;

architecture rtl of nexttang_spec256_cpu_cluster is
    type word_array is array (0 to 7) of std_logic_vector(15 downto 0);
    type register_array is array (0 to 7) of std_logic_vector(159 downto 0);
    type barrier_state_type is
        (waiting_for_start, running, assert_sync, release_sync, prime_fetch);

    signal barrier_state : barrier_state_type := waiting_for_start;
    signal master_m1_n : std_logic;
    signal start_hold : std_logic;
    signal master_hold : std_logic := '0';
    signal master_done : std_logic := '0';
    signal master_previous_m1_n : std_logic := '1';

    signal master_pc : std_logic_vector(15 downto 0);
    signal master_sp : std_logic_vector(15 downto 0);
    signal master_i : std_logic_vector(7 downto 0);
    signal master_r : std_logic_vector(7 downto 0);
    signal master_f : std_logic_vector(7 downto 0);
    signal master_iff1 : std_logic;
    signal master_iff2 : std_logic;
    signal master_halted : std_logic;
    signal master_imode : std_logic_vector(1 downto 0);
    signal master_xy : std_logic_vector(1 downto 0);
    signal master_int_cycle : std_logic;
    signal master_nmi_cycle : std_logic;
    signal master_instruction_boundary : std_logic;
    signal master_regs : std_logic_vector(159 downto 0);

    signal gpu_address : word_array;
    signal gpu_m1_n : std_logic_vector(7 downto 0);
    signal gpu_mreq_n : std_logic_vector(7 downto 0);
    signal gpu_iorq_n : std_logic_vector(7 downto 0);
    signal gpu_wr_n : std_logic_vector(7 downto 0);
    signal gpu_hold : std_logic_vector(7 downto 0) := (others => '1');
    signal gpu_done : std_logic_vector(7 downto 0) := (others => '0');
    signal gpu_previous_m1_n : std_logic_vector(7 downto 0) := (others => '1');
    signal gpu_instruction_boundary : std_logic_vector(7 downto 0);
    signal gpu_regs : register_array;
    signal gpu_sync_load : std_logic := '0';
begin
    m1_n <= master_m1_n;
    graphics_iorq <= not gpu_iorq_n;
    -- Snapshot restoration is executable code on the physical Z80.  GZX
    -- instead loads the complete CPU state and clones it into every graphical
    -- context before execution begins.  While the bootstrap runs, make all
    -- graphical CPUs consume the same stream as the main CPU and prevent its
    -- temporary stack writes from touching the colour planes.  The CPUs then
    -- enter their independent memories with identical restored registers.
    graphics_write <= (others => '0') when bootstrap = '1' else
                      not gpu_wr_n and not gpu_mreq_n;
    graphics_running <= not gpu_hold;
    debug_master_pc <= master_pc;
    debug_master_regs <= master_regs;
    start_hold <= '1' when
        barrier_state = waiting_for_start and
        sync_enable = '1' and master_m1_n = '0'
        else '0';

    master : entity work.T80Na
        generic map (Mode => 0)
        port map (
            RESET_n => reset_n,
            CLK_n => clock,
            WAIT_n => wait_n and not master_hold and not start_hold,
            INT_n => interrupt_n,
            NMI_n => nmi_n,
            BUSRQ_n => bus_request_n,
            M1_n => master_m1_n,
            MREQ_n => mreq_n,
            IORQ_n => iorq_n,
            RD_n => rd_n,
            WR_n => wr_n,
            RFSH_n => rfsh_n,
            HALT_n => halt_n,
            BUSAK_n => open,
            A => address,
            D_i => data_in,
            D_o => data_out,
            Spec256_state_pc => master_pc,
            Spec256_state_sp => master_sp,
            Spec256_state_i => master_i,
            Spec256_state_r => master_r,
            Spec256_state_f => master_f,
            Spec256_state_regs => master_regs,
            Spec256_state_iff1 => master_iff1,
            Spec256_state_iff2 => master_iff2,
            Spec256_state_halted => master_halted,
            Spec256_state_imode => master_imode,
            Spec256_state_xy => master_xy,
            Spec256_state_int_cycle => master_int_cycle,
            Spec256_state_nmi_cycle => master_nmi_cycle,
            Spec256_state_instruction_boundary => master_instruction_boundary,
            Z80N_dout_o => open,
            Z80N_data_o => open,
            Z80N_command_o => open
        );

    graphical_lanes : for lane in 0 to 7 generate
        signal graphical_data_input : std_logic_vector(7 downto 0);
        signal graphical_pc : std_logic_vector(15 downto 0);
    begin
        graphics_address(lane * 16 + 15 downto lane * 16) <= gpu_address(lane);
        debug_graphics_pc(lane * 16 + 15 downto lane * 16) <= graphical_pc;
        debug_graphics_regs(lane * 160 + 159 downto lane * 160) <= gpu_regs(lane);
        graphical_data_input <= data_in when bootstrap = '1' else
            graphics_data_in(lane * 8 + 7 downto lane * 8);

        graphical_cpu : entity work.T80Na
            generic map (Mode => 0)
            port map (
                RESET_n => reset_n,
                CLK_n => clock,
                Spec256_cen => '1',
                WAIT_n => not gpu_hold(lane),
                INT_n => interrupt_n,
                NMI_n => nmi_n,
                BUSRQ_n => bus_request_n,
                M1_n => gpu_m1_n(lane),
                MREQ_n => gpu_mreq_n(lane),
                IORQ_n => gpu_iorq_n(lane),
                RD_n => open,
                WR_n => gpu_wr_n(lane),
                RFSH_n => open,
                HALT_n => open,
                BUSAK_n => open,
                A => gpu_address(lane),
                D_i => graphical_data_input,
                D_o => graphics_data_out(lane * 8 + 7 downto lane * 8),
                Spec256_sync_load => gpu_sync_load,
                Spec256_sync_pc => master_pc,
                Spec256_sync_sp => master_sp,
                Spec256_sync_i => master_i,
                Spec256_sync_r => master_r,
                Spec256_sync_f => master_f,
                Spec256_sync_iff1 => master_iff1,
                Spec256_sync_iff2 => master_iff2,
                Spec256_sync_halted => master_halted,
                Spec256_sync_imode => master_imode,
                Spec256_sync_xy => master_xy,
                Spec256_sync_int_cycle => master_int_cycle,
                Spec256_sync_nmi_cycle => master_nmi_cycle,
                Spec256_state_pc => graphical_pc,
                Spec256_state_sp => open,
                Spec256_state_i => open,
                Spec256_state_r => open,
                Spec256_state_f => open,
                Spec256_state_regs => gpu_regs(lane),
                Spec256_state_iff1 => open,
                Spec256_state_iff2 => open,
                Spec256_state_halted => open,
                Spec256_state_imode => open,
                Spec256_state_xy => open,
                Spec256_state_int_cycle => open,
                Spec256_state_nmi_cycle => open,
                Spec256_state_instruction_boundary => gpu_instruction_boundary(lane),
                Z80N_dout_o => open,
                Z80N_data_o => open,
                Z80N_command_o => open
            );
    end generate;

    process (clock)
    begin
        if rising_edge(clock) then
            if reset_n = '0' then
                barrier_state <= waiting_for_start;
                master_hold <= '0';
                master_done <= '0';
                master_previous_m1_n <= '1';
                gpu_hold <= (others => '1');
                gpu_done <= (others => '0');
                gpu_previous_m1_n <= (others => '1');
                gpu_sync_load <= '0';
            else
                master_previous_m1_n <= master_m1_n;
                gpu_previous_m1_n <= gpu_m1_n;
                gpu_sync_load <= '0';

                case barrier_state is
                    when waiting_for_start =>
                        if sync_enable = '1' and
                           master_previous_m1_n = '1' and master_m1_n = '0' then
                            master_hold <= '1';
                            master_done <= '1';
                            barrier_state <= assert_sync;
                        end if;

                    when running =>
                        if master_done = '0' and
                           master_instruction_boundary = '1' and
                           master_previous_m1_n = '1' and master_m1_n = '0' then
                            master_done <= '1';
                            master_hold <= '1';
                        end if;

                        for lane in 0 to 7 loop
                            if gpu_done(lane) = '0' and
                               gpu_instruction_boundary(lane) = '1' and
                               gpu_previous_m1_n(lane) = '1' and
                               gpu_m1_n(lane) = '0' then
                                gpu_done(lane) <= '1';
                                gpu_hold(lane) <= '1';
                            end if;
                        end loop;

                        if master_done = '1' and gpu_done = x"ff" then
                            barrier_state <= assert_sync;
                        end if;

                    when assert_sync =>
                        gpu_sync_load <= '1';
                        barrier_state <= release_sync;

                    when release_sync =>
                        -- The synchronized PC also replaces the live opcode
                        -- fetch address.  Keep every CPU held for one more
                        -- cycle so the synchronous ROM/RAM output can catch
                        -- up before T80 samples the opcode.
                        barrier_state <= prime_fetch;

                    when prime_fetch =>
                        master_hold <= '0';
                        master_done <= '0';
                        gpu_hold <= (others => '0');
                        gpu_done <= (others => '0');
                        master_previous_m1_n <= master_m1_n;
                        gpu_previous_m1_n <= gpu_m1_n;
                        barrier_state <= running;
                end case;
            end if;
        end if;
    end process;
end architecture;
