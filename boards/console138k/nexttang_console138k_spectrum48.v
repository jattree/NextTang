// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// A 48K ZX Spectrum: the Z80 running a machine ROM against 48K of RAM, with
// its screen drawn to HDMI.
//
// This is the smallest workload that exercises the pieces the Next needs
// anyway. Booting a real ROM proves the processor, the memory map, the frame
// interrupt and the display path together, in a way no diagnostic firmware of
// our own can: the ROM was written against hardware, not against us.
//
// The ROM image is named by the build and is not part of this repository.
//
// What this is not: it does not implement contention, the floating bus, or the
// original video timing. The upstream core's zxula does all of that and is the
// intended destination. Nothing here duplicates it, because the display path is
// ours regardless and everything else is what any Spectrum needs.

`default_nettype none

`ifndef NEXTTANG_SPECTRUM48_TOP
`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48
`endif

module `NEXTTANG_SPECTRUM48_TOP #(
    // The build writes the image into its own directory and runs there.
    parameter ROM_IMAGE = "48k.mem",
`ifdef NEXTTANG_SPECTRUM128
    parameter ROM_IMAGE_1 = "128-1.mem",
`endif
`ifdef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
    parameter RAM_IMAGE = "snapshot-ram.mem",
`else
    parameter RAM_IMAGE = "",
`endif
    parameter SNAPSHOT_BOOT_IMAGE = "snapshot-boot.mem",
    parameter SPEC256_RAM_IMAGE = "spec256-ram.mem",
    parameter SPEC256_PALETTE_IMAGE = "spec256-palette.mem",
    parameter SPEC256_BACKGROUND_IMAGE = ""
) (
    input  wire       sys_clk,
    // TangCore messages from the companion BL616. Read only, so it does not
    // contend with the debugger for this multiplexed pin group.
    input  wire       bl616_uart_rx,
`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
    input  wire       loopback_uart_rx,
`endif
`ifdef NEXTTANG_SPEC256_RUNTIME
    // PMOD0 IO2, beside the status UART on IO5.  Keeping both directions on
    // one socket gives the runtime loader an ordinary TX/RX/GND connection.
    input  wire       game_pack_uart_rx,
`endif
    output wire       debug_uart_tx,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire       tmds_psv,

    // Z80 bus brought out to PMOD1 for a logic analyser. Passive: nothing in
    // the machine depends on these.
    inout  wire [5:0] probe
`ifdef NEXTTANG_SPECTRUM48_USB_KEYBOARD
    ,
    inout wire usb1_dp,
    inout wire usb1_dn,
    inout wire usb2_dp,
    inout wire usb2_dn
`endif
`ifdef NEXTTANG_CLASSIC_SD_LOADER
    ,
    input  wire sd_miso,
    output wire sd_clk,
    output wire sd_mosi,
    output wire sd_cs
`endif
`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    ,
    output wire        status_led,
    output wire        debug_uart_tx_alt,
    output wire [14:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs,
    output wire        ddr_ras,
    output wire        ddr_cas,
    output wire        ddr_we,
    output wire        ddr_ck,
    output wire        ddr_ck_n,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [3:0]  ddr_dm,
    inout  wire [31:0] ddr_dq,
    inout  wire [3:0]  ddr_dqs,
    inout  wire [3:0]  ddr_dqs_n
`endif
);
`ifdef NEXTTANG_SPEC256_RUNTIME
    // Roughly fifteen CPU clocks per bit gives the asynchronous receiver enough
    // phase margin for the FT232RL and flying leads.  Status and commands use
    // this same full-duplex rate so the host never changes baud mid-session.
    localparam integer RUNTIME_UART_BAUD = 230400;
`endif

    // ----------------------------------------------------------------- clocks
    wire serial_clock;
    wire pixel_clock;
    wire video_pll_locked;

    nexttang_console138k_pll video_pll (
        .clock_in(sys_clk),
        .serial_clock(serial_clock),
        .pixel_clock(pixel_clock),
        .locked(video_pll_locked)
    );

    wire clock_28;
    wire clock_14;
    wire clock_7;
    wire machine_pll_locked;

    nexttang_console138k_machine_pll machine_pll (
        .clock_in(sys_clk),
        .clock_28(clock_28),
        .clock_28_n(),
        .clock_14(clock_14),
        .clock_7(clock_7),
        .locked(machine_pll_locked)
    );

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    wire memory_clock;
    wire memory_reference_clock;
    wire memory_pll_locked;
    wire memory_clock_enable;
    wire controller_clock;
    wire controller_clock_enable;
    reg [7:0] controller_reset_shift = 0;
    wire controller_reset_n = controller_reset_shift[7];
    wire calibration_complete;
    wire ddr_reset;

    wire controller_command_ready;
    wire [2:0] controller_command;
    wire controller_command_enable;
    wire [28:0] controller_address;
    wire controller_write_data_ready;
    wire [255:0] controller_write_data;
    wire controller_write_data_enable;
    wire controller_write_data_end;
    wire [31:0] controller_write_data_mask;
    wire [255:0] controller_read_data;
    wire controller_read_data_valid;
    wire controller_read_data_end;
    wire controller_burst;
    wire self_refresh_acknowledge;
    wire refresh_acknowledge;
    reg memory_available_meta = 0;
    reg memory_available_cpu = 0;

    nexttang_console138k_ddr3_pll memory_pll (
        .clock_in(sys_clk),
        .clock_enable(memory_clock_enable),
        .memory_clock(memory_clock),
        .reference_clock(memory_reference_clock),
        .locked(memory_pll_locked)
    );

    always @(posedge sys_clk or negedge memory_pll_locked) begin
        if (!memory_pll_locked)
            controller_reset_shift <= 0;
        else
            controller_reset_shift <= {
                controller_reset_shift[6:0], 1'b1
            };
    end

    assign memory_clock_enable =
        !controller_reset_n || controller_clock_enable;
`endif

    wire cpu_clock;

    // 3.5 MHz is 7 halved. Dividing it here rather than with a third CLKDIV
    // keeps clock_28 down to two HCLK sections, which is what the device will
    // route, and ties the CPU's phase to the ULA it shares screen memory with.
    reg cpu_clock_divided = 1'b0;
    // Preserve a short feedback chain so the toggle flop cannot acquire a
    // sub-hold-time local feedback route on crowded placements.
    (* syn_keep = 1 *) wire cpu_divide_n1 = ~cpu_clock_divided;
    (* syn_keep = 1 *) wire cpu_divide_n2 = ~cpu_divide_n1;
    (* syn_keep = 1 *) wire cpu_divide_n3 = ~cpu_divide_n2;

    always @(posedge clock_7 or negedge machine_pll_locked) begin
        if (!machine_pll_locked)
            cpu_clock_divided <= 1'b0;
        else
            cpu_clock_divided <= cpu_divide_n3;
    end

    assign cpu_clock = cpu_clock_divided;

    reg [3:0] pixel_reset_shift = 0;
    reg [3:0] cpu_reset_shift = 0;
    wire pixel_reset = !pixel_reset_shift[3];
`ifdef NEXTTANG_SPEC256_RUNTIME
    wire loader_hold_reset;
    wire loader_ready;
    wire loader_fault;
    wire [20:0] loader_received_bytes;
    wire [7:0] loader_byte;
    wire loader_byte_valid;
    wire loader_boot_write;
    wire [13:0] loader_boot_address;
    wire loader_main_write;
    wire [15:0] loader_main_address;
    wire [7:0] loader_graphics_ram_write;
    wire [15:0] loader_graphics_ram_address;
    wire [7:0] loader_graphics_rom_write;
    wire [13:0] loader_graphics_rom_address;
    wire loader_palette_write;
    wire [7:0] loader_palette_index;
    wire [23:0] loader_palette_data;
    wire loader_background_write;
    wire [15:0] loader_background_address;
    wire loader_background_valid;
    wire [7:0] loader_write_data;
    wire [2:0] loader_launch_key_count;
    wire [7:0] loader_launch_key_0;
    wire [7:0] loader_launch_key_1;
    wire [7:0] loader_launch_key_2;
    wire [7:0] loader_launch_key_3;
    wire [15:0] loader_launch_start_delay_ms;
    wire [15:0] loader_launch_hold_ms;
    wire [15:0] loader_launch_gap_ms;

`ifdef NEXTTANG_SPEC256_SD_PACK
    wire [7:0] spec256_pack_byte;
    wire spec256_pack_byte_valid;
    wire spec256_pack_byte_pop;
    wire spec256_pack_consumer_ready;
    assign loader_byte = spec256_pack_byte;
    assign loader_byte_valid = spec256_pack_byte_valid &&
                               spec256_pack_consumer_ready;
    assign spec256_pack_byte_pop = loader_byte_valid;
`else
    nexttang_uart_receiver #(
        .CLOCK_HZ(3500000),
        .BAUD_RATE(RUNTIME_UART_BAUD)
    ) game_pack_uart (
        .clock(cpu_clock),
        .reset(!cpu_reset_shift[3]),
        .receive(game_pack_uart_rx),
        .data(loader_byte),
        .data_valid(loader_byte_valid)
    );
`endif

    nexttang_spec256_game_loader game_pack_loader (
        .clock(cpu_clock),
        .reset(!cpu_reset_shift[3]),
        .byte_data(loader_byte),
        .byte_valid(loader_byte_valid),
        .hold_reset(loader_hold_reset),
        .ready(loader_ready),
        .fault(loader_fault),
        .received_bytes(loader_received_bytes),
        .boot_write_enable(loader_boot_write),
        .boot_write_address(loader_boot_address),
        .main_write_enable(loader_main_write),
        .main_write_address(loader_main_address),
        .graphics_ram_write_enable(loader_graphics_ram_write),
        .graphics_ram_write_address(loader_graphics_ram_address),
        .graphics_rom_write_enable(loader_graphics_rom_write),
        .graphics_rom_write_address(loader_graphics_rom_address),
        .palette_write_enable(loader_palette_write),
        .palette_write_index(loader_palette_index),
        .palette_write_data(loader_palette_data),
        .background_write_enable(loader_background_write),
        .background_write_address(loader_background_address),
        .background_valid(loader_background_valid),
        .write_data(loader_write_data),
        .launch_key_count(loader_launch_key_count),
        .launch_key_0(loader_launch_key_0),
        .launch_key_1(loader_launch_key_1),
        .launch_key_2(loader_launch_key_2),
        .launch_key_3(loader_launch_key_3),
        .launch_start_delay_ms(loader_launch_start_delay_ms),
        .launch_hold_ms(loader_launch_hold_ms),
        .launch_gap_ms(loader_launch_gap_ms)
    );

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    wire cpu_reset = !cpu_reset_shift[3] || !memory_available_cpu ||
                     loader_hold_reset;
`elsif NEXTTANG_SPEC256_ROM_LANE_VIEW
    // The pack still loads -- the loader does not run from cpu_reset -- but no
    // CPU is ever released, so the ROM lanes hold exactly what the loader
    // wrote and every captured frame is identical.
    wire cpu_reset = 1'b1;
`else
    wire cpu_reset = !cpu_reset_shift[3] || loader_hold_reset;
`endif
`elsif NEXTTANG_SPEC256_FREEZE_CPU
    // Diagnostic-only hold: retain the CPU logic in the build while keeping
    // it reset long enough to inspect the untouched graphical RAM on HDMI.
    reg [31:0] spec256_freeze_counter = 32'b0;
    wire cpu_reset = !cpu_reset_shift[3] ||
                     spec256_freeze_counter != 32'hffffffff;
`elsif NEXTTANG_SPECTRUM48_USE_DDR3
`ifdef NEXTTANG_CLASSIC_SD_LOADER
    wire cpu_reset = !cpu_reset_shift[3] || !memory_available_cpu ||
                     classic_loader_hold_reset_cpu;
`else
    wire cpu_reset = !cpu_reset_shift[3] || !memory_available_cpu;
`endif
`else
    wire cpu_reset = !cpu_reset_shift[3];
