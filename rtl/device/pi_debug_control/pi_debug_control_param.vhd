--
-- Pi Debug Control
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

-- Pi Debug Control for SPI Slave
-- sliced by generics

-- AA : responsible for the mangling to try to make things smaller, sorry

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity pi_debug_control_param is
   generic
   (
      g_version      : unsigned(3 downto 0)   := X"1";
      g_capabilities : unsigned(7 downto 0)   := X"FF"
   );

   -- capabilities
   --
   --  (always)  CMD VERSION, CMD_STATUS (required)
   --     0      CMD_SYSTEM
   --     1      CMD_NEXTREG_R
   --     2      CMD_NEXTREG_W
   --     3      CMD_SRAM_R, CMD_SRAM_W (requires sram port c)
   --     4      CMD_CPU_PAUSE, CMD_CPU_RESUME, CMD_CPU_SSTEP
   --     5      CMD_BRAM_R, CMD_BRAM_W
   --     6      CMD_CPU_REG_R, CMD_CPU_REG_W (requires CMD_CPU_PAUSE, CMD_CPU_RESUME, t80n debug interface)
   --     7      Enable hotkeys (tzx controls)

   port
   (
      i_CLK          : in  std_logic;
      i_reset        : in  std_logic;

      -- spi slave connection
      
      i_spi_active_n : in  std_logic;                      -- acts as reset if slave indicates inactive, does not affect busrq status
      i_spi_rx_valid : in  std_logic;                      -- pulse: new byte available
      i_spi_rx_di    : in  std_logic_vector(7 downto 0);   -- received byte available for min eight spi cycles
--    o_spi_tx_valid : out std_logic;                      -- tx byte available, hold until ack  -- not needed always '1'
      o_spi_tx_do    : out std_logic_vector(7 downto 0);   -- tx byte
      i_spi_tx_ack   : in  std_logic;                      -- pulse: byte loaded, one load at start of transmission
      
      -- cpu pause
      
      o_cpu_busrq_n  : out std_logic;
      i_cpu_busak_n  : in  std_logic;

      -- cpu connection (requires cpu pause)
      
      o_cpu_wr       : out std_logic;
      i_cpu_di       : in  std_logic_vector(7 downto 0);
      
      -- nextreg connection
      
--    o_nextreg_rd     : out std_logic;                    -- not needed
      i_nextreg_rd_ack : in  std_logic;
      o_nextreg_wr     : out std_logic;
      i_nextreg_wr_ack : in  std_logic;
      i_nextreg_di     : in  std_logic_vector(7 downto 0);
      
      -- bram connection

      o_bram_req     : out std_logic;
      o_bram_wr      : out std_logic;
      i_bram_ack     : in std_logic;
      i_bram_di      : in  std_logic_vector(7 downto 0);

      -- sram port c connection
      
      o_sram_c_req   : out std_logic;
      o_sram_c_rd_n  : out std_logic;
      i_sram_c_ack   : in  std_logic;
      i_sram_c_di    : in  std_logic_vector(7 downto 0);

      -- status & command

      i_hotkeys      : in  std_logic_vector(4 downto 0);   -- pulsed bits via hotkeys (4:0 = nmi + QWERT)
      i_dma_busak_n  : in  std_logic;
      i_cpu_halt_n   : in  std_logic;
      o_command      : out std_logic_vector(4 downto 0);   -- pulsed bits (gen ctc-3 int, gen mf nmi, gen divmmc nmi, hard reset, soft reset)

      -- address and data i/o
      
      o_addr_2       : out std_logic_vector(4 downto 0);   -- address bus (20 downto 0)
      o_addr_1       : out std_logic_vector(7 downto 0);
      o_addr_0       : out std_logic_vector(7 downto 0);
      o_data         : out std_logic_vector(7 downto 0)    -- data bus (7 downto 0)
   );
