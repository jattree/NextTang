-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- hdmi_frame with an HDMI pixel clock that does not match the core's frame,
-- as on the Nano 20K: core pixels at 14.0625 MHz (28.125 / 2), HDMI at
-- 27 MHz, 48K frame timing (312 lines of 896 14 MHz cycles; 720 pixels and
-- 288 lines active), the lock pulse at the end of the first active line, as
-- zxula_timing sends it. Every core line's pixels carry its line number. Each
-- HDMI active line must show one core line, and the same core line in every
-- frame (counted from the frame's first active line), or the picture is
-- drifting through the line buffer. Run with G_RELOCK false to see the drift
-- and true to see it held. Every line must also keep the full CEA length
-- (864 HDMI clocks between hsyncs): the first re-lock cut one line per frame
-- to 196 clocks, which receivers reject (no signal on the Nano, 2026-11-11),
-- and the lines from vsync to the first active line must not change from
-- frame to frame: receivers that place the picture by vsync show a change as
-- a bounce (the second re-lock moved lines in the back porch).
-- CORE_CYC and CORE_LINES set the core's line length (14 MHz cycles) and
-- lines per frame: 896/312 is 48K timing, 912/311 128K, 896/320 Pentagon.
-- LOCK_LINE is the window line after which the lock pulse comes (0 in 48K
-- timing, 4 in 128K/+3, as zxula_timing's c_hdmi_ysync).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_hdmi_frame_relock is
   generic (
      RELOCK : boolean := true;
      FRAMES : natural := 12;
      CORE_CYC : natural := 896;
      CORE_LINES : natural := 312;
      LOCK_LINE : natural := 0
   );
end entity;

architecture sim of tb_hdmi_frame_relock is
   signal clk14 : std_logic := '0';
   signal clk7 : std_logic := '0';
   signal clk27 : std_logic := '0';
   signal reset_n : std_logic := '0';
   signal en : std_logic := '0';
   signal sync : std_logic := '0';
   signal rgb : std_logic_vector(8 downto 0) := (others => '0');
   signal blank, hsync_n, vsync_n : std_logic;
   signal orgb : std_logic_vector(8 downto 0);
   signal done : boolean := false;
   signal short_lines : natural := 0;
   signal porch_changes : natural := 0;
   constant T14 : time := 1 sec / 14062500;
   constant T27 : time := 1 sec / 27000000;
begin
   clk14 <= not clk14 after T14 / 2 when not done;
   clk27 <= not clk27 after T27 / 2 when not done;

   dut : entity work.hdmi_frame
      generic map (G_RELOCK => RELOCK)
      port map (
         i_reset_async_n => reset_n, i_scanlines => "00",
         i_CLK_RGB => clk14, i_CLK_RGB_EN => en, i_rgb_sync => sync, i_rgb => rgb,
         i_CLK_HDMI => clk27,
         o_blank => blank, o_vsync_n => vsync_n, o_hsync_n => hsync_n, o_rgb => orgb,
         i_HACTIVE => std_logic_vector(to_unsigned(144, 10)),
         i_HSYNC_BEG => std_logic_vector(to_unsigned(12, 10)),
         i_HSYNC_END => std_logic_vector(to_unsigned(75, 10)),
         i_HLAST => std_logic_vector(to_unsigned(863, 10)),
         i_VACTIVE => std_logic_vector(to_unsigned(49, 10)),
         i_VSYNC_BEG => std_logic_vector(to_unsigned(5, 10)),
         i_VSYNC_END => std_logic_vector(to_unsigned(9, 10)),
         i_VLAST => std_logic_vector(to_unsigned(624, 10)));

   -- core side: 312 lines x 896 cycles at 14 MHz; active lines 0..287 are
   -- frame lines 12..299, active pixels cycles 100..819; the lock pulse
   -- (two cycles, as one 7 MHz cycle) just before the first active pixel
   core : process
      variable line, cyc : natural := 0;
   begin
      wait for 1 us;
      reset_n <= '1';
      loop
         wait until rising_edge(clk14);
         if line >= 12 and line < 300 and cyc >= 100 and cyc < 820 then
            en <= '1';
            rgb <= std_logic_vector(to_unsigned((line - 12) mod 512, 9));
         else
            en <= '0';
         end if;
         -- the core's o_hdmi_frame_lock: end of the first HDMI-window line (48K)
         if line = 12 + LOCK_LINE and (cyc = CORE_CYC - 2 or cyc = CORE_CYC - 1) then sync <= '1'; else sync <= '0'; end if;
         cyc := cyc + 1;
         if cyc = CORE_CYC then cyc := 0; line := (line + 1) mod CORE_LINES; end if;
      end loop;
   end process;

   -- HDMI side: for each active line, the value it shows (it must be one value
   -- across the line), and per frame the value of the first active line
   watch : process (clk27)
      variable in_line : boolean := false;
      variable line_value, first_value : integer := -1;
      variable mixed, lines, frame, drift_frames, bad_lines : natural := 0;
      variable vs_prev : std_logic := '1';
      variable line_no : natural := 0;
      variable base : integer := -1;
      variable l : line;
   begin
      if rising_edge(clk27) then
         if vsync_n = '0' and vs_prev = '1' then
            -- new frame: report the first active line's value
            if frame >= 3 then
               if base < 0 then base := first_value;
               elsif first_value /= base then drift_frames := drift_frames + 1;
               end if;
            end if;
            write(l, string'("frame ") & integer'image(frame) & string'(" first line shows core line ") &
                  integer'image(first_value) & string'(", lines ") & integer'image(lines) &
                  string'(", mixed lines ") & integer'image(mixed));
            writeline(output, l);
            frame := frame + 1; lines := 0; first_value := -1;
            if frame > 3 then bad_lines := bad_lines + mixed; end if;
            mixed := 0;
            if frame = FRAMES then
               write(l, string'("RESULT relock=") & boolean'image(RELOCK) & string'(" frames whose first line moved: ") &
                     integer'image(drift_frames) & string'(", mixed lines after settling: ") & integer'image(bad_lines) &
                     string'(", lines not 864 clocks: ") & integer'image(short_lines) &
                     string'(", vsync-to-picture changes: ") & integer'image(porch_changes));
               writeline(output, l);
               if drift_frames = 0 and bad_lines = 0 and short_lines = 0 and porch_changes = 0 then
                  write(l, string'("PASS")); else write(l, string'("FAIL (the drift is expected without relock)"));
               end if;
               writeline(output, l);
               done <= true;
            end if;
         end if;
         vs_prev := vsync_n;
         if blank = '0' then
            if not in_line then
               in_line := true; line_value := to_integer(unsigned(orgb)); lines := lines + 1;
               if first_value < 0 then first_value := line_value; end if;
            elsif to_integer(unsigned(orgb)) /= line_value then
               mixed := mixed + 1; line_value := to_integer(unsigned(orgb));
            end if;
         else
            in_line := false;
         end if;
      end if;
   end process;
   -- every line from the second frame on: 864 HDMI clocks between hsyncs
   line_length : process (clk27)
      variable count : natural := 0;
      variable frame_count : natural := 0;
      variable h_prev, v_prev : std_logic := '1';
   begin
      if rising_edge(clk27) then
         count := count + 1;
         if vsync_n = '0' and v_prev = '1' then
            frame_count := frame_count + 1;
         end if;
         if hsync_n = '0' and h_prev = '1' then
            if frame_count >= 2 and count /= 864 then
               short_lines <= short_lines + 1;
            end if;
            count := 0;
         end if;
         h_prev := hsync_n; v_prev := vsync_n;
      end if;
   end process;
   -- lines from vsync to the first active line: the same in every frame after settling
   sync_to_picture : process (clk27)
      variable lines, first, frame_count : natural := 0;
      variable counting : boolean := false;
      variable h_prev, v_prev, b_prev : std_logic := '1';
   begin
      if rising_edge(clk27) then
         if vsync_n = '0' and v_prev = '1' then
            frame_count := frame_count + 1;
            counting := true;
            lines := 0;
         end if;
         if hsync_n = '0' and h_prev = '1' and counting then
            lines := lines + 1;
         end if;
         if blank = '0' and b_prev = '1' and counting then
            counting := false;
            if frame_count = FRAMES / 2 then
               first := lines;
            elsif frame_count > FRAMES / 2 and lines /= first then
               porch_changes <= porch_changes + 1;
            end if;
         end if;
         h_prev := hsync_n; v_prev := vsync_n; b_prev := blank;
      end if;
   end process;
end architecture;
