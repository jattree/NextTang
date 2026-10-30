-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- Spec256's eight graphical CPUs, beside the ZX Next core's own.
--
-- Each lane is a T80N on the core's clock and enables, with the master's
-- WAIT, INT, NMI and BUSRQ, so it steps on exactly the master's cycles. In
-- follow mode a lane reads everything from the master's data bus and writes
-- nothing, so it is an exact copy of the master from reset: no
-- synchronisation is needed, and switching to graphics mode at an
-- instruction boundary hands every lane the master's whole state, as the
-- original Spec256 does when it starts a game.
--
-- In graphics mode a lane reads data from its own colour plane, while
-- opcodes and operands still come from the master's bus. Its data, ALU and
-- carry are its own; every control decision (conditional jumps, calls,
-- returns, block repeats, DJNZ) is the master's, live, so the lane keeps the
-- master's timing without the master ever being held. At each instruction
-- boundary the master's state is loaded into the lanes once more (PC, SP,
-- flags but carry, the register snapshot used for effective addresses, and
-- so on). The T80 finishes writing the previous instruction's register
-- result on the second rising CPU edge of the next opcode fetch, so the load
-- waits for that edge, then takes the first 28 MHz cycle with no CPU enable;
-- one exists at 14 MHz and below. Spec256 games run at 3.5 MHz.
--
-- desync is set for good if any lane's bus strobes ever differ from the
-- master's: lockstep lost.

library ieee;
use ieee.std_logic_1164.all;

entity nexttang_zxnext_spec256_lanes is
    port (
        clock_28      : in  std_logic;
        cen_r         : in  std_logic;
        cen_f         : in  std_logic;
        reset_n       : in  std_logic;
        -- Graphics mode; change it only at an instruction boundary.
        graphics      : in  std_logic;
        -- Control decisions from the master; off only to show, in a test,
        -- that lockstep depends on it.
        master_control : in std_logic := '1';

        -- The master, as the core sees it.
        master_m1_n     : in  std_logic;
        master_mreq_n   : in  std_logic;
        master_iorq_n   : in  std_logic;
        master_rd_n     : in  std_logic;
        master_wr_n     : in  std_logic;
        master_wait_n   : in  std_logic;
        master_int_n    : in  std_logic;
        master_nmi_n    : in  std_logic;
        master_busrq_n  : in  std_logic;
        master_data_in  : in  std_logic_vector(7 downto 0);
        master_pc       : in  std_logic_vector(15 downto 0);
        master_sp       : in  std_logic_vector(15 downto 0);
        master_i        : in  std_logic_vector(7 downto 0);
        master_r        : in  std_logic_vector(7 downto 0);
        master_f        : in  std_logic_vector(7 downto 0);
        master_regs     : in  std_logic_vector(159 downto 0);
        master_iff1     : in  std_logic;
        master_iff2     : in  std_logic;
        master_halted   : in  std_logic;
        master_imode    : in  std_logic_vector(1 downto 0);
        master_xy       : in  std_logic_vector(1 downto 0);
        master_int_cycle : in std_logic;
        master_nmi_cycle : in std_logic;
        master_instruction_boundary : in std_logic;
        master_incdecz  : in  std_logic;

        -- The colour planes, lane k in bits 8k+7 downto 8k (16k+15 downto
        -- 16k for addresses).
        graphics_address  : out std_logic_vector(127 downto 0);
        graphics_data_in  : in  std_logic_vector(63 downto 0);
        graphics_data_out : out std_logic_vector(63 downto 0);
        graphics_write    : out std_logic_vector(7 downto 0);
        graphics_iorq     : out std_logic_vector(7 downto 0);

        desync          : out std_logic;
        debug_lane_pc   : out std_logic_vector(127 downto 0);
        debug_lane_regs : out std_logic_vector(1279 downto 0)
    );
end entity;