`endif

    always @(posedge pixel_clock or negedge video_pll_locked) begin
        if (!video_pll_locked)
            pixel_reset_shift <= 0;
        else
            pixel_reset_shift <= {pixel_reset_shift[2:0], 1'b1};
    end

    always @(posedge cpu_clock or negedge machine_pll_locked) begin
        if (!machine_pll_locked)
            cpu_reset_shift <= 0;
        else
            cpu_reset_shift <= {cpu_reset_shift[2:0], 1'b1};
    end

`ifdef NEXTTANG_SPEC256_FREEZE_CPU
    always @(posedge cpu_clock or negedge machine_pll_locked) begin
        if (!machine_pll_locked)
            spec256_freeze_counter <= 32'b0;
        else if (spec256_freeze_counter != 32'hffffffff)
            spec256_freeze_counter <= spec256_freeze_counter + 1'b1;
    end
`endif

`ifndef NEXTTANG_SPEC256_FREEZE_CPU
`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    always @(posedge cpu_clock or negedge machine_pll_locked) begin
        if (!machine_pll_locked) begin
            memory_available_meta <= 1'b0;
            memory_available_cpu <= 1'b0;
        end else begin
            memory_available_meta <= calibration_complete;
            memory_available_cpu <= memory_available_meta;
        end
    end
`endif
`endif

    // -------------------------------------------------------------- interrupt
    // The ROM runs on interrupts: the keyboard scan, the frame counter and the
    // flash phase all hang off them, and without one it stops at the first
    // HALT. A 48K frame is 69888 processor cycles and the original hardware
    // held the line low for 32 of them.
    localparam integer FRAME_CYCLES = 69888;
    localparam integer INTERRUPT_CYCLES = 32;

    reg [16:0] frame_counter = 0;
    wire interrupt_n = !(frame_counter < INTERRUPT_CYCLES);

    always @(posedge cpu_clock) begin
        if (cpu_reset)
            frame_counter <= 0;
        else if (frame_counter == FRAME_CYCLES - 1)
            frame_counter <= 0;
        else
            frame_counter <= frame_counter + 1'b1;
    end

    // -------------------------------------------------------------------- CPU
    wire [15:0] cpu_address;
    wire [7:0]  cpu_data_out;
    reg  [7:0]  cpu_data_in;
    wire mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n;

    wire cpu_wait_n;

`ifdef NEXTTANG_SPECTRUM48_USE_SPEC256
    wire spec256_sync_enable;
    wire spec256_bootstrap;
    wire [127:0] spec256_graphics_address;
    wire [63:0] spec256_graphics_data_in;
    wire [63:0] spec256_graphics_data_out;
    wire [7:0] spec256_graphics_iorq;
    wire [7:0] spec256_graphics_write;
    wire [7:0] spec256_graphics_running;

    nexttang_spec256_cpu_cluster cpu (
        .reset_n(!cpu_reset),
        .clock(cpu_clock),
        .sync_enable(spec256_sync_enable),
        .bootstrap(spec256_bootstrap),
        .wait_n(cpu_wait_n),
        .interrupt_n(interrupt_n),
        .nmi_n(1'b1),
        .bus_request_n(1'b1),
        .m1_n(m1_n),
        .mreq_n(mreq_n),
        .iorq_n(iorq_n),
        .rd_n(rd_n),
        .wr_n(wr_n),
        .rfsh_n(rfsh_n),
        .halt_n(halt_n),
        .address(cpu_address),
        .data_in(cpu_data_in),
        .data_out(cpu_data_out),
        .graphics_address(spec256_graphics_address),
        .graphics_data_in(spec256_graphics_data_in),
        .graphics_data_out(spec256_graphics_data_out),
        .graphics_iorq(spec256_graphics_iorq),
        .graphics_write(spec256_graphics_write),
        .graphics_running(spec256_graphics_running),
        .debug_master_pc(),
        .debug_graphics_pc(),
        .debug_master_regs(),
        .debug_graphics_regs()
    );
`else
    T80Na #(.Mode(0)) cpu (
        .RESET_n(!cpu_reset),
        .CLK_n(cpu_clock),
        .WAIT_n(cpu_wait_n),
        .INT_n(interrupt_n),
        .NMI_n(1'b1),
        .BUSRQ_n(1'b1),
        .M1_n(m1_n),
        .MREQ_n(mreq_n),
        .IORQ_n(iorq_n),
        .RD_n(rd_n),
        .WR_n(wr_n),
        .RFSH_n(rfsh_n),
        .HALT_n(halt_n),
        .BUSAK_n(),
        .A(cpu_address),
        .D_i(cpu_data_in),
        .D_o(cpu_data_out),
        .Z80N_dout_o(),
        .Z80N_data_o(),
        .Z80N_command_o()
    );
`endif

    // ----------------------------------------------------------------- memory
    // ROM occupies the bottom 16K and RAM the rest. The RAM is addressed by the
    // full processor address so the display can read the screen at its real
    // address, and its bottom 16K is simply never used.
`ifdef NEXTTANG_SPECTRUM128
    wire in_rom;
    wire [2:0] cpu_ram_bank;
    wire rom_select;
    wire screen_bank;
    wire paging_locked;

    nexttang_spectrum_paging paging (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .io_write(!iorq_n && !wr_n),
        .io_address(cpu_address),
        .io_data(cpu_data_out),
        .cpu_address(cpu_address),
        .cpu_is_rom(in_rom),
        .cpu_bank(cpu_ram_bank),
        .rom_select(rom_select),
        .screen_bank(screen_bank),
        .paging_locked(paging_locked)
    );
`else
    wire in_rom = (cpu_address[15:14] == 2'b00);
`endif
    wire memory_write = !mreq_n && !wr_n && !in_rom;

    wire [7:0] rom_data;
    wire [7:0] machine_rom_data;
    wire [7:0] ram_data;
    wire [12:0] display_address;
    wire [7:0]  display_data;
    wire [13:0] ula_vram_address;
    wire [7:0]  ula_vram_data;
`ifdef NEXTTANG_SPECTRUM48_USE_SPEC256
    wire [15:0] spec256_display_address;
    wire [63:0] spec256_graphics_ram_data;
    wire [63:0] spec256_graphics_rom_data;
    wire [63:0] spec256_plane_display_data;
`ifdef NEXTTANG_SPEC256_ROM_LANE_VIEW
    // Diagnostic view only. The eight graphical ROM lanes are the one loaded
    // artifact the display never reads, so their contents have never been
    // observed on hardware; the frozen-plane capture that validated the planes
    // could not cover them. This routes their second port to the display and
    // holds the CPUs, so a capture can be compared against the pack's
    // graphics_rom section by exactly the method that validated the planes.
    //
    // The display addresses an 8 KiB screen window, so one half of each 16 KiB
    // lane is visible per build; NEXTTANG_SPEC256_ROM_LANE_VIEW_HALF selects
    // which. Not supported alongside NEXTTANG_SPECTRUM48_USE_DDR3, where lane
    // 0 is distributed RAM with no second port.
    wire [63:0] spec256_rom_display_data;
    wire [63:0] spec256_display_data = spec256_rom_display_data;
`else
    wire [63:0] spec256_display_data = spec256_plane_display_data;
`endif
`endif

    wire [7:0] machine_rom_data_0;

    nexttang_rom #(
        .ADDRESS_BITS(14),
        .IMAGE(ROM_IMAGE)
    ) machine_rom_0 (
        .clock(cpu_clock),
        .address(cpu_address[13:0]),
        .data(machine_rom_data_0)
    );

`ifdef NEXTTANG_SPECTRUM128
    wire [7:0] machine_rom_data_1;

    nexttang_rom #(
        .ADDRESS_BITS(14),
        .IMAGE(ROM_IMAGE_1)
    ) machine_rom_1 (
        .clock(cpu_clock),
        .address(cpu_address[13:0]),
        .data(machine_rom_data_1)
    );

    // 128K reset selects ROM 0 (editor/menu); bit 4 of 7FFD selects ROM 1,
    // the 48K BASIC half of the pair.
    assign machine_rom_data = rom_select
        ? machine_rom_data_1 : machine_rom_data_0;
`else
    assign machine_rom_data = machine_rom_data_0;
`endif

`ifdef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
    wire [7:0] snapshot_boot_data;
    reg snapshot_boot_active = 1'b1;
    reg snapshot_boot_rom_active = 1'b1;
    reg snapshot_boot_ret_seen = 1'b0;
    reg snapshot_boot_previous_m1_n = 1'b1;
    localparam [13:0] SNAPSHOT_BOOT_RET_ADDRESS = 14'h0044;

`ifdef NEXTTANG_SPEC256_RUNTIME
`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    nexttang_spec256_bootstrap_overlay snapshot_boot_rom (
        .clock(cpu_clock),
        .write_enable(loader_boot_write),
        .write_address(loader_boot_address),
        .write_data(loader_write_data),
        .read_address(cpu_address[13:0]),
        .read_data(snapshot_boot_data)
    );
`else
    nexttang_block_ram #(
        .ADDRESS_BITS(14),
        .IMAGE("")
    ) snapshot_boot_rom (
        .clock(cpu_clock),
        .write_enable(loader_boot_write),
        .write_address(loader_boot_write ? loader_boot_address :
                                             cpu_address[13:0]),
        .write_data(loader_write_data),
        .read_data(snapshot_boot_data),
        .port_b_clock(cpu_clock),
        .port_b_address(14'b0),
        .port_b_data()
    );
`endif
`else
    nexttang_rom #(
        .ADDRESS_BITS(14),
        .IMAGE(SNAPSHOT_BOOT_IMAGE)
    ) snapshot_boot_rom (
        .clock(cpu_clock),
        .address(cpu_address[13:0]),
        .data(snapshot_boot_data)
    );
`endif

    // The bootstrap ends with RET through the PC stored on the SNA stack.
    // Its first opcode fetch in RAM is the unambiguous hand-off point: RAM is
    // already selected for that fetch, and later ROM calls see the real ROM.
    wire snapshot_handoff = snapshot_boot_active &&
                            !m1_n && !mreq_n && !in_rom;

    always @(posedge cpu_clock) begin
        if (cpu_reset) begin
            snapshot_boot_active <= 1'b1;
            snapshot_boot_rom_active <= 1'b1;
            snapshot_boot_ret_seen <= 1'b0;
            snapshot_boot_previous_m1_n <= 1'b1;
        end else begin
            snapshot_boot_previous_m1_n <= m1_n;
            if (snapshot_handoff)
                snapshot_boot_active <= 1'b0;

            // The generated bootstrap is a fixed 69-byte straight-line
            // program whose final byte at 0x0044 is RET.  A snapshot may
            // resume in ROM (notably inside the IM1 handler at 0x0038), so
            // selecting the overlay until the first RAM fetch would execute
            // bootstrap bytes in place of the Spectrum ROM.  Switch the ROM
            // mux on the first opcode fetch after that RET, while leaving the
            // graphical contexts cloned until execution actually reaches RAM.
            if (snapshot_boot_previous_m1_n && !m1_n && !mreq_n) begin
                if (snapshot_boot_ret_seen)
                    snapshot_boot_rom_active <= 1'b0;
                else if (snapshot_boot_rom_active &&
                         cpu_address[13:0] == SNAPSHOT_BOOT_RET_ADDRESS)
                    snapshot_boot_ret_seen <= 1'b1;
            end
        end
    end

`ifdef NEXTTANG_SPECTRUM48_USE_SPEC256
    // GZX clones the complete snapshot CPU state into every graphical context.
    // On hardware the state is restored by executable bootstrap code instead,
    // so run that same stream through all nine CPUs before their memories split.
    assign spec256_sync_enable = 1'b1;
    assign spec256_bootstrap = snapshot_boot_active;
`endif

    assign rom_data = snapshot_boot_rom_active
        ? snapshot_boot_data : machine_rom_data;
`else
    assign rom_data = machine_rom_data;
`ifdef NEXTTANG_SPECTRUM48_USE_SPEC256
    assign spec256_sync_enable = 1'b1;
    assign spec256_bootstrap = 1'b0;
`endif
`endif

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    wire upper_transaction_complete;
    wire line_request;
    wire line_ready;
    wire line_write;
    wire [16:0] line_address;
    wire [127:0] line_write_data;
    wire [15:0] line_write_enable;
    wire line_response_valid;
    wire [127:0] line_read_data;
    wire fault_timeout;
    wire fault_overrun;
    wire fault_calibration_lost;

`ifndef NEXTTANG_SPECTRUM48_USE_SPEC256
`ifdef NEXTTANG_SPECTRUM128
    nexttang_spectrum128_memory machine_ram (
        .cpu_clock(cpu_clock),
        .cpu_reset(cpu_reset),
        .memory_available(memory_available_cpu),
        .cpu_address(cpu_address),
        .cpu_bank(cpu_ram_bank),
        .cpu_write_data(cpu_data_out),
        .cpu_mreq_n(mreq_n),
        .cpu_rd_n(rd_n),
        .cpu_wr_n(wr_n),
        .cpu_rfsh_n(rfsh_n),
        .ram_read_data(ram_data),
        .cpu_wait_n(cpu_wait_n),
        .transaction_complete(upper_transaction_complete),
        .video_clock(clock_7),
        .video_bank(screen_bank),
        .video_address(ula_vram_address),
        .video_data(ula_vram_data),
        .memory_clock(controller_clock),
        .memory_reset(!controller_reset_n),
        .line_request(line_request),
        .line_ready(line_ready),
        .line_write(line_write),
        .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
        .fault_timeout(fault_timeout),
        .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );
`else
    nexttang_spectrum48_split_memory machine_ram (
        .cpu_clock(cpu_clock),
        .cpu_reset(cpu_reset),
        .memory_available(memory_available_cpu),
        .cpu_address(cpu_address),
        .cpu_write_data(cpu_data_out),
        .cpu_mreq_n(mreq_n),
        .cpu_rd_n(rd_n),
        .cpu_wr_n(wr_n),
        .cpu_rfsh_n(rfsh_n),
        .ram_read_data(ram_data),
        .cpu_wait_n(cpu_wait_n),
        .upper_transaction_complete(upper_transaction_complete),
        .video_clock(clock_7),
        .video_address(ula_vram_address),
        .video_data(ula_vram_data),
        .memory_clock(controller_clock),
        .memory_reset(!controller_reset_n),
        .line_request(line_request),
        .line_ready(line_ready),
        .line_write(line_write),
        .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
        .fault_timeout(fault_timeout),
        .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );
`endif
`endif

    nexttang_gowin_ddr3_ui_adapter memory_adapter (
        .clock(controller_clock),
        .reset(!controller_reset_n),
        .line_request(line_request),
        .line_ready(line_ready),
        .line_write(line_write),
        .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
        .controller_command_ready(controller_command_ready),
        .controller_command(controller_command),
        .controller_command_enable(controller_command_enable),
        .controller_address(controller_address),
        .controller_write_data_ready(controller_write_data_ready),
        .controller_write_data(controller_write_data),
        .controller_write_data_enable(controller_write_data_enable),
        .controller_write_data_end(controller_write_data_end),
        .controller_write_data_mask(controller_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(controller_read_data_valid),
        .controller_burst(controller_burst)
    );

    DDR3_Memory_Interface_Top ddr3 (
        .clk(sys_clk),
        .pll_stop(controller_clock_enable),
        .memory_clk(memory_clock),
        .pll_lock(memory_pll_locked),
        .rst_n(controller_reset_n),
        .clk_out(controller_clock),
        .ddr_rst(ddr_reset),
        .init_calib_complete(calibration_complete),
        .cmd_ready(controller_command_ready),
        .cmd(controller_command),
        .cmd_en(controller_command_enable),
        .addr(controller_address),
        .wr_data_rdy(controller_write_data_ready),
        .wr_data(controller_write_data),
        .wr_data_en(controller_write_data_enable),
        .wr_data_end(controller_write_data_end),
        .wr_data_mask(controller_write_data_mask),
        .rd_data(controller_read_data),
        .rd_data_valid(controller_read_data_valid),
        .rd_data_end(controller_read_data_end),
        .sr_req(1'b0),
        .ref_req(1'b0),
        .sr_ack(self_refresh_acknowledge),
        .ref_ack(refresh_acknowledge),
        .burst(controller_burst),
        .O_ddr_addr(ddr_addr),
        .O_ddr_ba(ddr_bank),
        .O_ddr_cs_n(ddr_cs),
        .O_ddr_ras_n(ddr_ras),
        .O_ddr_cas_n(ddr_cas),
        .O_ddr_we_n(ddr_we),
        .O_ddr_clk(ddr_ck),
        .O_ddr_clk_n(ddr_ck_n),
        .O_ddr_cke(ddr_cke),
        .O_ddr_odt(ddr_odt),
        .O_ddr_reset_n(ddr_reset_n),
        .O_ddr_dqm(ddr_dm),
        .IO_ddr_dq(ddr_dq),
        .IO_ddr_dqs(ddr_dqs),
        .IO_ddr_dqs_n(ddr_dqs_n)
    );
`endif

`ifdef NEXTTANG_SPECTRUM48_USE_SPEC256
`ifndef NEXTTANG_SPECTRUM48_USE_DDR3
    assign cpu_wait_n = 1'b1;
`endif

`ifdef NEXTTANG_SPEC256_RUNTIME
`ifdef NEXTTANG_SPEC256_ROM_LANE_VIEW
// Diagnostic build: the second port carries the lane to the display instead of
// being tied off. The macro is spelled out twice rather than nesting another
// macro inside its body, which the vendor preprocessor handles inconsistently.
`ifndef NEXTTANG_SPEC256_ROM_LANE_VIEW_HALF
`define NEXTTANG_SPEC256_ROM_LANE_VIEW_HALF 1'b0
`endif
`define NEXTTANG_RUNTIME_GRAPHICS_ROM(INSTANCE, LANE, ADDRESS_SLICE, DATA_SLICE) \
    nexttang_block_ram #(.ADDRESS_BITS(14), .IMAGE("")) INSTANCE ( \
        .clock(cpu_clock), \
        .write_enable(loader_graphics_rom_write[LANE]), \
        .write_address(loader_graphics_rom_write[LANE] ? \
                       loader_graphics_rom_address : ADDRESS_SLICE), \
        .write_data(loader_write_data), \
        .read_data(DATA_SLICE), \
        .port_b_clock(pixel_clock), \
        .port_b_address({`NEXTTANG_SPEC256_ROM_LANE_VIEW_HALF, \
                         spec256_display_address[12:0]}), \
        .port_b_data(spec256_rom_display_data[LANE * 8 +: 8]));
