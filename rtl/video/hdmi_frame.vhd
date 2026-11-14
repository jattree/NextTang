-- HDMI Frame
-- Copyright 2023 Alvin Albrecht
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


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use IEEE.std_logic_unsigned.ALL;

entity hdmi_frame is
   generic
   (
      -- NextTang: re-lock to the core's frame every frame, not just once at
      -- i_rgb_sync. For boards whose HDMI pixel clock cannot match the core's frame
      -- exactly (the Nano 20K's comes from the same crystal as its machine
      -- clock, 24/25 of it), so the line buffer would otherwise drift. Each
      -- re-lock restarts the read side at the frame's first line (see
      -- relock below), at a line boundary in the vertical back porch, so
      -- frames gain or lose a few lines but every line keeps its length.
      -- Off by default: the official behaviour.
      G_RELOCK         : boolean := false
   );
   port
   (
      i_reset_async_n  : std_logic;
      
      -- CLK_28 domain

      i_scanlines      : in std_logic_vector(1 downto 0);   -- CLK_28
      
      -- pixel in

      i_CLK_RGB        : in std_logic;                      -- CLK_14
      i_CLK_RGB_EN     : in std_logic;                      -- CLK_14
      
      i_rgb_sync       : in std_logic;                      -- CLK_7
      i_rgb            : in std_logic_vector(8 downto 0);   -- CLK_14

      -- pixel out

      i_CLK_HDMI       : in std_logic;                      -- ~ 27 MHZ

      o_blank          : out std_logic;
      o_vsync_n        : out std_logic;
      o_hsync_n        : out std_logic;
      
      o_rgb            : out std_logic_vector(8 downto 0);
      
      -- hdmi configuration
      
      i_HACTIVE        : in std_logic_vector(9 downto 0);   -- >=
      i_HSYNC_BEG      : in std_logic_vector(9 downto 0);   -- >= at least two cycles width
      i_HSYNC_END      : in std_logic_vector(9 downto 0);   -- <= at least two cycles width
      i_HLAST          : in std_logic_vector(9 downto 0);   -- ==
      
      i_VACTIVE        : in std_logic_vector(9 downto 0);   -- >=
      i_VSYNC_BEG      : in std_logic_vector(9 downto 0);   -- >=
      i_VSYNC_END      : in std_logic_vector(9 downto 0);   -- <=
      i_VLAST          : in std_logic_vector(9 downto 0)    -- ==
   );
end entity;
   