architecture rtl of nexttang_zxnext_spec256_lanes is
    type word_array is array (0 to 7) of std_logic_vector(15 downto 0);

    signal lane_address : word_array;
    signal lane_m1_n, lane_mreq_n, lane_iorq_n, lane_rd_n, lane_wr_n : std_logic_vector(7 downto 0);
    signal lane_instruction_access : std_logic_vector(7 downto 0);

    signal master_previous_m1_n : std_logic := '1';
    -- 1: a boundary fetch began, waiting for its second rising CPU edge;
    -- 2: that edge has passed, load at the next cycle without an enable.
    signal sync_stage : natural range 0 to 2 := 0;
    signal sync_load : std_logic;
    signal desync_r : std_logic := '0';
begin
    -- sync_load overrides a lane's normal step on its edge, so it is never
    -- raised on an edge with a rising CPU enable.
    sync_load <= graphics and not cen_r when sync_stage = 2 else '0';
    desync <= desync_r;

    process (clock_28)
    begin
        if rising_edge(clock_28) then
            if reset_n = '0' then
                master_previous_m1_n <= '1';
                sync_stage <= 0;
                desync_r <= '0';
            else
                master_previous_m1_n <= master_m1_n;
                if graphics = '0' then
                    sync_stage <= 0;
                elsif master_previous_m1_n = '1' and master_m1_n = '0' and
                      master_instruction_boundary = '1' then
                    sync_stage <= 1;
                elsif sync_stage = 1 and cen_r = '1' then
                    sync_stage <= 2;
                elsif sync_load = '1' then
                    sync_stage <= 0;
                end if;
                for lane in 0 to 7 loop
                    if lane_m1_n(lane) /= master_m1_n or lane_mreq_n(lane) /= master_mreq_n or
                       lane_iorq_n(lane) /= master_iorq_n or lane_rd_n(lane) /= master_rd_n or
                       lane_wr_n(lane) /= master_wr_n then
                        desync_r <= '1';
                    end if;
                end loop;
            end if;
        end if;
    end process;

    lanes : for lane in 0 to 7 generate
        signal data_in : std_logic_vector(7 downto 0);
    begin
        graphics_address(lane * 16 + 15 downto lane * 16) <= lane_address(lane);
        graphics_write(lane) <= graphics and not lane_wr_n(lane) and not lane_mreq_n(lane);
        graphics_iorq(lane) <= graphics and not lane_iorq_n(lane);
        data_in <= master_data_in when graphics = '0' or lane_instruction_access(lane) = '1' else
                   graphics_data_in(lane * 8 + 7 downto lane * 8);

        cpu : entity work.T80Na
            generic map (Mode => 0)
            port map (
                RESET_n => reset_n,
                CLK_n => clock_28,
                CEN_R => cen_r,
                CEN_F => cen_f,
                WAIT_n => master_wait_n,
                INT_n => master_int_n,
                NMI_n => master_nmi_n,
                BUSRQ_n => master_busrq_n,
                M1_n => lane_m1_n(lane),
                MREQ_n => lane_mreq_n(lane),
                IORQ_n => lane_iorq_n(lane),
                RD_n => lane_rd_n(lane),
                WR_n => lane_wr_n(lane),
                RFSH_n => open,
                HALT_n => open,
                BUSAK_n => open,
                A => lane_address(lane),
                D_i => data_in,
                D_o => graphics_data_out(lane * 8 + 7 downto lane * 8),
                Spec256_sync_load => sync_load,
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
                Spec256_master_addressing => graphics,
                Spec256_master_regs => master_regs,
                Spec256_master_control => graphics and master_control,
                Spec256_master_incdecz => master_incdecz,
                Spec256_state_pc => debug_lane_pc(lane * 16 + 15 downto lane * 16),
                Spec256_state_sp => open,
                Spec256_state_i => open,
                Spec256_state_r => open,
                Spec256_state_f => open,
                Spec256_state_regs => debug_lane_regs(lane * 160 + 159 downto lane * 160),
                Spec256_state_iff1 => open,
                Spec256_state_iff2 => open,
                Spec256_state_halted => open,
                Spec256_state_imode => open,
                Spec256_state_xy => open,
                Spec256_state_int_cycle => open,
                Spec256_state_nmi_cycle => open,
                Spec256_state_instruction_boundary => open,
                Spec256_state_incdecz => open,
                Spec256_instruction_access => lane_instruction_access(lane),
                Z80N_dout_o => open,
                Z80N_data_o => open,
                Z80N_command_o => open
            );
    end generate;
end architecture;