end entity;

   --
   -- PI COMMANDS
   --
   
   -- pi should write 00 when transmit byte is undefined
   -- will put the module in an error state if the pi loses sync for whatever reason
   --
   -- pi spi  : write CMD_VERSION, read junk,  read VERSION, read CAPABILITIES
   -- <state> :     S_IDLE            S_A0         S_L1           S_L0
   --
   -- pi spi  : write CMD_STATUS, read junk,  read STATUS, read HOTKEYS
   -- <state> :     S_IDLE           S_A0        S_L1         S_L0
   --
   -- pi spi  : write CMD_SYSTEM, write COMMAND
   -- <state> :     S_IDLE           S_L0
   --
   -- read status to find out when cpu is paused
   -- pi spi  : write CMD_CPU_PAUSE
   --
   -- immediately cancels CMD_CPU_PAUSE or CMD_CPU_SSTEP
   -- pi spi  : write CMD_CPU_RESUME
   --
   -- cpu should be paused, releases for one instruction, then enters CMD_CPU_PAUSE again, read status to find out if paused
   -- pi spi  : write CMD_CPU_SSTEP (acts as CMD_CPU_PAUSE if not already paused)
   --
   -- pi spi  : write CMD_BRAM_R, write ADDR[15:8], write ADDR[7:0], write LEN[15:8], write LEN[7:0], read junk, read data...
   -- <state> :     S_IDLE              S_A1             S_A0             S_L1             S_L0       S_BRAM_R    S_BRAM_R
   -- ADDR is modulo bank size :- bank 5 is 16K and bank 7 is 8K ; ADDR[15] = 0 to select bank 5, 1 to select bank 7
   --
   -- pi spi  : write CMD_BRAM_W, write ADDR[15:8], write ADDR[7:0], write LEN[15:8], write LEN[7:0], write data...
   -- <state> :     S_IDLE              S_A1             S_A0             S_L1             S_L0        S_BRAM_W
   -- ADDR is modulo bank size :- bank 5 is 16K and bank 7 is 8K ; ADDR[15] = 0 to select bank 5, 1 to select bank 7
   --
   -- pi spi  : write CMD_SRAM_R, write ADDR[20:16], write ADDR[15:8], write ADDR[7:0], write LEN[15:8], write LEN[7:0],  read junk,   read data...
   -- <state> :     S_IDLE              S_A2             S_A1             S_A0             S_L1              S_L0          S_SRAM_R     S_SRAM_R
   --
   -- pi spi  : write CMD_SRAM_W, write ADDR[20:16], write ADDR[15:8], write ADDR[7:0], write LEN[15:8], write LEN[7:0], write data...
   -- <state> :     S_IDLE              S_A2             S_A1             S_A0             S_L1              S_L0          S_SRAM_W
   --
   -- pi spi  : write CMD_NEXTREG_R, write NEXTREG, read junk, read data
   -- <state> :     S_IDLE              S_A0           S_L1      S_L0
   --
   -- pi spi  : write CMD_NEXTREG_W, write NEXTREG, write data, write junk
   -- <state> :     S_IDLE              S_A0           S_L1       S_L0
   --
   -- cpu must be paused
   -- pi spi  : write CMD_CPU_REG_R, write CPU_REG,  read junk, read REGVAL
   -- <state> :     S_IDLE              S_A0           S_L1       S_L0
   --
   -- cpu must be paused
   -- pi spi  : write CMD_CPU_REG_W, write CPU_REG,  write REGVAL, write junk
   -- <state> :     S_IDLE              S_A0           S_L1          S_L0

   --
   -- INFO BYTES
   --
   
   -- version = { v, v, v, v, x, x, x, x }
   -- capabilities = { hotkeys, cmd_cpu_reg_rw, cmd_bram_rw, (cmd_cpu_pause, cmd_cpu_resume, cmd_cpu_sstep), cmd_sram_rw, cmd_nextreg_w, cmd_nextreg_r, cmd_system }
   -- status = { had reset, busrq_status(1:0), dma_active_n, cpu_halted_n, 0, 0, had error }
   --                       \ 00 = idle, 01 = in process of stopping cpu, 10 = cpu paused, 11 = releasing cpu for single step
   -- hotkeys = { 0, 0, 0, Q, W, E, R, T }
   -- command = { 0, 0, 0, gen ctc-3 int, gen mf nmi, gen divmmc nmi, hard reset, soft reset }
   -- cpu_reg = see src/cpu/readme.txt

