-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- The reference rule for the ZX Next CPU clock, as MiSTer's zxnext_top builds
-- it, evaluated at each rising edge of clock_28. Simulation only: the
-- testbenches use it to drive a real CPU clock into the unmodified core and to
-- check the enables nexttang_zxnext_cpu_enables gives the converted one.
--
-- position is where this rising edge falls in the 7 MHz period, 0 being a
-- 7 MHz rising edge. The rule takes effect from START_CYCLE, the first edge on
-- which the enable generator can have measured the 7 MHz phase, so the two
-- cores begin from the same state.

library ieee;
use ieee.std_logic_1164.all;

package cpu_clock_reference_pkg is
    constant START_CYCLE : natural := 2;

    procedure cpu_clock_rising_edge (
        constant cycle    : in    natural;
        constant position : in    natural;
        constant speed    : in    std_logic_vector(1 downto 0);
        constant lsb      : in    std_logic;
        constant contend  : in    std_logic;
        variable selected : inout std_logic_vector(1 downto 0);
        variable level    : inout std_logic;
        variable at_28    : out   boolean;
        variable rises    : out   boolean;
        variable falls    : out   boolean
    );
end package;

package body cpu_clock_reference_pkg is
    procedure cpu_clock_rising_edge (
        constant cycle    : in    natural;
        constant position : in    natural;
        constant speed    : in    std_logic_vector(1 downto 0);
        constant lsb      : in    std_logic;
        constant contend  : in    std_logic;
        variable selected : inout std_logic_vector(1 downto 0);
        variable level    : inout std_logic;
        variable at_28    : out   boolean;
        variable rises    : out   boolean;
        variable falls    : out   boolean
    ) is
        variable before : std_logic;
    begin
        at_28 := false;
        rises := false;
        falls := false;
        if cycle < START_CYCLE then
            return;
        end if;
        before := level;
        at_28 := selected = "11";
        case selected is
            when "00" =>
                if position = 0 then
                    if lsb = '1' and contend = '0' then
                        level := '0';
                    elsif lsb = '0' then
                        level := '1';
                    end if;
                end if;
            when "01" =>
                if position = 0 then
                    level := '1';
                elsif position = 2 then
                    level := '0';
                end if;
            when "10" =>
                if position = 0 or position = 2 then
                    level := '1';
                else
                    level := '0';
                end if;
            when others =>
                level := '1';
        end case;
        rises := before = '0' and level = '1';
        falls := before = '1' and level = '0';
        if position = 3 then
            selected := speed;
        end if;
    end procedure;
end package body;
