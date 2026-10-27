-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- nexttang_zxnext_cpu_enables against the reference CPU clock rule.
--
-- Speed, pixel-counter bit and contention change at random, on falling edges as
-- the core's outputs would, and the 7 MHz clock starts at the phase PHASE
-- selects. Before every rising edge of clock_28 the generator's o_CEN_R must
-- equal "the reference clock rises here", and before every falling edge its
-- o_CEN_F must equal "the reference clock falls here or fell on the rising
-- edge just gone", which is where the converted core runs that work.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.cpu_clock_reference_pkg.all;

entity tb_cpu_enables is
    generic (
        PHASE  : natural := 0;
        CYCLES : natural := 200000;
        SEED   : positive := 1
    );
end entity;

architecture sim of tb_cpu_enables is
    constant HALF : time := 17857 ps;
    signal clock_28, clock_7 : std_logic := '0';
    signal speed    : std_logic_vector(1 downto 0) := "00";
    signal lsb, contend : std_logic := '0';
    signal cen_r, cen_f, locked : std_logic;
begin
    dut : entity work.nexttang_zxnext_cpu_enables
        port map (
            i_CLK_28 => clock_28,
            i_CLK_7 => clock_7,
            i_CPU_SPEED => speed,
            i_CPU_CONTEND => contend,
            i_CPU_CLK_LSB => lsb,
            o_CEN_R => cen_r,
            o_CEN_F => cen_f,
            o_LOCKED => locked
        );

    process
        variable position : natural range 0 to 3 := PHASE mod 4;
        variable first_7  : natural := (4 - PHASE mod 4) mod 4;
        variable selected : std_logic_vector(1 downto 0) := "00";
        variable level    : std_logic := '0';
        variable at_28, rises, falls : boolean;
        variable fall_due : boolean := false;
        variable seed_1   : positive := SEED;
        variable seed_2   : positive := 7919;
        variable draw     : real;
        variable checked_rises, checked_falls : natural := 0;
        variable speeds_seen : std_logic_vector(3 downto 0) := "0000";
    begin
        for cycle in 0 to CYCLES - 1 loop
            -- Rising edge: the generator's enable, before the edge, against
            -- the reference decision for this edge.
            if cycle >= first_7 then
                cpu_clock_rising_edge(cycle - first_7, position, speed, lsb, contend,
                                      selected, level, at_28, rises, falls);
            else
                at_28 := false; rises := false; falls := false;
            end if;
            assert (cen_r = '1') = rises
                report "cycle " & integer'image(cycle) & ": CEN_R " & std_logic'image(cen_r) &
                       " but the reference " & boolean'image(rises)
                severity failure;
            if rises then checked_rises := checked_rises + 1; end if;
            fall_due := falls or at_28;
            if at_28 then level := '0'; end if;
            if cycle >= first_7 + START_CYCLE then
                speeds_seen(to_integer(unsigned(selected))) := '1';
            end if;

            clock_28 <= '1';
            -- The divider leaves reset low, so its first rising edge is a
            -- genuine one at position 0.
            if cycle >= first_7 and (position = 0 or position = 1) then
                clock_7 <= '1';
            else
                clock_7 <= '0';
            end if;
            wait for HALF;

            assert (cen_f = '1') = fall_due
                report "cycle " & integer'image(cycle) & ": CEN_F " & std_logic'image(cen_f) &
                       " but the reference " & boolean'image(fall_due)
                severity failure;
            if fall_due then checked_falls := checked_falls + 1; end if;

            clock_28 <= '0';
            uniform(seed_1, seed_2, draw);
            if draw < 0.02 then
                uniform(seed_1, seed_2, draw);
                speed <= std_logic_vector(to_unsigned(integer(floor(draw * 4.0)) mod 4, 2));
            end if;
            uniform(seed_1, seed_2, draw);
            if draw < 0.5 then lsb <= not lsb; end if;
            uniform(seed_1, seed_2, draw);
            if draw < 0.3 then contend <= not contend; end if;
            position := (position + 1) mod 4;
            wait for HALF;
        end loop;

        assert locked = '1' report "the generator never locked" severity failure;
        assert speeds_seen = "1111" report "not every speed was exercised" severity failure;
        report "CPU_ENABLES_PASS rises=" & integer'image(checked_rises) &
               " falls=" & integer'image(checked_falls);
        wait;
    end process;
end architecture;