architecture rtl of pi_debug_control_param is

   -- commands
   -- valid command bytes have upper nibble = X"A"

   constant CMD_NOP            : std_logic_vector(3 downto 0) := X"0";
   constant CMD_VERSION        : std_logic_vector(3 downto 0) := X"1";
   constant CMD_STATUS         : std_logic_vector(3 downto 0) := X"2";
   constant CMD_SYSTEM         : std_logic_vector(3 downto 0) := X"3";
   constant CMD_CPU_PAUSE      : std_logic_vector(3 downto 0) := X"4";
   constant CMD_CPU_RESUME     : std_logic_vector(3 downto 0) := X"5";
   constant CMD_CPU_SSTEP      : std_logic_vector(3 downto 0) := X"6";
   constant CMD_SRAM_R         : std_logic_vector(3 downto 0) := X"7";
   constant CMD_SRAM_W         : std_logic_vector(3 downto 0) := X"8";
   constant CMD_BRAM_R         : std_logic_vector(3 downto 0) := X"9";
   constant CMD_BRAM_W         : std_logic_vector(3 downto 0) := X"A";
   constant CMD_NEXTREG_R      : std_logic_vector(3 downto 0) := X"B";
   constant CMD_NEXTREG_W      : std_logic_vector(3 downto 0) := X"C";
   constant CMD_CPU_REG_R      : std_logic_vector(3 downto 0) := X"D";
   constant CMD_CPU_REG_W      : std_logic_vector(3 downto 0) := X"E";

   -- state machine (one-hot)
   
   constant I_IDLE             : integer := 0;
   constant S_IDLE             : std_logic_vector(10 downto 0) := "00000000001";
   constant I_ERROR            : integer := 1;
   constant S_ERROR            : std_logic_vector(10 downto 0) := "00000000010";
   constant I_A2               : integer := 2;
   constant S_A2               : std_logic_vector(10 downto 0) := "00000000100";
   constant I_A1               : integer := 3;
   constant S_A1               : std_logic_vector(10 downto 0) := "00000001000";
   constant I_A0               : integer := 4;
   constant S_A0               : std_logic_vector(10 downto 0) := "00000010000";
   constant I_L1               : integer := 5;
   constant S_L1               : std_logic_vector(10 downto 0) := "00000100000";
   constant I_L0               : integer := 6;
   constant S_L0               : std_logic_vector(10 downto 0) := "00001000000";
   constant I_BRAM_R           : integer := 7;
   constant S_BRAM_R           : std_logic_vector(10 downto 0) := "00010000000";
   constant I_BRAM_W           : integer := 8;
   constant S_BRAM_W           : std_logic_vector(10 downto 0) := "00100000000";
   constant I_SRAM_R           : integer := 9;
   constant S_SRAM_R           : std_logic_vector(10 downto 0) := "01000000000";
   constant I_SRAM_W           : integer := 10;
   constant S_SRAM_W           : std_logic_vector(10 downto 0) := "10000000000";
   
   signal state                : std_logic_vector(10 downto 0) := S_IDLE;
   signal state_next           : std_logic_vector(10 downto 0);

   signal reset                : std_logic;
   
   signal cmd_upper_nibble     : std_logic;

   signal is_cmd_nop           : std_logic;
   signal is_cmd_version       : std_logic;
   signal is_cmd_status        : std_logic;
   signal is_cmd_hotkeys       : std_logic;
   signal is_cmd_system        : std_logic;
   signal is_cmd_cpu_pause     : std_logic;
   signal is_cmd_cpu_resume    : std_logic;
   signal is_cmd_cpu_sstep     : std_logic;
   signal is_cmd_bram_r        : std_logic;
   signal is_cmd_bram_w        : std_logic;
   signal is_cmd_sram_r        : std_logic;
   signal is_cmd_sram_w        : std_logic;
   signal is_cmd_nextreg_r     : std_logic;
   signal is_cmd_nextreg_w     : std_logic;
   signal is_cmd_cpu_reg_r     : std_logic;
   signal is_cmd_cpu_reg_w     : std_logic;

   signal r_is_cmd_version     : std_logic := '0';
   signal r_is_cmd_status      : std_logic := '0';
   signal r_is_cmd_system      : std_logic := '0';
   signal r_is_cmd_bram_r      : std_logic := '0';
   signal r_is_cmd_bram_w      : std_logic := '0';
   signal r_is_cmd_sram_r      : std_logic := '0';
   signal r_is_cmd_sram_w      : std_logic := '0';
   signal r_is_cmd_nextreg_r   : std_logic := '0';
   signal r_is_cmd_nextreg_w   : std_logic := '0';
   signal r_is_cmd_cpu_reg_r   : std_logic := '0';
   signal r_is_cmd_cpu_reg_w   : std_logic := '0';

   signal dispatch_a2          : std_logic;
   signal dispatch_a1          : std_logic;
   signal dispatch_a0          : std_logic;
   signal dispatch_l0          : std_logic;
   signal dispatch_idle        : std_logic;
   signal dispatch_error_a0    : std_logic;

   signal operation_inc_reg_a  : std_logic;
   signal REG_A                : std_logic_vector(20 downto 0) := (others => '0');
   signal REG_A2               : std_logic_vector(4 downto 0);
   signal REG_A1               : std_logic_vector(7 downto 0);
   signal REG_A0               : std_logic_vector(7 downto 0);

   signal operation_dec_reg_l  : std_logic;
   signal REG_L                : std_logic_vector(15 downto 0) := (others => '0');
   signal REG_L1               : std_logic_vector(7 downto 0);
   signal REG_L0               : std_logic_vector(7 downto 0);
   signal reg_l_is_zero        : std_logic;

   signal reg_di_load          : std_logic;
   signal reg_di_value         : std_logic_vector(7 downto 0);
   signal REG_DI               : std_logic_vector(7 downto 0) := (others => '0');

   signal status_error         : std_logic := '0';
   signal status_reset         : std_logic := '1';
   signal status_byte          : std_logic_vector(7 downto 0);
   
   signal hotkeys              : std_logic_vector(4 downto 0) := (others => '0');
   
   signal system_command       : std_logic_vector(4 downto 0) := (others => '0');
   
   signal bus_control          : std_logic_vector(1 downto 0) := "01";
   signal bus_status           : std_logic_vector(1 downto 0);

   signal bram_rd_control      : std_logic_vector(1 downto 0) := "00";
   signal bram_rd_control_next : std_logic_vector(1 downto 0);
   signal bram_wr_control      : std_logic_vector(1 downto 0) := "00";
   signal bram_wr_control_next : std_logic_vector(1 downto 0);
   signal bram_req             : std_logic := '0';
   
   signal sram_rd_control      : std_logic_vector(1 downto 0) := "00";
   signal sram_rd_control_next : std_logic_vector(1 downto 0);
   signal sram_wr_control      : std_logic_vector(1 downto 0) := "00";
   signal sram_wr_control_next : std_logic_vector(1 downto 0);
   signal sram_req             : std_logic := '0';

   signal nextreg_rd_control   : std_logic_vector(1 downto 0) := "00";
   signal nextreg_wr_control   : std_logic := '0';

   signal cpu_wr_control       : std_logic := '0';

   -- build time command recognition

   function f_recognize
   (
      choice  : std_logic;
      state_0 : std_logic;
      state_1 : std_logic
   )
   return std_logic is
   begin
      if choice = '0' then
         return state_0;
      else
         return state_1;
      end if;
   end function;