`else
`define NEXTTANG_RUNTIME_GRAPHICS_ROM(INSTANCE, LANE, ADDRESS_SLICE, DATA_SLICE) \
    nexttang_block_ram #(.ADDRESS_BITS(14), .IMAGE("")) INSTANCE ( \
        .clock(cpu_clock), \
        .write_enable(loader_graphics_rom_write[LANE]), \
        .write_address(loader_graphics_rom_write[LANE] ? \
                       loader_graphics_rom_address : ADDRESS_SLICE), \
        .write_data(loader_write_data), \
        .read_data(DATA_SLICE), \
        .port_b_clock(cpu_clock), .port_b_address(14'b0), .port_b_data());
`endif
`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    // One 16 KiB lane plus the compact bootstrap overlay recover the BSRAM
    // needed by the DDR3 controller while keeping the distributed footprint
    // bounded.
    nexttang_distributed_ram spec256_rom_0 (
        .clock(cpu_clock), .write_enable(loader_graphics_rom_write[0]),
        .address(loader_graphics_rom_write[0] ? loader_graphics_rom_address :
                 spec256_graphics_address[13:0]),
        .write_data(loader_write_data), .read_data(spec256_graphics_rom_data[7:0]));
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_1, 1,
        spec256_graphics_address[29:16], spec256_graphics_rom_data[15:8])
`else
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_0, 0,
        spec256_graphics_address[13:0], spec256_graphics_rom_data[7:0])
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_1, 1,
        spec256_graphics_address[29:16], spec256_graphics_rom_data[15:8])
`endif
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_2, 2,
        spec256_graphics_address[45:32], spec256_graphics_rom_data[23:16])
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_3, 3,
        spec256_graphics_address[61:48], spec256_graphics_rom_data[31:24])
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_4, 4,
        spec256_graphics_address[77:64], spec256_graphics_rom_data[39:32])
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_5, 5,
        spec256_graphics_address[93:80], spec256_graphics_rom_data[47:40])
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_6, 6,
        spec256_graphics_address[109:96], spec256_graphics_rom_data[55:48])
    `NEXTTANG_RUNTIME_GRAPHICS_ROM(spec256_rom_7, 7,
        spec256_graphics_address[125:112], spec256_graphics_rom_data[63:56])
`undef NEXTTANG_RUNTIME_GRAPHICS_ROM
`else
    nexttang_rom #(.ADDRESS_BITS(14), .IMAGE("spec256-rom-plane0.mem"))
    spec256_rom_0 (.clock(cpu_clock),
        .address(spec256_graphics_address[13:0]),
        .data(spec256_graphics_rom_data[7:0]));
    nexttang_rom #(.ADDRESS_BITS(14), .IMAGE("spec256-rom-plane1.mem"))
    spec256_rom_1 (.clock(cpu_clock),
        .address(spec256_graphics_address[29:16]),
        .data(spec256_graphics_rom_data[15:8]));
    nexttang_rom #(.ADDRESS_BITS(14), .IMAGE("spec256-rom-plane2.mem"))
    spec256_rom_2 (.clock(cpu_clock),
        .address(spec256_graphics_address[45:32]),
        .data(spec256_graphics_rom_data[23:16]));
    nexttang_rom #(.ADDRESS_BITS(14), .IMAGE("spec256-rom-plane3.mem"))
    spec256_rom_3 (.clock(cpu_clock),
        .address(spec256_graphics_address[61:48]),
        .data(spec256_graphics_rom_data[31:24]));
    nexttang_rom #(.ADDRESS_BITS(14), .IMAGE("spec256-rom-plane4.mem"))
    spec256_rom_4 (.clock(cpu_clock),
        .address(spec256_graphics_address[77:64]),
        .data(spec256_graphics_rom_data[39:32]));
    nexttang_rom #(.ADDRESS_BITS(14), .IMAGE("spec256-rom-plane5.mem"))
    spec256_rom_5 (.clock(cpu_clock),
        .address(spec256_graphics_address[93:80]),
        .data(spec256_graphics_rom_data[47:40]));
    nexttang_rom #(.ADDRESS_BITS(14), .IMAGE("spec256-rom-plane6.mem"))
    spec256_rom_6 (.clock(cpu_clock),
        .address(spec256_graphics_address[109:96]),
        .data(spec256_graphics_rom_data[55:48]));
    nexttang_rom #(.ADDRESS_BITS(14), .IMAGE("spec256-rom-plane7.mem"))
    spec256_rom_7 (.clock(cpu_clock),
        .address(spec256_graphics_address[125:112]),
        .data(spec256_graphics_rom_data[63:56]));
`endif

`ifdef NEXTTANG_SPEC256_RUNTIME
`define NEXTTANG_SPEC256_INITIAL_IMAGE(NAME) ""
`else
`define NEXTTANG_SPEC256_INITIAL_IMAGE(NAME) NAME
`endif

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    reg loader_ddr_write_busy = 1'b0;
    wire loader_main_upper_write = loader_main_write &&
                                   loader_main_address[15];
    wire spec256_ddr_path_reset = !cpu_reset_shift[3] ||
                                  !memory_available_cpu;
    always @(posedge cpu_clock) begin
        if (spec256_ddr_path_reset)
            loader_ddr_write_busy <= 1'b0;
        else if (upper_transaction_complete)
            loader_ddr_write_busy <= 1'b0;
        else if (loader_main_upper_write)
            loader_ddr_write_busy <= 1'b1;
    end
`ifdef NEXTTANG_SPEC256_SD_PACK
    assign spec256_pack_consumer_ready = memory_available_cpu &&
        !loader_ddr_write_busy && !loader_main_upper_write;
`endif
    nexttang_spec256_main_ddr_memory machine_ram (
        .cpu_clock(cpu_clock), .path_reset(spec256_ddr_path_reset),
        .memory_available(memory_available_cpu), .cpu_address(cpu_address),
        .cpu_write_data(cpu_data_out), .cpu_mreq_n(mreq_n), .cpu_rd_n(rd_n),
        .cpu_wr_n(wr_n), .cpu_rfsh_n(rfsh_n), .ram_read_data(ram_data),
        .cpu_wait_n(cpu_wait_n), .loader_write(loader_main_write),
        .loader_address(loader_main_address), .loader_write_data(loader_write_data),
        .loader_upper_complete(upper_transaction_complete),
        .video_clock(pixel_clock), .video_address({1'b0,display_address}),
        .video_data(display_data), .memory_clock(controller_clock),
        .memory_reset(!controller_reset_n), .line_request(line_request),
        .line_ready(line_ready), .line_write(line_write),
        .line_address(line_address), .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid), .line_read_data(line_read_data),
        .fault_timeout(fault_timeout), .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost));
`else
`ifdef NEXTTANG_SPEC256_SD_PACK
    assign spec256_pack_consumer_ready = 1'b1;
`endif
    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-main-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-main-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-main-bank2.mem"))
    ) machine_ram (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_main_write || memory_write),
        .write_address(loader_main_write ? loader_main_address : cpu_address),
        .write_data(loader_main_write ? loader_write_data : cpu_data_out),
