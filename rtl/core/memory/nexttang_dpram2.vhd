-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Portable 1RW + 1R dual-port RAM matching the direct ZXNext core boundary.
-- Both reads are synchronous and a same-port read during write returns the
-- previous value. Only blank initialisation is supported here.
entity dpram2 is
    generic (
        addr_width_g : integer := 8;
        data_width_g : integer := 8;
        init_file_g  : string := " "
    );
    port (
        clk_a_i  : in  std_logic;
        we_i     : in  std_logic;
        addr_a_i : in  std_logic_vector(addr_width_g - 1 downto 0);
        data_a_i : in  std_logic_vector(data_width_g - 1 downto 0);
        data_a_o : out std_logic_vector(data_width_g - 1 downto 0);
        clk_b_i  : in  std_logic;
        addr_b_i : in  std_logic_vector(addr_width_g - 1 downto 0);
        data_b_o : out std_logic_vector(data_width_g - 1 downto 0)
    );
end entity;

architecture rtl of dpram2 is
    type ram_t is array (0 to (2 ** addr_width_g) - 1) of
        std_logic_vector(data_width_g - 1 downto 0);
    signal ram : ram_t := (others => (others => '0'));
begin
    assert init_file_g = " " or init_file_g = "init/none.bin.txt"
        report "dpram2 supports blank initialisation only"
        severity failure;

    port_a : process (clk_a_i)
    begin
        if rising_edge(clk_a_i) then
            if we_i = '1' then
                ram(to_integer(unsigned(addr_a_i))) <= data_a_i;
            end if;
            data_a_o <= ram(to_integer(unsigned(addr_a_i)));
        end if;
    end process;

    port_b : process (clk_b_i)
    begin
        if rising_edge(clk_b_i) then
            data_b_o <= ram(to_integer(unsigned(addr_b_i)));
        end if;
    end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- The direct core uses this RAM for two UART FIFOs whose ports share i_CLK.
-- Keeping the same-clock requirement explicit permits portable inference and
-- makes a simultaneous same-address write a visible integration error.
entity tdpram is
    generic (
        addr_width_g : integer := 8;
        data_width_g : integer := 8
    );
    port (
        clk_a_i  : in  std_logic;
        we_a_i   : in  std_logic;
        addr_a_i : in  std_logic_vector(addr_width_g - 1 downto 0);
        data_a_i : in  std_logic_vector(data_width_g - 1 downto 0);
        data_a_o : out std_logic_vector(data_width_g - 1 downto 0);
        clk_b_i  : in  std_logic;
        we_b_i   : in  std_logic;
        addr_b_i : in  std_logic_vector(addr_width_g - 1 downto 0);
        data_b_i : in  std_logic_vector(data_width_g - 1 downto 0);
        data_b_o : out std_logic_vector(data_width_g - 1 downto 0)
    );
end entity;

architecture rtl of tdpram is
    type ram_t is array (0 to (2 ** addr_width_g) - 1) of
        std_logic_vector(data_width_g - 1 downto 0);
    signal ram : ram_t := (others => (others => '0'));
begin
    assert clk_a_i = clk_b_i
        report "tdpram requires both ports to share one clock"
        severity failure;

    ports : process (clk_a_i)
    begin
        if rising_edge(clk_a_i) then
            assert not (
                we_a_i = '1' and we_b_i = '1' and addr_a_i = addr_b_i
            )
                report "tdpram simultaneous writes selected one address"
                severity failure;

            if we_a_i = '1' then
                ram(to_integer(unsigned(addr_a_i))) <= data_a_i;
            end if;
            if we_b_i = '1' then
                ram(to_integer(unsigned(addr_b_i))) <= data_b_i;
            end if;

            data_a_o <= ram(to_integer(unsigned(addr_a_i)));
            data_b_o <= ram(to_integer(unsigned(addr_b_i)));
        end if;
    end process;
end architecture;
