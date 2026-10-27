-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- Clock enables that let the ZX Next core's CPU run on clock_28.
--
-- Upstream clocks the CPU, and the logic around it, from a separate CPU clock:
-- at 3.5 MHz a contended clock updated on each 7 MHz edge, at 7 and 14 MHz the
-- pixel clocks, at 28 MHz clock_28 itself. On the Console that clock came from
-- fabric through a speed-select DCS, a path Gowin's tools neither analyse nor
-- constrain, and its delay broke hold timing between the CPU and the machine
-- clocks. Here the CPU clock is never built. This entity tracks what its level
-- would be and tells the converted core when it would have changed:
--
--   o_CEN_R  high in the 28 MHz cycle before a rising edge of the CPU clock.
--            Logic upstream clocks on the CPU's rising edge runs on
--            rising_edge(clock_28) with this enable.
--   o_CEN_F  high in the half cycle before a falling edge. Logic upstream
--            clocks on the CPU's falling edge runs on falling_edge(clock_28)
--            with this enable.
--
-- Every CPU edge at 3.5, 7 and 14 MHz falls on a rising edge of clock_28, and
-- at 28 MHz the falling edge is clock_28's falling edge. A rising CPU edge
-- therefore maps exactly. A falling CPU edge at the slower speeds cannot run
-- on the clock_28 rising edge it belongs to, because at 28 MHz the same logic
-- needs the falling edge, so it runs on the following falling edge, half a
-- 28 MHz cycle late. Late, never early: anything clocked on a rising edge of
-- clock_28, clock_14 or clock_7 sees the same values on the same edge, because
-- the earliest it could look is the next rising edge.
--
-- The rules are MiSTer's zxnext_top. At 3.5 MHz, on each 7 MHz rising edge,
-- the clock falls if the pixel counter's low bit is set and the CPU is not
-- contended, and rises if the bit is clear. 7 and 14 MHz follow clock_7 and
-- clock_14. 28 MHz rises and falls with clock_28. A requested speed is adopted
-- on the 28 MHz edge before a 7 MHz edge.
--
-- clock_7 comes from a divider whose phase against clock_28 is set at
-- configuration and is not predictable, so it is measured. clock_7 flips a
-- marker on each rising edge, the marker is sampled on clock_28's falling
-- edge, half a cycle from any clock_7 edge, and a change seen on the next
-- rising edge places the count. Nothing is enabled until then.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nexttang_zxnext_cpu_enables is
    port (
        i_CLK_28      : in  std_logic;
        i_CLK_7       : in  std_logic;
        i_CPU_SPEED   : in  std_logic_vector(1 downto 0);
        i_CPU_CONTEND : in  std_logic;
        i_CPU_CLK_LSB : in  std_logic;
        o_CEN_R       : out std_logic;
        o_CEN_F       : out std_logic;
        o_LOCKED      : out std_logic
    );
end entity;

architecture rtl of nexttang_zxnext_cpu_enables is
    signal marker         : std_logic := '0';
    signal marker_falling : std_logic := '0';
    signal marker_rising  : std_logic := '0';
    signal locked         : std_logic := '0';
    -- Where the next rising edge of clock_28 falls in the 7 MHz period:
    -- 0 is a 7 MHz rising edge, 2 a 7 MHz falling edge.
    signal position       : unsigned(1 downto 0) := "00";
    signal selected       : std_logic_vector(1 downto 0) := "00";
    signal level          : std_logic := '0';
    signal level_next     : std_logic;
    signal falling_due    : std_logic := '0';
begin
    process (i_CLK_7)
    begin
        if rising_edge(i_CLK_7) then
            marker <= not marker;
        end if;
    end process;

    process (i_CLK_28)
    begin
        if falling_edge(i_CLK_28) then
            marker_falling <= marker;
        end if;
    end process;

    -- The CPU clock's level after the next rising edge of clock_28.
    process (selected, position, level, i_CPU_CLK_LSB, i_CPU_CONTEND)
    begin
        level_next <= level;
        case selected is
            when "00" =>
                if position = 0 then
                    if i_CPU_CLK_LSB = '1' and i_CPU_CONTEND = '0' then
                        level_next <= '0';
                    elsif i_CPU_CLK_LSB = '0' then
                        level_next <= '1';
                    end if;
                end if;
            when "01" =>
                if position = 0 then
                    level_next <= '1';
                elsif position = 2 then
                    level_next <= '0';
                end if;
            when "10" =>
                if position = 0 or position = 2 then
                    level_next <= '1';
                else
                    level_next <= '0';
                end if;
            when others =>
                level_next <= '1';
        end case;
    end process;

    o_CEN_R <= locked and not level and level_next;

    process (i_CLK_28)
    begin
        if rising_edge(i_CLK_28) then
            marker_rising <= marker_falling;
            if marker_falling /= marker_rising then
                -- This edge is the one after a 7 MHz rising edge.
                position <= "10";
                locked <= '1';
            else
                position <= position + 1;
            end if;

            if locked = '1' then
                if selected = "11" then
                    -- Rises on this edge and falls on the next falling edge.
                    falling_due <= '1';
                    level <= '0';
                else
                    falling_due <= level and not level_next;
                    level <= level_next;
                end if;
                if position = 3 then
                    selected <= i_CPU_SPEED;
                end if;
            end if;
        end if;
    end process;

    o_CEN_F <= falling_due;
    o_LOCKED <= locked;
end architecture;
