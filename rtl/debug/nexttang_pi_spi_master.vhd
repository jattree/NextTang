-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- An SPI master inside the FPGA for the official core's Pi debug slave.
--
-- The official core (3.02.04 on) takes debug commands from a Raspberry Pi over
-- SPI: pi_debug_control behind spi_slave, on the Pi's GPIO 8 to 11. This
-- module plays the Pi's part, so a host on any other link (the debug UART,
-- later PCIe) speaks the official protocol to the unchanged official logic.
-- A real Pi on those pins would see the same slave.
--
-- Mode 0, most significant bit first. Chip select falls when select rises and
-- rises when it falls; the slave resets its command state on a rising chip
-- select, so one select is one command. Each byte offered while selected is
-- shifted out on MOSI while the slave's byte comes back on MISO, and that byte
-- is reported on done.
--
-- The slave expects a Pi's timing, where its main-memory port (port C) has
-- long finished before the next clock edge. Main memory here is DDR3 behind a
-- cache shared with the CPU, so every SCLK edge waits until memory_busy has
-- been low for IDLE_CLOCKS clocks: a read's byte is in the slave's output
-- register before the edge that loads it, and a write has landed before the
-- next byte can start another.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nexttang_pi_spi_master is
   generic (
      HALF_CLOCKS : positive := 8;   -- clocks per SCLK half period
      IDLE_CLOCKS : positive := 4    -- clocks memory must be idle before an edge
   );
   port (
      clock       : in  std_logic;
      reset       : in  std_logic;

      select_in   : in  std_logic;                      -- hold high for one command
      byte_valid  : in  std_logic;
      byte_in     : in  std_logic_vector(7 downto 0);
      byte_ready  : out std_logic;                      -- pulse: byte_in taken
      done        : out std_logic;                      -- pulse: byte_out valid
      byte_out    : out std_logic_vector(7 downto 0);
      idle        : out std_logic;                      -- deselected, nothing in flight

      memory_busy : in  std_logic;

      spi_ce_n    : out std_logic;
      spi_sclk    : out std_logic;
      spi_mosi    : out std_logic;
      spi_miso    : in  std_logic
   );
end entity;

architecture rtl of nexttang_pi_spi_master is
   type state_t is (S_DESELECTED, S_SETUP, S_WAIT_BYTE, S_LOW, S_HIGH, S_HOLD);
   signal state     : state_t := S_DESELECTED;
   signal timer     : natural range 0 to 255 := 0;
   signal quiet     : natural range 0 to IDLE_CLOCKS := 0;
   signal shift_out : std_logic_vector(7 downto 0) := (others => '0');
   signal shift_in  : std_logic_vector(7 downto 0) := (others => '0');
   signal bits      : natural range 0 to 8 := 0;
   signal sclk      : std_logic := '0';
   signal ce_n      : std_logic := '1';
   signal ready_r   : std_logic := '0';
   signal done_r    : std_logic := '0';
   signal miso_sync : std_logic_vector(1 downto 0) := "00";

   -- An edge may happen once the half period has run and memory is quiet.
   function edge_due(t : natural; q : natural) return boolean is
   begin
      return t = 0 and q = IDLE_CLOCKS;
   end function;
begin
   spi_ce_n <= ce_n;
   spi_sclk <= sclk;
   spi_mosi <= shift_out(7);
   byte_ready <= ready_r;
   done <= done_r;
   byte_out <= shift_in;
   idle <= '1' when state = S_DESELECTED else '0';

   process (clock)
   begin
      if rising_edge(clock) then
         ready_r <= '0';
         done_r <= '0';
         miso_sync <= miso_sync(0) & spi_miso;

         if memory_busy = '1' then
            quiet <= 0;
         elsif quiet /= IDLE_CLOCKS then
            quiet <= quiet + 1;
         end if;

         if timer /= 0 then
            timer <= timer - 1;
         end if;

         if reset = '1' then
            state <= S_DESELECTED;
            ce_n <= '1';
            sclk <= '0';
            timer <= 0;
         else
            case state is
               when S_DESELECTED =>
                  sclk <= '0';
                  if select_in = '1' then
                     ce_n <= '0';
                     timer <= 2 * HALF_CLOCKS;
                     state <= S_SETUP;
                  end if;

               -- Chip select settles through the slave's synchroniser and it
               -- loads its first reply byte while SCLK is low.
               when S_SETUP =>
                  if timer = 0 then
                     state <= S_WAIT_BYTE;
                  end if;

               when S_WAIT_BYTE =>
                  if select_in = '0' then
                     if edge_due(timer, quiet) then
                        ce_n <= '1';
                        timer <= 2 * HALF_CLOCKS;
                        state <= S_HOLD;
                     end if;
                  elsif byte_valid = '1' then
                     shift_out <= byte_in;
                     ready_r <= '1';
                     bits <= 0;
                     timer <= HALF_CLOCKS;
                     state <= S_LOW;
                  end if;

               when S_LOW =>
                  if edge_due(timer, quiet) then
                     sclk <= '1';
                     -- MISO has been steady since the last falling edge.
                     shift_in <= shift_in(6 downto 0) & miso_sync(1);
                     timer <= HALF_CLOCKS;
                     state <= S_HIGH;
                  end if;

               when S_HIGH =>
                  if edge_due(timer, quiet) then
                     sclk <= '0';
                     timer <= HALF_CLOCKS;
                     if bits = 7 then
                        done_r <= '1';
                        state <= S_WAIT_BYTE;
                     else
                        bits <= bits + 1;
                        shift_out <= shift_out(6 downto 0) & '0';
                        state <= S_LOW;
                     end if;
                  end if;

               -- Chip select stays high long enough for the slave to see it.
               when S_HOLD =>
                  if timer = 0 then
                     state <= S_DESELECTED;
                  end if;
            end case;
         end if;
      end if;
   end process;
end architecture;
