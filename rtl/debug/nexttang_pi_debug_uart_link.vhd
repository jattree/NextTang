-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- Carries the official Pi debug protocol over the debug UART.
--
-- A host frame is the letter X, a length N (0 means 256) and N bytes. The
-- bytes go to the Pi debug slave as one SPI command (one chip select), and
-- the N bytes the slave returns come back as 0x01, x, N and those bytes. The
-- framing is NextTang's; the N bytes either way are exactly what a Pi would
-- send and receive (pi_debug_control readme), so a host tool written for the
-- official interface needs only this wrapping.
--
-- While a frame is arriving, frame_active tells the board to keep its own
-- single-letter commands from reading the frame's bytes. From the first frame
-- until SESSION_CLOCKS after the last, session_active gives this module the
-- UART's transmit line; the board's status lines are held back meanwhile, so
-- they cannot interleave with a reply. A frame whose bytes stop arriving for
-- TIMEOUT_CLOCKS is abandoned: chip select rises and the reply stops short.
--
-- Two NextTang additions ride on the same link. B, slot, flags, address high,
-- address low, page sets a hardware breakpoint slot (flags bit 0 enables it,
-- bit 1 makes it fire only while that 8K page is mapped at the address); the
-- board answers 0x01, b, slot. And when a breakpoint stops the CPU
-- (inject_pause), the link sends the slave CMD_CPU_PAUSE itself, between host
-- frames, so the slave owns the stop as if the host had paused there.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nexttang_pi_debug_uart_link is
   generic (
      CLOCK_HZ       : positive := 28000000;
      BAUD_RATE      : positive := 115200;
      TIMEOUT_CLOCKS : positive := 560000;     -- 20 ms at 28 MHz
      SESSION_CLOCKS : positive := 56000000    -- 2 s at 28 MHz
   );
   port (
      clock          : in  std_logic;
      reset          : in  std_logic;

      rx_valid       : in  std_logic;
      rx_byte        : in  std_logic_vector(7 downto 0);
      frame_active   : out std_logic;
      session_active : out std_logic;
      tx             : out std_logic;

      spi_select     : out std_logic;
      spi_valid      : out std_logic;
      spi_byte       : out std_logic_vector(7 downto 0);
      spi_ready      : in  std_logic;
      spi_done       : in  std_logic;
      spi_reply      : in  std_logic_vector(7 downto 0);
      spi_idle       : in  std_logic;

      bp_strobe      : out std_logic;
      bp_slot        : out std_logic_vector(7 downto 0);
      bp_enable      : out std_logic;
      bp_address     : out std_logic_vector(15 downto 0);
      bp_paged       : out std_logic;
      bp_page        : out std_logic_vector(7 downto 0);
      inject_pause   : in  std_logic
   );
end entity;

architecture rtl of nexttang_pi_debug_uart_link is
   constant BIT_CLOCKS : positive := (CLOCK_HZ + BAUD_RATE / 2) / BAUD_RATE;

   type frame_t is (F_IDLE, F_LENGTH, F_DATA, F_END, F_BREAKPOINT, F_INJECT);
   signal frame      : frame_t := F_IDLE;
   signal remaining  : natural range 0 to 256 := 0;   -- replies still to come
   signal pending    : std_logic := '0';               -- a byte waits for SPI
   signal pending_b  : std_logic_vector(7 downto 0) := (others => '0');
   signal silence    : natural range 0 to TIMEOUT_CLOCKS := 0;
   signal session    : natural range 0 to SESSION_CLOCKS := 0;
   signal inject     : std_logic := '0';              -- a pause waits to go out
   signal injecting  : std_logic := '0';              -- the frame under way is ours
   signal deferred   : std_logic_vector(7 downto 0) := (others => '0');
   signal deferring  : std_logic := '0';              -- a host frame began meanwhile
   type bp_bytes_t is array (0 to 4) of std_logic_vector(7 downto 0);
   signal bp_bytes   : bp_bytes_t := (others => (others => '0'));
   signal bp_count   : natural range 0 to 5 := 0;
   signal bp_strobe_r : std_logic := '0';

   -- Transmit queue. Replies arrive no faster than the host's bytes, at the
   -- same baud rate, so the queue only ever holds the header and a few bytes.
   type queue_t is array (0 to 15) of std_logic_vector(7 downto 0);
   signal queue      : queue_t;
   signal head, tail : unsigned(3 downto 0) := (others => '0');

   signal tx_busy    : std_logic := '0';
   signal tx_shift   : std_logic_vector(9 downto 0) := (others => '1');
   signal tx_bits    : natural range 0 to 10 := 0;
   signal tx_timer   : natural range 0 to BIT_CLOCKS := 0;
