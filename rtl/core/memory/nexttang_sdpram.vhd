-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Portable synchronous-write, asynchronous-read distributed RAM.
entity sdpram is
    generic (
        addr_width_g : integer := 6;
        data_width_g : integer := 8
    );
    port (
        clk_a_i  : in  std_logic;
        we_a_i   : in  std_logic;
        addr_a_i : in  std_logic_vector(addr_width_g - 1 downto 0);
        data_a_i : in  std_logic_vector(data_width_g - 1 downto 0);
        addr_b_i : in  std_logic_vector(addr_width_g - 1 downto 0);
        data_b_o : out std_logic_vector(data_width_g - 1 downto 0)
    );
end entity;

architecture rtl of sdpram is
    type ram_t is array (0 to (2 ** addr_width_g) - 1) of
        std_logic_vector(data_width_g - 1 downto 0);
    signal ram : ram_t := (others => (others => '0'));
begin
    write_port : process (clk_a_i)
    begin
        if rising_edge(clk_a_i) then
            if we_a_i = '1' then
                ram(to_integer(unsigned(addr_a_i))) <= data_a_i;
            end if;
        end if;
    end process;

    data_b_o <= ram(to_integer(unsigned(addr_b_i)));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Sprite-pattern memory: one synchronous write port and one independently
-- clocked synchronous read port.
entity sdpbram_16k_8 is
    port (
        WEA   : in  std_logic_vector(0 downto 0);
        ADDRA : in  std_logic_vector(13 downto 0);
        DINA  : in  std_logic_vector(7 downto 0);
        CLKA  : in  std_logic;
        ENB   : in  std_logic;
        ADDRB : in  std_logic_vector(13 downto 0);
        DOUTB : out std_logic_vector(7 downto 0);
        CLKB  : in  std_logic
    );
end entity;

architecture rtl of sdpbram_16k_8 is
    type ram_t is array (0 to (2 ** 14) - 1) of std_logic_vector(7 downto 0);
    signal ram : ram_t := (others => (others => '0'));
begin
    write_port : process (CLKA)
    begin
        if rising_edge(CLKA) then
            if WEA(0) = '1' then
                ram(to_integer(unsigned(ADDRA))) <= DINA;
            end if;
        end if;
    end process;

    read_port : process (CLKB)
    begin
        if rising_edge(CLKB) then
            if ENB = '1' then
                DOUTB <= ram(to_integer(unsigned(ADDRB)));
            end if;
        end if;
    end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity sdpram_128_8 is
    port (
        DPRA : in  std_logic_vector(6 downto 0);
        DPO  : out std_logic_vector(7 downto 0);
        CLK  : in  std_logic;
        WE   : in  std_logic;
        A    : in  std_logic_vector(6 downto 0);
        D    : in  std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of sdpram_128_8 is
begin
    ram : entity work.sdpram
        generic map (addr_width_g => 7, data_width_g => 8)
        port map (
            clk_a_i => CLK, we_a_i => WE, addr_a_i => A, data_a_i => D,
            addr_b_i => DPRA, data_b_o => DPO
        );
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity spram_320_9 is
    port (
        CLK : in  std_logic;
        WE  : in  std_logic;
        SPO : out std_logic_vector(8 downto 0);
        A   : in  std_logic_vector(8 downto 0);
        D   : in  std_logic_vector(8 downto 0)
    );
end entity;

-- A sprite line buffer holds 320 pixels. Built as one 512-entry RAM it took
-- 96 distributed-RAM cells per buffer for 192 entries nobody writes (both of
-- its writers stop at 319, sprites.vhd), so it is a 256-entry and a 64-entry
-- bank. Entries 320-511 read 0, as they did: they were never written.
architecture rtl of spram_320_9 is
    signal we_lo, we_hi : std_logic;
    signal q_lo, q_hi   : std_logic_vector(8 downto 0);
begin
    we_lo <= WE when A(8) = '0' else '0';
    we_hi <= WE when A(8 downto 6) = "100" else '0';
    lo : entity work.sdpram
        generic map (addr_width_g => 8, data_width_g => 9)
        port map (
            clk_a_i => CLK, we_a_i => we_lo, addr_a_i => A(7 downto 0), data_a_i => D,
            addr_b_i => A(7 downto 0), data_b_o => q_lo
        );
    hi : entity work.sdpram
        generic map (addr_width_g => 6, data_width_g => 9)
        port map (
            clk_a_i => CLK, we_a_i => we_hi, addr_a_i => A(5 downto 0), data_a_i => D,
            addr_b_i => A(5 downto 0), data_b_o => q_hi
        );
    SPO <= q_lo when A(8) = '0' else
           q_hi when A(7 downto 6) = "00" else
           (others => '0');
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity sdpram_16_9 is
    port (
        DPRA : in  std_logic_vector(3 downto 0);
        DPO  : out std_logic_vector(8 downto 0);
        CLK  : in  std_logic;
        WE   : in  std_logic;
        A    : in  std_logic_vector(3 downto 0);
        D    : in  std_logic_vector(8 downto 0)
    );
end entity;

architecture rtl of sdpram_16_9 is
begin
    ram : entity work.sdpram
        generic map (addr_width_g => 4, data_width_g => 9)
        port map (
            clk_a_i => CLK, we_a_i => WE, addr_a_i => A, data_a_i => D,
            addr_b_i => DPRA, data_b_o => DPO
        );
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity sdpram_64_9 is
    port (
        DPRA : in  std_logic_vector(5 downto 0);
        CLK  : in  std_logic;
        WE   : in  std_logic;
        DPO  : out std_logic_vector(8 downto 0);
        A    : in  std_logic_vector(5 downto 0);
        D    : in  std_logic_vector(8 downto 0)
    );
end entity;

architecture rtl of sdpram_64_9 is
begin
    ram : entity work.sdpram
        generic map (addr_width_g => 6, data_width_g => 9)
        port map (
            clk_a_i => CLK, we_a_i => WE, addr_a_i => A, data_a_i => D,
            addr_b_i => DPRA, data_b_o => DPO
        );
end architecture;
