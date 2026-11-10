// Simulation of nt_serdes_reinit (Icarus Verilog, sim/run.sh).
// REFCLK runs at 54 MHz, stops, then runs at 100 MHz; later it stops and
// comes back. The DRP model acknowledges each write by raising drp_ready for
// one cycle, ACK cycles after drp_wr was first seen (idle low, as measured),
// and refuses to count a write unless drp_wr is still high when it acks.
// Checks: no replay at 54 MHz; one full replay in ROM order once 100 MHz
// settles; reset hold after the replay; exactly one replay per settle; a
// second replay after the clock drops out; no timeouts.
`timescale 1ns/1ps
module tb_reinit;
    reg clk = 0, drp_clk = 0, refclk = 0;
    always #5 clk = ~clk;                 // 100 MHz
    always #4 drp_clk = ~drp_clk;         // 125 MHz, unrelated to clk
    real half = 9.259;                    // REFCLK half period, ns (54 MHz)
    reg  ref_on = 1;
    always begin
        #(half);
        if (ref_on) refclk = ~refclk;
    end

    wire [23:0] drp_addr; wire [31:0] drp_wrdata; wire [7:0] drp_strb;
    wire drp_wr, drp_rd, hold, ok; wire [7:0] replays, timeouts;
    reg  drp_ready = 0;
    nt_serdes_reinit #(.HOLD(20'd2000)) dut (
        .clk(clk), .refclk(refclk), .drp_clk(drp_clk), .drp_ready(drp_ready),
        .drp_addr(drp_addr), .drp_wrdata(drp_wrdata), .drp_strb(drp_strb),
        .drp_wr(drp_wr), .drp_rd(drp_rd), .hold_reset(hold), .refclk_ok(ok),
        .replays(replays), .timeouts(timeouts)
    );

    // DRP slave: ack ACK cycles after a write starts, if wr is still held
    localparam ACK = 5;
    integer busy = 0, nw = 0, errors = 0;
    reg [55:0] exp;
    always @(posedge drp_clk) begin
        drp_ready <= 1'b0;
        if (drp_rd) begin $display("FAIL: read issued"); errors = errors + 1; end
        if (busy == 0) begin
            if (drp_wr) busy = 1;
        end else if (busy == ACK) begin
            if (!drp_wr) begin $display("FAIL: drp_wr dropped before the ack (write %0d)", nw); errors = errors + 1; end
            else begin
                exp = dut.wrom(nw % dut.NW);
                if ({drp_addr, drp_wrdata} !== exp || drp_strb !== 8'hFF) begin
                    $display("FAIL: write %0d got %h/%h strb %h, expected %h", nw, drp_addr, drp_wrdata, drp_strb, exp);
                    errors = errors + 1;
                end
                nw = nw + 1;
            end
            drp_ready <= 1'b1;
            busy = busy + 1;
        end else if (busy > ACK) begin
            if (!drp_wr) busy = 0;           // master released wr after the ack
        end else busy = busy + 1;
    end

    // hold must only rise after the last write of a replay
    always @(posedge hold)
        if (nw % dut.NW != 0) begin $display("FAIL: hold rose after %0d writes", nw); errors = errors + 1; end

    task expect_count(input integer w, input integer r);
        if (nw != w || replays != r) begin
            $display("FAIL: %0d writes, %0d replays; expected %0d, %0d", nw, replays, w, r);
            errors = errors + 1;
        end
    endtask

    initial begin
        #3_000_000;                           // 3 ms at 54 MHz
        expect_count(0, 0);
        ref_on = 0; #500_000;                 // clock stops (failed link)
        expect_count(0, 0);
        half = 5.0; ref_on = 1; #4_000_000;   // 100 MHz for 4 ms: one replay
        expect_count(dut.NW, 1);
        if (hold) begin $display("FAIL: still holding reset"); errors = errors + 1; end
        #3_000_000;                           // still 100 MHz: no second replay
        expect_count(dut.NW, 1);
        ref_on = 0; #500_000; ref_on = 1; #4_000_000;   // dropout, then back
        expect_count(2 * dut.NW, 2);
        if (timeouts != 0) begin $display("FAIL: %0d timeouts", timeouts); errors = errors + 1; end
        if (errors == 0) $display("PASS: SerDes re-init simulation (%0d writes, %0d replays)", nw, replays);
        else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