begin
   frame_active <= '0' when frame = F_IDLE else '1';
   session_active <= '1' when session /= 0 else '0';
   spi_select <= '1' when frame = F_DATA or frame = F_INJECT else '0';
   bp_strobe <= bp_strobe_r;
   bp_slot <= bp_bytes(0);
   bp_enable <= bp_bytes(1)(0);
   bp_address <= bp_bytes(2) & bp_bytes(3);
   bp_paged <= bp_bytes(1)(1);
   bp_page <= bp_bytes(4);
   spi_valid <= pending;
   spi_byte <= pending_b;
   tx <= tx_shift(0);

   process (clock)
      variable push      : boolean;
      variable push_byte : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clock) then
         push := false;
         push_byte := (others => '0');
         bp_strobe_r <= '0';

         if inject_pause = '1' then
            inject <= '1';
         end if;

         if spi_ready = '1' then
            pending <= '0';
         end if;

         if session /= 0 then
            session <= session - 1;
         end if;

         if rx_valid = '1' or frame = F_IDLE then
            silence <= 0;
         elsif silence /= TIMEOUT_CLOCKS then
            silence <= silence + 1;
         end if;

         case frame is
            when F_IDLE =>
               if (rx_valid = '1' and rx_byte = x"58") or       -- 'X'
                  (deferring = '1' and deferred = x"58") then
                  frame <= F_LENGTH;
                  session <= SESSION_CLOCKS;
                  deferring <= '0';
               elsif (rx_valid = '1' and rx_byte = x"42") or    -- 'B'
                     (deferring = '1' and deferred = x"42") then
                  frame <= F_BREAKPOINT;
                  bp_count <= 0;
                  session <= SESSION_CLOCKS;
                  deferring <= '0';
               elsif deferring = '1' then
                  deferring <= '0';                            -- not a frame
               elsif inject = '1' and spi_idle = '1' then
                  inject <= '0';
                  injecting <= '1';
                  pending <= '1';
                  pending_b <= x"A4";                          -- CMD_CPU_PAUSE
                  frame <= F_INJECT;
               end if;

            -- The pause the board sends on a breakpoint. Its reply byte is
            -- not the host's. One SPI byte is far shorter than one UART
            -- byte, so at most the first byte of a host frame can arrive
            -- meanwhile; it is kept and acted on next.
            when F_INJECT =>
               if rx_valid = '1' then
                  deferring <= '1';
                  deferred <= rx_byte;
               end if;
               if spi_done = '1' then
                  frame <= F_END;
               end if;

            when F_BREAKPOINT =>
               if rx_valid = '1' then
                  bp_bytes(bp_count) <= rx_byte;
                  if bp_count = 4 then
                     bp_strobe_r <= '1';
                     frame <= F_IDLE;
                  end if;
                  bp_count <= bp_count + 1;
               elsif silence = TIMEOUT_CLOCKS then
                  frame <= F_IDLE;
               end if;

            when F_LENGTH =>
               if rx_valid = '1' then
                  if rx_byte = x"00" then
                     remaining <= 256;
                  else
                     remaining <= to_integer(unsigned(rx_byte));
                  end if;
                  frame <= F_DATA;
               elsif silence = TIMEOUT_CLOCKS then
                  frame <= F_END;
               end if;

            when F_DATA =>
               if rx_valid = '1' then
                  pending <= '1';
                  pending_b <= rx_byte;
               end if;
               if spi_done = '1' then
                  push := true;
                  push_byte := spi_reply;
                  if remaining = 1 then
                     frame <= F_END;
                  end if;
                  remaining <= remaining - 1;
               elsif silence = TIMEOUT_CLOCKS and pending = '0' then
                  frame <= F_END;
               end if;

            when F_END =>
               pending <= '0';
               if rx_valid = '1' then
                  deferring <= '1';
                  deferred <= rx_byte;
               end if;
               if spi_idle = '1' then
                  frame <= F_IDLE;
                  if injecting = '0' then
                     session <= SESSION_CLOCKS;
                  end if;
                  injecting <= '0';
               end if;
         end case;

         -- Header, queued as the length arrives.
         if frame = F_LENGTH and rx_valid = '1' then
            queue(to_integer(tail)) <= x"01";
            queue(to_integer(tail + 1)) <= x"78";             -- 'x'
            queue(to_integer(tail + 2)) <= rx_byte;
            tail <= tail + 3;
         elsif push then
            queue(to_integer(tail)) <= push_byte;
            tail <= tail + 1;
         elsif frame = F_BREAKPOINT and rx_valid = '1' and bp_count = 4 then
            queue(to_integer(tail)) <= x"01";
            queue(to_integer(tail + 1)) <= x"62";             -- 'b'
            queue(to_integer(tail + 2)) <= bp_bytes(0);
            tail <= tail + 3;
         end if;

         -- Transmitter: start bit, eight data bits, stop bit.
         if tx_busy = '0' then
            if head /= tail then
               tx_shift <= '1' & queue(to_integer(head)) & '0';
               head <= head + 1;
               tx_bits <= 10;
               tx_timer <= BIT_CLOCKS - 1;
               tx_busy <= '1';
            end if;
         elsif tx_timer /= 0 then
            tx_timer <= tx_timer - 1;
         elsif tx_bits = 1 then
            tx_busy <= '0';
            tx_shift <= (others => '1');
         else
            tx_shift <= '1' & tx_shift(9 downto 1);
            tx_bits <= tx_bits - 1;
            tx_timer <= BIT_CLOCKS - 1;
         end if;

         if reset = '1' then
            frame <= F_IDLE;
            pending <= '0';
            inject <= '0';
            injecting <= '0';
            deferring <= '0';
            session <= 0;
            head <= (others => '0');
            tail <= (others => '0');
            tx_busy <= '0';
            tx_shift <= (others => '1');
         end if;
      end if;
   end process;
end architecture;
