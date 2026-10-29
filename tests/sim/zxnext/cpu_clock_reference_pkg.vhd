-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- The reference rule for the ZX Next CPU clock, as MiSTer's zxnext_top builds
-- it, evaluated at each edge of clock_28. Simulation only: the testbenches use
-- it to drive a real CPU clock into the unmodified core and to check the
-- enables nexttang_zxnext_cpu_enables gives the converted one.
--
-- zxnext_top makes a slow clock, CLK_i0, from the selected speed (3.5 MHz
-- from the pixel counter and contention, 7 and 14 MHz from the 28 MHz
-- divider), adopting a requested speed on the 28 MHz edge before a 7 MHz
-- edge. A glitch-free multiplexer then gives the CPU either CLK_i0 or clock_28
-- itself, and it follows the requested speed directly:
--
--   q0 <= not is28 and q0_enable  on CLK_i0's rising edge
--   q1 <=     is28 and q1_enable  on clock_28's rising edge
--   q0_enable: cleared while q1 is set, else set on CLK_i0's falling edge
--   q1_enable: cleared while q0 is set, else set on clock_28's falling edge
--   CPU clock = CLK_i0 if q0, clock_28 if q1, otherwise held high
--
-- So a change to or from 28 MHz holds the CPU clock high until the other
-- source is running, and the core's memory timing, which changes with the
-- requested speed, never sees CPU edges at the old one. Changes among 3.5, 7
-- and 14 MHz pass straight through CLK_i0.
--
-- position is where this rising edge falls in the 7 MHz period, 0 being a
-- 7 MHz rising edge. The rule takes effect from START_CYCLE, the first edge on
-- which the enable generator can have measured the 7 MHz phase, so the two
-- cores begin from the same state.

library ieee;
use ieee.std_logic_1164.all;

package cpu_clock_reference_pkg is
    constant START_CYCLE : natural := 2;

    type cpu_clock_state is record
        slow      : std_logic;                     -- CLK_i0
        selected  : std_logic_vector(1 downto 0);  -- the speed CLK_i0 follows
        q0        : std_logic;
        q1        : std_logic;
        q0_enable : std_logic;
        q1_enable : std_logic;
        level     : std_logic;                     -- the CPU clock
    end record;

    -- Neither source passed and the clock held high. q1_enable is as the
    -- falling edge before START_CYCLE leaves it with q0 clear.
    constant CPU_CLOCK_START : cpu_clock_state :=
        (slow => '0', selected => "00", q0 => '0', q1 => '0',
         q0_enable => '0', q1_enable => '1', level => '1');

    -- At a rising edge of clock_28: whether the CPU clock rises or falls on
    -- it, and whether it will fall on the falling edge that follows.
    procedure cpu_clock_rising_edge (
        constant cycle    : in    natural;
        constant position : in    natural;
        constant speed    : in    std_logic_vector(1 downto 0);
        constant lsb      : in    std_logic;
        constant contend  : in    std_logic;
        variable state    : inout cpu_clock_state;
        variable at_28    : out   boolean;
        variable rises    : out   boolean;
        variable falls    : out   boolean
    );

    -- At the falling edge of clock_28 that follows.
    procedure cpu_clock_falling_edge (
        constant cycle : in    natural;
        variable state : inout cpu_clock_state
    );
end package;

package body cpu_clock_reference_pkg is
    procedure cpu_clock_rising_edge (
        constant cycle    : in    natural;
        constant position : in    natural;
        constant speed    : in    std_logic_vector(1 downto 0);
        constant lsb      : in    std_logic;
        constant contend  : in    std_logic;
        variable state    : inout cpu_clock_state;
        variable at_28    : out   boolean;
        variable rises    : out   boolean;
        variable falls    : out   boolean
    ) is
        variable before : std_logic;
        variable slow   : std_logic;
        variable is28   : std_logic;
    begin
        at_28 := false;
        rises := false;
        falls := false;
        if cycle < START_CYCLE then
            return;
        end if;
        before := state.level;

        -- CLK_i0, from the speed it has adopted.
        slow := state.slow;
        case state.selected is
            when "00" =>
                if position = 0 then
                    if lsb = '1' and contend = '0' then
                        slow := '0';
                    elsif lsb = '0' then
                        slow := '1';
                    end if;
                end if;
            when "01" =>
                if position = 0 or position = 1 then
                    slow := '1';
                else
                    slow := '0';
                end if;
            when others =>
                if position = 0 or position = 2 then
                    slow := '1';
                else
                    slow := '0';
                end if;
        end case;
        if position = 3 then
            state.selected := speed;
        end if;

        -- The multiplexer, from the speed requested now.
        if speed = "11" then is28 := '1'; else is28 := '0'; end if;
        state.q1 := is28 and state.q1_enable;
        if state.slow = '0' and slow = '1' then
            state.q0 := (not is28) and state.q0_enable;
        end if;
        if state.slow = '1' and slow = '0' then
            state.q0_enable := '1';
        end if;
        if state.q1 = '1' then
            state.q0_enable := '0';
        end if;
        if state.q0 = '1' then
            state.q1_enable := '0';
        end if;
        state.slow := slow;

        if state.q0 = '1' then
            state.level := slow;
        else
            -- clock_28 has just risen, and the held level is high too.
            state.level := '1';
        end if;
        rises := before = '0' and state.level = '1';
        falls := before = '1' and state.level = '0';
        at_28 := state.q0 = '0' and state.q1 = '1';
    end procedure;

    procedure cpu_clock_falling_edge (
        constant cycle : in    natural;
        variable state : inout cpu_clock_state
    ) is
    begin
        if cycle < START_CYCLE then
            return;
        end if;
        if state.q0 = '0' then
            state.q1_enable := '1';
            if state.q1 = '1' then
                state.level := '0';
            end if;
        end if;
    end procedure;
end package body;
