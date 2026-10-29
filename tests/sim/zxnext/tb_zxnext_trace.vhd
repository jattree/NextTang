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
        MODE       : string := "reference";
        -- 0: memory answers at once and never holds the CPU. Above 0: memory
        -- behaves like the Console's DDR3 service. It takes the address,
        -- direction and write data on the first cycle of o_RAM_A_REQ2, holds
        -- i_CPU_WAIT from the request until WAIT_CYCLES later, then keeps the
        -- read data until the request ends. Writes whose data or direction
        -- change after the request starts are counted, since the service
        -- would store the wrong byte.
        WAIT_CYCLES : natural := 0;
        -- When above 0, every LONG_EVERY-th access waits LONG_WAIT_CYCLES
        -- instead, as a DDR3 refresh or a queued write makes the board wait.
        LONG_EVERY : natural := 0;
        LONG_WAIT_CYCLES : natural := 300;
        -- At the end, print the 128 bytes the clock test ROM keeps at $8000.
        DUMP_RESULTS : boolean := true;
        -- At the end, compare memory with a copy written as the board's
        -- Layer 2 mirror writes: on every cycle of a write request, so the
        -- byte kept is the one present on its last cycle. Memory itself takes
        -- the first cycle's, as the board's memory path does.
        CHECK_MIRROR : boolean := false;
        -- Print every NextREG write the core performs, from the CPU or the
        -- copper, with the 28 MHz cycle it happened on.
        LOG_NEXTREG : boolean := false;
        -- Check that every CPU write to RAM bank 5, as main memory receives it,
        -- also lands in the core's own screen RAM, with the same offset and
        -- data and in the same order.
        CHECK_VRAM : boolean := false
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
    signal debug_nr_we : std_logic;
    signal debug_nr_reg, debug_nr_dat : std_logic_vector(7 downto 0);
    signal ram_a_req, ram_a_req2, ram_a_rd_n : std_logic;
    signal ram_a_do    : std_logic_vector(7 downto 0);
    signal ram_a_di    : std_logic_vector(7 downto 0) := (others => '0');
    signal ram_b_addr  : std_logic_vector(20 downto 0);
    signal cpu_wait    : std_logic;
    signal memory_done : std_logic := '0';

    signal rgb         : std_logic_vector(8 downto 0);
    signal vs_n, hs_n, bk_n, hdmi_pixel, hdmi_lock : std_logic;
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
        variable state    : cpu_clock_state := CPU_CLOCK_START;
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
                                  state, at_28, rises, falls);
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
            if MODE = "enables" then cpu_clock <= '1'; else cpu_clock <= state.level; end if;
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
            cpu_clock_falling_edge(cycle, state);
            if MODE = "enables" then
                cpu_clock <= '0';
            else
                cpu_clock <= state.level;
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
        variable mirror : memory_t := (others => (others => '0'));
        variable mismatches : natural := 0;
        variable address : natural;
        variable pending_address : natural;
        variable pending_write : boolean := false;
        variable pending_data : std_logic_vector(7 downto 0);
        variable active : boolean := false;
        variable count : natural := 0;
        variable done : boolean := false;
        variable unstable : natural := 0;
        variable accesses : natural := 0;
        variable this_wait : natural := 0;
        variable l : line;
    begin
        if rising_edge(clock_28) then
            if WAIT_CYCLES = 0 then
                address := to_integer(unsigned(ram_a_addr(15 downto 0)));
                if ram_a_req = '1' and ram_a_rd_n = '1' then
                    storage(address) := ram_a_do;
                else
                    ram_a_di <= storage(address);
                end if;
            else
                if ram_a_req2 = '1' and ram_a_rd_n = '1' then
                    mirror(to_integer(unsigned(ram_a_addr(15 downto 0)))) := ram_a_do;
                end if;
                if ram_a_req2 = '1' and not active then
                    active := true;
                    done := false;
                    count := 0;
                    pending_address := to_integer(unsigned(ram_a_addr(15 downto 0)));
                    pending_write := ram_a_rd_n = '1';
                    pending_data := ram_a_do;
                    accesses := accesses + 1;
                    if LONG_EVERY > 0 and accesses mod LONG_EVERY = 0 then
                        this_wait := LONG_WAIT_CYCLES;
                    else
                        this_wait := WAIT_CYCLES;
                    end if;
                elsif ram_a_req2 = '1' and active and not done then
                    if pending_write and (ram_a_rd_n /= '1' or ram_a_do /= pending_data) then
                        unstable := unstable + 1;
                        write(l, string'("UNSTABLE_WRITE addr=") & to_hstring(ram_a_addr) &
                              string'(" latched=") & to_hstring(pending_data) &
                              string'(" now=") & to_hstring(ram_a_do) &
                              string'(" rd_n=") & std_logic'image(ram_a_rd_n));
                        writeline(output, l);
                    end if;
                    count := count + 1;
                    if count >= this_wait then
                        done := true;
                        if pending_write then
                            storage(pending_address) := pending_data;
                        else
                            ram_a_di <= storage(pending_address);
                        end if;
                    end if;
                elsif ram_a_req2 = '0' then
                    active := false;
                    done := false;
                end if;
            end if;
            if done then
                memory_done <= '1';
            else
                memory_done <= '0';
            end if;
        end if;
        if DUMP_RESULTS and now >= CYCLES * 2 * HALF - 4 * HALF and now < CYCLES * 2 * HALF - 2 * HALF
                and rising_edge(clock_28) then
            write(l, string'("RESULTS"));
            for i in 0 to 127 loop
                write(l, string'(" ") & to_hstring(storage(16#8000# + i)));
            end loop;
            writeline(output, l);
            write(l, string'("UNSTABLE_WRITES ") & integer'image(unstable));
            writeline(output, l);
            if CHECK_MIRROR then
                mismatches := 0;
                for i in 0 to 65535 loop
                    if storage(i) /= mirror(i) then
                        if mismatches < 16 then
                            write(l, string'("MIRROR_DIFFERS ") & to_hstring(to_unsigned(i, 16)) &
                                  string'(" memory=") & to_hstring(storage(i)) &
                                  string'(" mirror=") & to_hstring(mirror(i)));
                            writeline(output, l);
                        end if;
                        mismatches := mismatches + 1;
                    end if;
                end loop;
                write(l, string'("MIRROR_MISMATCHES ") & integer'image(mismatches));
                writeline(output, l);
            end if;
        end if;
    end process;

    -- As nexttang_zxnext_memory_port: wait follows the request at once and
    -- falls when the service completes.
    cpu_wait <= '1' when WAIT_CYCLES > 0 and ram_a_req2 = '1' and memory_done = '0' else '0';

    vram_check : process (clock_28)
        alias bank5_sched is << signal .tb_zxnext_trace.core.cpu_bank5_sched : std_logic >>;
        alias bank5_we is << signal .tb_zxnext_trace.core.cpu_bank5_we : std_logic >>;
        alias bank5_a0 is << signal .tb_zxnext_trace.core.vram_bank5_a0 : std_logic_vector(13 downto 0) >>;
        alias core_do is << signal .tb_zxnext_trace.core.cpu_do : std_logic_vector(7 downto 0) >>;
        type queue_t is array (0 to 4095) of std_logic_vector(21 downto 0);
        variable queue : queue_t;
        variable head, tail : natural := 0;
        variable expected_writes, screen_writes, mismatches, missing : natural := 0;
        variable req_previous : std_logic := '0';
        variable l : line;
    begin
        if rising_edge(clock_28) and CHECK_VRAM then
            if ram_a_req2 = '1' and req_previous = '0' and ram_a_rd_n = '1' and
                    ram_a_addr(20 downto 14) = "0010101" then
                queue(tail mod 4096) := ram_a_addr(13 downto 0) & ram_a_do;
                tail := tail + 1;
                expected_writes := expected_writes + 1;
            end if;
            req_previous := ram_a_req2;
            if bank5_sched = '1' and bank5_we = '1' then
                write(l, string'("SCREEN_WRITE ") & to_hstring(bank5_a0) & string'(" ") & to_hstring(core_do));
                writeline(output, l);
                screen_writes := screen_writes + 1;
                if head = tail then
                    if mismatches < 8 then
                        write(l, string'("VRAM_UNEXPECTED ") & to_hstring(bank5_a0) & string'("=") & to_hstring(core_do));
                        writeline(output, l);
                    end if;
                    mismatches := mismatches + 1;
                else
                    if queue(head mod 4096) /= bank5_a0 & core_do then
                        if mismatches < 8 then
                            write(l, string'("VRAM_MISMATCH memory ") & to_hstring(queue(head mod 4096)) &
                                  string'(" screen ") & to_hstring(bank5_a0 & core_do));
                            writeline(output, l);
                        end if;
                        mismatches := mismatches + 1;
                    end if;
                    head := head + 1;
                end if;
            end if;
        end if;
        if CHECK_VRAM and now >= CYCLES * 2 * HALF - 4 * HALF and now < CYCLES * 2 * HALF - 2 * HALF
                and rising_edge(clock_28) then
            write(l, string'("VRAM_CHECK expected ") & integer'image(expected_writes) &
                  string'(" screen ") & integer'image(screen_writes) &
                  string'(" mismatches ") & integer'image(mismatches) &
                  string'(" unmatched ") & integer'image(tail - head));
            writeline(output, l);
        end if;
    end process;

    nextreg_log : process (clock_28)
        variable l : line;
        variable cycle : natural := 0;
    begin
        if rising_edge(clock_28) then
            cycle := cycle + 1;
            if LOG_NEXTREG and debug_nr_we = '1' then
                write(l, string'("NR ") & integer'image(cycle) & string'(" ") &
                      to_hstring(debug_nr_reg) & string'("=") & to_hstring(debug_nr_dat));
                writeline(output, l);
            end if;
        end if;
    end process;

    core : entity work.zxnext
        generic map (
            g_video_def   => "000",
            g_version     => x"32",
            g_sub_version => x"00",
            g_video_inc   => "10",
            g_machine_id  => x"0A",
            g_board_issue => x"2"
        )
        port map (
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
            o_RGB_VS_n => vs_n,
            o_RGB_HS_n => hs_n,
            o_RGB_BK_n => bk_n,
            o_VIDEO_50_60 => open,
            o_VIDEO_SCANLINES => open,
            o_VIDEO_SCANDOUBLE => open,
            o_VIDEO_MODE => open,
            o_MACHINE_TIMING => open,
            o_HDMI_RESET => open,
            o_HDMI_PIXEL => hdmi_pixel,
            o_HDMI_LOCK => hdmi_lock,
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
            o_RAM_A_RD_n => ram_a_rd_n,
            i_RAM_A_DI => ram_a_di,
            o_RAM_A_DO => ram_a_do,
            o_DEBUG_NR_WE => debug_nr_we,
            o_DEBUG_NR_REG => debug_nr_reg,
            o_DEBUG_NR_DAT => debug_nr_dat,
            i_CPU_WAIT => cpu_wait,
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
            o_GPIO_EN => open,
            i_XDNA_DO => '0',
            i_XADC_DRDY => '0',
            i_XADC_DO => (others => '0'),
            i_XADC_BUSY => '0',
            i_XADC_EOC => '0',
            i_XADC_EOS => '0'
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
                rgb & vs_n & hs_n & bk_n & '1' & hdmi_pixel & hdmi_lock &
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
