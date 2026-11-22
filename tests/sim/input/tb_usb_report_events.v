// nexttang_usb_report_events: a sequence of boot keyboard reports in, the
// press and release events out, checked against the expected list.
`timescale 1ns/1ps
module tb;
    reg clk = 0; always #17.778 clk = ~clk;
    reg reset = 1, kb = 1; reg [7:0] mods = 0; reg [47:0] keys = 0;
    wire ev; wire [7:0] eb;
    nexttang_usb_report_events dut (.clock(clk), .reset(reset), .keyboard(kb), .modifiers(mods), .keys(keys),
                                    .event_valid(ev), .event_byte(eb));
    reg [7:0] got [0:63]; integer n = 0;
    always @(posedge clk) if (ev) begin got[n] = eb; n = n + 1; end
    task report(input [7:0] m, input [47:0] k); begin @(posedge clk); #1 mods = m; keys = k; repeat (30) @(posedge clk); end endtask
    reg [7:0] want [0:63]; integer w = 0, i, errors = 0;
    task expect_ev(input [7:0] b); begin want[w] = b; w = w + 1; end endtask
    initial begin
        repeat (3) @(posedge clk); reset = 0;
        report(8'h00, {40'd0, 8'h04});                expect_ev(8'h04);            // A down
        report(8'h00, {32'd0, 8'h05, 8'h04});         expect_ev(8'h05);            // B down too
        report(8'h00, {40'd0, 8'h05});                expect_ev(8'h84);            // A up (B moved to slot 1)
        report(8'h02, {40'd0, 8'h05});                expect_ev(8'h69);            // left shift down
        report(8'h02, 48'd0);                         expect_ev(8'h85);            // B up
        report(8'h00, 48'd0);                         expect_ev(8'hE9);            // left shift up
        report(8'h11, {40'd0, 8'h39});                expect_ev(8'h39); expect_ev(8'h68); expect_ev(8'h6C);   // Caps Lock, LCtrl, RCtrl
        report(8'h00, {48{1'b0}} | {6{8'h01}});       expect_ev(8'hB9); expect_ev(8'hE8); expect_ev(8'hEC);   // rollover: all released
        report(8'h00, {40'd0, 8'h85});                                             // 0x85 not usable: nothing
        kb = 0; report(8'h00, 48'd0);                                              // not a keyboard: the empty report
        repeat (10) @(posedge clk);
        if (n != w) begin errors = errors + 1; $display("FAIL %0d events, want %0d", n, w); end
        for (i = 0; i < w && i < n; i = i + 1)
            if (got[i] !== want[i]) begin errors = errors + 1; $display("FAIL event %0d is %h, want %h", i, got[i], want[i]); end
        if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
        $finish;
    end
endmodule
