-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- Input player for RZX replay (docs/replay-and-rewind.md, step 2).
--
-- Plays back what nexttang_rzx_logger records. It takes the frames of an RZX
-- input recording block as a byte stream, each frame laid out as in the file
-- (RZX format v0.13) with any repeat already resolved by the host:
--
--     fetch count (2 bytes, LE), IN count (2 bytes, LE), the IN bytes
--
-- While playing, the core takes every CPU I/O read's byte from in_data
-- instead of from the ports (zxnext i_RZX_IN_DATA), and its maskable
-- interrupt from int_request instead of from the ULA, line interrupt, CTC
-- or expansion bus (i_RZX_INT). Starting from the snapshot the recording
-- began with, the CPU then runs the recorded instructions exactly.
--
-- Fetches are counted as the recorder counts them: one per M1 cycle that is
-- not an interrupt acknowledge. A frame ends with an interrupt request after
-- exactly its fetch count, so int_request rises during the frame's last
-- fetch (M1 low with fetch count - 1 already done), well before the CPU
-- samples INT at the end of that instruction, at any CPU speed, and stays up
-- until the next M1 cycle starts. The last fetch is always the last M1 of
-- its instruction in a faithful replay, as the recording ended the frame at
-- that boundary.
--
-- That next M1 cycle is either the acknowledge, or, when the CPU has
-- interrupts disabled, an ordinary fetch: the recorder ends a frame there
-- too (a declined interrupt), and that fetch is the next frame's first. So
-- the request is one try per frame, as an emulator's is. A frame with a
-- fetch count of 0 is tried as soon as it is known.
--
-- At each frame end the frame is checked: exactly its fetches, exactly its
-- IN bytes used. An I/O read when the frame has no byte left, a byte not yet
-- in from the stream when a read starts, or a frame that ends wrongly is a
-- desync: playing drops, so the core goes back to its live ports and
-- interrupts, and desync stays set until the next start. The player cannot
-- tell a declined interrupt the recording did not have from one it did;
-- such a replay goes wrong at a later frame's check.
--
-- The stream must keep up: a frame's header is read after the previous
-- frame end and must be in before the frame's last fetch, and each IN byte
-- before its read starts (one byte is held ready ahead). After a declined
-- interrupt the CPU is already one fetch into the next frame when its
-- header starts to arrive.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nexttang_rzx_player is
   port (
      clock       : in  std_logic;
      reset       : in  std_logic;

      start       : in  std_logic;
      stop        : in  std_logic;
      playing     : out std_logic;
      desync      : out std_logic;
      frames      : out std_logic_vector(15 downto 0);

      m1_n        : in  std_logic;
      iorq_n      : in  std_logic;
      rd_n        : in  std_logic;

      byte_in     : in  std_logic_vector(7 downto 0);
      byte_valid  : in  std_logic;
      byte_ready  : out std_logic;

      in_data     : out std_logic_vector(7 downto 0);
      int_request : out std_logic
   );
end entity;

architecture rtl of nexttang_rzx_player is
   signal play_r      : std_logic := '0';
   signal desync_r    : std_logic := '0';
   signal frames_r    : unsigned(15 downto 0) := (others => '0');

   signal m1_n_q      : std_logic := '1';
   signal io_rd_q     : std_logic := '0';
   signal ack_seen    : std_logic := '0';

   -- header bytes still to read: 4 down to 0; 0 = the frame is known
   signal header_left : unsigned(2 downto 0) := to_unsigned(4, 3);
   signal target      : unsigned(15 downto 0) := (others => '0');
   signal in_count    : unsigned(15 downto 0) := (others => '0');
   signal fetches     : unsigned(15 downto 0) := (others => '0');
   signal loaded      : unsigned(15 downto 0) := (others => '0');  -- IN bytes taken from the stream
   signal used        : unsigned(15 downto 0) := (others => '0');  -- IN bytes the CPU has read
   signal have_byte   : std_logic := '0';
   signal next_byte   : std_logic_vector(7 downto 0) := (others => '1');

   signal io_rd, m1_end, io_start, io_end : std_logic;
   signal take        : std_logic;
   signal in_last_fetch : std_logic;
   signal last_fetch_ending : std_logic;
