-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- spi_master against an SPI mode 0 card through the Nano 20K's pins: SCK
-- leaves through an I/O-cell register on clock_28's rising edge and reaches
-- the card SCK_OUT later; the card moves MISO CARD_DELAY after each SCK fall
-- it sees; MISO takes MISO_IN back to the master's registers. The CPU clock is
-- clock_28 with enables (one CPU clock every DIVIDE clock_28 periods), and
-- STRETCH holds an enable pair back now and then as contention does.
--
-- Each transfer is checked: the byte the master publishes is the card's, the
-- byte the card took from MOSI is the one written, eight SCK pulses. Prints
-- PASS, or FAIL with the first difference. Reads and writes alternate in runs
-- started as soon as the master is free (as DMA does) and with gaps.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_spi_master is
   generic (
      MISO_LATE  : integer := 0;
      DIVIDE     : integer := 1;        -- 1: 28 MHz CPU, 2: 14, 4: 7, 8: 3.5
      STRETCH    : boolean := false;
      CARD_PS    : integer := 14000;    -- the card's MISO delay after SCK falls, ps
      SCK_OUT_PS : integer := 6440;     -- clock-to-pin 6.19 ns + board 0.25
      MISO_IN_PS : integer := 3950;     -- board 0.25 ns + pin to register 3.7
      TRANSFERS  : integer := 200
   );
end entity;

architecture sim of tb_spi_master is
   constant PERIOD     : time := 35.556 ns;   -- clock_28 (28.125 MHz)
   constant CARD_DELAY : time := CARD_PS * 1 ps;
   constant SCK_OUT    : time := SCK_OUT_PS * 1 ps;
   constant MISO_IN    : time := MISO_IN_PS * 1 ps;

   signal clock     : std_logic := '0';
   signal cen_r     : std_logic := '0';
   signal cen_f     : std_logic := '0';
   signal sck       : std_logic;
   signal mosi      : std_logic;
   signal miso_core : std_logic := '1';
   signal mosi_wr   : std_logic := '0';
   signal miso_rd   : std_logic := '0';
   signal wr_data   : std_logic_vector(7 downto 0) := (others => '0');
   signal rd_data   : std_logic_vector(7 downto 0);
   signal wait_n    : std_logic;

   signal sck_reg   : std_logic := '0';   -- the top's I/O-cell register
   signal sck_card  : std_logic := '0';
   signal mosi_reg  : std_logic := '1';
   signal mosi_card : std_logic := '1';
   signal miso_card : std_logic := '1';

   -- what the card sends and takes
   signal card_in_byte  : std_logic_vector(7 downto 0) := (others => '0');
   signal card_edges    : integer := 0;      -- SCK rises seen by the card

   signal done : boolean := false;

   function next_byte(seed : unsigned(15 downto 0)) return unsigned is
      variable s : unsigned(15 downto 0) := seed;
   begin
      for i in 1 to 8 loop
         s := s(14 downto 0) & (s(15) xor s(13) xor s(12) xor s(10));
      end loop;
      return s;
   end function;