begin

   reset <= i_reset or i_spi_active_n;

   -- command decode

   cmd_upper_nibble <= '1' when i_spi_rx_di(7 downto 4) = "1010" else '0';

   process (cmd_upper_nibble, i_spi_rx_di)
   begin
      is_cmd_nop <= '0';
      is_cmd_version <= '0';
      is_cmd_status <= '0';
      is_cmd_hotkeys <= '0';
      is_cmd_system <= '0';
      is_cmd_cpu_pause <= '0';
      is_cmd_cpu_resume <= '0';
      is_cmd_cpu_sstep <= '0';
      is_cmd_bram_r <= '0';
      is_cmd_bram_w <= '0';
      is_cmd_sram_r <= '0';
      is_cmd_sram_w <= '0';
      is_cmd_nextreg_r <= '0';
      is_cmd_nextreg_w <= '0';
      is_cmd_cpu_reg_r <= '0';
      is_cmd_cpu_reg_w <= '0';
      if cmd_upper_nibble = '1' then
         case i_spi_rx_di(3 downto 0) is
            when CMD_NOP        =>  is_cmd_nop <= '1';
            when CMD_VERSION    =>  is_cmd_version <= '1';
            when CMD_STATUS     =>  is_cmd_status <= '1';
            when CMD_SYSTEM     =>  is_cmd_system <= f_recognize(g_capabilities(0), '0', '1');
            when CMD_CPU_PAUSE  =>  is_cmd_cpu_pause <= f_recognize(g_capabilities(4), '0', '1');
            when CMD_CPU_RESUME =>  is_cmd_cpu_resume <= f_recognize(g_capabilities(4), '0', '1');
            when CMD_CPU_SSTEP  =>  is_cmd_cpu_sstep <= f_recognize(g_capabilities(4), '0', '1');
            when CMD_BRAM_R     =>  is_cmd_bram_r <= f_recognize(g_capabilities(5), '0', '1');
            when CMD_BRAM_W     =>  is_cmd_bram_w <= f_recognize(g_capabilities(5), '0', '1');
            when CMD_SRAM_R     =>  is_cmd_sram_r <= f_recognize(g_capabilities(3), '0', '1');
            when CMD_SRAM_W     =>  is_cmd_sram_w <= f_recognize(g_capabilities(3), '0', '1');
            when CMD_NEXTREG_R  =>  is_cmd_nextreg_r <= f_recognize(g_capabilities(1), '0', '1');
            when CMD_NEXTREG_W  =>  is_cmd_nextreg_w <= f_recognize(g_capabilities(2), '0', '1');
            when CMD_CPU_REG_R  =>  is_cmd_cpu_reg_r <= f_recognize(g_capabilities(6), '0', '1');
            when CMD_CPU_REG_W  =>  is_cmd_cpu_reg_w <= f_recognize(g_capabilities(6), '0', '1');
            when others => null;
         end case;
      end if;
   end process;

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if (state(I_IDLE) = '1' or state(I_ERROR) = '1') and i_spi_rx_valid = '1' then
            r_is_cmd_version <= is_cmd_version;
            r_is_cmd_status <= is_cmd_status;
            r_is_cmd_system <= is_cmd_system;
            r_is_cmd_bram_r <= is_cmd_bram_r;
            r_is_cmd_bram_w <= is_cmd_bram_w;
            r_is_cmd_sram_r <= is_cmd_sram_r;
            r_is_cmd_sram_w <= is_cmd_sram_w;
            r_is_cmd_nextreg_r <= is_cmd_nextreg_r;
            r_is_cmd_nextreg_w <= is_cmd_nextreg_w;
            r_is_cmd_cpu_reg_r <= is_cmd_cpu_reg_r;
            r_is_cmd_cpu_reg_w <= is_cmd_cpu_reg_w;
         end if;
      end if;
   end process;
   
   -- one-hot state machine

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if reset = '1' then
            state <= S_IDLE;
         else
            state <= state_next;
         end if;
      end if;
   end process;

   dispatch_a2 <= is_cmd_sram_r or is_cmd_sram_w;
   dispatch_a1 <= is_cmd_bram_r or is_cmd_bram_w;
   dispatch_a0 <= is_cmd_version or is_cmd_status or is_cmd_nextreg_r or is_cmd_nextreg_w or is_cmd_cpu_reg_r or is_cmd_cpu_reg_w;
   dispatch_l0 <= is_cmd_system;
   dispatch_idle <= is_cmd_nop or is_cmd_cpu_pause or is_cmd_cpu_resume or is_cmd_cpu_sstep;
   
   dispatch_error_a0 <= is_cmd_version or is_cmd_status;

   process (state, i_spi_rx_valid, reg_l_is_zero, r_is_cmd_bram_r, r_is_cmd_bram_w, r_is_cmd_sram_r, r_is_cmd_sram_w,
            dispatch_error_a0, dispatch_a2, dispatch_a1, dispatch_a0, dispatch_l0, dispatch_idle)
   begin
      -- highest priority assignment is at bottom of process
      state_next <= S_ERROR;
      if state(I_SRAM_W) = '1' then
         -- S_SRAM_W
         if i_spi_rx_valid = '1' and reg_l_is_zero = '1' then
            state_next <= S_IDLE;
         else
            state_next <= S_SRAM_W;
         end if;
      end if;
      if state(I_SRAM_R) = '1' then
         -- S_SRAM_R
         if i_spi_rx_valid = '1' and reg_l_is_zero = '1' then
            state_next <= S_IDLE;
         else
            state_next <= S_SRAM_R;
         end if;
      end if;
      if state(I_BRAM_W) = '1' then
         -- S_BRAM_W
         if i_spi_rx_valid = '1' and reg_l_is_zero = '1' then
            state_next <= S_IDLE;
         else
            state_next <= S_BRAM_W;
         end if;
      end if;
      if state(I_BRAM_R) = '1' then
         -- S_BRAM_R
         if i_spi_rx_valid = '1' and reg_l_is_zero = '1' then
            state_next <= S_IDLE;
         else
            state_next <= S_BRAM_R;
         end if;
      end if;
      if state(I_L0) = '1' then
         -- S_L0
         if i_spi_rx_valid = '1' then
            state_next <= S_IDLE;
            if r_is_cmd_bram_r = '1' then
               state_next <= S_BRAM_R;
            end if;
            if r_is_cmd_bram_w = '1' then
               state_next <= S_BRAM_W;
            end if;
            if r_is_cmd_sram_r = '1' then
               state_next <= S_SRAM_R;
            end if;
            if r_is_cmd_sram_w = '1' then
               state_next <= S_SRAM_W;
            end if;
         else
            state_next <= S_L0;
         end if;
      end if;
      if state(I_L1) = '1' then
         -- S_L1
         if i_spi_rx_valid = '1' then
            state_next <= S_L0;
         else
            state_next <= S_L1;
         end if;
      end if;
      if state(I_A0) = '1' then
         -- S_A0
         if i_spi_rx_valid = '1' then
            state_next <= S_L1;
         else
            state_next <= S_A0;
         end if;
      end if;
      if state(I_A1) = '1' then
         -- S_A1
         if i_spi_rx_valid = '1' then
            state_next <= S_A0;
         else
            state_next <= S_A1;
         end if;
      end if;
      if state(I_A2) = '1' then
         -- S_A2
         if i_spi_rx_valid = '1' then
            state_next <= S_A1;
         else
            state_next <= S_A2;
         end if;
      end if;
      if state(I_ERROR) = '1' then
         -- S_ERROR, illegal command must use CMD_VERSION or CMD_STATUS to exit
         if i_spi_rx_valid = '1' and dispatch_error_a0 = '1' then
            state_next <= S_A0;
         else
            state_next <= S_ERROR;
         end if;
      end if;
      if state(I_IDLE) = '1' then
         -- S_IDLE, ready for command
         if i_spi_rx_valid = '1' then
            if dispatch_a2 = '1' or dispatch_a1 = '1' or dispatch_a0 = '1' or dispatch_l0 = '1' or dispatch_idle = '1' then
               state_next <= "0000" & dispatch_l0 & '0' & dispatch_a0 & dispatch_a1 & dispatch_a2 & '0' & dispatch_idle;
            else
               state_next <= S_ERROR;
            end if;
         else
            state_next <= S_IDLE;
         end if;
      end if;
   end process;

   -- state registers
   -- REG_A2, REG_A1, REG_A0, REG_L1, REG_L0, REG_DI

