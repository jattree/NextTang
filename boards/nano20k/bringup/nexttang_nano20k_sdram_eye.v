// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Tang Nano 20K: SDRAM read-data eye scan, with the Next shell's clocking.
//
// The memory clock is the Next shell's (rPLL CLKOUT, 84.375 MHz), and the
// SDRAM clock leaves through an output DDR register in its I/O cell as in
// nexttang_nano20k_zxnext.v, so the read-data window seen here is the one the
// Next image sees. Every data pin's input goes through a run-time IODELAY
// (128 steps of about 25 ps, Gowin's model) before the capture registers.
//
// Each word is one access: ACTIVE, READ or WRITE with auto-precharge, CAS
// latency 2, burst 1 (the shell's controller's command timing). For each
// delay step the test writes WORDS words (a pattern that changes with the
// step) and reads them back, capturing every read at five points:
//   E  the pins at the rising memory edge 2 cycles after READ
//   D  the falling edge half a cycle later
//   A  the rising memory edge 3 cycles after READ
//   B  the falling edge half a cycle later (the Next controller's point,
//      nexttang_sdr_sdram_service CAPTURE 1)
//   C  the rising edge 4 cycles after READ
// and sends one line on the debug UART (115200 8N1, header pin 29 and the
// BL616's USB serial):
//   EYE ss eeeeee dddddd aaaaaa bbbbbb cccccc
// ss the delay step and the five error counts in hex. The delay then steps
// by one: up from 0 to 127, back down to 0, and round again.
// Delaying the data moves each capture point earlier against the data, so
// the step at which A starts failing marks the window's opening, and the step
// at which C starts passing (if within range) its closing.
//
// LEDs, lit low: 0 PLL lock, 1 SDRAM initialised, 2 scan running (blinks per
// step), 5 any error in the last step at capture B.

