
-- SPI Master
--
-- Copyright 2009-2010 Mike Stirling
-- Copyright 2020 Alvin Albrecht and Fabio Belavenuto
--
-- All rights reserved
--
-- Redistribution and use in source and synthezised forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- * Redistributions of source code must retain the above copyright notice,
--   this list of conditions and the following disclaimer.
--
-- * Redistributions in synthesized form must reproduce the above copyright
--   notice, this list of conditions and the following disclaimer in the
--   documentation and/or other materials provided with the distribution.
--
-- * Neither the name of the author nor the names of other contributors may
--   be used to endorse or promote products derived from this software without
--   specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
--

-- Mike Stirling's original implementation:
-- https://github.com/mikestir/fpga-spectrum/blob/master/spi.vhd

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity spi_master is
   generic (
      -- NextTang: 1 samples MISO on the enabled rising edge after the usual
      -- falling one, half a CPU clock later, for boards whose SCK reaches the
      -- card late (Nano 20K: an I/O-cell register and 6 ns of output path
      -- left the card 7.4 ns of the spec's 14 at 28 MHz). The card changes
      -- MISO only after SCK falls, which is launched at the next enabled
      -- falling edge, so the later sample still sees this bit. 0: as official.
      g_miso_late    : integer := 0
   );
   port (
      clock_i        : in std_logic;
      cen_r_i        : in std_logic := '1';   -- NextTang: clock_i edge enables
      cen_f_i        : in std_logic := '1';
      reset_i        : in std_logic;
      
      spi_sck_o      : out std_logic;
      spi_mosi_o     : out std_logic;
      spi_miso_i     : in std_logic;
      
      spi_mosi_wr_i  : in std_logic;
      spi_mosi_dat_i : in std_logic_vector(7 downto 0);
      
      spi_miso_rd_i  : in std_logic;
      spi_miso_dat_o : out std_logic_vector(7 downto 0);
      
      spi_wait_n_o   : out std_logic   -- wait signal for dma
   );
end entity;

architecture rtl of spi_master is

   signal spi_begin        : std_logic;
   signal counter_is_zero  : std_logic;
   signal counter          : std_logic_vector(3 downto 0) := (others => '0');
   signal sck              : std_logic := '0';
   signal shift            : std_logic_vector(8 downto 0) := (others => '1');
   signal miso_dat         : std_logic_vector(7 downto 0);
   -- NextTang: g_miso_late
   signal sample_due       : std_logic := '0';   -- this falling edge was a sampling edge
   signal miso_late        : std_logic := '1';   -- the bit, taken on the rising edge after
   signal miso_now         : std_logic;          -- the received bit 0 as the byte is published

begin

   -- start condition
   
   spi_begin <= '1' when (spi_miso_rd_i = '1' or spi_mosi_wr_i = '1') and counter_is_zero = '1' else '0';
   
   -- spi bit counter
   
   counter_is_zero <= '1' when counter = X"0" else '0';
   
   process (clock_i)
   begin
      if falling_edge(clock_i) and cen_f_i = '1' then
         if reset_i = '1' then
            counter <= (others => '0');
         elsif counter_is_zero = '0' or spi_begin = '1' then
            counter <= counter + 1;
         end if;
      end if;
   end process;
   
   process (clock_i)
   begin
      if falling_edge(clock_i) and cen_f_i = '1' then
         if reset_i = '1' then
            sck <= '0';
         else
            sck <= counter(0);
         end if;
      end if;
   end process;
   
   -- spi shift register
   
   process (clock_i)
   begin
      if falling_edge(clock_i) and cen_f_i = '1' then
         if reset_i = '1' then
            shift <= (others => '1');
         elsif spi_begin = '1' then
            if spi_miso_rd_i = '1' then
               shift <= (others => '1');
            else
               shift <= spi_mosi_dat_i & '1';
            end if;
         elsif counter_is_zero = '0' then
            if sck = '0' then
               if g_miso_late = 0 then
                  shift(0) <= spi_miso_i;
               end if;
            elsif g_miso_late = 0 then
               shift <= shift(7 downto 0) & '1';
            else
               shift <= shift(7 downto 1) & miso_late & '1';   -- NextTang: miso_late stands in for shift(0)
            end if;
         end if;
      end if;
   end process;

   -- NextTang: g_miso_late. sample_due marks the falling edges that would
   -- have sampled; the rising edge after one takes the bit into miso_late,
   -- which the next shifting edge moves up as it would have moved shift(0).
   -- No register here is written on both edges.
   process (clock_i)
   begin
      if falling_edge(clock_i) and cen_f_i = '1' then
         if reset_i = '1' or spi_begin = '1' or counter_is_zero = '1' then
            sample_due <= '0';
         else
            sample_due <= not sck;
         end if;
      end if;
   end process;

   process (clock_i)
   begin
      if rising_edge(clock_i) and cen_r_i = '1' then
         if sample_due = '1' then
            miso_late <= spi_miso_i;
         end if;
      end if;
   end process;

   -- the last bit is sampled on the same rising edge that publishes the byte
   miso_now <= spi_miso_i when sample_due = '1' else miso_late;

   -- miso data
   
   process (clock_i)
   begin
      if rising_edge(clock_i) and cen_r_i = '1' then
         if counter_is_zero = '1' then
            if g_miso_late = 0 then
               miso_dat <= shift(7 downto 0);
            else
               miso_dat <= shift(7 downto 1) & miso_now;   -- NextTang: g_miso_late
            end if;
         end if;
      end if;
   end process;
   
   -- connect pins
   
   spi_sck_o <= sck;
   spi_mosi_o <= shift(8);
   spi_miso_dat_o <= miso_dat;
   
   spi_wait_n_o <= '1' when counter_is_zero = '1' else '0';

end architecture;