architecture rtl of hdmi_frame is
   
   signal scanlines      : std_logic_vector(1 downto 0) := (others => '0');

   signal rgb_sync       : std_logic := '0';
   signal rgb_sync_meta  : std_logic := '0';   -- NextTang

   type   state_t        is (S_ASYNC_RESET, S_RGB_SYNC, S_FRAME_WAIT, S_RUNNING);
   signal state          : state_t;
   signal state_next     : state_t;
   
   signal running        : std_logic;
   
   signal h_last         : std_logic;
   signal v_last         : std_logic;
   
   signal hcnt           : std_logic_vector(9 downto 0) := (others => '0');
   signal vcnt           : std_logic_vector(9 downto 0) := (others => '0');
   
   signal hsync_n        : std_logic := '1';
   signal vsync_n        : std_logic := '1';
   signal blank          : std_logic := '1';

   signal v_active       : std_logic;
   signal h_active       : std_logic;
   signal hdmi_active    : std_logic;

   signal waddr          : std_logic_vector(12 downto 0) := (others => '0');
   signal raddr          : std_logic_vector(12 downto 0) := (others => '0');
   signal raddr_lag      : std_logic_vector(12 downto 0) := (others => '0');

   signal rgb_raw        : std_logic_vector(8 downto 0);

   signal rgb_r_25       : std_logic_vector(3 downto 0);
   signal rgb_g_25       : std_logic_vector(3 downto 0);
   signal rgb_b_25       : std_logic_vector(3 downto 0);
   signal rgb_r_12       : std_logic_vector(3 downto 0);
   signal rgb_g_12       : std_logic_vector(3 downto 0);
   signal rgb_b_12       : std_logic_vector(3 downto 0);

   signal rgb_scanline   : std_logic_vector(8 downto 0) := (others => '0');
   -- NextTang: G_RELOCK
   signal relock         : std_logic;
   signal frame_start_toggle : std_logic := '0';
   signal frame_start_sync   : std_logic_vector(2 downto 0) := (others => '0');
   -- HDMI lines from the core frame's first written pixel to the first active
   -- line: the read side runs 6 core lines behind the write side, so it
   -- neither overtakes a core whose lines are longer than two HDMI lines
   -- (128K/+3 timing: it gains about 4 lines a frame) nor falls out of the
   -- 11-line buffer behind one whose lines are shorter (48K: it loses 1.3).
   constant RELOCK_LAG   : integer := 12;
   constant FP_MAX_EXTRA : integer := 40;
   signal line_idx       : signed(11 downto 0) := (others => '0');   -- lines since this frame's start
   signal active_idx     : signed(11 downto 0) := (others => '0');   -- line_idx of the first active line
   signal event_idx      : signed(11 downto 0) := (others => '0');   -- line_idx of the core's frame start
   signal event_seen     : std_logic := '0';
   signal q_prev         : signed(11 downto 0) := (others => '0');
   signal q_prev_valid   : std_logic := '0';
   signal fp_extra       : signed(11 downto 0) := (others => '0');   -- this frame's front porch change
   signal fp_hold        : unsigned(6 downto 0) := (others => '0');  -- front porch lines still to repeat
   signal frame_waddr    : std_logic_vector(12 downto 0) := (others => '0');
   signal frame_waddr_h  : std_logic_vector(12 downto 0) := (others => '0');   -- frame_waddr, taken in i_CLK_HDMI's domain
   signal running_rgb_sync : std_logic_vector(1 downto 0) := (others => '0'); -- running, in i_CLK_RGB's domain
   signal running_rgb    : std_logic;
   signal rgb_gap        : unsigned(11 downto 0) := (others => '0');