gen_reg_a_111: if g_capabilities(3) = '1' generate

   operation_inc_reg_a <= bram_rd_control(1) or bram_wr_control(1) or sram_rd_control(1) or sram_wr_control(1);

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if operation_inc_reg_a = '1' then
            REG_A <= REG_A + 1;
         else
            if state(I_A2) = '1' and i_spi_rx_valid = '1' then
               REG_A(20 downto 16) <= i_spi_rx_di(4 downto 0);
            end if;
            if state(I_A1) = '1' and i_spi_rx_valid = '1' then
               REG_A(15 downto 8) <= i_spi_rx_di;
            end if;
            if state(I_A0) = '1' and i_spi_rx_valid = '1' then
               REG_A(7 downto 0) <= i_spi_rx_di;
            end if;
         end if;
      end if;
   end process;

   REG_A2 <= REG_A(20 downto 16);
   REG_A1 <= REG_A(15 downto 8);
   REG_A0 <= REG_A(7 downto 0);

end generate;

gen_reg_a_011: if g_capabilities(3) = '0' and g_capabilities(5) = '1' generate

   operation_inc_reg_a <= bram_rd_control(1) or bram_wr_control(1);

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if operation_inc_reg_a = '1' then
            REG_A(15 downto 0) <= REG_A(15 downto 0) + 1;
         else
            if state(I_A1) = '1' and i_spi_rx_valid = '1' then
               REG_A(15 downto 8) <= i_spi_rx_di;
            end if;
            if state(I_A0) = '1' and i_spi_rx_valid = '1' then
               REG_A(7 downto 0) <= i_spi_rx_di;
            end if;
         end if;
      end if;
   end process;

   REG_A2 <= (others => '0');
   REG_A1 <= REG_A(15 downto 8);
   REG_A0 <= REG_A(7 downto 0);

end generate;

gen_reg_a_001: if g_capabilities(3) = '0' and g_capabilities(5) = '0' and (g_capabilities(6) = '1' or g_capabilities(2) = '1' or g_capabilities(1) = '1') generate

   operation_inc_reg_a <= '0';
   
   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if state(I_A0) = '1' and i_spi_rx_valid = '1' then
            REG_A(7 downto 0) <= i_spi_rx_di;
         end if;
      end if;
   end process;

   REG_A2 <= (others => '0');
   REG_A1 <= (others => '0');
   REG_A0 <= REG_A(7 downto 0);

end generate;

gen_reg_a_000: if g_capabilities(3) = '0' and g_capabilities(5) = '0' and g_capabilities(6) = '0' and g_capabilities(2) = '0' and g_capabilities(1) = '0' generate

   operation_inc_reg_a <= '0';

   REG_A2 <= (others => '0');
   REG_A1 <= (others => '0');
   REG_A0 <= (others => '0');