`default_nettype none

module nexttang_nano20k_sdram_eye (
    input  wire        clock_27,
    output wire        O_sdram_clk,
    output reg         O_sdram_cke = 1'b0,
    output reg         O_sdram_cs_n = 1'b1,
    output reg         O_sdram_cas_n = 1'b1,
    output reg         O_sdram_ras_n = 1'b1,
    output reg         O_sdram_wen_n = 1'b1,
    output reg  [10:0] O_sdram_addr = 11'd0,
    output reg  [1:0]  O_sdram_ba = 2'd0,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq,
    output wire        debug_uart_tx,
    output wire        companion_irq_n,
    output wire [5:0]  led
);
    localparam integer CLOCK_HZ = 84_375_000;
    localparam [15:0]  WORDS = 16'hFFFF;          // words per step, minus one
    localparam integer INIT_WAIT = CLOCK_HZ / 5000 + 100;
    localparam integer REFRESH_EVERY = CLOCK_HZ / 1_000_000 * 7;

    wire clock, pll_lock;
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2AR-18C"),
        .IDIV_SEL(7), .FBDIV_SEL(24), .ODIV_SEL(8),
        .DYN_SDIV_SEL(2),
        .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0), .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false")
    ) pll (
        .CLKIN(clock_27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0), .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0),
        .CLKOUT(clock), .LOCK(pll_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3());

    reg [2:0] reset_sync = 3'b111;
    always @(posedge clock or negedge pll_lock)
        if (!pll_lock) reset_sync <= 3'b111;
        else reset_sync <= {reset_sync[1:0], 1'b0};
    wire reset = reset_sync[2];

    // SDRAM clock: as the Next shell (low after the rising edge, high after
    // the falling edge).
    ODDR #(.TXCLK_POL(1'b0), .INIT(1'b0)) sdram_clock_out (
        .D0(1'b0), .D1(1'b1), .TX(1'b0), .CLK(clock), .Q0(O_sdram_clk), .Q1());
    assign O_sdram_dqm = 4'b0000;

    // data pins: buffer, run-time delay, captures
    reg        dq_oe = 1'b0;
    reg [31:0] dq_out = 32'd0;
    wire [31:0] dq_pin, dq_delayed;
    reg        delay_pulse = 1'b0;   // falling edge of VALUE steps the delay
    reg        delay_down = 1'b0;    // SETN: 0 counts up, 1 down
    wire [31:0] delay_at_end;
    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : pins
            IOBUF buffer (.O(dq_pin[i]), .IO(IO_sdram_dq[i]), .I(dq_out[i]), .OEN(!dq_oe));
            IODELAY #(.C_STATIC_DLY(0)) delay (
                .DI(dq_pin[i]), .SDTAP(1'b1), .SETN(delay_down), .VALUE(delay_pulse),
                .DO(dq_delayed[i]), .DF(delay_at_end[i]));
        end
    endgenerate
    reg [31:0] cap_a1 = 32'd0;
    reg [31:0] cap_b = 32'd0;
    always @(posedge clock) begin
        cap_a1 <= dq_delayed;       // every rising edge; taken as A or C by position
    end
    always @(negedge clock) cap_b <= dq_delayed;

    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    task automatic cmd(input [3:0] c);
        {O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} = c;
    endtask
    function automatic [31:0] pattern(input [20:0] a, input [7:0] p);
        reg [31:0] x;
        begin
            x = {a[10:0], a[20:0]} ^ {p, p, p, p};
            x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5);
            pattern = x ^ {11'd0, a};
        end
    endfunction

    localparam S_INIT = 4'd0, S_PRE = 4'd1, S_REF1 = 4'd2, S_REF2 = 4'd3, S_MRS = 4'd4,
               S_IDLE = 4'd5, S_RW = 4'd6, S_WAIT = 4'd7, S_REPORT = 4'd8, S_STEP = 4'd9;
    reg [3:0]  st = S_INIT;
    reg [15:0] wait_n = 16'd0, refresh_n = 16'd0;
    reg [20:0] addr = 21'd0;
    reg        reading = 1'b0;
    reg [6:0]  step = 7'd0;
    reg [7:0]  pass = 8'd0;
    reg [31:0] expected = 32'd0;
    reg [5:0]  cap = 6'd0;
    reg [23:0] err_a = 24'd0, err_b = 24'd0, err_c = 24'd0, err_d = 24'd0, err_e = 24'd0;
    reg [23:0] last_b = 24'd0;
    reg        initialised = 1'b0;
    reg        report_start = 1'b0;
    wire       report_busy;

    always @(posedge clock) begin
        cmd(C_NOP);
        dq_oe <= 1'b0;
        report_start <= 1'b0;
        if (refresh_n != 16'd0) refresh_n <= refresh_n - 16'd1;
        // READ at rising edge E0 (registered, on the pins after E0). cap[k] is
        // set at E(k+1). cap_a1 holds pins(Ek) from edge E(k+1): at cap[3]
        // (E4) cap_a1 = pins(E3) (A); cap_b holds pins(E3.5) (B); at cap[4]
        // (E5) cap_a1 = pins(E4) (C).
        cap <= {cap[4:0], 1'b0};
        if (cap[2] && cap_a1 != expected) err_e <= err_e + 24'd1;   // pins(E2)
        if (cap[2] && cap_b != expected) err_d <= err_d + 24'd1;    // pins(E2.5)
        if (cap[3] && cap_a1 != expected) err_a <= err_a + 24'd1;
        if (cap[3] && cap_b != expected) err_b <= err_b + 24'd1;
        if (cap[4] && cap_a1 != expected) err_c <= err_c + 24'd1;
        if (reset) begin
            st <= S_INIT; wait_n <= INIT_WAIT[15:0]; O_sdram_cke <= 1'b0; initialised <= 1'b0;
            step <= 7'd0; pass <= 8'd0; addr <= 21'd0; reading <= 1'b0; cap <= 6'd0;
            err_a <= 24'd0; err_b <= 24'd0; err_c <= 24'd0; err_d <= 24'd0; err_e <= 24'd0;
            delay_pulse <= 1'b0; delay_down <= 1'b0;
        end else case (st)
            S_INIT: begin
                O_sdram_cke <= 1'b1;
                if (wait_n != 16'd0) wait_n <= wait_n - 16'd1; else st <= S_PRE;
            end
            S_PRE: begin cmd(C_PRE); O_sdram_addr <= 11'h400; wait_n <= 16'd6; st <= S_REF1; end
            S_REF1: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                    else begin cmd(C_REF); wait_n <= 16'd12; st <= S_REF2; end
            S_REF2: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                    else begin cmd(C_REF); wait_n <= 16'd12; st <= S_MRS; end
            S_MRS: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                   else begin
                       cmd(C_MRS); O_sdram_ba <= 2'b00; O_sdram_addr <= 11'b0000_010_0_000;
                       wait_n <= 16'd4; st <= S_WAIT; initialised <= 1'b1;
                       refresh_n <= REFRESH_EVERY[15:0];
                   end
            S_IDLE: begin
                if (refresh_n == 16'd0) begin
                    cmd(C_REF); refresh_n <= REFRESH_EVERY[15:0]; wait_n <= 16'd10; st <= S_WAIT;
                end else begin
                    cmd(C_ACT); O_sdram_ba <= addr[20:19]; O_sdram_addr <= addr[18:8];
                    wait_n <= 16'd1; st <= S_RW;
                end
            end
            S_RW: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                  else begin
                      O_sdram_ba <= addr[20:19];
                      O_sdram_addr <= {3'b100, addr[7:0]};
                      if (!reading) begin
                          cmd(C_WRITE); dq_oe <= 1'b1; dq_out <= pattern(addr, pass);
                          wait_n <= 16'd5;
                      end else begin
                          cmd(C_READ); cap[0] <= 1'b1; expected <= pattern(addr, pass);
                          wait_n <= 16'd7;
                      end
                      st <= S_WAIT;
                      if (addr[15:0] == WORDS) begin
                          addr <= 21'd0;
                          if (reading) st <= S_REPORT;
                          reading <= !reading;
                      end else addr <= addr + 21'd1;
                  end
            S_WAIT: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1; else st <= S_IDLE;
            S_REPORT: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;   // last read's captures
                      else if (!report_busy) begin
                          report_start <= 1'b1; last_b <= err_b; st <= S_STEP; wait_n <= 16'd16;
                      end
            S_STEP: begin
                // step the delay: VALUE high, then low (its falling edge counts)
                if (wait_n == 16'd16) delay_pulse <= 1'b1;
                if (wait_n == 16'd8) delay_pulse <= 1'b0;
                if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                else if (!report_busy && !report_start) begin
                    err_a <= 24'd0; err_b <= 24'd0; err_c <= 24'd0; err_d <= 24'd0; err_e <= 24'd0;
                    pass <= pass + 8'd1;
                    // the pulse above already moved the delay; follow it,
                    // and turn round at the ends for the next step
                    if (!delay_down) begin
                        step <= step + 7'd1;
                        if (step == 7'd126) delay_down <= 1'b1;
                    end else begin
                        step <= step - 7'd1;
                        if (step == 7'd1) delay_down <= 1'b0;
                    end
                    st <= S_IDLE;
                end
            end
            default: st <= S_INIT;
        endcase
    end

    // ------------------------------------------------------------ report
    // "EYE ss eeeeee dddddd aaaaaa bbbbbb cccccc\r\n" at 115200 baud.
    function automatic [7:0] hex(input [3:0] v);
        hex = v < 10 ? "0" + v : "a" + v - 10;
    endfunction
    localparam integer LINE = 43;
    reg [LINE*8-1:0] line = 0;
    reg [5:0]  chars_left = 6'd0;
    reg [9:0]  bit_timer = 10'd0;
    reg [3:0]  bit_index = 4'd0;
    reg [9:0]  shifter = 10'h3ff;
    localparam [9:0] BIT_CLOCKS = 10'd732;           // 84.375 MHz / 115200
    assign report_busy = chars_left != 6'd0 || bit_index != 4'd0;
    always @(posedge clock) begin
        if (report_start) begin
            line <= {"EYE ", hex({1'b0, step[6:4]}), hex(step[3:0]), " ",
                     hex(err_e[23:20]), hex(err_e[19:16]), hex(err_e[15:12]), hex(err_e[11:8]), hex(err_e[7:4]), hex(err_e[3:0]), " ",
                     hex(err_d[23:20]), hex(err_d[19:16]), hex(err_d[15:12]), hex(err_d[11:8]), hex(err_d[7:4]), hex(err_d[3:0]), " ",
                     hex(err_a[23:20]), hex(err_a[19:16]), hex(err_a[15:12]), hex(err_a[11:8]), hex(err_a[7:4]), hex(err_a[3:0]), " ",
                     hex(err_b[23:20]), hex(err_b[19:16]), hex(err_b[15:12]), hex(err_b[11:8]), hex(err_b[7:4]), hex(err_b[3:0]), " ",
                     hex(err_c[23:20]), hex(err_c[19:16]), hex(err_c[15:12]), hex(err_c[11:8]), hex(err_c[7:4]), hex(err_c[3:0]),
                     8'h0d, 8'h0a};
            chars_left <= LINE[5:0];
        end else if (bit_index == 4'd0 && chars_left != 6'd0) begin
            shifter <= {1'b1, line[LINE*8-1 -: 8], 1'b0};
            line <= line << 8;
            chars_left <= chars_left - 6'd1;
            bit_index <= 4'd10; bit_timer <= BIT_CLOCKS;
        end else if (bit_index != 4'd0) begin
            if (bit_timer == 10'd1) begin
                bit_timer <= BIT_CLOCKS;
                shifter <= {1'b1, shifter[9:1]};
                bit_index <= bit_index - 4'd1;
            end else bit_timer <= bit_timer - 10'd1;
        end
    end
    assign debug_uart_tx = shifter[0];
    assign companion_irq_n = shifter[0];

    reg [23:0] blink = 24'd0;
    always @(posedge clock) if (report_start) blink <= ~blink;
    assign led = ~{last_b != 24'd0, 2'b00, blink[0], initialised, pll_lock};
endmodule

`default_nettype wire
