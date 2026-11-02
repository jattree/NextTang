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
        CHECK_VRAM : boolean := false;
        -- The core's build options (g_option). With PI_DEBUG, an FPGA-side SPI
        -- master drives the official Pi debug slave through a script of
        -- commands, port C reaches the same memory as port A after
        -- PORT_C_WAIT cycles, and each reply is checked.
        G_OPTION : natural := 0;
        PI_DEBUG : boolean := false;
        PORT_C_WAIT : natural := 20
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

    signal ram_c_addr  : std_logic_vector(20 downto 0);
    signal ram_c_req, ram_c_rd_n : std_logic;
    signal ram_c_do    : std_logic_vector(7 downto 0);
    signal ram_c_di    : std_logic_vector(7 downto 0) := (others => '0');
    signal ram_c_ack   : std_logic := '0';
    signal gpio_in     : std_logic_vector(27 downto 0) := (others => '0');
    signal gpio_out    : std_logic_vector(27 downto 0);
    signal spi_select, spi_valid, spi_ready, spi_done, spi_idle : std_logic := '0';
    signal spi_byte, spi_reply : std_logic_vector(7 downto 0) := (others => '0');
    signal debug_finished : boolean := false;
    signal spi_ce_n_s, spi_sclk_s, spi_mosi_s : std_logic;
    signal pi_force : std_logic := '0';
    signal debug_watch : boolean := false;
    signal cpu_next_pc : std_logic_vector(15 downto 0);
    signal cpu_stopped, cpu_break, bp_hit, bp_strobe, bp_enable : std_logic := '0';
    signal bp_slot : std_logic_vector(7 downto 0) := (others => '0');
    signal bp_address : std_logic_vector(15 downto 0) := (others => '0');
    signal core_mmu : std_logic_vector(63 downto 0);
    signal bp_paged : std_logic := '0';
    signal bp_page : std_logic_vector(7 downto 0) := (others => '0');

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
        variable c_active : boolean := false;
        variable c_count : natural := 0;
        variable c_seen_low : boolean := true;
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

            -- Port C, the Pi debug slave's: served only while port A is idle,
            -- as the board's mux does, after PORT_C_WAIT cycles. The slave
            -- drops its request the cycle after the acknowledge, so a request
            -- is new only once it has been seen low.
            ram_c_ack <= '0';
            if ram_c_req = '0' then
                c_seen_low := true;
            end if;
            if ram_c_req = '1' and c_seen_low and not c_active and not active and ram_a_req2 = '0' then
                c_seen_low := false;
                c_active := true;
                c_count := 0;
            elsif c_active then
                c_count := c_count + 1;
                if c_count >= PORT_C_WAIT then
                    if ram_c_rd_n = '1' then
                        storage(to_integer(unsigned(ram_c_addr(15 downto 0)))) := ram_c_do;
                    else
                        ram_c_di <= storage(to_integer(unsigned(ram_c_addr(15 downto 0))));
                    end if;
                    ram_c_ack <= '1';
                    c_active := false;
                end if;
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
            g_board_issue => x"2",
            g_option      => to_unsigned(G_OPTION, 16)
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
            i_SPKEY_FUNCTION_EXT => (others => '0'),
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
            o_RAM_C_ADDR => ram_c_addr,
            o_RAM_C_REQ => ram_c_req,
            o_RAM_C_RD_n => ram_c_rd_n,
            i_RAM_C_DI => ram_c_di,
            o_RAM_C_DO => ram_c_do,
            i_RAM_C_ACK => ram_c_ack,
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
            i_GPIO => gpio_in,
            i_PI_SPI_SLAVE_FORCE => pi_force,
            o_CPU_NEXT_PC => cpu_next_pc,
            o_CPU_STOPPED => cpu_stopped,
            i_CPU_BREAK => cpu_break,
            o_MMU => core_mmu,
            o_GPIO => gpio_out,
            o_GPIO_EN => open,
            i_XDNA_DO => '0',
            i_XADC_DRDY => '0',
            i_XADC_DO => (others => '0'),
            i_XADC_BUSY => '0',
            i_XADC_EOC => '0',
            i_XADC_EOS => '0'
        );

    -- The official Pi debug slave, driven as a Pi would drive it. GPIO 8 is
    -- chip select, 10 MOSI, 11 SCLK and 9 MISO; the rest stay low.
    pi_force <= '1' when PI_DEBUG else '0';
    gpio_in(8) <= spi_ce_n_s;
    gpio_in(10) <= spi_mosi_s;
    gpio_in(11) <= spi_sclk_s;

    pi_spi : entity work.nexttang_pi_spi_master
        port map (
            clock => clock_28, reset => reset,
            select_in => spi_select, byte_valid => spi_valid, byte_in => spi_byte,
            byte_ready => spi_ready, done => spi_done, byte_out => spi_reply, idle => spi_idle,
            memory_busy => ram_c_req,
            spi_ce_n => spi_ce_n_s, spi_sclk => spi_sclk_s, spi_mosi => spi_mosi_s,
            spi_miso => gpio_out(9)
        );

    -- With PI_DEBUG, every instruction fetch from the reset vector onwards,
    -- for reading a failed step.
    pi_fetches : process (clock_28)
        variable l : line;
        variable last_m1 : std_logic := '1';
    begin
        if rising_edge(clock_28) then
            if PI_DEBUG and bus_m1_n = '0' and last_m1 = '1' and debug_watch then
                write(l, string'("PI_DEBUG fetch ") & to_hstring(bus_addr));
                writeline(output, l);
            end if;
            last_m1 := bus_m1_n;
        end if;
    end process;

    breakpoints : entity work.nexttang_breakpoints
        port map (
            clock => clock_28, reset => reset,
            write_strobe => bp_strobe, write_slot => bp_slot, write_enable => bp_enable,
            write_address => bp_address, write_paged => bp_paged, write_page => bp_page, mmu => core_mmu,
            next_pc => cpu_next_pc, cpu_stopped => cpu_stopped, break_now => cpu_break, hit => bp_hit
        );

    pi_script : process
        type bytes_t is array (natural range <>) of std_logic_vector(7 downto 0);
        variable reply : bytes_t(0 to 15);
        variable l : line;
        variable pc_before, pc_after : std_logic_vector(15 downto 0);
        variable saved : std_logic_vector(7 downto 0);
        variable polls : natural;
        constant steps : bytes_t(1 to 5) := (x"01", x"04", x"05", x"07", x"09");

        procedure command(sent : bytes_t) is
        begin
            spi_select <= '1';
            for i in sent'range loop
                spi_byte <= sent(i);
                spi_valid <= '1';
                wait until rising_edge(clock_28) and spi_ready = '1';
                spi_valid <= '0';
                wait until rising_edge(clock_28) and spi_done = '1';
                reply(i - sent'low) := spi_reply;
            end loop;
            spi_select <= '0';
            wait until rising_edge(clock_28) and spi_idle = '1';
        end procedure;

        procedure expect(what : string; got, wanted : std_logic_vector(7 downto 0)) is
        begin
            write(l, string'("PI_DEBUG ") & what & string'(" ") & to_hstring(got));
            if got /= wanted then
                write(l, string'(" FAIL, wanted ") & to_hstring(wanted));
            end if;
            writeline(output, l);
            assert got = wanted report "PI_DEBUG mismatch: " & what severity error;
        end procedure;

        procedure set_breakpoint(slot : natural; address : std_logic_vector(15 downto 0); enable : std_logic;
                                 paged : std_logic := '0'; page : std_logic_vector(7 downto 0) := x"00") is
        begin
            bp_slot <= std_logic_vector(to_unsigned(slot, 8));
            bp_address <= address;
            bp_enable <= enable;
            bp_paged <= paged;
            bp_page <= page;
            bp_strobe <= '1';
            wait until rising_edge(clock_28);
            bp_strobe <= '0';
        end procedure;

        -- As the board does: once a breakpoint has stopped the CPU, send the
        -- slave a pause so that it owns the stop.
        procedure wait_breakpoint is
            variable cycles : natural := 0;
        begin
            loop
                wait until rising_edge(clock_28);
                exit when bp_hit = '1';
                cycles := cycles + 1;
                assert cycles < 200000 report "PI_DEBUG breakpoint never hit" severity failure;
            end loop;
            command((0 => x"A4"));
        end procedure;

        procedure read_pc(pc : out std_logic_vector(15 downto 0)) is
        begin
            command((x"AD", x"16", x"00", x"00"));
            pc(15 downto 8) := reply(3);
            command((x"AD", x"17", x"00", x"00"));
            pc(7 downto 0) := reply(3);
        end procedure;

        procedure wait_status(bus_state : std_logic_vector(1 downto 0)) is
        begin
            polls := 0;
            loop
                command((x"A2", x"00", x"00", x"00"));
                exit when reply(2)(6 downto 5) = bus_state;
                polls := polls + 1;
                assert polls < 200 report "PI_DEBUG status never reached " & to_hstring(bus_state) severity failure;
            end loop;
        end procedure;
    begin
        if not PI_DEBUG then
            wait;
        end if;
        for i in 1 to 200000 loop
            wait until rising_edge(clock_28);
        end loop;

        command((x"A1", x"00", x"00", x"00"));
        expect("version", reply(2), x"10");
        expect("capabilities", reply(3), x"FF");

        command((x"AB", x"00", x"00", x"00"));
        expect("nextreg 00", reply(3), x"0A");

        command((x"A8", x"00", x"81", x"00", x"00", x"04", x"11", x"22", x"33", x"44"));
        command((x"A7", x"00", x"81", x"00", x"00", x"04", x"00", x"00", x"00", x"00", x"00"));
        expect("sram 8100", reply(7), x"11");
        expect("sram 8101", reply(8), x"22");
        expect("sram 8102", reply(9), x"33");
        expect("sram 8103", reply(10), x"44");

        command((0 => x"A4"));
        wait_status("10");
        write(l, string'("PI_DEBUG paused after ") & integer'image(polls) & string'(" polls"));
        writeline(output, l);

        command((x"AD", x"16", x"00", x"00"));
        pc_before(15 downto 8) := reply(3);
        command((x"AD", x"17", x"00", x"00"));
        pc_before(7 downto 0) := reply(3);
        write(l, string'("PI_DEBUG pc ") & to_hstring(pc_before));
        writeline(output, l);

        command((x"AD", x"10", x"00", x"00"));
        saved := reply(3);
        command((x"AE", x"10", x"5A", x"00"));
        command((x"AD", x"10", x"00", x"00"));
        expect("ixh written", reply(3), x"5A");
        command((x"AE", x"10", saved, x"00"));

        command((x"AA", x"9F", x"00", x"00", x"02", x"DE", x"AD"));
        command((x"A9", x"9F", x"00", x"00", x"02", x"00", x"00", x"00"));
        expect("bram 7:1f00", reply(6), x"DE");
        expect("bram 7:1f01", reply(7), x"AD");

        -- The clock test ends in DI and HALT, where a step stays put. Point
        -- the CPU at the reset vector instead, out of HALT: DI is one byte and
        -- LD SP,nn three, so two steps land on 0001 and 0004.
        -- At 28 MHz every clock is a CPU clock enable, which is where the
        -- official wedge's HALT/IFF write never landed: run the rest there.
        command((x"AC", x"07", x"03", x"00"));
        command((x"AE", x"16", x"00", x"00"));
        command((x"AE", x"17", x"00", x"00"));
        command((x"AE", x"1B", x"00", x"00"));
        command((x"AD", x"1A", x"00", x"00"));
        expect("out of HALT, interrupts off (state register)", reply(3) and x"07", x"00");
        debug_watch <= true;
        -- DI; LD SP,$FFFF; XOR A; OUT ($FE),A; IM 1 (ED 56); JP main.
        for i in steps'range loop
            command((0 => x"A6"));
            wait_status("10");
            command((x"AD", x"16", x"00", x"00"));
            pc_after(15 downto 8) := reply(3);
            command((x"AD", x"17", x"00", x"00"));
            pc_after(7 downto 0) := reply(3);
            expect("pc after step " & integer'image(i) & " (high)", pc_after(15 downto 8), x"00");
            expect("pc after step " & integer'image(i) & " (low)", pc_after(7 downto 0), steps(i));
        end loop;

        -- Breakpoints. JP main at 0009 lands on 0043: the CPU must stop
        -- before 0043 runs although JP loads PC on its last edge. Then a
        -- breakpoint reached by plain sequence (0049, two instructions on),
        -- and a single step off it.
        set_breakpoint(0, x"0043", '1');
        command((0 => x"A5"));
        wait_breakpoint;
        wait_status("10");
        read_pc(pc_after);
        expect("pc at jump-target breakpoint (high)", pc_after(15 downto 8), x"00");
        expect("pc at jump-target breakpoint (low)", pc_after(7 downto 0), x"43");
        set_breakpoint(1, x"0049", '1');
        command((0 => x"A5"));
        wait_breakpoint;
        wait_status("10");
        read_pc(pc_after);
        expect("pc at sequential breakpoint (low)", pc_after(7 downto 0), x"49");
        command((0 => x"A6"));
        wait_status("10");
        read_pc(pc_after);
        expect("pc after stepping off a breakpoint (low)", pc_after(7 downto 0), x"4C");
        set_breakpoint(0, x"0043", '0');
        set_breakpoint(1, x"0049", '0');

        -- A page-qualified breakpoint on the LDIR at 004C, which refetches
        -- itself every byte: with a page other than slot 0's it must not
        -- fire; with slot 0's page it must stop the next repetition.
        command((x"AB", x"50", x"00", x"00"));
        saved := reply(3);
        write(l, string'("PI_DEBUG slot 0 page ") & to_hstring(saved));
        writeline(output, l);
        set_breakpoint(2, x"004C", '1', '1', saved xor x"01");
        command((0 => x"A5"));
        for i in 1 to 3000 loop
            wait until rising_edge(clock_28);
            assert bp_hit = '0' report "PI_DEBUG breakpoint fired with the wrong page" severity error;
        end loop;
        command((x"A2", x"00", x"00", x"00"));
        expect("still running with the wrong page (bus bits)", "000000" & reply(2)(6 downto 5), x"00");
        command((0 => x"A4"));
        wait_status("10");
        set_breakpoint(2, x"004C", '1', '1', saved);
        command((0 => x"A5"));
        wait_breakpoint;
        wait_status("10");
        read_pc(pc_after);
        expect("pc at page-qualified breakpoint (low)", pc_after(7 downto 0), x"4C");
        set_breakpoint(2, x"004C", '0');

        -- A PC written while stopped must be where the next fetch comes
        -- from: from 004C (LDIR) set PC to 0043 (LD HL,nn) with a breakpoint
        -- at 0046, the instruction after it.
        command((x"AE", x"16", x"00", x"00"));
        command((x"AE", x"17", x"43", x"00"));
        set_breakpoint(3, x"0046", '1');
        command((0 => x"A5"));
        wait_breakpoint;
        wait_status("10");
        read_pc(pc_after);
        expect("pc after a written PC (low)", pc_after(7 downto 0), x"46");
        set_breakpoint(3, x"0046", '0');

        command((0 => x"A5"));
        wait_status("00");
        command((x"A2", x"00", x"00", x"00"));
        expect("status error bit", "0000000" & reply(2)(0), x"00");

        write(l, string'("PI_DEBUG DONE"));
        writeline(output, l);
        debug_finished <= true;
        wait;
    end process;

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
