-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 NextTang contributors
--
-- Runs the ZX Next core against a boot ROM and records every output, sampled
-- just before each rising edge of the 28 MHz clock, whenever it changes.
--
-- The trace is the evidence for the single-clock CPU conversion: the
-- unmodified core with a real CPU clock and the converted core with clock
-- enables must produce the same trace. Sampling at the 28 MHz rising edge is
-- what makes that comparison fair. Everything the rest of the machine sees is
-- sampled there, and the conversion moves the CPU's slow-speed falling-edge
-- work half a 28 MHz cycle later, never earlier, so nothing clocked on a
-- rising edge may see a difference.
--
-- All clocks, the CPU clock included, change in one process at one instant, so
-- the simulation has no delta-cycle skew between them. A clock produced by a
-- register in another process would fire one delta later and see values the
-- hardware never would. Inputs the core samples are changed on the falling
-- edge, half a cycle from any rising-edge sampler.
--
-- The CPU clock follows MiSTer's zxnext_top: at 3.5 MHz the contended clock
-- is updated on each 7 MHz rising edge from the pixel-counter bit and the
-- contention flag; 7 and 14 MHz follow clock_7 and clock_14, as the Console's
-- speed-select DCS did; 28 MHz is clock_28 itself. A requested speed is
-- adopted on the 28 MHz edge before a 7 MHz edge.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.cpu_clock_reference_pkg.all;

entity tb_zxnext_trace is
    generic (
        TRACE_FILE : string := "trace.txt";
        CYCLES     : natural := 200000;
        -- "reference": a real CPU clock into i_CLK_CPU, enables left at '1'.
        -- "enables": i_CLK_CPU is clock_28 and nexttang_zxnext_cpu_enables
        -- drives the enables, checked against the reference rule every edge.
        MODE       : string := "reference"
    );
end entity;

architecture sim of tb_zxnext_trace is
    constant HALF : time := 17857 ps;

    signal clock_28, clock_28_n, clock_14, clock_7 : std_logic := '0';
    signal cpu_clock   : std_logic := '0';
    signal cen_r, cen_f   : std_logic := '1';
    signal generator_cen_r, generator_cen_f, generator_locked : std_logic;
    signal psg_enable  : std_logic := '0';
    signal reset       : std_logic := '1';

    signal cpu_speed   : std_logic_vector(1 downto 0);
    signal cpu_contend : std_logic;
    signal cpu_lsb     : std_logic;

    signal ram_a_addr  : std_logic_vector(20 downto 0);
    signal ram_a_req, ram_a_req2, ram_a_rd_n : std_logic;
    signal ram_a_do    : std_logic_vector(7 downto 0);
    signal ram_a_di    : std_logic_vector(7 downto 0) := (others => '0');
    signal ram_b_addr  : std_logic_vector(20 downto 0);

    signal rgb         : std_logic_vector(8 downto 0);
    signal vs_n, hs_n, vb_n, hb_n, hdmi_pixel, hdmi_lock : std_logic;
    signal spi_sd0_n, spi_sck, spi_mosi : std_logic;
    signal kbd_row     : std_logic_vector(7 downto 0);
    signal audio_l, audio_r : std_logic_vector(12 downto 0);
    signal bus_addr    : std_logic_vector(15 downto 0);
    signal bus_do      : std_logic_vector(7 downto 0);
    signal bus_mreq_n, bus_iorq_n, bus_rd_n, bus_wr_n, bus_m1_n : std_logic;
    signal bus_rfsh_n, bus_halt_n, uart_tx : std_logic;

    type memory_t is array (0 to 65535) of std_logic_vector(7 downto 0);