begin
   io_rd    <= '1' when iorq_n = '0' and rd_n = '0' and m1_n = '1' else '0';
   m1_end   <= '1' when m1_n_q = '0' and m1_n = '1' else '0';
   io_start <= io_rd and not io_rd_q;
   io_end   <= io_rd_q and not io_rd;

   -- A header byte, or the next IN byte when none is held, is taken whenever
   -- the stream offers one.
   take <= '1' when play_r = '1' and byte_valid = '1' and
                    (header_left /= 0 or (have_byte = '0' and loaded /= in_count)) else '0';
   byte_ready <= take;

   in_last_fetch <= '1' when m1_n = '0' and ack_seen = '0' and target /= 0 and
                             fetches = target - 1 else '0';
   -- The request must not drop between the last fetch's M1 going high and
   -- the count catching up one clock later: at 28 MHz the CPU samples it on
   -- every clock and, after a four-T-state instruction, decides from that
   -- very sample, so it would miss the interrupt.
   last_fetch_ending <= '1' when m1_end = '1' and ack_seen = '0' and target /= 0 and
                                 fetches = target - 1 else '0';
   int_request <= '1' when play_r = '1' and header_left = 0 and
                           ((fetches = target and m1_n = '1') or in_last_fetch = '1' or
                            last_fetch_ending = '1') else '0';

   in_data <= next_byte;
   playing <= play_r;
   desync  <= desync_r;
   frames  <= std_logic_vector(frames_r);

   process (clock)
      variable bad : boolean;
   begin
      if rising_edge(clock) then
         m1_n_q  <= m1_n;
         io_rd_q <= io_rd;
         if m1_n = '0' and iorq_n = '0' then
            ack_seen <= '1';
         elsif m1_end = '1' then
            ack_seen <= '0';
         end if;

         bad := false;

         if take = '1' then
            case to_integer(header_left) is
               when 4 => target(7 downto 0) <= unsigned(byte_in);
               when 3 => target(15 downto 8) <= unsigned(byte_in);
               when 2 => in_count(7 downto 0) <= unsigned(byte_in);
               when 1 => in_count(15 downto 8) <= unsigned(byte_in);
               when others =>
                  next_byte <= byte_in;
                  have_byte <= '1';
                  loaded <= loaded + 1;
            end case;
            if header_left /= 0 then
               header_left <= header_left - 1;
            end if;
         end if;

         if play_r = '1' then
            if io_start = '1' and have_byte = '0' then
               bad := true;   -- a read with no recorded byte ready
            end if;
            if io_end = '1' then
               have_byte <= '0';
               used <= used + 1;
            end if;
            if m1_end = '1' then
               if ack_seen = '1' then
                  if header_left /= 0 or fetches /= target or used /= in_count then
                     bad := true;
                  end if;
                  frames_r <= frames_r + 1;
                  fetches <= (others => '0');
                  header_left <= to_unsigned(4, 3);
                  loaded <= (others => '0');
                  used <= (others => '0');
                  have_byte <= '0';
               elsif header_left = 0 and fetches = target then
                  -- The interrupt was declined: the frame ends here and this
                  -- fetch is the next frame's first.
                  if used /= in_count then
                     bad := true;
                  end if;
                  frames_r <= frames_r + 1;
                  fetches <= to_unsigned(1, 16);
                  header_left <= to_unsigned(4, 3);
                  loaded <= (others => '0');
                  used <= (others => '0');
                  have_byte <= '0';
               else
                  if header_left = 0 and fetches > target then
                     bad := true;   -- the header came after the frame's last fetch
                  end if;
                  fetches <= fetches + 1;
               end if;
            end if;
         end if;

         if bad then
            desync_r <= '1';
            play_r <= '0';
         end if;

         if stop = '1' then
            play_r <= '0';
         end if;
         if start = '1' then
            play_r <= '1';
            desync_r <= '0';
            frames_r <= (others => '0');
            fetches <= (others => '0');
            header_left <= to_unsigned(4, 3);
            loaded <= (others => '0');
            used <= (others => '0');
            have_byte <= '0';
         end if;
         if reset = '1' then
            play_r <= '0';
            desync_r <= '0';
            frames_r <= (others => '0');
            fetches <= (others => '0');
            header_left <= to_unsigned(4, 3);
            loaded <= (others => '0');
            used <= (others => '0');
            have_byte <= '0';
            ack_seen <= '0';
            m1_n_q <= '1';
            io_rd_q <= '0';
         end if;
      end if;
   end process;
end architecture;