end generate;

   --

gen_reg_l_1: if g_capabilities(3) = '1' or g_capabilities(5) = '1' generate


   operation_dec_reg_l <= '1' when ((state(I_SRAM_R) = '1' or state(I_BRAM_R) = '1') and i_spi_rx_valid = '1') or
                                   ((state(I_SRAM_W) = '1' or state(I_BRAM_W) = '1') and i_spi_tx_ack = '1') else '0';

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if operation_dec_reg_l = '1' then
            if reg_l_is_zero = '0' then
               REG_L <= REG_L - 1;
            end if;
         else
            if state(I_L1) = '1' and i_spi_rx_valid = '1' then
               REG_L(15 downto 8) <= i_spi_rx_di;
            end if;
            if state(I_L0) = '1' and i_spi_rx_valid = '1' then
               REG_L(7 downto 0) <= i_spi_rx_di;
            end if;
         end if;
      end if;
   end process;
   
   reg_l_is_zero <= '1' when REG_L = X"0000" else '0';
   
   REG_L1 <= REG_L(15 downto 8);
   REG_L0 <= REG_L(7 downto 0);

end generate;

gen_reg_l_0: if g_capabilities(3) = '0' and g_capabilities(5) = '0' generate

   operation_dec_reg_l <= '0';
   
   reg_l_is_zero <= '1';
   
   REG_L1 <= (others => '0');
   REG_L0 <= (others => '0');

end generate;

   --

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if reg_di_load = '1' then
            REG_DI <= reg_di_value;
         end if;
      end if;
   end process;

   -- output register
   -- REG_DI is shared by o_data and o_spi_tx_do

   process (r_is_cmd_version, state, i_spi_rx_valid, r_is_cmd_status, status_byte, hotkeys, bram_rd_control, i_bram_di, sram_rd_control, 
            i_sram_c_di, nextreg_rd_control, i_nextreg_di, r_is_cmd_nextreg_w, r_is_cmd_cpu_reg_r, i_cpu_di, r_is_cmd_cpu_reg_w)
   begin
      -- highest priority assignment is at bottom of process
      reg_di_load <= '0';
      reg_di_value <= (others => '0');
      if r_is_cmd_version = '1' then
         if state(I_A0) = '1' and i_spi_rx_valid = '1' then
            reg_di_load <= '1';
            reg_di_value <= std_logic_vector(g_version) & X"0";
         end if;
         if state(I_L1) = '1' and i_spi_rx_valid = '1' then
            reg_di_load <= '1';
            reg_di_value <= std_logic_vector(g_capabilities);
         end if;
      end if;
      if r_is_cmd_status = '1' then
         if state(I_A0) = '1' and i_spi_rx_valid = '1' then
            reg_di_load <= '1';
            reg_di_value <= status_byte;
         end if;
         if state(I_L1) = '1' and i_spi_rx_valid = '1' then
            reg_di_load <= '1';
            reg_di_value <= "000" & hotkeys;
         end if;
      end if;
      if bram_rd_control(1) = '1' then
         reg_di_load <= '1';
         reg_di_value <= i_bram_di;
      end if;
      if state(I_BRAM_W) = '1' and i_spi_rx_valid = '1' then
         -- consistent with bram_wr_control
         reg_di_load <= '1';
         reg_di_value <= i_spi_rx_di;
      end if;
      if sram_rd_control(1) = '1' then
         reg_di_load <= '1';
         reg_di_value <= i_sram_c_di;
      end if;
      if state(I_SRAM_W) = '1' and i_spi_rx_valid = '1' then
         -- consistent with sram_wr_control
         reg_di_load <= '1';
         reg_di_value <= i_spi_rx_di;
      end if;
      if nextreg_rd_control(1) = '1' then
         reg_di_load <= '1';
         reg_di_value <= i_nextreg_di;
      end if;
      if r_is_cmd_nextreg_w = '1' then
         -- consistent with nextreg_wr_control
         if state(I_L1) = '1' and i_spi_rx_valid = '1' then
            reg_di_load <= '1';
            reg_di_value <= i_spi_rx_di;
         end if;
      end if;
      if r_is_cmd_cpu_reg_r = '1' and state(I_L1) = '1' and i_spi_rx_valid = '1' then
         reg_di_load <= '1';
         reg_di_value <= i_cpu_di;
      end if;
      if r_is_cmd_cpu_reg_w = '1' then
         -- consistent with cpu_wr_control
         if state(I_L1) = '1' and i_spi_rx_valid = '1' then
            reg_di_load <= '1';
            reg_di_value <= i_spi_rx_di;
         end if;
      end if;
   end process;

   -- actions
   
   -- CMD_STATUS
   -- { had reset, busrq_status(1:0), dma_active_n, cpu_halted_n, 0, 0, had error }

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            status_error <= '0';
            status_reset <= '1';
         elsif i_spi_active_n = '1' then
            status_error <= '0';
         elsif r_is_cmd_status = '1' and state(I_A0) = '1' and i_spi_rx_valid = '1' then
            status_error <= '0';
            status_reset <= '0';
         elsif state(I_ERROR) = '1' then
            status_error <= '1';
         end if;
      end if;
   end process;
   
   status_byte <= status_reset & bus_status & i_dma_busak_n & i_cpu_halt_n & "00" & status_error;

   -- hotkeys
   -- { 0, 0, 0, Q, W, E, R, T }