begin
   clock <= not clock after PERIOD / 2 when not done;

   -- CPU clock enables: one CPU clock every DIVIDE clock_28 periods, rising
   -- enable at the start of one, falling enable on the clock_28 falling edge
   -- DIVIDE/2 periods in (the same period for DIVIDE 1). STRETCH holds a
   -- period now and then: no enable in it and the phase does not move.
   enables : process
      variable phase : integer := 0;
      variable rnd   : unsigned(15 downto 0) := x"1234";
      variable hold  : boolean;
   begin
      wait until rising_edge(clock);
      loop
         exit when done;
         rnd := rnd(14 downto 0) & (rnd(15) xor rnd(13) xor rnd(12) xor rnd(10));
         hold := STRETCH and rnd(2 downto 0) = "000";
         -- for this period's falling edge
         if not hold and phase = DIVIDE / 2 then cen_f <= '1'; else cen_f <= '0'; end if;
         wait until falling_edge(clock);
         -- for the next rising edge
         if not hold then phase := (phase + 1) mod DIVIDE; end if;
         if not hold and phase = 0 then cen_r <= '1'; else cen_r <= '0'; end if;
         wait until rising_edge(clock);
      end loop;
      wait;
   end process;

   dut : entity work.spi_master
      generic map (g_miso_late => MISO_LATE)
      port map (
         clock_i => clock, cen_r_i => cen_r, cen_f_i => cen_f, reset_i => '0',
         spi_sck_o => sck, spi_mosi_o => mosi, spi_miso_i => miso_core,
         spi_mosi_wr_i => mosi_wr, spi_mosi_dat_i => wr_data,
         spi_miso_rd_i => miso_rd, spi_miso_dat_o => rd_data,
         spi_wait_n_o => wait_n);

   -- the Nano top: SCK through a register on clock_28's rising edge
   process (clock)
   begin
      if rising_edge(clock) then
         sck_reg <= sck;
         mosi_reg <= mosi;
      end if;
   end process;
   sck_card <= transport sck_reg after SCK_OUT;
   mosi_card <= transport mosi_reg after SCK_OUT;
   miso_core <= transport miso_card after MISO_IN;

   -- the card, SPI mode 0: takes MOSI on SCK rises, moves MISO CARD_DELAY
   -- after each SCK fall; after the eighth rise of a byte, the fall brings
   -- the next byte's first bit.
   card : process
      variable out_shift : std_logic_vector(7 downto 0);
      variable in_shift  : std_logic_vector(7 downto 0) := (others => '0');
      variable rises     : integer := 0;
      variable seed      : unsigned(15 downto 0) := x"ace1";
   begin
      seed := next_byte(seed);
      out_shift := std_logic_vector(seed(7 downto 0));
      miso_card <= out_shift(7);
      loop
         wait until sck_card'event or done;
         exit when done;
         if sck_card = '1' then
            in_shift := in_shift(6 downto 0) & mosi_card;
            rises := rises + 1;
            if rises mod 8 = 0 then
               card_in_byte <= in_shift;
            end if;
            card_edges <= rises;
         elsif rises mod 8 = 0 then
            seed := next_byte(seed);
            out_shift := std_logic_vector(seed(7 downto 0));
            miso_card <= transport out_shift(7) after CARD_DELAY;
         else
            out_shift := out_shift(6 downto 0) & '1';
            miso_card <= transport out_shift(7) after CARD_DELAY;
         end if;
      end loop;
      wait;
   end process;

   -- the CPU / DMA side
   stimulus : process
      variable rnd       : unsigned(15 downto 0) := x"5a5a";
      variable expect_rx : std_logic_vector(7 downto 0);
      variable expect_tx : std_logic_vector(7 downto 0);
      variable writing   : boolean;
      variable edges0    : integer;
      variable errors    : integer := 0;
      variable gap       : integer;
      variable card_seed : unsigned(15 downto 0) := x"ace1";   -- the card's sequence
   begin
      for i in 1 to 4 loop wait until rising_edge(clock); end loop;
      for t in 1 to TRANSFERS loop
         rnd := next_byte(rnd);
         writing := rnd(0) = '1';
         expect_tx := std_logic_vector(rnd(15 downto 8));
         card_seed := next_byte(card_seed);
         expect_rx := std_logic_vector(card_seed(7 downto 0));
         edges0 := 8 * (t - 1);
         -- request on a rising edge, held until an enabled falling edge takes it
         wait until rising_edge(clock) and wait_n = '1';
         if writing then
            wr_data <= expect_tx; mosi_wr <= '1';
         else
            miso_rd <= '1';
         end if;
         loop
            wait until falling_edge(clock);
            exit when cen_f = '1';
         end loop;
         mosi_wr <= '0'; miso_rd <= '0';
         -- wait for the end of the transfer and the byte's publication
         wait until rising_edge(clock) and wait_n = '1' and cen_r = '1';
         wait for 1 ns;
         -- the eighth SCK rise reaches the card SCK_OUT after this edge
         if card_edges < edges0 + 8 then
            wait until card_edges >= edges0 + 8 for 10 * PERIOD;
         end if;
         if rd_data /= expect_rx then
            if errors < 5 then
               report "transfer " & integer'image(t) & ": read " & to_hstring(rd_data) &
                      ", card sent " & to_hstring(expect_rx);
            end if;
            errors := errors + 1;
         end if;
         if writing and card_in_byte /= expect_tx then
            if errors < 5 then
               report "transfer " & integer'image(t) & ": card took " & to_hstring(card_in_byte) &
                      ", written " & to_hstring(expect_tx);
            end if;
            errors := errors + 1;
         end if;
         if card_edges - edges0 /= 8 then
            report "transfer " & integer'image(t) & ": " & integer'image(card_edges - edges0) & " SCK pulses";
            errors := errors + 1;
         end if;
         -- a gap now and then, else straight on (DMA)
         gap := to_integer(rnd(11 downto 9));
         if gap > 4 then
            for i in 1 to gap * 3 loop wait until rising_edge(clock); end loop;
         end if;
      end loop;
      if errors = 0 then
         report "PASS " & integer'image(TRANSFERS) & " transfers";
      else
         report "FAIL " & integer'image(errors) & " errors";
      end if;
      done <= true;
      wait;
   end process;
end architecture;
