--
-- SPI Slave
--
-- Copyright 2025 David Saphier
--
-- This file is part of the ZX Spectrum Next Project
-- <https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA/tree/master/cores>
--
-- The ZX Spectrum Next FPGA source code is free software: you can 
-- redistribute it and/or modify it under the terms of the GNU General 
-- Public License as published by the Free Software Foundation, either 
-- version 3 of the License, or (at your option) any later version.
--
-- The ZX Spectrum Next FPGA source code is distributed in the hope 
-- that it will be useful, but WITHOUT ANY WARRANTY; without even the 
-- implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR 
-- PURPOSE.  See the GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with the ZX Spectrum Next FPGA source code.  If not, see 
-- <https://www.gnu.org/licenses/>.

-- SPI Slave module for Pi Zero memory access
-- CPOL=0, CPHA=0 (SPI Mode 0) to match Pi default
-- Uses oversampling in CLK domain for clean CDC

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity spi_slave is
   port
   (
      -- System clock domain (CLK_28 on Next)
      
      i_CLK          : in  std_logic;
      i_reset        : in  std_logic;
      
      -- SPI pins (directly from/to GPIO which see one period CLK_28 delays on Next)
      
      i_spi_ce_n     : in  std_logic;   -- chip enable, active low
      o_spi_ce_n     : out std_logic;   -- synchronized chip enable to disable attached device
      i_spi_sclk     : in  std_logic;
      i_spi_mosi     : in  std_logic;
      o_spi_miso     : out std_logic;

      -- Byte-level interface to controller (CLK domain)
      
      o_rx_byte      : out std_logic_vector(7 downto 0);    -- received byte available for min eight spi cycles
      o_rx_valid     : out std_logic;                       -- pulse: new byte available
      
      i_tx_byte      : in  std_logic_vector(7 downto 0);    -- byte to transmit
      i_tx_load      : in  std_logic;                       -- load tx byte into shift register
      o_tx_loaded    : out std_logic                        -- pulse: new byte loaded, will only load once at start of byte
   );
end entity;

architecture rtl of spi_slave is

   -- Oversample SCLK and CE_n into CLK domain
   
--   signal ce_n_sync_r     : std_logic_vector(1 downto 0) := "11";
--   signal sclk_sync_r     : std_logic_vector(1 downto 0) := "00";
--   signal mosi_sync_r     : std_logic_vector(1 downto 0) := "00";

   signal ce_n_d          : std_logic := '1';
   signal sclk_d          : std_logic := '0';
   signal mosi_d          : std_logic := '0';
   
   signal ce_n_sync_r     : std_logic_vector(1 downto 0);
   signal sclk_sync_r     : std_logic_vector(1 downto 0);
   signal mosi_sync_r     : std_logic_vector(1 downto 0);

   signal ce_active_n     : std_logic;
   signal sclk            : std_logic := '0';
   signal sclk_next       : std_logic;
   signal sclk_rising     : std_logic;
   signal sclk_falling    : std_logic;
   signal mosi            : std_logic;

   -- Shift registers (CLK_28 domain, triggered by oversampled SCLK edges)
   
   signal rx_shift_r      : std_logic_vector(6 downto 0) := (others => '0');
   signal tx_shift_r      : std_logic_vector(7 downto 0) := (others => '1');
   signal bit_count_r     : std_logic_vector(2 downto 0) := (others => '0');

   -- Byte completion
   
   signal rx_byte_r       : std_logic_vector(7 downto 0) := (others => '0');
   signal rx_valid_r      : std_logic := '0';

   -- TX loading
   
   signal tx_loaded_r     : std_logic_vector(1 downto 0) := "00";

begin

   -- Synchronize SPI signals into CLK domain (double-FF, one FF from top level)

--   process (i_CLK)
--   begin
--      if rising_edge(i_CLK) then
--         if i_reset = '1' then
--            ce_n_sync_r <= "11";
--            sclk_sync_r <= "00";
--            mosi_sync_r <= "00";
--         else
--            ce_n_sync_r <= ce_n_sync_r(0) & i_spi_ce_n;
--            sclk_sync_r <= sclk_sync_r(0) & i_spi_sclk;
--            mosi_sync_r <= mosi_sync_r(0) & i_spi_mosi;
--         end if;
--      end if;
--   end process;

   -- try to operate faster with one less synchronizing FF (one at top level)

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            ce_n_d <= '1';
            sclk_d <= '0';
            mosi_d <= '0';
         else
            ce_n_d <= i_spi_ce_n;
            sclk_d <= i_spi_sclk;
            mosi_d <= i_spi_mosi;
         end if;
      end if;
   end process;

   ce_n_sync_r <= ce_n_d & i_spi_ce_n;
   sclk_sync_r <= sclk_d & i_spi_sclk;
   mosi_sync_r <= mosi_d & i_spi_mosi;

   -- Edge detection on synchronized SCLK

   ce_active_n  <= ce_n_sync_r(1) or ce_n_sync_r(0);

   sclk_next <= '0' when sclk = '1' and sclk_sync_r = "00" else '1' when sclk = '0' and sclk_sync_r = "11" else sclk;

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' or ce_active_n = '1' then
            sclk <= '0';
         else
            sclk <= sclk_next;
         end if;
      end if;
   end process;
  
   sclk_rising  <= sclk_next and (not sclk);
   sclk_falling <= (not sclk_next) and sclk;
   
   mosi <= mosi_sync_r(1);

   -- RX shift register: sample MOSI on rising SCLK edge
   -- TX shift register: shift out on falling SCLK edge
   -- Bit counter tracks position within byte

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' or ce_active_n = '1' then
            rx_shift_r <= (others => '0');
            bit_count_r <= (others => '0');
            rx_valid_r <= '0';
            tx_shift_r <= (others => '0');
            tx_loaded_r <= "00";
         else
            -- Sample MOSI on rising SCLK
            
            rx_valid_r <= '0';

            if sclk_rising = '1' then
               rx_shift_r <= rx_shift_r(5 downto 0) & mosi;
               bit_count_r <= bit_count_r + 1;

               -- Byte complete (bit_count wraps from 7 to 0)
               
               if bit_count_r = "111" then
                  rx_byte_r <= rx_shift_r & mosi;
                  rx_valid_r <= '1';
               end if;
            end if;

            -- Shift TX out on falling SCLK (7 shifts per byte, not 8)
            -- Skip shift when bit_count=0 (byte boundary) to avoid
            -- corrupting the next byte's MSB before master samples it
            
            tx_loaded_r(1) <= tx_loaded_r(0);
			
            if bit_count_r /= "000" then
               if sclk_falling = '1' then
                  tx_shift_r <= tx_shift_r(6 downto 0) & '0';
               end if;
               tx_loaded_r(0) <= '0';
            elsif i_tx_load = '1' and sclk_next = '0' and tx_loaded_r(0) = '0' then
               tx_shift_r <= i_tx_byte;
               tx_loaded_r(0) <= '1';
            end if;

         end if;
      end if;
   end process;

   -- Output assignments

   o_spi_ce_n <= ce_active_n;
   o_spi_miso <= tx_shift_r(7) when ce_active_n = '0' else '0';
   
   o_rx_byte  <= rx_byte_r;
   o_rx_valid <= rx_valid_r;
   
   o_tx_loaded <= tx_loaded_r(0) and not tx_loaded_r(1);

end architecture;
