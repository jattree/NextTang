-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- The official core picks its CPU by g_option(1 downto 0): T80na, the
-- "complete" T80 with the MEMPTR and XY-flag fixes, and either with David
-- Saphier's debug interface. NextTang's single T80Na is Sorgelig's ZEXALL-
-- and MEMPTR-correct T80, which already has those fixes, with the official
-- debug interface merged in (docs/upstream-official-files.tsv). These
-- entities give the official names to that one CPU, so zxnext.vhd's CPU
-- selection merges unchanged from each official release.

library ieee;
use ieee.std_logic_1164.all;
use work.Z80N_pack.all;

entity T80na_Complete is
   generic (Mode : integer := 0);
   port (
      RESET_n, CLK_n : in std_logic;
      CEN_R, CEN_F : in std_logic := '1';
      WAIT_n, INT_n, NMI_n, BUSRQ_n : in std_logic;
      M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n : out std_logic;
      A : out std_logic_vector(15 downto 0);
      D_i : in std_logic_vector(7 downto 0);
      D_o : out std_logic_vector(7 downto 0);
      Z80N_dout_o : out std_logic := '0';
      Z80N_data_o : out std_logic_vector(15 downto 0);
      Z80N_command_o : out Z80N_seq
   );
end entity;

architecture rtl of T80na_Complete is
begin
   cpu : entity work.T80Na
      generic map (Mode => Mode)
      port map (
         RESET_n => RESET_n, CLK_n => CLK_n, CEN_R => CEN_R, CEN_F => CEN_F,
         WAIT_n => WAIT_n, INT_n => INT_n, NMI_n => NMI_n, BUSRQ_n => BUSRQ_n,
         M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n, WR_n => WR_n,
         RFSH_n => RFSH_n, HALT_n => HALT_n, BUSAK_n => BUSAK_n,
         A => A, D_i => D_i, D_o => D_o,
         Z80N_dout_o => Z80N_dout_o, Z80N_data_o => Z80N_data_o, Z80N_command_o => Z80N_command_o,
         o_debug_dat => open, o_debug_lastM => open
      );
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use work.Z80N_pack.all;

entity T80na_Debug is
   generic (Mode : integer := 0);
   port (
      RESET_n, CLK_n : in std_logic;
      CEN_R, CEN_F : in std_logic := '1';
      WAIT_n, INT_n, NMI_n, BUSRQ_n : in std_logic;
      M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n : out std_logic;
      A : out std_logic_vector(15 downto 0);
      D_i : in std_logic_vector(7 downto 0);
      D_o : out std_logic_vector(7 downto 0);
      Z80N_dout_o : out std_logic := '0';
      Z80N_data_o : out std_logic_vector(15 downto 0);
      Z80N_command_o : out Z80N_seq;
      i_debug_reg : in std_logic_vector(4 downto 0);
      i_debug_wr : in std_logic;
      i_debug_dat : in std_logic_vector(7 downto 0);
      o_debug_dat : out std_logic_vector(7 downto 0);
      o_debug_lastM : out std_logic;
      i_debug_pause : in std_logic := '0';   -- NextTang: see t80n.vhd
      o_debug_next_pc : out std_logic_vector(15 downto 0);
      i_debug_break : in std_logic := '0'
   );
end entity;

architecture rtl of T80na_Debug is
begin
   cpu : entity work.T80Na
      generic map (Mode => Mode)
      port map (
         RESET_n => RESET_n, CLK_n => CLK_n, CEN_R => CEN_R, CEN_F => CEN_F,
         WAIT_n => WAIT_n, INT_n => INT_n, NMI_n => NMI_n, BUSRQ_n => BUSRQ_n,
         M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n, WR_n => WR_n,
         RFSH_n => RFSH_n, HALT_n => HALT_n, BUSAK_n => BUSAK_n,
         A => A, D_i => D_i, D_o => D_o,
         Z80N_dout_o => Z80N_dout_o, Z80N_data_o => Z80N_data_o, Z80N_command_o => Z80N_command_o,
         i_debug_reg => i_debug_reg, i_debug_wr => i_debug_wr, i_debug_dat => i_debug_dat,
         o_debug_dat => o_debug_dat, o_debug_lastM => o_debug_lastM, i_debug_pause => i_debug_pause,
         o_debug_next_pc => o_debug_next_pc, i_debug_break => i_debug_break
      );
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use work.Z80N_pack.all;

entity T80na_Complete_Debug is
   generic (Mode : integer := 0);
   port (
      RESET_n, CLK_n : in std_logic;
      CEN_R, CEN_F : in std_logic := '1';
      WAIT_n, INT_n, NMI_n, BUSRQ_n : in std_logic;
      M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n : out std_logic;
      A : out std_logic_vector(15 downto 0);
      D_i : in std_logic_vector(7 downto 0);
      D_o : out std_logic_vector(7 downto 0);
      Z80N_dout_o : out std_logic := '0';
      Z80N_data_o : out std_logic_vector(15 downto 0);
      Z80N_command_o : out Z80N_seq;
      i_debug_reg : in std_logic_vector(4 downto 0);
      i_debug_wr : in std_logic;
      i_debug_dat : in std_logic_vector(7 downto 0);
      o_debug_dat : out std_logic_vector(7 downto 0);
      o_debug_lastM : out std_logic;
      i_debug_pause : in std_logic := '0';   -- NextTang: see t80n.vhd
      o_debug_next_pc : out std_logic_vector(15 downto 0);
      i_debug_break : in std_logic := '0'
   );
end entity;

architecture rtl of T80na_Complete_Debug is
begin
   cpu : entity work.T80na_Debug
      generic map (Mode => Mode)
      port map (
         RESET_n => RESET_n, CLK_n => CLK_n, CEN_R => CEN_R, CEN_F => CEN_F,
         WAIT_n => WAIT_n, INT_n => INT_n, NMI_n => NMI_n, BUSRQ_n => BUSRQ_n,
         M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n, WR_n => WR_n,
         RFSH_n => RFSH_n, HALT_n => HALT_n, BUSAK_n => BUSAK_n,
         A => A, D_i => D_i, D_o => D_o,
         Z80N_dout_o => Z80N_dout_o, Z80N_data_o => Z80N_data_o, Z80N_command_o => Z80N_command_o,
         i_debug_reg => i_debug_reg, i_debug_wr => i_debug_wr, i_debug_dat => i_debug_dat,
         o_debug_dat => o_debug_dat, o_debug_lastM => o_debug_lastM, i_debug_pause => i_debug_pause,
         o_debug_next_pc => o_debug_next_pc, i_debug_break => i_debug_break
      );
end architecture;
