-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- The FPGA's own SPI master (rtl/debug/nexttang_pi_spi_master.vhd, used by
-- the debug UART link and the rewind ring) against the Pi debug slave and
-- the official pi_debug_control, at HALF_CLOCKS clock_28 periods per SCLK
-- half period: VERSION and main-memory reads (A7) from a port C that answers
-- after 4 to 20 clocks, every byte checked. Prints PASS or FAIL.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_internal_spi_master is
   generic (HALF_CLOCKS : positive := 8; READS : integer := 40);
end entity;

architecture sim of tb_internal_spi_master is
   constant PERIOD : time := 35.556 ns;
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal sel, bvalid, bready, done, idle : std_logic := '0';
   signal bin, bout : std_logic_vector(7 downto 0) := (others => '0');
   signal ce_n, sclk, mosi, miso : std_logic;
   signal ce_active_n, rx_valid, tx_ack : std_logic;
   signal rx_byte, tx_byte : std_logic_vector(7 downto 0);
   signal c_req, c_rd_n, c_ack : std_logic := '0';
   signal c_di : std_logic_vector(7 downto 0) := (others => '0');
   signal a1x, a0 : std_logic_vector(7 downto 0);
   signal a2_5 : std_logic_vector(4 downto 0);
   function mem(addr : unsigned) return std_logic_vector is
      variable a : unsigned(20 downto 0);
   begin
      a := resize(addr, 21);
      return std_logic_vector(resize(resize(a * 7, 21) xor (a srl 8) xor (a srl 13), 8));
   end function;
begin
   clk <= not clk after PERIOD / 2;

   master : entity work.nexttang_pi_spi_master generic map (HALF_CLOCKS => HALF_CLOCKS) port map (
      clock => clk, reset => reset, select_in => sel, byte_valid => bvalid, byte_in => bin,
      byte_ready => bready, done => done, byte_out => bout, idle => idle,
      memory_busy => c_req, spi_ce_n => ce_n, spi_sclk => sclk, spi_mosi => mosi, spi_miso => miso);

   slave : entity work.spi_slave port map (
      i_CLK => clk, i_reset => reset,
      i_spi_ce_n => ce_n, o_spi_ce_n => ce_active_n, i_spi_sclk => sclk, i_spi_mosi => mosi,
      o_spi_miso => miso, o_rx_byte => rx_byte, o_rx_valid => rx_valid,
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

   process
      variable got : std_logic_vector(7 downto 0);
      variable errors : natural := 0;
      variable s1, s2 : positive := 11;
      variable r : real;
      variable addr, count : integer;
      procedure xfer(tx : in std_logic_vector(7 downto 0); rx : out std_logic_vector(7 downto 0)) is
      begin
         wait until rising_edge(clk);
         bin <= tx; bvalid <= '1';
         wait until rising_edge(clk) and bready = '1';
         bvalid <= '0';
         wait until rising_edge(clk) and done = '1';
         rx := bout;
      end procedure;
      procedure check(what : string; want, have : std_logic_vector(7 downto 0)) is
      begin
         if want /= have then
            errors := errors + 1;
            if errors < 4 then report what & " wrong" severity warning; end if;
         end if;
      end procedure;
      procedure deselect is
      begin
         wait until rising_edge(clk); sel <= '0';
         wait until rising_edge(clk) and idle = '1';
         for k in 1 to 10 loop wait until rising_edge(clk); end loop;
      end procedure;
   begin
      for k in 1 to 20 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      for k in 1 to 20 loop wait until rising_edge(clk); end loop;
      for n in 0 to READS loop
         sel <= '1';
         xfer(x"A1", got); xfer(x"00", got); xfer(x"00", got); check("version", x"10", got);
         xfer(x"00", got); check("capabilities", x"FF", got);
         deselect;
         uniform(s1, s2, r); addr := integer(trunc(r * 2097000.0));
         uniform(s1, s2, r); count := 1 + integer(trunc(r * 40.0));
         sel <= '1';
         xfer(x"A7", got);
         xfer(std_logic_vector(to_unsigned(addr / 65536, 8)), got);
         xfer(std_logic_vector(to_unsigned((addr / 256) mod 256, 8)), got);
         xfer(std_logic_vector(to_unsigned(addr mod 256, 8)), got);
         xfer(x"00", got); xfer(std_logic_vector(to_unsigned(count, 8)), got);
         xfer(x"00", got);
         for k in 0 to count - 1 loop
            xfer(x"00", got);
            check("A7 byte", mem(to_unsigned(addr + k, 21)), got);
         end loop;
         deselect;
      end loop;
      if errors = 0 then report "PASS at HALF_CLOCKS " & integer'image(HALF_CLOCKS) severity note;
      else report "FAIL " & integer'image(errors) & " at HALF_CLOCKS " & integer'image(HALF_CLOCKS) severity note; end if;
      std.env.finish;
   end process;
end architecture;
