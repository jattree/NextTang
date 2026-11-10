// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Tang Nano 20K bring-up, step 2: the in-package SDR SDRAM.
//
// A deliberately simple controller and a self-test, to learn whether the
// interface works on this board before NextTang's real controller is written.
// The GW2AR-18's die is 2M x 32 (4 banks, 2048 rows, 256 columns). Every
// access is one word: ACTIVE, then READ or WRITE with auto-precharge, CAS
// latency 2, burst length 1, refresh every REFRESH_EVERY clocks. Slow, and
// correct by construction rather than fast.
//
// The test writes word = f(address, pass) to all 2M words, reads them all
// back, and counts mismatches. Read data is captured at two points, the
// pins at the rising edge 3 clocks after READ (A) and at the falling edge
// half a clock later (B), and each has its own error count, so the board tells us which capture point holds
// without a rebuild. f mixes the address with an LFSR so that address-line
// faults (aliasing) and stuck data bits both show up.

`default_nettype none

module nexttang_nano20k_sdram_test #(
    parameter integer CLOCK_HZ = 81_000_000,
    parameter [20:0]  LAST_WORD = 21'h1FFFFF   // smaller in simulation
) (
    input  wire        clock,
    input  wire        reset,

    output wire        O_sdram_clk,
    output reg         O_sdram_cke,
    output reg         O_sdram_cs_n,
    output reg         O_sdram_cas_n,
    output reg         O_sdram_ras_n,
    output reg         O_sdram_wen_n,
    output reg  [10:0] O_sdram_addr,
    output reg  [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq,

    output reg  [15:0] passes,       // completed write+read passes
    output reg  [23:0] errors_a,     // mismatches, capture A (all passes)
    output reg  [23:0] errors_b,     // mismatches, capture B
    output reg         init_done,
    output reg         reading       // current pass phase
);
    localparam integer INIT_WAIT     = CLOCK_HZ / 5000 + 100;    // 200 us + margin
    localparam integer REFRESH_EVERY = CLOCK_HZ / 1_000_000 * 7; // 7 us (64 ms / 4096 rows = 15.6 us)

    // the SDRAM samples on the rising edge of its clock; give it the
    // inverted controller clock so commands and data are mid-eye
    assign O_sdram_clk = ~clock;
    assign O_sdram_dqm = 4'b0000;

    reg        dq_oe = 1'b0;
    reg [31:0] dq_out = 32'd0;
    assign IO_sdram_dq = dq_oe ? dq_out : 32'bz;

    // commands {cs_n, ras_n, cas_n, we_n}
    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    task automatic cmd(input [3:0] c);
        {O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} = c;
    endtask

    function automatic [31:0] pattern(input [20:0] a, input [15:0] p);
        reg [31:0] x;
        begin
            x = {a[10:0], a[20:0]} ^ {p, p};
            x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5);   // xorshift32 mix
            pattern = x ^ {11'd0, a};
        end
    endfunction

    reg [5:0]  st = 6'd0;
    reg [15:0] wait_n = 16'd0;
    reg [15:0] refresh_n = 16'd0;
    reg [20:0] addr = 21'd0;      // {bank, row, column}
    reg [3:0]  step = 4'd0;
    reg [31:0] expected = 32'd0;
    reg [4:0]  cap = 5'd0;        // capture pipeline after READ
    reg [31:0] dq_in1 = 32'd0;
    reg [31:0] dq_fall = 32'd0;
    always @(negedge clock) dq_fall <= IO_sdram_dq;   // capture B: half a clock later

    localparam S_INIT = 6'd0, S_PRE_ALL = 6'd1, S_REF1 = 6'd2, S_REF2 = 6'd3, S_MRS = 6'd4,
               S_IDLE = 6'd5, S_ACT = 6'd6, S_RW = 6'd7, S_WAIT = 6'd8, S_REF = 6'd9, S_DONE = 6'd10;

    always @(posedge clock) begin
        dq_in1 <= IO_sdram_dq;   // pins sampled on every rising edge
        cmd(C_NOP);
        dq_oe <= 1'b0;
        if (refresh_n != 16'd0) refresh_n <= refresh_n - 16'd1;
        // Read capture. READ is issued at rising edge E0; the SDRAM sees it
        // half a clock later (inverted clock) and, at CL 2, drives the word
        // from E2.5 + tAC (about 5.4 ns) until E3.5 + tOH (about 2.5 ns).
        // At 81 MHz that window opens just before E3, so capture A (pins at
        // rising E3) is at its leading edge and capture B (pins at falling
        // E3.5) is near its middle. Both are checked at E4, when cap[3] is
        // visible: dq_in1 = pins(E3), dq_fall = pins(E3.5).
        cap <= {cap[3:0], 1'b0};
        if (cap[3] && dq_in1 != expected) errors_a <= errors_a + 24'd1;
        if (cap[3] && dq_fall != expected) errors_b <= errors_b + 24'd1;

        if (reset) begin
            st <= S_INIT; wait_n <= INIT_WAIT[15:0]; O_sdram_cke <= 1'b0;
            init_done <= 1'b0; passes <= 16'd0; errors_a <= 24'd0; errors_b <= 24'd0;
            reading <= 1'b0; addr <= 21'd0; cap <= 5'd0;
        end else case (st)
            S_INIT: begin
                O_sdram_cke <= 1'b1;
                if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                else st <= S_PRE_ALL;
            end
            S_PRE_ALL: begin cmd(C_PRE); O_sdram_addr <= 11'h400; wait_n <= 16'd4; st <= S_REF1; end
            S_REF1: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                    else begin cmd(C_REF); wait_n <= 16'd12; st <= S_REF2; end
            S_REF2: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                    else begin cmd(C_REF); wait_n <= 16'd12; st <= S_MRS; end
            S_MRS: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                   else begin
                       cmd(C_MRS); O_sdram_ba <= 2'b00;
                       O_sdram_addr <= 11'b0000_010_0_000;  // A10-A7 0 (burst write), CL 2, sequential, BL 1
                       wait_n <= 16'd4; st <= S_WAIT; step <= 4'd0;
                       init_done <= 1'b1; refresh_n <= REFRESH_EVERY[15:0];
                   end
            S_IDLE: begin
                if (refresh_n == 16'd0) begin
                    cmd(C_REF); refresh_n <= REFRESH_EVERY[15:0]; wait_n <= 16'd10; st <= S_WAIT;
                end else begin
                    cmd(C_ACT); O_sdram_ba <= addr[20:19]; O_sdram_addr <= addr[18:8];
                    wait_n <= 16'd1; st <= S_RW;   // tRCD: 2 clocks
                end
            end
            S_RW: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                  else begin
                      O_sdram_ba <= addr[20:19];
                      O_sdram_addr <= {3'b100, addr[7:0]};       // A10 = auto-precharge
                      if (!reading) begin
                          cmd(C_WRITE); dq_oe <= 1'b1; dq_out <= pattern(addr, passes);
                          wait_n <= 16'd5;                        // tWR + tRP
                      end else begin
                          cmd(C_READ); cap[0] <= 1'b1; expected <= pattern(addr, passes);
                          wait_n <= 16'd7;                        // CL + tRP, both captures done
                      end
                      if (addr == LAST_WORD) begin
                          if (reading) passes <= passes + 16'd1;
                          reading <= !reading;
                      end
                      addr <= (addr == LAST_WORD) ? 21'd0 : addr + 21'd1;
                      st <= S_WAIT;
                  end
            S_WAIT: if (wait_n != 16'd0) wait_n <= wait_n - 16'd1;
                    else st <= S_IDLE;
            default: st <= S_INIT;
        endcase
    end

endmodule

`default_nettype wire
