-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- Hardware PC breakpoints for the Next core's CPU.
--
-- The official Pi debug interface can pause and step the CPU but has no
-- breakpoints, and a host checking the PC between single steps over a UART
-- would be far too slow. Here each slot compares the address the CPU will
-- fetch its next instruction from, which the CPU reports at every
-- instruction end (o_CPU_NEXT_PC), with a breakpoint address. A match stops
-- the CPU at that instruction end, before the instruction at the breakpoint
-- runs, the way a Pi debug pause does (i_CPU_BREAK).
--
-- The CPU then holds itself until the Pi debug slave takes over: hit pulses
-- once when the CPU has stopped on a breakpoint, and the board answers by
-- sending the slave CMD_CPU_PAUSE, so to the host a breakpoint looks like a
-- pause and resume and single step work as they always do.
--
-- A slot may also name an 8K page (DZRP's "long" breakpoint): it then fires
-- only while that page is mapped in the slot holding its address, as JNext's
-- DZRP server does (doc/design/debug-subsystem/dzrp-frontend.md, 3.1). The
-- page test uses the breakpoint's own address, not the CPU's, so it is a
-- register refreshed every clock and adds nothing to the CPU's path; an MMU
-- write is at least an instruction before any fetch it affects.
--
-- Slots are written one at a time with a strobe. SLOTS comparators sit on the
-- CPU's instruction-end decision path, so the count is kept small.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nexttang_breakpoints is
   generic (
      SLOTS : positive := 10
   );
   port (
      clock         : in  std_logic;
      reset         : in  std_logic;

      write_strobe  : in  std_logic;
      write_slot    : in  std_logic_vector(7 downto 0);
      write_enable  : in  std_logic;
      write_address : in  std_logic_vector(15 downto 0);
      write_paged   : in  std_logic;
      write_page    : in  std_logic_vector(7 downto 0);
      mmu           : in  std_logic_vector(63 downto 0);   -- NextREG 0x57 & ... & 0x50

      next_pc       : in  std_logic_vector(15 downto 0);
      cpu_stopped   : in  std_logic;
      break_now     : out std_logic;
      hit           : out std_logic
   );
end entity;

architecture rtl of nexttang_breakpoints is
   type addresses_t is array (0 to SLOTS - 1) of std_logic_vector(15 downto 0);
   signal addresses : addresses_t := (others => (others => '0'));
   signal enabled   : std_logic_vector(SLOTS - 1 downto 0) := (others => '0');
   type pages_t is array (0 to SLOTS - 1) of std_logic_vector(7 downto 0);
   signal pages     : pages_t := (others => (others => '0'));
   signal paged     : std_logic_vector(SLOTS - 1 downto 0) := (others => '0');
   signal page_ok   : std_logic_vector(SLOTS - 1 downto 0) := (others => '1');
   signal matched   : std_logic;
   signal stopped_on_break : std_logic := '0';
begin
   process (next_pc, addresses, enabled, page_ok)
      variable any : std_logic;
   begin
      any := '0';
      for i in 0 to SLOTS - 1 loop
         if enabled(i) = '1' and page_ok(i) = '1' and next_pc = addresses(i) then
            any := '1';
         end if;
      end loop;
      matched <= any;
   end process;

   break_now <= matched;

   process (clock)
   begin
      if rising_edge(clock) then
         hit <= '0';
         if reset = '1' then
            enabled <= (others => '0');
            stopped_on_break <= '0';
         else
            if write_strobe = '1' and to_integer(unsigned(write_slot)) < SLOTS then
               enabled(to_integer(unsigned(write_slot))) <= write_enable;
               addresses(to_integer(unsigned(write_slot))) <= write_address;
               paged(to_integer(unsigned(write_slot))) <= write_paged;
               pages(to_integer(unsigned(write_slot))) <= write_page;
            end if;
            for i in 0 to SLOTS - 1 loop
               if paged(i) = '0' or
                  mmu(to_integer(unsigned(addresses(i)(15 downto 13))) * 8 + 7 downto
                      to_integer(unsigned(addresses(i)(15 downto 13))) * 8) = pages(i) then
                  page_ok(i) <= '1';
               else
                  page_ok(i) <= '0';
               end if;
            end loop;
            -- Once per stop: the CPU stopped with a breakpoint matching.
            stopped_on_break <= cpu_stopped and matched;
            if cpu_stopped = '1' and matched = '1' and stopped_on_break = '0' then
               hit <= '1';
            end if;
         end if;
      end if;
   end process;
end architecture;