gen_hotkeys_1: if g_capabilities(7) = '1' generate

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            hotkeys <= (others => '0');
         elsif r_is_cmd_status = '1' and state(I_L1) = '1' and i_spi_rx_valid = '1' then
            hotkeys <= i_hotkeys(4 downto 0);
         else
            hotkeys <= hotkeys or i_hotkeys(4 downto 0);
         end if;
      end if;
   end process;

end generate;

gen_hotkeys_0: if g_capabilities(7) = '0' generate

   hotkeys <= (others => '0');

end generate;

   -- CMD_SYSTEM
   -- { 0, 0, 0, gen ctc-3 int, gen mf nmi, gen divmmc nmi, hard reset, soft reset }

gen_cmd_system_1: if g_capabilities(0) = '1' generate

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if r_is_cmd_system = '1' and state(I_L0) = '1' and i_spi_rx_valid = '1' then
            system_command <= i_spi_rx_di(4 downto 0);
         else
            -- pulsed signals
            system_command <= (others => '0');
         end if;
      end if;
   end process;

end generate;

gen_cmd_system_0: if g_capabilities(0) = '0' generate

   system_command <= (others => '0');

end generate;

   -- CMD_CPU_PAUSE, CMD_CPU_RESUME, CMD_CPU_SSTEP

gen_cmd_busrq_1: if g_capabilities(4) = '1' generate

   process (i_CLK)
   begin
      -- bus_control(0) = busrq_n
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            bus_control <= "01";
         elsif is_cmd_cpu_resume = '1' and state(I_IDLE) = '1' and i_spi_rx_valid = '1' then
            bus_control <= "01";
         else
            case bus_control is
               when "01" =>
                  -- idle wait for command
                  if (is_cmd_cpu_pause = '1' or is_cmd_cpu_sstep = '1') and state(I_IDLE) = '1' and i_spi_rx_valid = '1' then
                     bus_control <= "00";
                  else
                     bus_control <= "01";
                  end if;
               when "00" =>
                  -- request bus
                  if is_cmd_cpu_sstep = '1' and state(I_IDLE) = '1' and i_spi_rx_valid = '1' and i_cpu_busak_n = '0' then
                     bus_control <= "11";
                  else
                     bus_control <= "00";
                  end if;
               when "11" =>
                  -- single step wait for busak to release
                  if i_cpu_busak_n = '1' then
                     bus_control <= "00";
                  else
                     bus_control <= "11";
                  end if;
               when others =>
                  bus_control <= "01";
            end case;
         end if;
      end if;
   end process;
   
   process (bus_control, i_cpu_busak_n)
   begin
      case bus_control is
         when "00"   =>
            bus_status <= not i_cpu_busak_n & i_cpu_busak_n;
         when "01"   =>
            bus_status <= "00";
         when others =>
            bus_status <= "11";
      end case;
   end process;

end generate;

gen_cmd_busrq_0: if g_capabilities(4) = '0' generate

   bus_control <= "01";
   bus_status <= "00";

end generate;

   -- CMD_BRAM_RW

gen_cmd_bram_1: if g_capabilities(5) = '1' generate

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if reset = '1' then
            bram_rd_control <= "00";
         else
            bram_rd_control <= bram_rd_control_next;
         end if;
      end if;
   end process;

   process (bram_rd_control, state, i_spi_tx_ack, reg_l_is_zero, i_bram_ack)
   begin
      bram_rd_control_next <= "00";
      if state(I_BRAM_R) = '1' then
         case bram_rd_control is
            when "00" =>
               bram_rd_control_next <= '0' & (i_spi_tx_ack and not reg_l_is_zero);
            when "01" =>
               -- bram read cycle
               if i_bram_ack = '1' then
                  bram_rd_control_next <= "10";
               else
                  bram_rd_control_next <= "01";
               end if;
--          when "10" =>
               -- byte available
            when others =>
               bram_rd_control_next <= "00";
         end case;
      end if;
   end process;

   --

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            bram_wr_control <= "00";
         else
            bram_wr_control <= bram_wr_control_next;
         end if;
      end if;
   end process;

   process (bram_wr_control, state, i_spi_rx_valid, reg_l_is_zero, i_bram_ack)
   begin
      case bram_wr_control is
         when "00" =>
            if state(I_BRAM_W) = '1' then
               -- writes of length zero write one byte
               bram_wr_control_next <= '0' & i_spi_rx_valid;
            else
               bram_wr_control_next <= "00";
            end if;
         when "01" =>
            -- bram write cycle
            if i_bram_ack = '1' then
               bram_wr_control_next <= "10";
            else
               bram_wr_control_next <= "01";
            end if;
--       when "10" =>
            -- byte written
         when others =>
            bram_wr_control_next <= "00";
      end case;
   end process;

   --

   process (i_CLK)
   begin
      -- separated next state logic allows output signals to pass through registers
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            bram_req <= '0';
         else
            bram_req <= bram_rd_control_next(0) or bram_wr_control_next(0);
         end if;
      end if;
   end process;

end generate;

gen_cmd_bram_0: if g_capabilities(5) = '0' generate

   bram_rd_control <= "00";
   bram_wr_control <= "00";
   bram_req <= '0';

end generate;

   -- CMD_SRAM_RW

