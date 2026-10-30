-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- Spec256's eight graphical CPUs, beside the ZX Next core's own.
--
-- Each lane is a T80N on the core's clock and enables, with the master's
-- WAIT, INT, NMI and BUSRQ, so it steps on exactly the master's cycles, one
-- 28 MHz cycle later. Its strobes, WAIT, interrupts and state are registered
-- first, on the edge the T80 samples each on (WAIT on both), the enables and
-- reset with them. Data comes from the master's own registers instead of the
-- bus (see master_ir). Taking the bus directly, the master's data, after the
-- core's input multiplexer, had half a 28 MHz cycle to reach eight lanes
-- spread over the chip, and did not make it. In
-- follow mode a lane reads everything from the master's data bus and writes
-- nothing, so it is an exact copy of the master from reset: no
-- synchronisation is needed, and switching to graphics mode at an
-- instruction boundary hands every lane the master's whole state, as the
-- original Spec256 does when it starts a game.
--
-- In graphics mode a lane reads data from its own colour plane, while
-- opcodes and operands still come from the master's bus, and so do reads
-- below 0x4000 (Spec256's default for a game without a coloured ROM: every
-- plane sees the master's ROM byte) and I/O reads. With rom_planes, a game's
-- coloured ROM character set is loaded: data reads from 0x3D00 to 0x3FFF
-- then come from the lane's own plane too (the board serves them), as in
-- Alberto Conde's SPEC256_MISTER, which colours only the character set. Its data, ALU and
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
-- With arith_mono (the .256's RUL1 flag for Spec256 DOS games), a boundary
-- after an instruction that computes the accumulator also loads the master's
-- A into every lane, as the DOS program does: ADD, ADC, SUB and SBC (0x80
-- to 0x9F), ADD/ADC/SUB/SBC/AND/XOR/OR n, INC A, DEC A, DAA, LD A,n,
-- IN A,(n), and after ED, NEG, LD A,I, LD A,R and IN A,(C), with DD/FD forms
-- counted and CB forms not. AND, XOR, OR and CP on registers and CP n are not
-- on the list. It is Alberto Conde's (SPEC256_MISTER, writes_acc), kept
-- exactly. The opcodes are the
-- master's, taken from its opcode register as each opcode fetch ends.
--
-- desync is set for good if any lane's bus strobes ever differ from the
-- master's a cycle before, or if a lane reads or writes memory or I/O at an
-- address other than the master's: lockstep lost. Every lane addresses
-- memory through the master's registers, so one address serves all eight
-- planes. A lane that took the wrong path would still be handed the master's
-- opcodes, so the address is what shows it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

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
        -- A coloured ROM character set (0x3D00 to 0x3FFF) is in the planes.
        rom_planes     : in std_logic := '0';
        -- The master's accumulator after arithmetic (Spec256 DOS games).
        arith_mono     : in std_logic := '0';

        -- The master, as the core sees it.
        master_a        : in  std_logic_vector(15 downto 0);
        master_m1_n     : in  std_logic;
        master_mreq_n   : in  std_logic;
        master_iorq_n   : in  std_logic;
        master_rd_n     : in  std_logic;
        master_wr_n     : in  std_logic;
        master_wait_n   : in  std_logic;
        master_int_n    : in  std_logic;
        master_nmi_n    : in  std_logic;
        master_busrq_n  : in  std_logic;
        -- The master's opcode, IM2 vector and falling-edge data registers.
        -- A lane a cycle behind takes these instead of the data bus: each holds
        -- what the bus carried when the master latched it, a cycle before the
        -- lane latches the same thing, so the lanes add no load to the core's
        -- data bus.
        master_ir       : in  std_logic_vector(7 downto 0);
        master_vector   : in  std_logic_vector(7 downto 0);
        master_di       : in  std_logic_vector(7 downto 0);
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

    function writes_acc(op : std_logic_vector(7 downto 0)) return boolean is
        variable v : natural;
    begin
        v := to_integer(unsigned(op));
        if v >= 16#80# and v <= 16#9F# then
            return true;
        end if;
        case v is
            when 16#C6# | 16#CE# | 16#D6# | 16#DE# | 16#E6# | 16#EE# | 16#F6# |
                 16#3C# | 16#3D# | 16#27# | 16#3E# | 16#DB# => return true;
            when others => return false;
        end case;
    end function;

    function writes_acc_ed(op : std_logic_vector(7 downto 0)) return boolean is
    begin
        case to_integer(unsigned(op)) is
            when 16#44# | 16#4C# | 16#54# | 16#5C# | 16#64# | 16#6C# | 16#74# | 16#7C# |
                 16#57# | 16#5F# | 16#78# => return true;
            when others => return false;
        end case;
    end function;

    -- The master, a cycle late: rising-edge copies, and falling-edge copies
    -- of the two inputs the T80 also samples on falling edges.
    signal reset_d, cen_r_d, cen_f_d, graphics_d : std_logic := '0';
    signal m1_d, mreq_d, iorq_d, rd_d, wr_d : std_logic := '1';
    signal wait_d, wait_fall_d, int_d, nmi_d, busrq_d : std_logic := '1';
    signal a_d, pc_d, sp_d : std_logic_vector(15 downto 0) := (others => '0');
    signal i_d, r_d, f_d : std_logic_vector(7 downto 0) := (others => '0');
    signal regs_d : std_logic_vector(159 downto 0) := (others => '0');
    signal iff1_d, iff2_d, halted_d, int_cycle_d, nmi_cycle_d, boundary_d, incdecz_d : std_logic := '0';
    signal imode_d, xy_d : std_logic_vector(1 downto 0) := (others => '0');

    signal lane_address : word_array;
    signal lane_m1_n, lane_mreq_n, lane_iorq_n, lane_rd_n, lane_wr_n : std_logic_vector(7 downto 0);
    signal lane_instruction_access : std_logic_vector(7 downto 0);

    signal master_previous_m1_n : std_logic := '1';
    -- 1: a boundary fetch began, waiting for its second rising CPU edge;
    -- 2: that edge has passed, load at the next cycle without an enable.
    signal sync_stage : natural range 0 to 2 := 0;
    signal sync_load : std_logic;
    signal desync_r : std_logic := '0';

    -- The master's opcodes: 00 none, 01 after CB, 10 after ED, 11 after DD/FD.
    signal fetch_seen : std_logic := '0';
    signal prefix : std_logic_vector(1 downto 0) := "00";
    signal acc_written : std_logic := '0';  -- the last whole instruction computed A
    signal sync_acc : std_logic := '0';     -- for the sync load in progress
begin
    process (clock_28)
    begin
        if rising_edge(clock_28) then
            reset_d <= reset_n;
            cen_r_d <= cen_r;
            graphics_d <= graphics;
            a_d <= master_a;
            m1_d <= master_m1_n; mreq_d <= master_mreq_n; iorq_d <= master_iorq_n;
            rd_d <= master_rd_n; wr_d <= master_wr_n;
            wait_d <= master_wait_n; int_d <= master_int_n; nmi_d <= master_nmi_n;
            busrq_d <= master_busrq_n;
            pc_d <= master_pc; sp_d <= master_sp; i_d <= master_i; r_d <= master_r;
            f_d <= master_f; regs_d <= master_regs; iff1_d <= master_iff1; iff2_d <= master_iff2;
            halted_d <= master_halted; imode_d <= master_imode; xy_d <= master_xy;
            int_cycle_d <= master_int_cycle; nmi_cycle_d <= master_nmi_cycle;
            boundary_d <= master_instruction_boundary; incdecz_d <= master_incdecz;
        end if;
        if falling_edge(clock_28) then
            cen_f_d <= cen_f;
            wait_fall_d <= master_wait_n;
        end if;
    end process;

    -- sync_load overrides a lane's normal step on its edge, so it is never
    -- raised on an edge with a rising CPU enable.
    sync_load <= graphics_d and not cen_r_d when sync_stage = 2 else '0';
    desync <= desync_r;

    process (clock_28)
    begin
        if rising_edge(clock_28) then
            if reset_d = '0' then
                master_previous_m1_n <= '1';
                sync_stage <= 0;
                desync_r <= '0';
                fetch_seen <= '0';
                prefix <= "00";
                acc_written <= '0';
                sync_acc <= '0';
            else
                master_previous_m1_n <= m1_d;
                -- An opcode fetch is M1 with MREQ (an interrupt acknowledge
                -- has IORQ instead); its opcode is in the master's register
                -- by the time M1 ends.
                if m1_d = '0' and mreq_d = '0' then
                    fetch_seen <= '1';
                elsif master_previous_m1_n = '0' and m1_d = '1' then
                    fetch_seen <= '0';
                    if fetch_seen = '1' then
                        if master_ir = x"CB" and prefix /= "11" then
                            prefix <= "01";
                        elsif master_ir = x"ED" then
                            prefix <= "10";
                        elsif master_ir = x"DD" or master_ir = x"FD" then
                            prefix <= "11";
                        else
                            prefix <= "00";
                            if prefix = "01" then
                                acc_written <= '0';
                            elsif prefix = "10" and writes_acc_ed(master_ir) then
                                acc_written <= '1';
                            elsif prefix /= "10" and writes_acc(master_ir) then
                                acc_written <= '1';
                            else
                                acc_written <= '0';
                            end if;
                        end if;
                    end if;
                end if;
                if graphics_d = '0' then
                    sync_stage <= 0;
                elsif master_previous_m1_n = '1' and m1_d = '0' and boundary_d = '1' then
                    sync_stage <= 1;
                    sync_acc <= arith_mono and acc_written;
                elsif sync_stage = 1 and cen_r_d = '1' then
                    sync_stage <= 2;
                elsif sync_load = '1' then
                    sync_stage <= 0;
                end if;
                -- A lane now is the master a cycle ago.
                for lane in 0 to 7 loop
                    if lane_m1_n(lane) /= m1_d or lane_mreq_n(lane) /= mreq_d or
                       lane_iorq_n(lane) /= iorq_d or lane_rd_n(lane) /= rd_d or
                       lane_wr_n(lane) /= wr_d then
                        desync_r <= '1';
                    end if;
                    if ((lane_mreq_n(lane) = '0' and (lane_rd_n(lane) = '0' or lane_wr_n(lane) = '0')) or
                        lane_iorq_n(lane) = '0') and lane_address(lane) /= a_d then
                        desync_r <= '1';
                    end if;
                end loop;
            end if;
        end if;
    end process;

    lanes : for lane in 0 to 7 generate
        signal own_data, data_in_fall : std_logic_vector(7 downto 0);
        signal from_master : boolean;
    begin
        graphics_address(lane * 16 + 15 downto lane * 16) <= lane_address(lane);
        graphics_write(lane) <= graphics_d and not lane_wr_n(lane) and not lane_mreq_n(lane);
        graphics_iorq(lane) <= graphics_d and not lane_iorq_n(lane);
        own_data <= graphics_data_in(lane * 8 + 7 downto lane * 8);
        from_master <= graphics_d = '0' or lane_instruction_access(lane) = '1' or
                       lane_iorq_n(lane) = '0' or
                       (lane_address(lane)(15 downto 14) = "00" and
                        not (rom_planes = '1' and unsigned(lane_address(lane)(13 downto 8)) >= 16#3D#));
        data_in_fall <= master_di when from_master else own_data;

        cpu : entity work.T80Na
            generic map (Mode => 0)
            port map (
                RESET_n => reset_d,
                CLK_n => clock_28,
                CEN_R => cen_r_d,
                CEN_F => cen_f_d,
                WAIT_n => wait_d,
                INT_n => int_d,
                NMI_n => nmi_d,
                BUSRQ_n => busrq_d,
                M1_n => lane_m1_n(lane),
                MREQ_n => lane_mreq_n(lane),
                IORQ_n => lane_iorq_n(lane),
                RD_n => lane_rd_n(lane),
                WR_n => lane_wr_n(lane),
                RFSH_n => open,
                HALT_n => open,
                BUSAK_n => open,
                A => lane_address(lane),
                D_i => own_data,  -- unused: opcodes and vectors come from the master
                D_o => graphics_data_out(lane * 8 + 7 downto lane * 8),
                Split_edge_inputs => '1',
                D_i_fall => data_in_fall,
                WAIT_n_fall => wait_fall_d,
                Spec256_fetch_from_master => '1',
                Spec256_master_ir => master_ir,
                Spec256_master_vector => master_vector,
                Spec256_state_ir => open,
                Spec256_state_vector => open,
                Spec256_state_di => open,
                Spec256_sync_load => sync_load,
                Spec256_sync_pc => pc_d,
                Spec256_sync_sp => sp_d,
                Spec256_sync_i => i_d,
                Spec256_sync_r => r_d,
                Spec256_sync_f => f_d,
                Spec256_sync_iff1 => iff1_d,
                Spec256_sync_iff2 => iff2_d,
                Spec256_sync_halted => halted_d,
                Spec256_sync_imode => imode_d,
                Spec256_sync_xy => xy_d,
                Spec256_sync_int_cycle => int_cycle_d,
                Spec256_sync_nmi_cycle => nmi_cycle_d,
                Spec256_sync_acc => sync_acc,
                Spec256_master_addressing => graphics_d,
                Spec256_master_regs => regs_d,
                Spec256_master_control => graphics_d and master_control,
                Spec256_master_incdecz => incdecz_d,
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
