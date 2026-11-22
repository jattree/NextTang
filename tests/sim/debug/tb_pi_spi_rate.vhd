-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- The Pi debug slave (rtl/serial/spi_slave.vhd + the official
-- pi_debug_control_param) read by an SPI mode 0 master at SCLK_HZ, as a Pi
-- Zero reads it: the pins reach the slave through one clock_28 register, and
-- MISO leaves through one register and MISO_OUT_PS of pad and wire. The
-- master runs VERSION, STATUS and main-memory reads (A7) of 1 to 40 bytes
-- from a memory that answers port C after 4 to 20 clocks, and checks every
-- byte. Prints PASS or FAIL with the first wrong byte.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_pi_spi_rate is
   generic (
      SCLK_HZ     : integer := 2000000;
      MISO_OUT_PS : integer := 8000;
      READS       : integer := 60
   );
end entity;

architecture sim of tb_pi_spi_rate is
   constant PERIOD : time := 35.556 ns;
   constant HALF   : time := (1.0e12 / real(SCLK_HZ) / 2.0) * 1 ps;
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   -- pins (Pi side) and the registered copies the core sees
   signal ce_n, sclk, mosi : std_logic := '1';
   signal ce_n_q, sclk_q, mosi_q : std_logic := '1';
   signal miso_core, miso_q, miso_pin : std_logic := '0';
   -- slave <-> controller
   signal ce_active_n, rx_valid, tx_ack : std_logic;
   signal rx_byte, tx_byte : std_logic_vector(7 downto 0);
   -- port C model
   signal c_req, c_rd_n, c_ack : std_logic := '0';
   signal c_di : std_logic_vector(7 downto 0) := (others => '0');
   signal a2, a1x, a0 : std_logic_vector(7 downto 0);
   signal a2_5 : std_logic_vector(4 downto 0);
   function mem(addr : unsigned) return std_logic_vector is
      variable a : unsigned(20 downto 0);
   begin
      a := resize(addr, 21);
      return std_logic_vector(resize(resize(a * 7, 21) xor (a srl 8) xor (a srl 13), 8));
   end function;
begin
   clk <= not clk after PERIOD / 2;

   process (clk) begin
      if rising_edge(clk) then
         ce_n_q <= ce_n; sclk_q <= sclk; mosi_q <= mosi;
         miso_q <= miso_core;
      end if;
   end process;
   miso_pin <= transport miso_q after MISO_OUT_PS * 1 ps;

   slave : entity work.spi_slave port map (
      i_CLK => clk, i_reset => reset,
      i_spi_ce_n => ce_n_q, o_spi_ce_n => ce_active_n, i_spi_sclk => sclk_q, i_spi_mosi => mosi_q,
      o_spi_miso => miso_core,
      o_rx_byte => rx_byte, o_rx_valid => rx_valid,
      i_tx_byte => tx_byte, i_tx_load => '1', o_tx_loaded => tx_ack);

   control : entity work.pi_debug_control_param port map (
      i_CLK => clk, i_reset => reset,
      i_spi_active_n => ce_active_n, i_spi_rx_valid => rx_valid, i_spi_rx_di => rx_byte,
      o_spi_tx_do => tx_byte, i_spi_tx_ack => tx_ack,
      o_cpu_busrq_n => open, i_cpu_busak_n => '1', o_cpu_wr => open, i_cpu_di => x"00",
      i_nextreg_rd_ack => '0', o_nextreg_wr => open, i_nextreg_wr_ack => '0', i_nextreg_di => x"00",
      o_bram_req => open, o_bram_wr => open, i_bram_ack => '0', i_bram_di => x"00",
      o_sram_c_req => c_req, o_sram_c_rd_n => c_rd_n, i_sram_c_ack => c_ack, i_sram_c_di => c_di,
      i_hotkeys => "00000", i_dma_busak_n => '1', i_cpu_halt_n => '1',
      o_command => open, o_addr_2 => a2_5, o_addr_1 => a1x, o_addr_0 => a0, o_data => open);

   -- port C: held request, one-clock ack after a variable delay, data with the ack
   process (clk)
      variable s1, s2 : positive := 3;
      variable r : real;
      variable wait_n : integer := -1;
   begin
      if rising_edge(clk) then
         c_ack <= '0';
         if c_req = '1' and wait_n < 0 and c_ack = '0' then
            uniform(s1, s2, r); wait_n := 4 + integer(trunc(r * 16.0));
         elsif wait_n > 0 then
            wait_n := wait_n - 1;
         elsif wait_n = 0 then
            c_ack <= '1';
            c_di <= mem(unsigned(a2_5 & a1x & a0));
            wait_n := -1;
         end if;
      end if;
   end process;

   master : process
      variable got : std_logic_vector(7 downto 0);
      variable errors : natural := 0;
      variable s1, s2 : positive := 11;
      variable r : real;
      variable addr, count : integer;
      procedure xfer(tx : in std_logic_vector(7 downto 0); rx : out std_logic_vector(7 downto 0)) is
      begin
         for b in 7 downto 0 loop
            mosi <= tx(b);
            wait for HALF;
            sclk <= '1';
            rx(b) := miso_pin;               -- the Pi samples on its rising edge
            wait for HALF;
            sclk <= '0';
         end loop;
      end procedure;
      procedure check(what : string; want, have : std_logic_vector(7 downto 0)) is
      begin
         if want /= have then
            errors := errors + 1;
            if errors < 4 then
               report what & ": want " & integer'image(to_integer(unsigned(want))) &
                      " got " & integer'image(to_integer(unsigned(have))) severity warning;
            end if;
         end if;
      end procedure;
   begin
      wait for 20 * PERIOD; reset <= '0'; wait for 20 * PERIOD;
      for n in 0 to READS loop
         -- VERSION: A1 x x x -> byte 2 = version<<4, byte 3 = capabilities
         ce_n <= '0'; wait for 2 * HALF;
         xfer(x"A1", got); xfer(x"00", got); xfer(x"00", got); check("version", x"10", got); xfer(x"00", got); check("capabilities", x"FF", got);
         wait for 2 * HALF; ce_n <= '1'; wait for 40 * PERIOD;
         -- A7: address(3), count(2), one more byte, then the data
         uniform(s1, s2, r); addr := integer(trunc(r * 2097000.0));
         uniform(s1, s2, r); count := 1 + integer(trunc(r * 40.0));
         ce_n <= '0'; wait for 2 * HALF;
         xfer(x"A7", got);
         xfer(std_logic_vector(to_unsigned(addr / 65536, 8)), got);
         xfer(std_logic_vector(to_unsigned((addr / 256) mod 256, 8)), got);
         xfer(std_logic_vector(to_unsigned(addr mod 256, 8)), got);
         xfer(x"00", got); xfer(std_logic_vector(to_unsigned(count, 8)), got);
         xfer(x"00", got);
         for k in 0 to count - 1 loop
            xfer(x"00", got);
            check("A7 byte " & integer'image(k), mem(to_unsigned(addr + k, 21)), got);
         end loop;
         wait for 2 * HALF; ce_n <= '1'; wait for 40 * PERIOD;
      end loop;
      if errors = 0 then report "PASS at " & integer'image(SCLK_HZ) & " Hz" severity note;
      else report "FAIL " & integer'image(errors) & " at " & integer'image(SCLK_HZ) & " Hz" severity note; end if;
      std.env.finish;
   end process;
end architecture;