gen_cmd_sram_1: if g_capabilities(3) = '1' generate

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if reset = '1' then
            sram_rd_control <= "00";
         else
            sram_rd_control <= sram_rd_control_next;
         end if;
      end if;
   end process;
   
   process (sram_rd_control, state, i_spi_tx_ack, reg_l_is_zero, i_sram_c_ack)
   begin
      sram_rd_control_next <= "00";
      if state(I_SRAM_R) = '1' then
         case sram_rd_control is
            when "00" =>
               sram_rd_control_next <= '0' & (i_spi_tx_ack and not reg_l_is_zero);
            when "01" =>
               -- sram port c read cycle
               if i_sram_c_ack = '1' then
                  sram_rd_control_next <= "10";
               else
                  sram_rd_control_next <= "01";
               end if;
--          when "10" =>
               -- byte available
            when others =>
               sram_rd_control_next <= "00";
         end case;
      end if;
   end process;

   --
   
   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            sram_wr_control <= "00";
         else
            sram_wr_control <= sram_wr_control_next;
         end if;
      end if;
   end process;

   process (sram_wr_control, state, i_spi_rx_valid, reg_l_is_zero, i_sram_c_ack)
   begin
      case sram_wr_control is
         when "00" =>
            if state(I_SRAM_W) = '1' then
               -- writes of length zero write one byte
               sram_wr_control_next <= '0' & i_spi_rx_valid;
            else
               sram_wr_control_next <= "00";
            end if;
         when "01" =>
            -- sram port c write cycle
            if i_sram_c_ack = '1' then
               sram_wr_control_next <= "10";
            else
               sram_wr_control_next <= "01";
            end if;
--       when "10" =>
            -- byte written
         when others =>
            sram_wr_control_next <= "00";
      end case;
   end process;
   
   --

   process (i_CLK)
   begin
      -- separated next state logic allows output signals to pass through registers
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            sram_req <= '0';
         else
            sram_req <= sram_rd_control_next(0) or sram_wr_control_next(0);
         end if;
      end if;
   end process;

end generate;

gen_cmd_sram_0: if g_capabilities(3) = '0' generate

   sram_rd_control <= "00";
   sram_wr_control <= "00";
   sram_req <= '0';

end generate;

   -- CMD_NEXTREG_R

gen_cmd_nextreg_r_1: if g_capabilities(1) = '1' generate

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if reset = '1' then
            nextreg_rd_control <= "00";
         elsif r_is_cmd_nextreg_r = '1' and state(I_A0) = '1' and i_spi_rx_valid = '1' then
            nextreg_rd_control <= "01";
         else
            case nextreg_rd_control is
               when "01" =>
                  -- nextreg read cycle
                  if i_nextreg_rd_ack = '1' then
                     nextreg_rd_control <= "10";
                  else
                     nextreg_rd_control <= "01";
                  end if;
--             when "10" =>
                  -- byte available
               when others =>
                  nextreg_rd_control <= "00";
            end case;
         end if;
      end if;
   end process;   

end generate;

gen_cmd_nextreg_r_0: if g_capabilities(1) = '0' generate

   nextreg_rd_control <= "00";
   
end generate;

   -- CMD_NEXTREG_W
   
gen_cmd_nextreg_w_1: if g_capabilities(2) = '1' generate

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if i_reset = '1' then
            nextreg_wr_control <= '0';
         elsif r_is_cmd_nextreg_w = '1' and state(I_L1) = '1' and i_spi_rx_valid = '1' then
            nextreg_wr_control <= '1';
         elsif nextreg_wr_control = '1' then
            -- nextreg write cycle
            nextreg_wr_control <= not i_nextreg_wr_ack;
         end if;
      end if;
   end process;

end generate;

gen_cmd_nextreg_w_0: if g_capabilities(2) = '0' generate

   nextreg_wr_control <= '0';
   
end generate;

   -- CMD_CPU_REG_W

gen_cmd_cpu_reg_1: if g_capabilities(6) = '1' generate

   process (i_CLK)
   begin
      if rising_edge(i_CLK) then
         if reset = '1' then
            cpu_wr_control <= '0';
         elsif i_spi_rx_valid = '1' then
            if r_is_cmd_cpu_reg_w = '1' and state(I_L1) = '1' then
               cpu_wr_control <= '1';
            else
               cpu_wr_control <= '0';
            end if;
         end if;         
      end if;
   end process;

end generate;

gen_cmd_cpu_reg_0: if g_capabilities(6) = '0' generate

   cpu_wr_control <= '0';

end generate;

   -- output

   o_cpu_busrq_n <= bus_control(0);

-- o_spi_tx_valid <= '1';   -- always ok to output data if correct data is present at right time, needed for tx_ack timing
   o_spi_tx_do <= REG_DI;

   o_addr_2 <= REG_A2;
   o_addr_1 <= REG_A1;
   o_addr_0 <= REG_A0;
   o_data <= REG_DI;

   o_cpu_wr <= cpu_wr_control;
   
-- o_nextreg_rd <= nextreg_rd_control(0);   -- not needed
   o_nextreg_wr <= nextreg_wr_control;

   o_bram_req <= bram_req;
   o_bram_wr <= bram_wr_control(0);

   o_sram_c_req <= sram_req;
   o_sram_c_rd_n <= sram_wr_control(0);

   o_command <= system_command;
   
end architecture;