begin
    clocks : process
        variable position : natural range 0 to 3 := 0;  -- 0: a 7 MHz rising edge
        variable selected : std_logic_vector(1 downto 0) := "00";
        variable level    : std_logic := '0';
        variable at_28, rises, falls : boolean;
        variable fall_due : boolean := false;
        variable divider  : unsigned(3 downto 0) := (others => '0');
        variable cycle    : natural := 0;
    begin
        clock_28_n <= '1';
        while cycle < CYCLES loop
            -- Rising edge of clock_28. Decide the CPU clock from values that
            -- settled during the last cycle.
            cpu_clock_rising_edge(cycle, position, cpu_speed, cpu_lsb, cpu_contend,
                                  selected, level, at_28, rises, falls);
            if MODE = "enables" then
                assert (generator_cen_r = '1') = rises
                    report "cycle " & integer'image(cycle) & ": rising enable " &
                           std_logic'image(generator_cen_r) & ", reference " & boolean'image(rises)
                    severity failure;
            end if;
            fall_due := falls or at_28;

            clock_28 <= '1';
            clock_28_n <= '0';
            if position = 0 or position = 1 then clock_7 <= '1'; else clock_7 <= '0'; end if;
            if position = 0 or position = 2 then clock_14 <= '1'; else clock_14 <= '0'; end if;
            -- In enables mode i_CLK_CPU is clock_28 itself, changed in the same
            -- statement group so it carries no delta of its own.
            if MODE = "enables" then cpu_clock <= '1'; else cpu_clock <= level; end if;
            wait for HALF;

            -- Falling edge.
            if MODE = "enables" then
                assert (generator_cen_f = '1') = fall_due
                    report "cycle " & integer'image(cycle) & ": falling enable " &
                           std_logic'image(generator_cen_f) & ", reference " & boolean'image(fall_due)
                    severity failure;
            end if;
            clock_28 <= '0';
            clock_28_n <= '1';
            if at_28 then
                level := '0';
            end if;
            if MODE = "enables" or at_28 then
                cpu_clock <= '0';
            end if;
            divider := divider + 1;
            if divider = "1110" then psg_enable <= '1'; else psg_enable <= '0'; end if;
            if cycle = 64 then reset <= '0'; end if;
            position := (position + 1) mod 4;
            cycle := cycle + 1;
            wait for HALF;
        end loop;
        wait;
    end process;

    enables : entity work.nexttang_zxnext_cpu_enables
        port map (
            i_CLK_28 => clock_28,
            i_CLK_7 => clock_7,
            i_CPU_SPEED => cpu_speed,
            i_CPU_CONTEND => cpu_contend,
            i_CPU_CLK_LSB => cpu_lsb,
            o_CEN_R => generator_cen_r,
            o_CEN_F => generator_cen_f,
            o_LOCKED => generator_locked
        );

    cen_r <= generator_cen_r when MODE = "enables" else '1';
    cen_f <= generator_cen_f when MODE = "enables" else '1';

    memory : process (clock_28)
        variable storage : memory_t := (others => (others => '0'));
        variable address : natural;
    begin
        if rising_edge(clock_28) then
            address := to_integer(unsigned(ram_a_addr(15 downto 0)));
            if ram_a_req = '1' and ram_a_rd_n = '1' then
                storage(address) := ram_a_do;
            else
                ram_a_di <= storage(address);
            end if;
        end if;
    end process;

    core : entity work.zxnext
        generic map (
            g_video_def   => "000",
            g_version     => x"32",
            g_sub_version => x"00",
            g_video_inc   => "10"
        )
        port map (
            g_machine_id => x"0A",
            g_board_issue => x"2",
            i_CLK_28 => clock_28,
            i_CLK_28_n => clock_28_n,
            i_CLK_14 => clock_14,
            i_CLK_7 => clock_7,
            i_CLK_CPU => cpu_clock,
            i_CPU_CEN_R => cen_r,
            i_CPU_CEN_F => cen_f,
            i_CLK_PSG_EN => psg_enable,
            o_CPU_SPEED => cpu_speed,
            o_CPU_CONTEND => cpu_contend,
            o_CPU_CLK_LSB => cpu_lsb,
            i_RESET => reset,
            i_BOOT => reset,
            o_RESET_SOFT => open,
            o_RESET_HARD => open,
            o_RESET_PERIPHERAL => open,
            o_FLASH_BOOT => open,
            o_CORE_ID => open,
            i_SPKEY_FUNCTION => (others => '0'),
            i_SPKEY_BUTTONS => (others => '0'),
            o_KBD_CANCEL => open,
            o_KBD_ROW => kbd_row,
            i_KBD_COL => (others => '1'),
            i_KBD_EXTENDED_KEYS => (others => '1'),
            o_KEYMAP_ADDR => open,
            o_KEYMAP_DATA => open,
            o_KEYMAP_WE => open,
            o_JOYMAP_WE => open,
            i_JOY_LEFT => (others => '0'),
            i_JOY_RIGHT => (others => '0'),
            o_JOY_IO_MODE_EN => open,
            o_JOY_IO_MODE_PIN_7 => open,
            o_JOY_LEFT_TYPE => open,
            o_JOY_RIGHT_TYPE => open,
            i_MOUSE_X => (others => '0'),
            i_MOUSE_Y => (others => '0'),
            i_MOUSE_BUTTON => (others => '0'),
            i_MOUSE_WHEEL => (others => '0'),
            o_PS2_MODE => open,
            o_MOUSE_CONTROL => open,
            i_I2C_SCL_n => '1',
            i_I2C_SDA_n => '1',
            o_I2C_SCL_n => open,
            o_I2C_SDA_n => open,
            o_SPI_SS_FLASH_n => open,
            o_SPI_SS_SD1_n => open,
            o_SPI_SS_SD0_n => spi_sd0_n,
            o_SPI_SCK => spi_sck,
            o_SPI_MOSI => spi_mosi,
            i_SPI_SD_MISO => spi_mosi,
            i_SPI_FLASH_MISO => '1',
            i_UART0_RX => '1',
            o_UART0_TX => uart_tx,
            i_UART0_CTS_n => '0',
            o_UART0_RTR_n => open,
            o_RGB => rgb,
            o_RGB_CS_n => open,
            o_RGB_VS_n => vs_n,
            o_RGB_HS_n => hs_n,
            o_RGB_VB_n => vb_n,
            o_RGB_HB_n => hb_n,
            o_VIDEO_50_60 => open,
            o_VIDEO_SCANLINES => open,
            o_VIDEO_SCANDOUBLE => open,
            o_VIDEO_MODE => open,
            o_MACHINE_TIMING => open,
            o_HDMI_RESET => open,
            o_HDMI_PIXEL => hdmi_pixel,
            o_HDMI_LOCK => hdmi_lock,
            center => '1',
            o_AUDIO_HDMI_AUDIO_EN => open,
            o_AUDIO_SPEAKER_EN => open,
            o_AUDIO_SPEAKER_EXCL => open,
            i_AUDIO_EAR => '0',
            o_AUDIO_MIC => open,
            o_AUDIO_EAR => open,
            o_AUDIO_L => audio_l,
            o_AUDIO_R => audio_r,
            o_RAM_A_ADDR => ram_a_addr,
            o_RAM_A_REQ => ram_a_req,
            o_RAM_A_REQ2 => ram_a_req2,
            i_RAM_A_REQ_ALLOW => '0',
            o_RAM_A_RD_n => ram_a_rd_n,
            i_RAM_A_DI => ram_a_di,
            o_RAM_A_DO => ram_a_do,
            o_RAM_A_CYCLE => open,
            o_RAM_A_RFSH => open,
            i_CPU_WAIT => '0',
            o_RAM_B_ADDR => ram_b_addr,
            o_RAM_B_REQ_T => open,
            i_RAM_B_DI => (others => '0'),
            o_BUS_ADDR => bus_addr,
            i_BUS_DI => (others => '1'),
            o_BUS_DO => bus_do,
            o_BUS_MREQ_n => bus_mreq_n,
            o_BUS_IORQ_n => bus_iorq_n,
            o_BUS_RD_n => bus_rd_n,
            o_BUS_WR_n => bus_wr_n,
            o_BUS_M1_n => bus_m1_n,
            i_BUS_WAIT_n => '1',
            i_BUS_NMI_n => '1',
            i_BUS_INT_n => '1',
            o_BUS_INT_n => open,
            i_BUS_BUSREQ_n => '1',
            o_BUS_BUSAK_n => open,
            o_BUS_HALT_n => bus_halt_n,
            o_BUS_RFSH_n => bus_rfsh_n,
            o_BUS_IEO => open,
            i_BUS_ROMCS_n => '1',
            i_BUS_IORQULA_n => '1',
            o_BUS_EN => open,
            o_BUS_CLKEN => open,
            o_BUS_NMI_DEBOUNCE_DISABLE => open,
            i_ESP_GPIO_20 => "111",
            o_ESP_GPIO_0 => open,
            o_ESP_GPIO_0_EN => open,
            i_GPIO => (others => '0'),
            o_GPIO => open,
            o_GPIO_EN => open
        );

    trace : process
        file output : text open write_mode is TRACE_FILE;
        variable entry : line;
        variable now_seen, last_seen : std_logic_vector(140 downto 0);
        variable cycle : natural := 0;
        variable first : boolean := true;
    begin
        wait until rising_edge(clock_28);
        loop
            -- Wake a quarter period before the next rising edge, when every
            -- output launched on the last rising or falling edge has settled.
            wait for HALF + HALF / 2;
            now_seen :=
                ram_a_addr & ram_a_req & ram_a_req2 & ram_a_rd_n & ram_a_do &
                ram_b_addr &
                rgb & vs_n & hs_n & vb_n & hb_n & hdmi_pixel & hdmi_lock &
                spi_sd0_n & spi_sck & spi_mosi & kbd_row &
                audio_l & audio_r &
                cpu_speed & cpu_contend & cpu_lsb &
                bus_addr & bus_do & bus_mreq_n & bus_iorq_n & bus_rd_n & bus_wr_n &
                bus_m1_n & bus_rfsh_n & bus_halt_n & uart_tx;
            if first or now_seen /= last_seen then
                write(entry, cycle);
                write(entry, string'(" "));
                write(entry, to_hstring(now_seen));
                writeline(output, entry);
                last_seen := now_seen;
                first := false;
            end if;
            cycle := cycle + 1;
            wait until rising_edge(clock_28);
        end loop;
    end process;
end architecture;
