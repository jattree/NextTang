-- spram_320_9 (two banks, rtl/core/memory/nexttang_sdpram.vhd) against a
-- plain 512-entry RAM, with random writes below 320 (as the sprite engine
-- makes them) and random reads anywhere: every read must match.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_spram_320_9 is
end entity;

architecture sim of tb_spram_320_9 is
   signal clk : std_logic := '0';
   signal we  : std_logic := '0';
   signal a, d, q, q_ref : std_logic_vector(8 downto 0) := (others => '0');
   type ram_t is array (0 to 511) of std_logic_vector(8 downto 0);
   signal ref : ram_t := (others => (others => '0'));
begin
   clk <= not clk after 5 ns;
   dut : entity work.spram_320_9 port map (CLK => clk, WE => we, SPO => q, A => a, D => d);
   process (clk) begin
      if rising_edge(clk) then
         if we = '1' then ref(to_integer(unsigned(a))) <= d; end if;
      end if;
   end process;
   q_ref <= ref(to_integer(unsigned(a)));

   process
      variable s1, s2 : positive := 7;
      variable r : real;
      variable errors : natural := 0;
   begin
      for i in 0 to 200000 loop
         wait until falling_edge(clk);
         uniform(s1, s2, r);
         if r < 0.5 then
            we <= '1';
            uniform(s1, s2, r); a <= std_logic_vector(to_unsigned(integer(trunc(r * 320.0)), 9));
         else
            we <= '0';
            uniform(s1, s2, r); a <= std_logic_vector(to_unsigned(integer(trunc(r * 512.0)), 9));
         end if;
         uniform(s1, s2, r); d <= std_logic_vector(to_unsigned(integer(trunc(r * 512.0)), 9));
         wait for 1 ns;
         if q /= q_ref then
            errors := errors + 1;
            if errors < 5 then report "mismatch at " & integer'image(to_integer(unsigned(a))) severity warning; end if;
         end if;
      end loop;
      if errors = 0 then report "PASS" severity note; else report "FAIL " & integer'image(errors) severity note; end if;
      std.env.finish;
   end process;
end architecture;