`else
        .write_enable(memory_write),
        .write_address(cpu_address),
        .write_data(cpu_data_out),
`endif
        .read_data(ram_data),
        // Port B feeds the ordinary renderer that resolves 0xFF passthrough
        // pixels.  The screen lives at 0x4000 of this page, as it does in the
        // plain profile.
        .port_b_clock(pixel_clock),
        .port_b_address({3'b010, display_address}),
        .port_b_data(display_data)
    );
`endif

    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane0-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane0-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane0-bank2.mem")))
    spec256_ram_0 (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_graphics_ram_write[0] ||
                      (spec256_graphics_write[0] &&
                       spec256_graphics_address[15:14] != 2'b00)),
        .write_address(loader_graphics_ram_write[0] ?
                       loader_graphics_ram_address :
                       spec256_graphics_address[15:0]),
        .write_data(loader_graphics_ram_write[0] ? loader_write_data :
                    spec256_graphics_data_out[7:0]),
`else
        .write_enable(spec256_graphics_write[0] &&
                      spec256_graphics_address[15:14] != 2'b00),
        .write_address(spec256_graphics_address[15:0]),
        .write_data(spec256_graphics_data_out[7:0]),
`endif
        .read_data(spec256_graphics_ram_data[7:0]),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_display_address),
        .port_b_data(spec256_plane_display_data[7:0])
    );

    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane1-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane1-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane1-bank2.mem")))
    spec256_ram_1 (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_graphics_ram_write[1] ||
                      (spec256_graphics_write[1] &&
                       spec256_graphics_address[31:30] != 2'b00)),
        .write_address(loader_graphics_ram_write[1] ?
                       loader_graphics_ram_address :
                       spec256_graphics_address[31:16]),
        .write_data(loader_graphics_ram_write[1] ? loader_write_data :
                    spec256_graphics_data_out[15:8]),
`else
        .write_enable(spec256_graphics_write[1] &&
                      spec256_graphics_address[31:30] != 2'b00),
        .write_address(spec256_graphics_address[31:16]),
        .write_data(spec256_graphics_data_out[15:8]),
`endif
        .read_data(spec256_graphics_ram_data[15:8]),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_display_address),
        .port_b_data(spec256_plane_display_data[15:8])
    );

    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane2-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane2-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane2-bank2.mem")))
    spec256_ram_2 (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_graphics_ram_write[2] ||
                      (spec256_graphics_write[2] &&
                       spec256_graphics_address[47:46] != 2'b00)),
        .write_address(loader_graphics_ram_write[2] ?
                       loader_graphics_ram_address :
                       spec256_graphics_address[47:32]),
        .write_data(loader_graphics_ram_write[2] ? loader_write_data :
                    spec256_graphics_data_out[23:16]),
`else
        .write_enable(spec256_graphics_write[2] &&
                      spec256_graphics_address[47:46] != 2'b00),
        .write_address(spec256_graphics_address[47:32]),
        .write_data(spec256_graphics_data_out[23:16]),
`endif
        .read_data(spec256_graphics_ram_data[23:16]),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_display_address),
        .port_b_data(spec256_plane_display_data[23:16])
    );

    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane3-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane3-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane3-bank2.mem")))
    spec256_ram_3 (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_graphics_ram_write[3] ||
                      (spec256_graphics_write[3] &&
                       spec256_graphics_address[63:62] != 2'b00)),
        .write_address(loader_graphics_ram_write[3] ?
                       loader_graphics_ram_address :
                       spec256_graphics_address[63:48]),
        .write_data(loader_graphics_ram_write[3] ? loader_write_data :
                    spec256_graphics_data_out[31:24]),
`else
        .write_enable(spec256_graphics_write[3] &&
                      spec256_graphics_address[63:62] != 2'b00),
        .write_address(spec256_graphics_address[63:48]),
        .write_data(spec256_graphics_data_out[31:24]),
`endif
        .read_data(spec256_graphics_ram_data[31:24]),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_display_address),
        .port_b_data(spec256_plane_display_data[31:24])
    );

    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane4-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane4-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane4-bank2.mem")))
    spec256_ram_4 (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_graphics_ram_write[4] ||
                      (spec256_graphics_write[4] &&
                       spec256_graphics_address[79:78] != 2'b00)),
        .write_address(loader_graphics_ram_write[4] ?
                       loader_graphics_ram_address :
                       spec256_graphics_address[79:64]),
        .write_data(loader_graphics_ram_write[4] ? loader_write_data :
                    spec256_graphics_data_out[39:32]),
`else
        .write_enable(spec256_graphics_write[4] &&
                      spec256_graphics_address[79:78] != 2'b00),
        .write_address(spec256_graphics_address[79:64]),
        .write_data(spec256_graphics_data_out[39:32]),
`endif
        .read_data(spec256_graphics_ram_data[39:32]),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_display_address),
        .port_b_data(spec256_plane_display_data[39:32])
    );

    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane5-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane5-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane5-bank2.mem")))
    spec256_ram_5 (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_graphics_ram_write[5] ||
                      (spec256_graphics_write[5] &&
                       spec256_graphics_address[95:94] != 2'b00)),
        .write_address(loader_graphics_ram_write[5] ?
                       loader_graphics_ram_address :
                       spec256_graphics_address[95:80]),
        .write_data(loader_graphics_ram_write[5] ? loader_write_data :
                    spec256_graphics_data_out[47:40]),
`else
        .write_enable(spec256_graphics_write[5] &&
                      spec256_graphics_address[95:94] != 2'b00),
        .write_address(spec256_graphics_address[95:80]),
        .write_data(spec256_graphics_data_out[47:40]),
`endif
        .read_data(spec256_graphics_ram_data[47:40]),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_display_address),
        .port_b_data(spec256_plane_display_data[47:40])
    );

    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane6-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane6-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane6-bank2.mem")))
    spec256_ram_6 (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_graphics_ram_write[6] ||
                      (spec256_graphics_write[6] &&
                       spec256_graphics_address[111:110] != 2'b00)),
        .write_address(loader_graphics_ram_write[6] ?
                       loader_graphics_ram_address :
                       spec256_graphics_address[111:96]),
        .write_data(loader_graphics_ram_write[6] ? loader_write_data :
                    spec256_graphics_data_out[55:48]),
`else
        .write_enable(spec256_graphics_write[6] &&
                      spec256_graphics_address[111:110] != 2'b00),
        .write_address(spec256_graphics_address[111:96]),
        .write_data(spec256_graphics_data_out[55:48]),
`endif
        .read_data(spec256_graphics_ram_data[55:48]),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_display_address),
        .port_b_data(spec256_plane_display_data[55:48])
    );

    nexttang_spectrum_ram #(
        .IMAGE_0(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane7-bank0.mem")),
        .IMAGE_1(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane7-bank1.mem")),
        .IMAGE_2(`NEXTTANG_SPEC256_INITIAL_IMAGE("spec256-plane7-bank2.mem")))
    spec256_ram_7 (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_graphics_ram_write[7] ||
                      (spec256_graphics_write[7] &&
                       spec256_graphics_address[127:126] != 2'b00)),
        .write_address(loader_graphics_ram_write[7] ?
                       loader_graphics_ram_address :
                       spec256_graphics_address[127:112]),
        .write_data(loader_graphics_ram_write[7] ? loader_write_data :
                    spec256_graphics_data_out[63:56]),
`else
        .write_enable(spec256_graphics_write[7] &&
                      spec256_graphics_address[127:126] != 2'b00),
        .write_address(spec256_graphics_address[127:112]),
        .write_data(spec256_graphics_data_out[63:56]),
`endif
        .read_data(spec256_graphics_ram_data[63:56]),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_display_address),
        .port_b_data(spec256_plane_display_data[63:56])
    );

`ifdef NEXTTANG_SPEC256_WRITE_TRACE
    // Diagnostic-only A/B recorder.  Arm on the PC-keyboard 5 key used to
    // leave Jetpac's selection screen, then preserve the first actual RAM
    // write presented to each plane's combined port.  Capturing after the
    // loader/CPU mux makes stale loader ownership directly observable.
    wire spec256_trace_key5_async = usb1_key1 == 8'h22 ||
        usb1_key2 == 8'h22 || usb1_key3 == 8'h22 || usb1_key4 == 8'h22 ||
        usb1_key5 == 8'h22 || usb1_key6 == 8'h22 || usb2_key1 == 8'h22 ||
        usb2_key2 == 8'h22 || usb2_key3 == 8'h22 || usb2_key4 == 8'h22 ||
        usb2_key5 == 8'h22 || usb2_key6 == 8'h22;
    reg spec256_trace_key5_meta = 1'b0;
    reg spec256_trace_key5_sync = 1'b0;
    reg spec256_trace_key5_previous = 1'b0;
    reg spec256_trace_armed = 1'b0;
    reg [7:0] spec256_trace_captured = 8'b0;
    reg [15:0] spec256_trace_address [0:7];
    reg [7:0] spec256_trace_data [0:7];
    reg [7:0] spec256_trace_loader = 8'b0;
    integer spec256_trace_index;

    always @(posedge cpu_clock) begin
        if (cpu_reset) begin
            spec256_trace_key5_meta <= 1'b0;
            spec256_trace_key5_sync <= 1'b0;
            spec256_trace_key5_previous <= 1'b0;
            spec256_trace_armed <= 1'b0;
            spec256_trace_captured <= 8'b0;
            spec256_trace_loader <= 8'b0;
            for (spec256_trace_index = 0; spec256_trace_index < 8;
                 spec256_trace_index = spec256_trace_index + 1) begin
                spec256_trace_address[spec256_trace_index] <= 16'b0;
                spec256_trace_data[spec256_trace_index] <= 8'b0;
            end
        end else begin
            spec256_trace_key5_meta <= spec256_trace_key5_async;
            spec256_trace_key5_sync <= spec256_trace_key5_meta;
            spec256_trace_key5_previous <= spec256_trace_key5_sync;
            if (spec256_trace_key5_sync && !spec256_trace_key5_previous) begin
                spec256_trace_armed <= 1'b1;
                spec256_trace_captured <= 8'b0;
                spec256_trace_loader <= 8'b0;
            end else if (spec256_trace_armed) begin
                for (spec256_trace_index = 0; spec256_trace_index < 8;
                     spec256_trace_index = spec256_trace_index + 1) begin
                    if (!spec256_trace_captured[spec256_trace_index] &&
                        (loader_graphics_ram_write[spec256_trace_index] ||
                         (spec256_graphics_write[spec256_trace_index] &&
                          spec256_graphics_address[spec256_trace_index*16+14 +: 2] != 2'b00))) begin
                        spec256_trace_captured[spec256_trace_index] <= 1'b1;
                        spec256_trace_loader[spec256_trace_index] <=
                            loader_graphics_ram_write[spec256_trace_index];
                        spec256_trace_address[spec256_trace_index] <=
                            loader_graphics_ram_write[spec256_trace_index] ?
                            loader_graphics_ram_address :
                            spec256_graphics_address[spec256_trace_index*16 +: 16];
                        spec256_trace_data[spec256_trace_index] <=
                            loader_graphics_ram_write[spec256_trace_index] ?
                            loader_write_data :
                            spec256_graphics_data_out[spec256_trace_index*8 +: 8];
                    end
                end
            end
        end
    end

    reg [18:0] spec256_trace_report_counter = 0;
    reg [2:0] spec256_trace_report_lane = 0;
    always @(posedge cpu_clock) begin
        if (cpu_reset) begin
            spec256_trace_report_counter <= 0;
            spec256_trace_report_lane <= 0;
        end else if (spec256_trace_report_counter == 19'd349999) begin
            spec256_trace_report_counter <= 0;
            spec256_trace_report_lane <= spec256_trace_report_lane + 1'b1;
        end else
            spec256_trace_report_counter <= spec256_trace_report_counter + 1'b1;
    end
`endif
`undef NEXTTANG_SPEC256_INITIAL_IMAGE
`else
`ifndef NEXTTANG_SPECTRUM48_USE_DDR3
    assign cpu_wait_n = 1'b1;

    nexttang_block_ram #(
        .ADDRESS_BITS(16),
        .IMAGE(RAM_IMAGE)
    ) machine_ram (
        .clock(cpu_clock),
        .write_enable(memory_write),
        .write_address(cpu_address),
        .write_data(cpu_data_out),
        .read_data(ram_data),
`ifdef NEXTTANG_SPECTRUM48_USE_ULA
        .port_b_clock(clock_7),
        .port_b_address({2'b01, ula_vram_address}),  // ULA screen bank at 0x4000
        .port_b_data(ula_vram_data)
`else
        .port_b_clock(pixel_clock),
        .port_b_address({3'b010, display_address}),  // screen lives at 0x4000
        .port_b_data(display_data)
`endif
    );
`endif
`endif

    // Port 0xFE is decoded on address bit 0 alone, as the original did. Reading
    // it returns the keyboard in the low five bits and EAR on bit 6.
    wire port_fe = !iorq_n && !cpu_address[0];
    wire port_kempston = !iorq_n && cpu_address[7:0] == 8'h1f;
`ifdef NEXTTANG_SPECTRUM128
    // Original 128K partial decode: A15 high and A1 low; A14 selects the
    // register-address/read port (FFFD family) or data-write port (BFFD).
    wire port_ay_select = !iorq_n && !cpu_address[1] &&
                          cpu_address[15] && cpu_address[14];
    wire port_ay_data = !iorq_n && !cpu_address[1] &&
                        cpu_address[15] && !cpu_address[14];
    wire [7:0] ay_read_data;
    wire [7:0] ay_channel_a, ay_channel_b, ay_channel_c;

    nexttang_ay8912 ay (
        .clock(cpu_clock), .reset(cpu_reset),
        .select_write(port_ay_select && !wr_n),
        .data_write(port_ay_data && !wr_n),
        .data_read(port_ay_select && !rd_n),
        .write_data(cpu_data_out), .read_data(ay_read_data),
        .channel_a(ay_channel_a), .channel_b(ay_channel_b),
        .channel_c(ay_channel_c)
    );
`else
    wire [7:0] ay_channel_a = 8'b0;
    wire [7:0] ay_channel_b = 8'b0;
    wire [7:0] ay_channel_c = 8'b0;
`endif

    wire [39:0] keys;
    wire [39:0] typist_keys;
    wire [39:0] post_tape_keys;
    wire [39:0] keyboard_keys;
    wire [39:0] usb_keyboard_keys;
    wire [4:0] usb_kempston_joystick;
    wire [39:0] runtime_uart_keys;
    wire [4:0] runtime_uart_joystick;

`ifdef NEXTTANG_SPEC256_RUNTIME
    nexttang_spec256_runtime_input runtime_input (
        .clock(cpu_clock),
        .reset(!cpu_reset_shift[3]),
        .enable(loader_ready),
        .byte_data(loader_byte),
        .byte_valid(loader_byte_valid),
        .keys(runtime_uart_keys),
        .joystick(runtime_uart_joystick)
    );
`else
    assign runtime_uart_keys = 40'b0;
    assign runtime_uart_joystick = 5'b0;
`endif
    wire [4:0] kempston_joystick =
        usb_kempston_joystick | runtime_uart_joystick;

    // The typist still types LOAD "" so a tape image loads on its own; a real
    // keyboard is simply held down alongside it.
    assign keys = typist_keys | post_tape_keys |
                  keyboard_keys | usb_keyboard_keys | runtime_uart_keys;

    wire [39:0] keyboard_keys_async;
    wire [7:0] keyboard_scancode_async;
    wire keyboard_scancode_valid_async;
    wire keyboard_byte_valid_async;
    wire keyboard_sync_valid_async;
    wire [7:0] keyboard_scancode;
    wire keyboard_scancode_valid;
    wire keyboard_byte_valid;
    wire keyboard_sync_valid;

    // The BL616 sends at 2 Mbaud, which the 3.5 MHz CPU clock cannot sample:
    // a bit is 1.75 clocks and the receiver counts 2, so the sampling point
    // walks 2.5 bit-times across a frame.  Receive in the 28 MHz domain at 14
    // clocks per bit instead.  The decoder moves with it because its output is
    // a key level the CPU domain samples, not a pulse that has to be caught.
    nexttang_bl616_keyboard #(
        .CLOCK_HZ(28000000),
        .BAUD_RATE(2000000)
    ) bl616_keyboard (
        .clock(clock_28),
        .reset(cpu_reset),
        .receive(bl616_uart_rx),
        .scancode(keyboard_scancode_async),
        .scancode_valid(keyboard_scancode_valid_async),
        .debug_byte_valid(keyboard_byte_valid_async),
        .debug_sync_valid(keyboard_sync_valid_async)
    );

    // The decoder shares the receiver's domain, so it takes the receiver's own
    // signals.  Handing it the CPU-domain copies would sample a 36 ns pulse at
    // 286 ns and drop nearly every key.
    nexttang_ps2_matrix key_decode (
        .clock(clock_28),
        .reset(cpu_reset),
        .scancode(keyboard_scancode_async),
        .scancode_valid(keyboard_scancode_valid_async),
        .keys(keyboard_keys_async)
    );

    // The debug flags are single-cycle 28 MHz pulses and the status reporter
    // samples at 3.5 MHz, so a pulse crossing raw is lost eight times out of
    // nine and the diagnostic reads "nothing arrived" while bytes are flowing.
    // Latch each event in the fast domain first; the reporter already holds
    // its flags from first assertion, so sticky here matches sticky there.
`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
    // Calibration: the host drives this pin, so a byte sent from the laptop
    // lights the same latch V14 would.  Without it a clear flag cannot be
    // told apart from a broken latch, which is the whole difficulty.
    wire loopback_byte_valid;
    nexttang_uart_receiver #(
        .CLOCK_HZ(28000000),
        .BAUD_RATE(230400)
    ) loopback_receiver (
        .clock(clock_28),
        .reset(cpu_reset),
        .receive(loopback_uart_rx),
        .data(),
        .data_valid(loopback_byte_valid)
    );
    reg loopback_byte_seen = 1'b0;
    always @(posedge clock_28)
        if (cpu_reset) loopback_byte_seen <= 1'b0;
        else if (loopback_byte_valid) loopback_byte_seen <= 1'b1;
`endif

    reg keyboard_byte_seen = 1'b0;
    reg keyboard_sync_seen = 1'b0;
    reg keyboard_scancode_seen = 1'b0;

    always @(posedge clock_28) begin
        if (cpu_reset) begin
            keyboard_byte_seen <= 1'b0;
            keyboard_sync_seen <= 1'b0;
            keyboard_scancode_seen <= 1'b0;
        end else begin
            if (keyboard_byte_valid_async) keyboard_byte_seen <= 1'b1;
            if (keyboard_sync_valid_async) keyboard_sync_seen <= 1'b1;
            if (keyboard_scancode_valid_async) keyboard_scancode_seen <= 1'b1;
        end
    end

    // Levels cross on two flops.  Key bits are independent and change far
    // slower than a frame, so they need no coherency beyond this.  Without the
    // synchroniser the tool reports hold violations from key_decode into the
    // Z80's data register.
    reg [39:0] keyboard_keys_meta = 40'b0;
    reg [39:0] keyboard_keys_sync = 40'b0;
    reg [7:0] keyboard_scancode_meta = 8'b0;
    reg [7:0] keyboard_scancode_sync = 8'b0;
    reg [2:0] keyboard_debug_meta = 3'b0;
    reg [2:0] keyboard_debug_sync = 3'b0;

    always @(posedge cpu_clock) begin
        keyboard_keys_meta <= keyboard_keys_async;
        keyboard_keys_sync <= keyboard_keys_meta;
        keyboard_scancode_meta <= keyboard_scancode_async;
        keyboard_scancode_sync <= keyboard_scancode_meta;
        keyboard_debug_meta <= {keyboard_scancode_seen, keyboard_sync_seen,
                                keyboard_byte_seen};
        keyboard_debug_sync <= keyboard_debug_meta;
    end

    assign keyboard_keys = keyboard_keys_sync;
    assign keyboard_scancode = keyboard_scancode_sync;
    assign keyboard_scancode_valid = keyboard_debug_sync[2];
    assign keyboard_sync_valid = keyboard_debug_sync[1];
    assign keyboard_byte_valid = keyboard_debug_sync[0];

`ifdef NEXTTANG_SPECTRUM48_USB_KEYBOARD
    wire usb_clock;
    wire usb_pll_locked;
    wire [1:0] usb1_type;
    wire [1:0] usb2_type;
    wire usb1_report, usb2_report;
    wire usb1_error, usb2_error;
    wire [7:0] usb1_modifiers, usb2_modifiers;
    wire [7:0] usb1_key1, usb1_key2, usb1_key3, usb1_key4, usb1_key5, usb1_key6;
    wire [7:0] usb2_key1, usb2_key2, usb2_key3, usb2_key4, usb2_key5, usb2_key6;
    wire [39:0] usb1_keyboard_keys;
    wire [39:0] usb2_keyboard_keys;
    wire usb1_dm_out, usb1_dp_out, usb1_output_enable;
    wire usb2_dm_out, usb2_dp_out, usb2_output_enable;
    wire [9:0] usb1_rom_address, usb2_rom_address;
    wire [3:0] usb1_rom_data, usb2_rom_data;
    wire usb1_rom_enable, usb2_rom_enable;
    wire [63:0] usb1_raw_report, usb2_raw_report;
    wire [63:0] usb1_hid_regs, usb2_hid_regs;
    wire [63:0] usb1_config_snapshot, usb2_config_snapshot;
    wire usb1_config_snapshot_valid, usb2_config_snapshot_valid;
    wire usb1_full_speed, usb2_full_speed;
    wire [15:0] usb1_speed_sample, usb2_speed_sample;
    wire usb1_byte_strobe, usb2_byte_strobe;
    wire usb1_packet_valid, usb2_packet_valid;
    wire usb1_game_left, usb1_game_right, usb1_game_up, usb1_game_down;
    wire usb1_game_a, usb1_game_b, usb1_game_x, usb1_game_y;
    wire usb2_game_left, usb2_game_right, usb2_game_up, usb2_game_down;
    wire usb2_game_a, usb2_game_b, usb2_game_x, usb2_game_y;
    wire usb1_game_select, usb1_game_start;
    wire usb2_game_select, usb2_game_start;
    wire [3:0] usb1_game_extra, usb2_game_extra;

    nexttang_console138k_usb_pll usb_pll (
        .clock_in(sys_clk), .clock_60(usb_clock), .locked(usb_pll_locked)
    );

    assign usb1_dn = usb1_output_enable ? usb1_dm_out : 1'bz;
    assign usb1_dp = usb1_output_enable ? usb1_dp_out : 1'bz;
    assign usb2_dn = usb2_output_enable ? usb2_dm_out : 1'bz;
    assign usb2_dp = usb2_output_enable ? usb2_dp_out : 1'bz;

`ifdef NEXTTANG_USB_PORT_TWO_ONLY
    assign usb1_type = 2'b00;
    assign usb1_report = 1'b0;
    assign usb1_error = 1'b0;
    assign usb1_modifiers = 8'b0;
    assign {usb1_key1, usb1_key2, usb1_key3, usb1_key4,
            usb1_key5, usb1_key6} = 48'b0;
    assign {usb1_dm_out, usb1_dp_out, usb1_output_enable} = 3'b000;
    assign {usb1_rom_address, usb1_rom_enable} = 11'b0;
    assign usb1_raw_report = 64'b0;
    assign usb1_hid_regs = 64'b0;
    assign usb1_config_snapshot = 64'b0;
    assign usb1_config_snapshot_valid = 1'b0;
    assign usb1_full_speed = 1'b0;
    assign usb1_speed_sample = 16'b0;
    assign usb1_byte_strobe = 1'b0;
    assign usb1_packet_valid = 1'b0;
    assign {usb1_game_left, usb1_game_right, usb1_game_up, usb1_game_down,
            usb1_game_a, usb1_game_b, usb1_game_x, usb1_game_y} = 8'b0;
    assign {usb1_game_select, usb1_game_start, usb1_game_extra} = 6'b0;
`else
    usb_hid_host #(
        .FULL_SPEED(1), .KEYBOARD_SUPPORT(1),
`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
        .MOUSE_SUPPORT(0), .GAME_SUPPORT(0)
`else
        .MOUSE_SUPPORT(0), .GAME_SUPPORT(1)
`endif
    ) usb_host_one (
        .clk(usb_clock), .reset(!usb_pll_locked), .cs(1'b1),
        .usb_dm_i(usb1_dn), .usb_dp_i(usb1_dp),
        .usb_dm_o(usb1_dm_out), .usb_dp_o(usb1_dp_out),
        .usb_oe(usb1_output_enable),
        .typ(usb1_type), .full_report(usb1_report), .connerr(usb1_error), .busy(),
        .key_modifiers(usb1_modifiers),
        .key_0(usb1_key1), .key_1(usb1_key2), .key_2(usb1_key3),
        .key_3(usb1_key4), .key_4(usb1_key5), .key_5(usb1_key6),
        .mouse_btn(), .mouse_dx(), .mouse_dy(),
        .game_l(usb1_game_left), .game_r(usb1_game_right),
        .game_u(usb1_game_up), .game_d(usb1_game_down),
        .game_a(usb1_game_a), .game_b(usb1_game_b),
        .game_x(usb1_game_x), .game_y(usb1_game_y),
        .game_sel(usb1_game_select), .game_sta(usb1_game_start),
        .game_extra(usb1_game_extra),
        .dbg_hid_report(usb1_raw_report), .dbg_hid_regs(usb1_hid_regs),
        .dbg_byte_strobe(usb1_byte_strobe),
        .dbg_packet_valid(usb1_packet_valid),
        .dbg_config_snapshot(usb1_config_snapshot),
        .dbg_config_snapshot_valid(usb1_config_snapshot_valid),
        .dbg_full_speed(usb1_full_speed),
        .dbg_speed_sample(usb1_speed_sample),
        .rom_addr(usb1_rom_address), .rom_dout(usb1_rom_data),
        .rom_en(usb1_rom_enable)
    );
`endif

    usb_hid_host #(
        .FULL_SPEED(1), .KEYBOARD_SUPPORT(1),
`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
        .MOUSE_SUPPORT(0), .GAME_SUPPORT(0)
`else
        .MOUSE_SUPPORT(0), .GAME_SUPPORT(1)
`endif
    ) usb_host_two (
        .clk(usb_clock), .reset(!usb_pll_locked), .cs(1'b1),
        .usb_dm_i(usb2_dn), .usb_dp_i(usb2_dp),
        .usb_dm_o(usb2_dm_out), .usb_dp_o(usb2_dp_out),
        .usb_oe(usb2_output_enable),
        .typ(usb2_type), .full_report(usb2_report), .connerr(usb2_error), .busy(),
        .key_modifiers(usb2_modifiers),
        .key_0(usb2_key1), .key_1(usb2_key2), .key_2(usb2_key3),
        .key_3(usb2_key4), .key_4(usb2_key5), .key_5(usb2_key6),
        .mouse_btn(), .mouse_dx(), .mouse_dy(),
        .game_l(usb2_game_left), .game_r(usb2_game_right),
        .game_u(usb2_game_up), .game_d(usb2_game_down),
        .game_a(usb2_game_a), .game_b(usb2_game_b),
        .game_x(usb2_game_x), .game_y(usb2_game_y),
        .game_sel(usb2_game_select), .game_sta(usb2_game_start),
        .game_extra(usb2_game_extra),
        .dbg_hid_report(usb2_raw_report), .dbg_hid_regs(usb2_hid_regs),
        .dbg_byte_strobe(usb2_byte_strobe),
        .dbg_packet_valid(usb2_packet_valid),
        .dbg_config_snapshot(usb2_config_snapshot),
        .dbg_config_snapshot_valid(usb2_config_snapshot_valid),
        .dbg_full_speed(usb2_full_speed),
        .dbg_speed_sample(usb2_speed_sample),
        .rom_addr(usb2_rom_address), .rom_dout(usb2_rom_data),
        .rom_en(usb2_rom_enable)
    );

`ifdef NEXTTANG_USB_PORT_TWO_ONLY
    usb_hid_host_rom usb_microcode (
        .clk(usb_clock), .addr(usb2_rom_address),
        .dout(usb2_rom_data), .en(usb2_rom_enable)
    );
`else
    usb_hid_host_dual_rom usb_microcode (
        .clk(usb_clock),
        .addra(usb1_rom_address), .douta(usb1_rom_data), .ena(usb1_rom_enable),
        .addrb(usb2_rom_address), .doutb(usb2_rom_data), .enb(usb2_rom_enable)
    );
`endif

    nexttang_usb_keyboard_matrix usb1_key_decode (
        .device_type(usb1_type), .modifiers(usb1_modifiers),
        .key1(usb1_key1), .key2(usb1_key2),
        .key3(usb1_key3), .key4(usb1_key4),
        .key5(usb1_key5), .key6(usb1_key6), .keys(usb1_keyboard_keys)
    );
    nexttang_usb_keyboard_matrix usb2_key_decode (
        .device_type(usb2_type), .modifiers(usb2_modifiers),
        .key1(usb2_key1), .key2(usb2_key2),
        .key3(usb2_key3), .key4(usb2_key4),
        .key5(usb2_key5), .key6(usb2_key6), .keys(usb2_keyboard_keys)
    );

    wire [4:0] usb1_kempston_async;
    wire [4:0] usb2_kempston_async;
`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
    assign usb1_kempston_async = 5'b00000;
    assign usb2_kempston_async = 5'b00000;
`else
    nexttang_usb_gamepad_kempston usb1_game_decode (
        .device_type(usb1_type),
        .left(usb1_game_left), .right(usb1_game_right),
        .up(usb1_game_up), .down(usb1_game_down),
        .a(usb1_game_a), .b(usb1_game_b),
        .x(usb1_game_x), .y(usb1_game_y),
        .select_button(usb1_game_select),
        .start_button(usb1_game_start),
        .extra_buttons(usb1_game_extra),
        .joystick(usb1_kempston_async)
    );
    nexttang_usb_gamepad_kempston usb2_game_decode (
        .device_type(usb2_type),
        .left(usb2_game_left), .right(usb2_game_right),
        .up(usb2_game_up), .down(usb2_game_down),
        .a(usb2_game_a), .b(usb2_game_b),
        .x(usb2_game_x), .y(usb2_game_y),
        .select_button(usb2_game_select),
        .start_button(usb2_game_start),
        .extra_buttons(usb2_game_extra),
        .joystick(usb2_kempston_async)
    );
`endif

`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
    // The first hardware test deliberately isolates the socket containing the
    // keyboard. A hub or unsupported device in the other socket must not be
    // allowed to masquerade as keyboard usages while the host is brought up.
    wire [39:0] usb_keyboard_keys_async = usb2_keyboard_keys;
`else
    wire [39:0] usb_keyboard_keys_async =
        usb1_keyboard_keys | usb2_keyboard_keys;
`endif
    reg [39:0] usb_keyboard_keys_meta = 0;
    reg [39:0] usb_keyboard_keys_sync = 0;
    reg [4:0] usb_kempston_meta = 0;
    reg [4:0] usb_kempston_sync = 0;
    always @(posedge cpu_clock) begin
        usb_keyboard_keys_meta <= usb_keyboard_keys_async;
        usb_keyboard_keys_sync <= usb_keyboard_keys_meta;
        usb_kempston_meta <= usb1_kempston_async | usb2_kempston_async;
        usb_kempston_sync <= usb_kempston_meta;
    end
    assign usb_keyboard_keys = usb_keyboard_keys_sync;
    assign usb_kempston_joystick = usb_kempston_sync;
`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
    wire usb_keyboard_connected = usb2_type == 2'd1;
    wire usb_keyboard_report = usb2_report;
`else
    wire usb_keyboard_connected = usb1_type == 2'd1 || usb2_type == 2'd1;
    wire usb_keyboard_report = usb1_report | usb2_report;
`endif
    wire usb1_keycode_present = |usb1_key1 | |usb1_key2 | |usb1_key3 |
                                |usb1_key4 | |usb1_key5 | |usb1_key6;
    wire usb2_keycode_present = |usb2_key1 | |usb2_key2 | |usb2_key3 |
                                |usb2_key4 | |usb2_key5 | |usb2_key6;
`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
    wire usb_keycode_present = usb2_keycode_present;
`else
    wire usb_keycode_present = usb1_keycode_present | usb2_keycode_present;
`endif
    reg usb_report_seen = 1'b0;
    always @(posedge usb_clock) begin
        if (!usb_pll_locked)
            usb_report_seen <= 1'b0;
        else if (usb_keyboard_report)
            usb_report_seen <= 1'b1;
    end
`else
    assign usb_keyboard_keys = 40'b0;
    assign usb_kempston_joystick = 5'b00000;
`endif

`ifdef NEXTTANG_CLASSIC_SD_LOADER
    // The loader owns only boot/menu policy.  The existing USB host remains
    // the single input implementation and the machine sees the same keyboard
    // and Kempston levels once the menu releases it.
    wire loader_directory_start,loader_file_start,loader_entry_valid;
    wire[31:0]loader_directory_cluster,loader_file_cluster,loader_file_size;
    wire[7:0]loader_entry_attributes,loader_entry_name_length;
    wire[31:0]loader_entry_cluster,loader_entry_size;
    wire[7:0]loader_entry_name_index,loader_entry_name_data;
    wire[7:0]loader_storage_file_byte;wire[31:0]loader_storage_file_offset;
    wire loader_storage_file_valid,loader_storage_ready,loader_storage_busy;
    wire loader_storage_done,loader_storage_error,loader_file_pause;
    wire[2:0]loader_storage_diagnostic;
    wire loader_menu_ready,loader_menu_active,loader_basic_selected;
    wire loader_content_start,loader_content_valid,loader_content_done;
    wire[7:0]loader_content_byte;wire[31:0]loader_content_offset;
    wire[2:0]loader_content_format;wire loader_catalog_error;
    wire[5:0]loader_selection,loader_file_count;
    wire[5:0]loader_display_entry,loader_display_name_index;
    wire[7:0]loader_display_name_data,loader_display_name_length;

    function loader_has_hid_code;
        input[7:0]code;
        begin loader_has_hid_code=usb1_key1==code||usb1_key2==code||
            usb1_key3==code||usb1_key4==code||usb1_key5==code||usb1_key6==code||
            usb2_key1==code||usb2_key2==code||usb2_key3==code||usb2_key4==code||
            usb2_key5==code||usb2_key6==code;end
    endfunction
    wire loader_up_async=loader_has_hid_code(8'h52)||usb1_game_up||usb2_game_up;
    wire loader_down_async=loader_has_hid_code(8'h51)||usb1_game_down||usb2_game_down;
    wire loader_activate_async=loader_has_hid_code(8'h28)||usb1_game_a||usb1_game_x||
                               usb2_game_a||usb2_game_x;
    wire loader_menu_async=loader_has_hid_code(8'h29)||usb1_game_select||usb2_game_select;
    reg[3:0]loader_input_meta=0,loader_input_sync=0,loader_input_previous=0;
    always@(posedge sys_clk)begin
        loader_input_meta<={loader_menu_async,loader_activate_async,
                           loader_down_async,loader_up_async};
        loader_input_sync<=loader_input_meta;loader_input_previous<=loader_input_sync;
    end
    wire loader_nav_up=loader_input_sync[0]&&!loader_input_previous[0];
    wire loader_nav_down=loader_input_sync[1]&&!loader_input_previous[1];
    wire loader_activate=loader_input_sync[2]&&!loader_input_previous[2];
    wire loader_open_menu=loader_input_sync[3]&&!loader_input_previous[3];

    nexttang_fat32_storage storage(
        .clock(sys_clk),.reset(!machine_pll_locked),
        .directory_start(loader_directory_start),.directory_cluster(loader_directory_cluster),
        .file_start(loader_file_start),.file_cluster(loader_file_cluster),.file_size(loader_file_size),
        .file_pause(loader_file_pause),.entry_valid(loader_entry_valid),
        .entry_attributes(loader_entry_attributes),.entry_cluster(loader_entry_cluster),
        .entry_size(loader_entry_size),.entry_name_length(loader_entry_name_length),
        .entry_name_index(loader_entry_name_index),.entry_name_data(loader_entry_name_data),
        .file_byte(loader_storage_file_byte),.file_offset(loader_storage_file_offset),
        .file_byte_valid(loader_storage_file_valid),.ready(loader_storage_ready),
        .busy(loader_storage_busy),.operation_done(loader_storage_done),.error(loader_storage_error),
        .diagnostic_code(loader_storage_diagnostic),
        .sd_clk(sd_clk),.sd_mosi(sd_mosi),.sd_miso(sd_miso),.sd_cs(sd_cs));

    nexttang_loader_catalog #(
`ifdef NEXTTANG_SPECTRUM48_USE_SPEC256
        .MACHINE_KIND(2), .MAX_ENTRIES(8), .MAX_NAME(24)
`elsif NEXTTANG_SPECTRUM128
        .MACHINE_KIND(1)
`else
        .MACHINE_KIND(0)
`endif
    ) loader_catalog(
        .clock(sys_clk),.reset(!machine_pll_locked),.storage_ready(loader_storage_ready),
        .storage_busy(loader_storage_busy),.storage_done(loader_storage_done),
        .storage_error(loader_storage_error),.directory_start(loader_directory_start),
        .directory_cluster(loader_directory_cluster),.entry_valid(loader_entry_valid),
        .entry_attributes(loader_entry_attributes),.entry_cluster(loader_entry_cluster),
        .entry_size(loader_entry_size),.entry_name_length(loader_entry_name_length),
        .entry_name_index(loader_entry_name_index),.entry_name_data(loader_entry_name_data),
        .file_start(loader_file_start),.file_cluster(loader_file_cluster),.file_size(loader_file_size),
        .storage_file_byte(loader_storage_file_byte),.storage_file_offset(loader_storage_file_offset),
        .storage_file_valid(loader_storage_file_valid),.navigate_up(loader_nav_up),
        .navigate_down(loader_nav_down),.activate(loader_activate),.open_menu(loader_open_menu),
        .menu_ready(loader_menu_ready),.menu_active(loader_menu_active),
        .selection(loader_selection),.file_count(loader_file_count),
        .display_clock(pixel_clock),
        .display_entry(loader_display_entry),.display_name_index(loader_display_name_index),
        .display_name_data(loader_display_name_data),.display_name_length(loader_display_name_length),
        .basic_selected(loader_basic_selected),.content_start(loader_content_start),
        .content_byte(loader_content_byte),.content_offset(loader_content_offset),
        .content_valid(loader_content_valid),.content_done(loader_content_done),
        .content_format(loader_content_format),.error(loader_catalog_error));

`ifndef NEXTTANG_SPECTRUM48_USE_SPEC256
    reg classic_loader_run=0,classic_loader_tape_selected=0;
    always@(posedge sys_clk)begin
        if(!machine_pll_locked)begin classic_loader_run<=0;
            classic_loader_tape_selected<=0;end
        else begin
            if(loader_basic_selected||loader_content_start)classic_loader_run<=1;
            if(loader_content_start)classic_loader_tape_selected<=1;
        end
    end
    reg classic_loader_run_meta=0,classic_loader_run_cpu=0;
    reg classic_loader_tape_meta=0,classic_loader_tape_cpu=0;
    always@(posedge cpu_clock)begin classic_loader_run_meta<=classic_loader_run;
        classic_loader_run_cpu<=classic_loader_run_meta;
        classic_loader_tape_meta<=classic_loader_tape_selected;
        classic_loader_tape_cpu<=classic_loader_tape_meta;end
    wire classic_loader_hold_reset_cpu=!classic_loader_run_cpu;
`endif
`endif
    wire [4:0] key_columns;
    wire typing_finished;

`ifdef NEXTTANG_CLASSIC_SD_LOADER
    wire tape_ear,tape_active,tape_finished,tape_fault,tape_fault_unsupported;
`ifdef NEXTTANG_SPEC256_SD_PACK
    wire [6:0] spec256_pack_fifo_level;
    wire spec256_pack_fifo_full;
    assign loader_file_pause = spec256_pack_fifo_level >= 11'd48;
    nexttang_async_byte_fifo_small spec256_pack_fifo (
        .write_clock(sys_clk), .write_reset(!machine_pll_locked),
        .write_clear(loader_content_start), .write_data(loader_content_byte),
        .write_enable(loader_content_valid), .write_full(spec256_pack_fifo_full),
        .write_level(spec256_pack_fifo_level), .read_clock(cpu_clock),
        .read_reset(!cpu_reset_shift[3]), .read_clear(loader_content_start),
        .read_data(spec256_pack_byte), .read_valid(spec256_pack_byte_valid),
        .read_pop(spec256_pack_byte_pop));
    assign typist_keys=40'b0; assign post_tape_keys=40'b0;
    assign typing_finished=1'b1; assign tape_ear=1'b0;
    assign tape_active=loader_content_valid||spec256_pack_byte_valid;
    assign tape_finished=loader_content_done&&!spec256_pack_byte_valid;
    assign tape_fault=loader_catalog_error||loader_storage_error||
                      (loader_content_valid&&spec256_pack_fifo_full);
    assign tape_fault_unsupported=1'b0;
`elsif NEXTTANG_SPECTRUM128
    // The 128 ROM boots with Tape Loader selected; ENTER is sufficient.
    nexttang_post_tape_key_sequencer #(.CLOCK_HZ(3500000),.START_DELAY_MS(3000),
        .HOLD_MS(140),.KEY_ROW(6),.KEY_COLUMN(0)) typist(
        .clock(cpu_clock),.reset(cpu_reset||!classic_loader_tape_cpu),
        .start(1'b1),.keys(typist_keys),.finished(typing_finished));
`else
    nexttang_load_key_sequencer #(.CLOCK_HZ(3500000),.START_DELAY_MS(3000)) typist(
        .clock(cpu_clock),.reset(cpu_reset||!classic_loader_tape_cpu),
        .keys(typist_keys),.finished(typing_finished));
`endif
`ifndef NEXTTANG_SPEC256_SD_PACK
    assign post_tape_keys=40'b0;
    nexttang_classic_tape_loader tape_loader(
        .write_clock(sys_clk),.write_reset(!machine_pll_locked),
        .content_start(loader_content_start),.content_format(loader_content_format),
        .content_byte(loader_content_byte),.content_valid(loader_content_valid),
        .content_done(loader_content_done),.file_pause(loader_file_pause),
        .tape_clock(cpu_clock),.tape_reset(cpu_reset),.play_start(typing_finished),
        .ear(tape_ear),.active(tape_active),.finished(tape_finished),
        .fault(tape_fault),.fault_unsupported(tape_fault_unsupported));
`endif
`elsif NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
    assign typist_keys = 40'b0;
    assign post_tape_keys = 40'b0;
    assign typing_finished = 1'b1;
    wire tape_ear = 1'b0;
`elsif NEXTTANG_SPECTRUM128
    // The 48K bring-up profile types a demonstration BASIC program by itself.
    // A 128K ROM starts in a menu, so those same synthetic keys repeatedly
    // activate Tape Loader and obscure physical keyboard input.
    assign typist_keys = 40'b0;
    assign post_tape_keys = 40'b0;
    assign typing_finished = 1'b1;
    wire tape_ear = 1'b0;
`elsif NEXTTANG_SPECTRUM48_USE_SNAPSHOT
    assign typist_keys = 40'b0;
    assign typing_finished = 1'b1;
    wire snapshot_menu_finished;

`ifdef NEXTTANG_SPECTRUM48_USE_SPEC256
`ifdef NEXTTANG_SPEC256_RUNTIME
    nexttang_spec256_runtime_key_sequencer #(
        .CLOCK_HZ(3500000)
    ) snapshot_menu_key (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .start(!snapshot_boot_active),
        .key_count(loader_launch_key_count),
        .key_0(loader_launch_key_0),
        .key_1(loader_launch_key_1),
        .key_2(loader_launch_key_2),
        .key_3(loader_launch_key_3),
        .start_delay_ms(loader_launch_start_delay_ms),
        .hold_ms(loader_launch_hold_ms),
        .gap_ms(loader_launch_gap_ms),
        .keys(post_tape_keys),
        .finished(snapshot_menu_finished)
    );
`elsif NEXTTANG_SPEC256_AUTOSTART_CHUCKIE
    // Chuckie Egg leaves the snapshot at its title screen: S enters the game
    // menu, then 1 selects a single player after that prompt has been drawn.
    nexttang_post_tape_key_sequencer #(
        .CLOCK_HZ(3500000),
        .START_DELAY_MS(2000),
        .HOLD_MS(140),
        .GAP_MS(4000),
        .KEY_ROW(1),
        .KEY_COLUMN(1),
        .SECOND_KEY_ENABLE(1),
        .SECOND_KEY_ROW(3),
        .SECOND_KEY_COLUMN(0)
    ) snapshot_menu_key (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .start(!snapshot_boot_active),
        .keys(post_tape_keys),
        .finished(snapshot_menu_finished)
    );
`else
    // Select Kempston joystick, then start the supplied Jetpac snapshot.  A
    // physical USB gamepad can then drive the original port 0x1f interface.
    nexttang_post_tape_key_sequencer #(
        .CLOCK_HZ(3500000),
        .START_DELAY_MS(2000),
        .HOLD_MS(140),
        .GAP_MS(300),
        .KEY_ROW(3),
        .KEY_COLUMN(3),
        .SECOND_KEY_ENABLE(1),
        .SECOND_KEY_ROW(3),
        .SECOND_KEY_COLUMN(4)
    ) snapshot_menu_key (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .start(!snapshot_boot_active),
        .keys(post_tape_keys),
        .finished(snapshot_menu_finished)
    );
`endif
`else
    // The ordinary snapshot target keeps the existing keyboard-selected
    // behaviour and only presses 5 to start.
    nexttang_post_tape_key_sequencer #(
        .CLOCK_HZ(3500000),
        .START_DELAY_MS(2000),
        .HOLD_MS(140),
        .KEY_ROW(3),
        .KEY_COLUMN(4)
    ) snapshot_menu_key (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .start(!snapshot_boot_active),
        .keys(post_tape_keys),
        .finished(snapshot_menu_finished)
    );
`endif
    wire tape_ear = 1'b0;
`elsif NEXTTANG_SPECTRUM48_USE_TAPE
    // The capture card takes about forty seconds to relock after the FPGA is
    // reconfigured, so a tape that starts at the ROM's own pace is already
    // past its header blocks before anything can be recorded or watched. Wait
    // out the relock so the typing and the first blocks are visible.
    nexttang_load_key_sequencer #(
        .CLOCK_HZ(3500000),
        .START_DELAY_MS(45000)
    ) typist (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .keys(typist_keys),
        .finished(typing_finished)
    );

    wire tape_ear;
    wire tape_active;
    wire tape_finished;
    wire tape_fault;
    wire tape_fault_unsupported;
    wire [7:0] tape_block;
    wire [16:0] tape_byte_position;

    nexttang_tzx_player #(
        .CLOCK_HZ(3500000),
        .TZX_BYTES(65536),
        .IMAGE("tape.mem")
    ) tape_player (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .start(typing_finished),
        .ear(tape_ear),
        .active(tape_active),
        .finished(tape_finished),
        .fault(tape_fault),
        .fault_unsupported(tape_fault_unsupported),
        .current_block(tape_block),
        .byte_position(tape_byte_position)
    );
`ifdef NEXTTANG_SPECTRUM48_POST_TAPE_S1
    wire post_tape_finished;
    nexttang_post_tape_key_sequencer #(
        .CLOCK_HZ(3500000),
        .START_DELAY_MS(2000),
        .HOLD_MS(140),
        // Chuckie Egg spends roughly three seconds leaving its title screen
        // after S. Wait until the player-count prompt is listening before 1.
        .GAP_MS(4000),
        .KEY_ROW(1),
        .KEY_COLUMN(1),
        .SECOND_KEY_ENABLE(1),
        .SECOND_KEY_ROW(3),
        .SECOND_KEY_COLUMN(0)
    ) post_tape_key (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .start(tape_finished && !tape_fault),
        .keys(post_tape_keys),
        .finished(post_tape_finished)
    );
`else
    assign post_tape_keys = 40'b0;
`endif
`else
    nexttang_key_sequencer #(.CLOCK_HZ(3500000)) typist (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .keys(typist_keys),
        .finished(typing_finished)
    );

    assign post_tape_keys = 40'b0;
    wire tape_ear = 1'b0;
`endif

    nexttang_keyboard_matrix keyboard (
        .row_select(cpu_address[15:8]),
        .keys(keys),
        .columns(key_columns)
    );
    reg [2:0] border_colour = 3'd0;
    wire beeper;

    nexttang_spectrum_beeper beeper_latch (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .iorq_n(iorq_n),
        .wr_n(wr_n),
        .address(cpu_address),
        .data(cpu_data_out),
        .beeper(beeper)
    );

    always @(posedge cpu_clock) begin
        if (cpu_reset)
            border_colour <= 3'd0;
        else if (port_fe && !wr_n)
            border_colour <= cpu_data_out[2:0];
    end

    always @(*) begin
        if (!iorq_n)
`ifdef NEXTTANG_SPECTRUM128
            cpu_data_in = port_ay_select && !rd_n ? ay_read_data :
                          port_fe ? {1'b1, tape_ear, 1'b1, key_columns} :
                          port_kempston ? {3'b000, kempston_joystick} : 8'hff;
`else
            cpu_data_in = port_fe
                ? {1'b1, tape_ear, 1'b1, key_columns} :
                port_kempston ? {3'b000, kempston_joystick} : 8'hff;
`endif
        else if (in_rom)
            cpu_data_in = rom_data;
        else
            cpu_data_in = ram_data;
    end

`ifdef NEXTTANG_SPECTRUM48_USE_SPEC256
    genvar spec256_lane;
    generate
        for (spec256_lane = 0; spec256_lane < 8; spec256_lane = spec256_lane + 1) begin : spec256_inputs
            wire [15:0] lane_address =
                spec256_graphics_address[spec256_lane * 16 +: 16];

            nexttang_spec256_input_mux lane_input (
                .address(lane_address),
                .io_request(spec256_graphics_iorq[spec256_lane]),
                .keys(keys),
                .joystick(kempston_joystick),
                .tape_ear(tape_ear),
                .rom_data(spec256_graphics_rom_data[spec256_lane * 8 +: 8]),
                .ram_data(spec256_graphics_ram_data[spec256_lane * 8 +: 8]),
                .data(spec256_graphics_data_in[spec256_lane * 8 +: 8])
            );
        end
    endgenerate
`endif

    reg [2:0] border_meta = 3'd0;
    reg [2:0] border_pixel = 3'd0;
    reg [2:0] border_ula_meta = 3'd0;
    reg [2:0] border_ula = 3'd0;

    always @(posedge clock_14) begin
        border_ula_meta <= border_colour;
        border_ula <= border_ula_meta;
    end

    always @(posedge pixel_clock) begin
        border_meta  <= border_colour;
        border_pixel <= border_meta;
    end

    // ------------------------------------------------------------------ video
    wire timing_hsync;
    wire timing_vsync;
    wire timing_data_enable;
    wire [10:0] horizontal_position;
    wire [9:0]  vertical_position;

    nexttang_video_timing timing (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .hsync(timing_hsync),
        .vsync(timing_vsync),
        .data_enable(timing_data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    wire hsync;
    wire vsync;
    wire data_enable;
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;

`ifdef NEXTTANG_SPECTRUM48_USE_ULA
    // The imported timing and ULA modules generate the native 48K raster.  A
    // frame buffer is the explicit 50 Hz -> 60 Hz clock and cadence boundary;
    // it doubles the qualified 360x288 source to 720x576 inside 720p.
    wire ula_frame_sync;
    wire ula_hdmi_pixel_enable;
    wire ula_hdmi_frame_lock;
    wire ula_hblank_n;
    wire ula_vblank_n;
    wire ula_hsync_n;
    wire ula_vsync_n;
    wire [8:0] ula_hc;
    wire [8:0] ula_vc;
    wire [8:0] ula_cvc;
    wire [8:0] ula_whc;
    wire [8:0] ula_wvc;
    wire [8:0] ula_phc;
    wire [1:0] ula_subpixel;
    wire ula_interrupt;
    wire ula_line_interrupt;

    zxula_timing ula_timing (
        .i_CLK_28(clock_28),
        .i_50_60(1'b0),
        .i_timing(3'b000),
        .i_cu_offset(8'h00),
        .i_CLK_7(clock_7),
        .o_vblank_n(ula_vblank_n),
        .o_hblank_n(ula_hblank_n),
        .o_hsync_n(ula_hsync_n),
        .o_vsync_n(ula_vsync_n),
        .o_frame_sync(ula_frame_sync),
        .o_hdmi_pixel_en(ula_hdmi_pixel_enable),
        .o_hdmi_frame_lock(ula_hdmi_frame_lock),
        .o_hc_ula(ula_hc),
        .o_vc_ula(ula_vc),
        .o_vc_cu(ula_cvc),
        .o_whc(ula_whc),
        .o_wvc(ula_wvc),
        .o_phc(ula_phc),
        .center(1'b1),
        .o_sc(ula_subpixel),
        .i_inten_ula_n(1'b0),
        .i_inten_line(1'b0),
        .i_int_line(9'b0),
        .o_int_ula(ula_interrupt),
        .o_int_line(ula_line_interrupt)
    );

    wire ula_shadow;
    wire ula_vram_read;
    wire ula_border;
    wire [7:0] ula_pixel;
    wire ula_select_background;
    wire ula_clipped;
    wire [7:0] ula_floating_bus;
    wire ula_wait_n;
    wire ula_cpu_contend;

    zxula ula (
        .i_CLK_7(clock_7),
        .i_CLK_14(clock_14),
        .i_CLK_CPU(cpu_clock),
        .i_cpu_mreq_n(mreq_n),
        .i_cpu_iorq_n(iorq_n),
        .i_hc(ula_hc),
        .i_vc(ula_vc),
        .i_phc(ula_phc),
        .i_timing_pentagon(1'b0),
        .i_timing_p3(1'b0),
        .i_port_ff_reg(6'b0),
        .i_port_fe_border(border_ula),
        .i_ula_shadow_en(1'b0),
        .i_ulanext_en(1'b0),
        .i_ulanext_format(8'hff),
        .i_ulap_en(1'b0),
        .o_ula_vram_a(ula_vram_address),
        .o_ula_shadow(ula_shadow),
        .o_ula_vram_rd(ula_vram_read),
        .i_ula_vram_d(ula_vram_data),
        .o_ula_border(ula_border),
        .o_ula_pixel(ula_pixel),
        .o_ula_select_bgnd(ula_select_background),
        .o_ula_clipped(ula_clipped),
        .i_ula_clip_x1(8'h00),
        .i_ula_clip_x2(8'hff),
        .i_ula_clip_y1(8'h00),
        .i_ula_clip_y2(8'hbf),
        .i_ula_scroll_x(8'h00),
        .i_ula_scroll_y(8'h00),
        .i_ula_fine_scroll_x(1'b0),
        .i_p3_floating_bus(8'hff),
        .o_ula_floating_bus(ula_floating_bus),
        .i_contention_en(1'b0),
        .i_contention_port(1'b0),
        .i_contention_memory(1'b0),
        .o_cpu_wait_n(ula_wait_n),
        .o_cpu_contend(ula_cpu_contend)
    );

    wire capture_frame_start;
    wire capture_pixel_valid;
    wire [8:0] capture_x;
    wire [8:0] capture_y;
    wire [7:0] capture_pixel;
    wire capture_protocol_error;

    nexttang_ula_capture capture (
        .clock(clock_7),
        .reset(!machine_pll_locked),
        .frame_sync(ula_frame_sync),
        .pixel_valid(ula_hdmi_pixel_enable),
        .pixel(ula_pixel),
        .capture_frame_start(capture_frame_start),
        .capture_pixel_valid(capture_pixel_valid),
        .capture_x(capture_x),
        .capture_y(capture_y),
        .capture_pixel(capture_pixel),
        .protocol_error(capture_protocol_error)
    );

    wire scaled_frame_valid;
    wire scaled_overrun;
    wire [7:0] scaled_pixel;
    wire output_frame_start = horizontal_position == 0 && vertical_position == 0;

    nexttang_framebuffer_scaler scaler (
        .source_clock(clock_7),
        .source_reset(!machine_pll_locked),
        .source_frame_start(capture_frame_start),
        .source_pixel_valid(capture_pixel_valid),
        .source_x(capture_x),
        .source_y(capture_y),
        .source_pixel(capture_pixel),
        .source_overrun(scaled_overrun),
        .output_clock(pixel_clock),
        .output_reset(pixel_reset),
        .output_frame_start(output_frame_start),
        .output_hsync(timing_hsync),
        .output_vsync(timing_vsync),
        .output_data_enable(timing_data_enable),
        .output_x(horizontal_position),
        .output_y(vertical_position),
        .scaled_hsync(hsync),
        .scaled_vsync(vsync),
        .scaled_data_enable(data_enable),
        .scaled_pixel(scaled_pixel),
        .output_frame_valid(scaled_frame_valid)
    );

    nexttang_ula_palette palette (
        .palette_index(scaled_pixel),
        .red(red),
        .green(green),
        .blue(blue)
    );
`elsif NEXTTANG_SPECTRUM48_USE_SPEC256
    wire [7:0] spec256_palette_index;
    wire spec256_passthrough;
    wire [15:0] spec256_background_address;
    wire [7:0] spec256_background_data;
`ifdef NEXTTANG_SPEC256_RUNTIME
    wire spec256_background_valid = loader_background_valid;
`else
    wire spec256_background_valid = SPEC256_BACKGROUND_IMAGE != "";
`endif
    reg [7:0] spec256_palette_index_q = 8'b0;
    reg spec256_passthrough_q = 1'b0;
    reg spec256_hsync_q = 1'b0;
    reg spec256_vsync_q = 1'b0;
    reg spec256_data_enable_q = 1'b0;

    // Graphical colour and the ordinary Spectrum colour are produced by two
    // renderers reading the same coordinates, each one registered stage from
    // its own shift register, so their outputs land on the same pixel.
    wire [7:0] spec256_red;
    wire [7:0] spec256_green;
    wire [7:0] spec256_blue;
    wire [7:0] ordinary_red;
    wire [7:0] ordinary_green;
    wire [7:0] ordinary_blue;

    reg spec256_previous_vsync = 1'b0;
    reg [4:0] spec256_flash_counter = 5'b0;

    always @(posedge pixel_clock) begin
        if (pixel_reset) begin
            spec256_previous_vsync <= 1'b0;
            spec256_flash_counter <= 5'b0;
        end else begin
            spec256_previous_vsync <= vsync;
            if (vsync && !spec256_previous_vsync)
                spec256_flash_counter <= spec256_flash_counter + 1'b1;
        end
    end

    assign hsync = spec256_hsync_q;
    assign vsync = spec256_vsync_q;
    assign data_enable = spec256_data_enable_q;

    always @(posedge pixel_clock) begin
        if (pixel_reset) begin
            spec256_palette_index_q <= 8'b0;
            spec256_passthrough_q <= 1'b0;
            spec256_hsync_q <= 1'b0;
            spec256_vsync_q <= 1'b0;
            spec256_data_enable_q <= 1'b0;
        end else begin
            // Break the coordinate -> palette -> TMDS path at the pixel
            // boundary and delay the accompanying timing signals equally.
            spec256_palette_index_q <= spec256_palette_index;
            spec256_passthrough_q <= spec256_passthrough;
            spec256_hsync_q <= timing_hsync;
            spec256_vsync_q <= timing_vsync;
            spec256_data_enable_q <= timing_data_enable;
        end
    end

    nexttang_spec256_display display (
        .pixel_clock(pixel_clock),
        .reset(pixel_reset),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position),
        .data_enable(data_enable),
        .memory_address(spec256_display_address),
        .memory_data(spec256_display_data),
        .background_address(spec256_background_address),
        .background_data(spec256_background_data),
        .background_valid(spec256_background_valid),
        .palette_index(spec256_palette_index),
        .passthrough(spec256_passthrough)
    );

    // One 320x200 background.  Block RAM holds exactly one on this device;
    // a pack may carry up to eight and the loader stores the first.
    nexttang_block_ram #(
        .ADDRESS_BITS(16),
        .IMAGE(SPEC256_BACKGROUND_IMAGE)
    ) spec256_background (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_background_write),
        .write_address(loader_background_address),
        .write_data(loader_write_data),
`else
        // loader_write_data is declared only under NEXTTANG_SPEC256_RUNTIME,
        // so it has to be inside this guard with the rest of the write port.
        // Outside it the background is preloaded from SPEC256_BACKGROUND_IMAGE
        // and write_enable is tied low, so the data is a don't-care.
        .write_enable(1'b0),
        .write_address(16'b0),
        .write_data(8'b0),
`endif
        .read_data(),
        .port_b_clock(pixel_clock),
        .port_b_address(spec256_background_address),
        .port_b_data(spec256_background_data)
    );

    // The ordinary renderer supplies the colour for pixels the artist left
    // unrecoloured.  Reusing it keeps one owner for attribute, bright and
    // flash handling instead of a second copy that can drift.
    nexttang_spectrum_display #(.SCALE(3)) ordinary_display (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position),
        .data_enable(data_enable),
        .border_colour(border_pixel),
        .flash_phase(spec256_flash_counter[4]),
        .screen_address(display_address),
        .screen_data(display_data),
        .red(ordinary_red),
        .green(ordinary_green),
        .blue(ordinary_blue)
    );

    assign red = spec256_passthrough_q ? ordinary_red : spec256_red;
    assign green = spec256_passthrough_q ? ordinary_green : spec256_green;
    assign blue = spec256_passthrough_q ? ordinary_blue : spec256_blue;

`ifdef NEXTTANG_SPEC256_DISTRIBUTED_PALETTE
    nexttang_spec256_palette_distributed #(
`else
    nexttang_spec256_palette #(
`endif
`ifdef NEXTTANG_SPEC256_RUNTIME
        .IMAGE("")
`else
        .IMAGE(SPEC256_PALETTE_IMAGE)
`endif
    ) palette (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .write_enable(loader_palette_write),
        .write_index(loader_palette_index),
        .write_data(loader_palette_data),
`else
        .write_enable(1'b0),
        .write_index(8'b0),
        .write_data(24'b0),
`endif
        .index(spec256_palette_index_q),
        .red(spec256_red),
        .green(spec256_green),
        .blue(spec256_blue)
    );
`else
    assign hsync = timing_hsync;
    assign vsync = timing_vsync;
    assign data_enable = timing_data_enable;

    reg previous_vsync = 0;
    reg [4:0] flash_counter = 0;

    always @(posedge pixel_clock) begin
        if (pixel_reset) begin
            previous_vsync <= 0;
            flash_counter <= 0;
        end else begin
            previous_vsync <= vsync;
            if (vsync && !previous_vsync)
                flash_counter <= flash_counter + 1'b1;
        end
    end

    nexttang_spectrum_display #(.SCALE(3)) display (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position),
        .data_enable(data_enable),
        .border_colour(border_pixel),
        .flash_phase(flash_counter[4]),
        .screen_address(display_address),
        .screen_data(display_data),
        .red(red),
        .green(green),
        .blue(blue)
    );
`endif

    wire [2:0] serial_data;
    wire output_clock;

`ifdef NEXTTANG_HDMI_AUDIO
    wire audio_ce;
    wire signed [15:0] audio_sample;
    wire [15:0] audio_sample_words [1:0];
    wire hdmi_serial_clock;
    wire [10:0] hdmi_x;
    wire [9:0] hdmi_y;
    wire [10:0] hdmi_frame_width;
    wire [9:0] hdmi_frame_height;
    wire [10:0] hdmi_screen_width;
    wire [9:0] hdmi_screen_height;

    nexttang_classic_audio_pcm classic_audio_pcm (
        .clock(pixel_clock),
        .reset(cpu_reset),
        .beeper(beeper),
`ifdef NEXTTANG_SPECTRUM128
        .ay_enable(1'b1),
`else
        .ay_enable(1'b0),
`endif
        .ay_a(ay_channel_a), .ay_b(ay_channel_b), .ay_c(ay_channel_c),
        .audio_ce(audio_ce),
        .sample(audio_sample)
    );

    assign audio_sample_words[0] = audio_sample;
    assign audio_sample_words[1] = audio_sample;

`ifdef NEXTTANG_CLASSIC_SD_LOADER
    wire loader_overlay_enable;
    wire[7:0]loader_overlay_red,loader_overlay_green,loader_overlay_blue;
    nexttang_loader_overlay loader_overlay(
        .clock(pixel_clock),.enable(loader_menu_active),.ready(loader_menu_ready),
        .error(loader_storage_error||loader_catalog_error),
        .diagnostic_code(loader_storage_error?loader_storage_diagnostic:3'd0),
        .x(hdmi_x),.y(hdmi_y),
        .selection(loader_selection),.file_count(loader_file_count),
        .display_entry(loader_display_entry),.display_name_index(loader_display_name_index),
        .display_name_data(loader_display_name_data),.display_name_length(loader_display_name_length),
        .overlay_enable(loader_overlay_enable),.red(loader_overlay_red),
        .green(loader_overlay_green),.blue(loader_overlay_blue));
    reg[7:0]hdmi_red=0,hdmi_green=0,hdmi_blue=0;
    always@(posedge pixel_clock)begin
        hdmi_red<=loader_overlay_enable?loader_overlay_red:red;
        hdmi_green<=loader_overlay_enable?loader_overlay_green:green;
        hdmi_blue<=loader_overlay_enable?loader_overlay_blue:blue;
    end
`else
`ifdef NEXTTANG_SPEC256_WRITE_TRACE
    reg[7:0]hdmi_red=0,hdmi_green=0,hdmi_blue=0;
    always@(posedge pixel_clock)begin
        hdmi_red<=red;hdmi_green<=green;hdmi_blue<=blue;
    end
`else
    wire[7:0]hdmi_red=red,hdmi_green=green,hdmi_blue=blue;
`endif
`endif

    hdmi #(
        .VIDEO_ID_CODE(4),
        .VIDEO_REFRESH_RATE(60.0),
        .AUDIO_RATE(48000),
        .AUDIO_BIT_WIDTH(16),
        .VENDOR_NAME({"NextTang"}),
        .PRODUCT_DESCRIPTION({"Spectrum beeper", 8'd0})
    ) hdmi_transmitter (
        .clk_pixel_x5(serial_clock),
        .clk_pixel(pixel_clock),
        .audio_ce(audio_ce),
        .reset(pixel_reset),
        .rgb({hdmi_red, hdmi_green, hdmi_blue}),
        .audio_sample_word(audio_sample_words),
        .tmds(serial_data),
        .tmds_clock(hdmi_serial_clock),
        .cx(hdmi_x),
        .cy(hdmi_y),
        .frame_width(hdmi_frame_width),
        .frame_height(hdmi_frame_height),
        .screen_width(hdmi_screen_width),
        .screen_height(hdmi_screen_height)
    );

    assign output_clock = hdmi_serial_clock;
`else
    wire [9:0] red_symbol;
    wire [9:0] green_symbol;
    wire [9:0] blue_symbol;

    nexttang_tmds_encoder blue_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(blue), .control_zero(hsync), .control_one(vsync),
        .data_enable(data_enable), .symbol(blue_symbol)
    );
    nexttang_tmds_encoder green_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(green), .control_zero(1'b0), .control_one(1'b0),
        .data_enable(data_enable), .symbol(green_symbol)
    );
    nexttang_tmds_encoder red_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(red), .control_zero(1'b0), .control_one(1'b0),
        .data_enable(data_enable), .symbol(red_symbol)
    );

    OSER10 blue_serializer (
        .D0(blue_symbol[0]), .D1(blue_symbol[1]),
        .D2(blue_symbol[2]), .D3(blue_symbol[3]),
        .D4(blue_symbol[4]), .D5(blue_symbol[5]),
        .D6(blue_symbol[6]), .D7(blue_symbol[7]),
        .D8(blue_symbol[8]), .D9(blue_symbol[9]),
        .PCLK(pixel_clock), .FCLK(serial_clock),
        .RESET(1'b0), .Q(serial_data[0])
    );
    OSER10 green_serializer (
        .D0(green_symbol[0]), .D1(green_symbol[1]),
        .D2(green_symbol[2]), .D3(green_symbol[3]),
        .D4(green_symbol[4]), .D5(green_symbol[5]),
        .D6(green_symbol[6]), .D7(green_symbol[7]),
        .D8(green_symbol[8]), .D9(green_symbol[9]),
        .PCLK(pixel_clock), .FCLK(serial_clock),
        .RESET(1'b0), .Q(serial_data[1])
    );
    OSER10 red_serializer (
        .D0(red_symbol[0]), .D1(red_symbol[1]),
        .D2(red_symbol[2]), .D3(red_symbol[3]),
        .D4(red_symbol[4]), .D5(red_symbol[5]),
        .D6(red_symbol[6]), .D7(red_symbol[7]),
        .D8(red_symbol[8]), .D9(red_symbol[9]),
        .PCLK(pixel_clock), .FCLK(serial_clock),
        .RESET(1'b0), .Q(serial_data[2])
    );

    assign output_clock = pixel_clock;
`endif

    ELVDS_OBUF clock_output (
        .I(output_clock), .O(tmds_clk_p), .OB(tmds_clk_n));
    ELVDS_OBUF data_output_zero (
        .I(serial_data[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF data_output_one (
        .I(serial_data[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF data_output_two (
        .I(serial_data[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));

    assign tmds_psv = 1'b1;

    // --------------------------------------------------------------- reporting
    // The flags say how far the ROM got. Reaching the first HALT means it
    // finished its memory sizing and set up its screen, which is the point past
    // which a picture is expected.
    reg opcode_seen = 0;
    reg screen_write_seen = 0;
    reg high_ram_write_seen = 0;
    reg border_write_seen = 0;
    reg halt_seen = 0;
    reg [31:0] opcode_count = 0;

    always @(posedge cpu_clock) begin
        if (cpu_reset) begin
            opcode_seen <= 0;
            screen_write_seen <= 0;
            high_ram_write_seen <= 0;
            border_write_seen <= 0;
            halt_seen <= 0;
            opcode_count <= 0;
        end else begin
            if (!m1_n && !mreq_n && rfsh_n) begin
                opcode_seen <= 1'b1;
                opcode_count <= opcode_count + 1'b1;
            end
            if (memory_write && cpu_address[15:11] == 5'b01000)
                screen_write_seen <= 1'b1;
            if (memory_write && cpu_address[15])
                high_ram_write_seen <= 1'b1;
            if (port_fe && !wr_n)
                border_write_seen <= 1'b1;
            if (!halt_n)
                halt_seen <= 1'b1;
        end
    end

    // Slow enough for a 24 MHz analyser and chosen to show the machine's
    // rhythm: opcode fetches, memory against IO, writes, and the 50 Hz frame
    // interrupt the ROM runs on.
`ifdef NEXTTANG_SPEC256_RUNTIME
    // PMOD1 IO2 is the runtime pack input.  The remaining five pins retain a
    // useful passive bus trace; IO2 is tri-stated so the FT232RL owns it.
    assign probe = {
        interrupt_n, wr_n, iorq_n, mreq_n, m1_n, 1'bz
    };
`elsif NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
    wire any_matrix_key = |keys;

`ifdef NEXTTANG_SPECTRUM48_USB_KEYBOARD
    // Both physical root-port pairs plus the two keyboard-source boundaries.
    // D2 is the legacy BL616 matrix and D5 is the direct USB2 matrix; this
    // distinguishes source contamination from a bad direct-HID report.
    // Register the bidirectional USB pins before driving the output-only probe
    // path.  Directly aliasing each inout onto another top-level port makes
    // Gowin 1.9.12.03 create four malformed netlist connections during DIO.
    reg [3:0] usb_pin_samples = 4'b0;
    always @(posedge usb_clock)
        usb_pin_samples <= {usb2_dn, usb2_dp, usb1_dn, usb1_dp};
    assign probe = {
        |usb2_keyboard_keys, usb_pin_samples[3], usb_pin_samples[2],
        |keyboard_keys, usb_pin_samples[1], usb_pin_samples[0]
    };
`else
    // MCU-side keyboard diagnostic. D1 is the raw 2 Mbit/s TangCore UART;
    // D2-D5 progressively show matrix, byte, frame-sync and scan-code events.
    assign probe = {
        keyboard_scancode_valid, keyboard_sync_valid,
        keyboard_byte_valid, |keyboard_keys,
        bl616_uart_rx, cpu_clock
    };
`endif
`else
    assign probe = {interrupt_n, wr_n, iorq_n, mreq_n, m1_n, cpu_clock};
`endif

`ifdef NEXTTANG_SPEC256_RUNTIME
`ifdef NEXTTANG_SPEC256_WRITE_TRACE
    // V/M/R/C/P/Y: video/machine lock, trace armed, all lanes captured,
    // any captured loader-owned write, and loader fault.  Value layout is
    // 000:lane, captured, loader-owned, address, data, running[2:0].
    wire [5:0] status_flags = {
        loader_fault, |spec256_trace_loader,
        &spec256_trace_captured, spec256_trace_armed,
        machine_pll_locked, video_pll_locked
    };
    wire [31:0] status_value = {
        spec256_trace_report_lane,
        spec256_trace_captured[spec256_trace_report_lane],
        spec256_trace_loader[spec256_trace_report_lane],
        spec256_trace_address[spec256_trace_report_lane],
        spec256_trace_data[spec256_trace_report_lane],
        spec256_graphics_running[2:0]
    };
`else
    // V/M/R/C/P/Y: video PLL, machine PLL, payload byte seen, CPUs held,
    // complete pack accepted, and pack fault.  The value is payload progress.
    wire [5:0] status_flags = {
        loader_fault, loader_ready, loader_hold_reset, loader_byte_valid,
        machine_pll_locked, video_pll_locked
    };
    wire [31:0] status_value = {11'b0, loader_background_valid,
                                loader_received_bytes};
`endif
`elsif NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
`ifdef NEXTTANG_SPECTRUM48_USB_KEYBOARD
    // UART labels V/M/R/C/P/Y mean video lock, USB PLL lock, keyboard
    // enumerated, HID report, key usage present, and Spectrum matrix asserted.
    wire [5:0] status_flags = {
        any_matrix_key, usb_keycode_present, usb_report_seen,
        usb_keyboard_connected, usb_pll_locked, video_pll_locked
    };
    // Show the descriptor classification bytes followed by the first decoded
    // key usage. This distinguishes a bad interface descriptor from a bad
    // interrupt report without changing the host or the keyboard matrix.
    wire [31:0] status_value = {
        usb2_hid_regs[39:32], usb2_hid_regs[47:40],
        usb2_hid_regs[55:48], usb2_key1
    };
`else
    // V/M/R/C/P/Y mean video lock, machine released, any UART byte,
    // TangCore sync, scan-code event and resulting matrix key.
    // M carries the loopback result during bring-up rather than a flag that is
    // always set: V loopback-independent video lock, M host byte on G21,
    // R BL616 byte on V14, then sync, scan code and matrix key.
    wire [5:0] status_flags = {
        any_matrix_key, keyboard_scancode_valid, keyboard_sync_valid,
        keyboard_byte_valid, loopback_byte_seen, video_pll_locked
    };
    wire [31:0] status_value = {24'b0, keyboard_scancode};
`endif
`elsif NEXTTANG_SPECTRUM48_USE_TAPE
`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    // For this profile C/P are tape active/finished. Y combines tape and
    // memory-service faults. The trailing UART value is the next tape byte.
    wire [5:0] status_flags = {
        tape_fault | tape_fault_unsupported | fault_calibration_lost |
            fault_overrun | fault_timeout,
        tape_finished, tape_active, calibration_complete,
        high_ram_write_seen, opcode_seen
    };
`else
    // The internal-RAM control has no calibration to report, so R is the video
    // PLL lock and Y is the tape player alone. C/P stay tape active/finished
    // so both tape profiles decode the same way.
    wire [5:0] status_flags = {
        tape_fault | tape_fault_unsupported,
        tape_finished, tape_active, video_pll_locked,
        high_ram_write_seen, opcode_seen
    };
`endif
    // Where the processor actually is. A machine that stops answering the
    // tape has either crashed or is looping, and the opcode address says
    // which, and where.
    reg [15:0] last_opcode_address = 0;

    always @(posedge cpu_clock) begin
        if (cpu_reset)
            last_opcode_address <= 0;
        else if (!m1_n && !mreq_n && rfsh_n)
            last_opcode_address <= cpu_address;
    end

    wire [31:0] status_value = {15'b0, tape_byte_position};
`elsif NEXTTANG_SPECTRUM48_USE_DDR3
    wire [5:0] status_flags = {
        fault_calibration_lost, fault_overrun, fault_timeout,
        calibration_complete, high_ram_write_seen, opcode_seen
    };
    wire [31:0] status_value = opcode_count;
`elsif NEXTTANG_SPECTRUM48_USE_ULA
    wire [5:0] status_flags = {
        capture_protocol_error, scaled_overrun, scaled_frame_valid,
        screen_write_seen, opcode_seen, video_pll_locked
    };
    wire [31:0] status_value = opcode_count;
`else
    wire [5:0] status_flags = {
        typing_finished, border_write_seen, high_ram_write_seen,
        screen_write_seen, opcode_seen, video_pll_locked
    };
    wire [31:0] status_value = opcode_count;
`endif

`ifdef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
`ifdef NEXTTANG_SPECTRUM48_USB_KEYBOARD
    wire usb_snapshot_port_two = usb2_config_snapshot_valid;
    wire usb_snapshot_valid = usb1_config_snapshot_valid |
                              usb2_config_snapshot_valid;
    wire usb_snapshot_full_speed = usb_snapshot_port_two ?
                                   usb2_full_speed : usb1_full_speed;
    wire [15:0] usb_snapshot_speed_sample = usb_snapshot_port_two ?
                                            usb2_speed_sample :
                                            usb1_speed_sample;
    wire [63:0] usb_snapshot = usb_snapshot_port_two ?
                               usb2_config_snapshot : usb1_config_snapshot;

    nexttang_usb_snapshot_uart #(
        .CLOCK_HZ(60000000)
    ) usb_snapshot_uart (
        .clock(usb_clock),
        .reset(!usb_pll_locked),
        .snapshot_valid(usb_snapshot_valid),
        .port_two(usb_snapshot_port_two),
        .full_speed(usb_snapshot_full_speed),
        .speed_sample(usb_snapshot_speed_sample),
        .snapshot(usb_snapshot),
        .transmit(debug_uart_tx)
    );
`else
    nexttang_debug_status_uart #(
        .CLOCK_HZ(3500000)
`ifdef NEXTTANG_SPEC256_RUNTIME
        , .BAUD_RATE(RUNTIME_UART_BAUD)
`ifdef NEXTTANG_SPEC256_WRITE_TRACE
        , .GAP_CLOCKS(350000)
`endif
`endif
    ) status_uart (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .reset(!cpu_reset_shift[3] ||
               (loader_hold_reset && !loader_fault)),
`else
        .reset(cpu_reset),
`endif
        .flags(status_flags),
        .value(status_value),
        .transmit(debug_uart_tx)
    );
`endif
`else
    nexttang_debug_status_uart #(
        .CLOCK_HZ(3500000)
`ifdef NEXTTANG_SPEC256_RUNTIME
        , .BAUD_RATE(RUNTIME_UART_BAUD)
`ifdef NEXTTANG_SPEC256_WRITE_TRACE
        , .GAP_CLOCKS(350000)
`endif
`endif
    ) status_uart (
        .clock(cpu_clock),
`ifdef NEXTTANG_SPEC256_RUNTIME
        .reset(!cpu_reset_shift[3] ||
               (loader_hold_reset && !loader_fault)),
`else
        .reset(cpu_reset),
`endif
        .flags(status_flags),
        .value(status_value),
        .transmit(debug_uart_tx)
    );
`endif

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    assign debug_uart_tx_alt = debug_uart_tx;
    assign status_led = calibration_complete &&
                        !fault_timeout && !fault_overrun &&
                        !fault_calibration_lost ? 1'b0 : 1'b1;
`endif
endmodule

`default_nettype wire
