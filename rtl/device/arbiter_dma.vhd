-- Z80 DMA ARBITER
-- Copyright 2026 Alvin Albrecht
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

-- arbitrate dma access between z80-dma and pi-slave-control

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity arbiter_dma is
   port
   (
      i_CLK            : in std_logic;
      i_reset          : in std_logic;
      
      i_busrq_pi_n     : in std_logic;   -- pi high priority
      i_busrq_dma_n    : in std_logic;   -- dma low priority
      
      i_cpu_lastM      : in std_logic;   -- cpu is in last machine cycle
      
      o_busak_pi_n     : out std_logic;  -- pi busak
      o_busak_dma_n    : out std_logic;  -- dma busak
      
      o_cpu_busrq_n    : out std_logic;  -- Z80
      i_cpu_busak_n    : in  std_logic   -- Z80
   );
end entity;

architecture rtl of arbiter_dma is

   signal state        : std_logic_vector(3 downto 0) := "1110";

begin

   -- state machine

   -- pi debug control has higher priority but only transmits busrq on instruction boundaries
   -- dma busrq must be transmitted without delay to avoid single cycle diff from older implementation

   -- state is four bits
   --
   -- b0 = 0 to generate busrq if dma requests but pi does not
   -- b1 = 0 to generate busrq
   -- b2 = 0 to pass busak to pi debug control
   -- b3 = 0 to pass busak to dma

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            state <= "1110";
         else
            case state is
               when "1110" =>
                  -- idle
                  if i_busrq_pi_n = '0' then
                     state <= "1111";
                  elsif i_busrq_dma_n = '0' then
                     state <= "0101";
                  else
                     state <= "1110";
                  end if;
               when "1111" =>
                  -- pi wait on lastM
                  if i_busrq_pi_n = '0' and i_cpu_lastM = '1' then
                     state <= "1001";
                  elsif i_busrq_pi_n = '0' then
                     state <= "1111";
                  else
                     state <= "1110";
                  end if;
               when "1001" =>
                  -- pi holds bus
                  if i_busrq_pi_n = '0' then
                     state <= "1001";
                  else
                     state <= "1110";
                  end if;
               when "0101" =>
                  -- dma holds bus
                  if i_busrq_dma_n = '0' then
                     state <= "0101";
                  else
                     state <= "1110";
                  end if;               
               when others =>
                  state <= "1110";
            end case;
         end if;
      end if;
   end process;
         
   o_busak_pi_n <= state(2) or i_cpu_busak_n;
   o_busak_dma_n <= state(3) or i_cpu_busak_n;
   
   o_cpu_busrq_n <= state(1) and (state(0) or i_busrq_dma_n or not i_busrq_pi_n);

end architecture;