begin

   -- cross clock domains
   
   process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         scanlines <= i_scanlines;
      end if;
   end process;

   -- NextTang: i_rgb_sync comes from the core's 7 MHz domain, asynchronous to
   -- i_CLK_HDMI on boards whose pixel clock has its own PLL; one more register
   -- before the state machine uses it.
   process (i_CLK_HDMI, i_reset_async_n)
   begin
      if i_reset_async_n = '0' then
         rgb_sync_meta <= '0';
         rgb_sync <= '0';
      elsif rising_edge(i_CLK_HDMI) then
         rgb_sync_meta <= i_rgb_sync;
         if state = S_RGB_SYNC then
            rgb_sync <= rgb_sync_meta;
         else
            rgb_sync <= '0';
         end if;
      end if;
   end process;

   -- reset & frame sync
   
   process (i_CLK_HDMI, i_reset_async_n)
   begin
      if i_reset_async_n = '0' then
         state <= S_ASYNC_RESET;
      elsif rising_edge(i_CLK_HDMI) then
         state <= state_next;
      end if;
   end process;
   
   process (state, rgb_sync, h_last, v_last)
   begin
      case state is
         when S_ASYNC_RESET =>
            state_next <= S_RGB_SYNC;
         when S_RGB_SYNC =>
            if rgb_sync = '1' then
               state_next <= S_FRAME_WAIT;
            else
               state_next <= S_RGB_SYNC;
            end if;
         when S_FRAME_WAIT =>
            if h_last = '1' and v_last = '1' then
               state_next <= S_RUNNING;
            else
               state_next <= S_FRAME_WAIT;
            end if;
         when S_RUNNING =>
            state_next <= S_RUNNING;
         when others =>
            state_next <= S_RGB_SYNC;
      end case;
   end process;
   
   running <= '1' when state = S_RUNNING else '0';

   -- NextTang: G_RELOCK. While running, each frame start re-aligns the read
   -- side as the first lock did: the counters go to the start of the first
   -- active line (sync included, so raddr_lag is set for the line doubling)
   -- and both read addresses to where this frame's first line was written.
   -- The write side never restarts; frame_waddr is the write address of the
   -- first pixel after a gap longer than a line (the vertical blanking).
   --
   -- How: the frame length is adjusted only in the front porch (lines before
   -- vsync), by repeating its last line or skipping some of its lines, so
   -- every line keeps its full length and the distance from vsync to the
   -- first active line never changes. (Two earlier versions moved lines after
   -- vsync: one cut a line to 196 clocks every frame, which receivers reject;
   -- the other jumped within the back porch, which receivers that place the
   -- picture by vsync showed as a one-line bounce. Nano 20K, 2026-11-11.)
   --
   -- The reference is the write side's frame start (the first pixel after
   -- the vertical blanking, where frame_waddr is taken), not i_rgb_sync,
   -- which the core sends after the first window line in 48K timing but after
   -- the fifth in 128K/+3. Each frame records q, the HDMI line of that frame
   -- start relative to the first active line, and sets the next frame's front
   -- porch so the next q lands on -RELOCK_LAG: extra = (q + RELOCK_LAG) +
   -- (q - q_prev) + last extra, where (q - q_prev) + last extra is how much
   -- longer the core's frame is than 625 HDMI lines. The first active line
   -- reads from frame_waddr, so the picture always starts at the core's
   -- first line. Frames differ from 625 lines by the core's frame length;
   -- hsync, vsync and the back porch stay as CEA.
   frame_start_sync_p : process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         frame_start_sync <= frame_start_sync(1 downto 0) & frame_start_toggle;
      end if;
   end process;
   relock <= '1' when G_RELOCK and state = S_RUNNING and (frame_start_sync(2) xor frame_start_sync(1)) = '1' else '0';

   -- NextTang: G_RELOCK. frame_waddr is a 13-bit value from i_CLK_RGB's
   -- domain, written on the same edge as frame_start_toggle and then still
   -- for a frame. Taken here when the synchronised toggle moves (two
   -- i_CLK_HDMI edges later) rather than read whenever the first active line
   -- comes round, which could catch it changing.
   frame_waddr_take : process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         if (frame_start_sync(2) xor frame_start_sync(1)) = '1' then
            frame_waddr_h <= frame_waddr;
         end if;
      end if;
   end process;

   relock_control : process (i_CLK_HDMI)
      variable q, extra, flen : signed(11 downto 0);
      variable q_ok : boolean;
   begin
      if rising_edge(i_CLK_HDMI) then
         if not G_RELOCK or state /= S_RUNNING then
            line_idx <= (others => '0');
            event_seen <= '0';
            q_prev_valid <= '0';
            fp_extra <= (others => '0');
            fp_hold <= (others => '0');
         else
            if relock = '1' and event_seen = '0' then
               event_idx <= line_idx;
               event_seen <= '1';
            end if;
            if h_last = '1' then
               if v_last = '1' then
                  -- end of frame: set the next frame's front porch
                  flen := line_idx + 1;
                  q_ok := false;
                  q := (others => '0');
                  if event_seen = '1' then
                     if event_idx > shift_right(flen, 1) then
                        -- it came in this frame's tail: it belongs to the next frame
                        event_idx <= event_idx - flen;
                     else
                        q := event_idx - active_idx;
                        q_ok := true;
                        event_seen <= '0';
                     end if;
                  end if;
                  if relock = '1' then
                     event_seen <= '1';
                     event_idx <= to_signed(-1, 12);
                  end if;
                  if q_ok and q_prev_valid = '1' then
                     extra := (q + RELOCK_LAG) + (q - q_prev) + fp_extra;
                  elsif q_ok then
                     extra := q + RELOCK_LAG;
                  else
                     extra := (others => '0');
                  end if;
                  if extra > FP_MAX_EXTRA then
                     extra := to_signed(FP_MAX_EXTRA, 12);
                  elsif extra < 1 - signed(resize(unsigned(i_VSYNC_BEG), 12)) then
                     extra := 1 - signed(resize(unsigned(i_VSYNC_BEG), 12));
                  end if;
                  fp_extra <= extra;
                  if extra > 0 then
                     fp_hold <= unsigned(extra(6 downto 0));
                  else
                     fp_hold <= (others => '0');
                  end if;
                  q_prev <= q;
                  if q_ok then q_prev_valid <= '1'; else q_prev_valid <= '0'; end if;
                  line_idx <= (others => '0');
               else
                  line_idx <= line_idx + 1;
                  if vcnt = i_VSYNC_BEG - 1 and fp_hold /= 0 then
                     fp_hold <= fp_hold - 1;
                  end if;
                  if vcnt = i_VACTIVE - 1 then
                     active_idx <= line_idx + 1;
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;

   process (i_CLK_RGB)
   begin
      if rising_edge(i_CLK_RGB) then
         if i_CLK_RGB_EN = '1' then
            if rgb_gap(11) = '1' then
               frame_waddr <= waddr;
               frame_start_toggle <= not frame_start_toggle;
            end if;
            rgb_gap <= (others => '0');
         elsif rgb_gap(11) = '0' then
            rgb_gap <= rgb_gap + 1;
         end if;
      end if;
   end process;

   -- hdmi frame
   
   h_last <= '1' when hcnt = i_HLAST else '0';
   v_last <= '1' when vcnt = i_VLAST else '0';
   
   process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         if rgb_sync = '1' then
            hcnt <= i_HACTIVE;
            vcnt <= i_VACTIVE;
         elsif h_last = '1' then
            hcnt <= (others => '0');
            if v_last = '1' then
               vcnt <= (others => '0');
            elsif G_RELOCK and state = S_RUNNING and vcnt = 0 and fp_extra < 0 then   -- NextTang: G_RELOCK, skip front porch lines
               vcnt <= std_logic_vector(resize(unsigned(1 - fp_extra), 10));
            elsif G_RELOCK and state = S_RUNNING and vcnt = i_VSYNC_BEG - 1 and fp_hold /= 0 then   -- NextTang: G_RELOCK, repeat the last front porch line
               vcnt <= vcnt;
            else
               vcnt <= vcnt + 1;
            end if;
         else
            hcnt <= hcnt + 1;
         end if;
      end if;
   end process;
   
   process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         if (hcnt >= i_HSYNC_BEG) and (hcnt <= i_HSYNC_END) then
            hsync_n <= not running;
         else
            hsync_n <= '1';
         end if;
      end if;
   end process;
   
   o_hsync_n <= hsync_n;
   
   process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         if (vcnt >= i_VSYNC_BEG) and (vcnt <= i_VSYNC_END) then
            vsync_n <= not running;
         else
            vsync_n <= '1';
         end if;
      end if;
   end process;
   
   o_vsync_n <= vsync_n;

   v_active <= '1' when vcnt >= i_VACTIVE else '0';
   h_active <= '1' when hcnt >= i_HACTIVE else '0';
   
   hdmi_active <= h_active and v_active;

   process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         if hdmi_active = '1' then
            blank <= not running;
         else
            blank <= '1';
         end if;
      end if;
   end process;
   
   o_blank <= blank;

   -- pixel buffer
   
   -- NextTang: G_RELOCK. running is an i_CLK_HDMI signal; two registers
   -- bring it into i_CLK_RGB's domain before it holds waddr at zero. (The
   -- re-lock reads from frame_waddr, so the two clocks' extra delay moves
   -- nothing on screen; without G_RELOCK, as before.)
   process (i_CLK_RGB)
   begin
      if rising_edge(i_CLK_RGB) then
         running_rgb_sync <= running_rgb_sync(0) & running;
      end if;
   end process;
   running_rgb <= running_rgb_sync(1) when G_RELOCK else running;

   process (i_CLK_RGB)
   begin
      if rising_edge(i_CLK_RGB) then
         if running_rgb = '0' then
            waddr <= (others => '0');
         elsif i_CLK_RGB_EN = '1' then
            waddr <= waddr + 1;
         end if;
      end if;
   end process;
   
   process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         if running = '0' then
            raddr <= (others => '0');
         elsif G_RELOCK and h_last = '1' and vcnt = i_VACTIVE - 1 then   -- NextTang: G_RELOCK, the frame's first line
            raddr <= frame_waddr_h;
         elsif hdmi_active = '1' then
            raddr <= raddr + 1;
         elsif (v_active = '1') and (hsync_n = '0') and (vcnt(0) /= i_VACTIVE(0)) then
            raddr <= raddr_lag;
         end if;
      end if;
   end process;
   
   process (i_CLK_HDMI)
   begin
      if rising_edge(i_CLK_HDMI) then
         if G_RELOCK and h_last = '1' and vcnt = i_VACTIVE - 1 then   -- NextTang: G_RELOCK
            raddr_lag <= frame_waddr_h;
         elsif (hsync_n = '0') and (vcnt(0) = i_VACTIVE(0)) then
            raddr_lag <= raddr;
         end if;
      end if;
   end process;
   
   hdmi_buffer : entity work.dpram2
   generic map
   (
      addr_width_g   => 13,
      data_width_g   => 9
   )
   port map
   (
      -- sync write only port
      clk_a_i        => i_CLK_RGB,
      we_i           => i_CLK_RGB_EN,
      addr_a_i       => waddr,
      data_a_i       => i_rgb,
      -- sync read only port
      clk_b_i        => i_CLK_HDMI,
      addr_b_i       => raddr,
      data_b_o       => rgb_raw
   );

   rgb_r_25 <= ('0' & rgb_raw(8 downto 6)) + ("00" & rgb_raw(8 downto 7));
   rgb_g_25 <= ('0' & rgb_raw(5 downto 3)) + ("00" & rgb_raw(5 downto 4));
   rgb_b_25 <= ('0' & rgb_raw(2 downto 0)) + ("00" & rgb_raw(2 downto 1));
   
   rgb_r_12 <= (rgb_r_25) + ("000" & rgb_raw(8));
   rgb_g_12 <= (rgb_g_25) + ("000" & rgb_raw(5));
   rgb_b_12 <= (rgb_b_25) + ("000" & rgb_raw(2));

   process (running, vcnt, i_VACTIVE, scanlines, rgb_raw, rgb_r_25, rgb_g_25, rgb_b_25, rgb_r_12, rgb_g_12, rgb_b_12)
   begin
      if running = '0' then
         rgb_scanline <= (others => '0');
      elsif vcnt(0) = i_VACTIVE(0) then
         rgb_scanline <= rgb_raw;
      else
         case scanlines is
            when "00" =>
               rgb_scanline <= rgb_raw;
            when "01" =>
               rgb_scanline <= '0' & rgb_raw(8 downto 7) & '0' & rgb_raw(5 downto 4) & '0' & rgb_raw(2 downto 1);   -- 50%
            when "10" =>
               rgb_scanline <= rgb_r_25(3 downto 1) & rgb_g_25(3 downto 1) & rgb_b_25(3 downto 1);   -- 25%
            when others =>
               rgb_scanline <= rgb_r_12(3 downto 1) & rgb_g_12(3 downto 1) & rgb_b_12(3 downto 1);   -- 12.5%
         end case;
      end if;
   end process;

--   process (i_CLK_HDMI)
--   begin
--      if rising_edge(i_CLK_HDMI) then
--         o_rgb <= rgb_scanline;
--      end if;
--   end process;

   o_rgb <= rgb_scanline;

end architecture;

