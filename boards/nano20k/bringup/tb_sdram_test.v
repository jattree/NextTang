// Simulation: the step-2 self-test against a behavioural SDR SDRAM (CL 2,
// BL 1, auto-precharge, commands on the rising edge of O_sdram_clk, read
// data driven tAC after the CL-th edge). Checks no errors at capture A or
// B with a good memory, and that a stuck data bit and an aliased address
// line are both caught.
`timescale 1ns/1ps
module tb;
    reg clock = 0; always #6.17 clock = ~clock;   // 81 MHz
    reg reset = 1;
    wire sclk, cke, cs_n, cas_n, ras_n, we_n; wire [10:0] a; wire [1:0] ba; wire [3:0] dqm;
    wire [31:0] dq;
    wire [15:0] passes; wire [23:0] ea, eb; wire init_done, reading;
    nexttang_nano20k_sdram_test #(.CLOCK_HZ(81_000_000), .LAST_WORD(21'h1FFF)) dut (
        clock, reset, sclk, cke, cs_n, cas_n, ras_n, we_n, a, ba, dqm, dq, passes, ea, eb, init_done, reading);

    // memory model
    integer FAULT = 0;   // 0 good, 1 stuck bit 5, 2 address line 3 ignored
    reg [31:0] mem [0:2097151];
    reg [10:0] row [0:3];
    reg [31:0] dout; reg drive = 0; reg [20:0] raddr; reg [2:0] rpipe = 0;
    assign dq = drive ? dout : 32'bz;   // valid from edge + tAC (5.4 ns) to next edge + tOH (2.5 ns)
    function [20:0] fa(input [20:0] x); fa = (FAULT == 2) ? (x & ~21'h8) : x; endfunction
    always @(posedge sclk) begin
        rpipe <= {rpipe[1:0], 1'b0};
        if (drive) drive <= #2.5 1'b0;
        if (rpipe[1]) begin dout <= #5.4 mem[fa(raddr)] | ((FAULT == 1) ? 32'h20 : 0); drive <= #5.4 1'b1; end
        if (!cs_n) case ({ras_n, cas_n, we_n})
            3'b011: row[ba] <= a;
            3'b101: begin raddr <= {ba, row[ba], a[7:0]}; rpipe[0] <= 1'b1;
                      if (!a[10]) begin $display("FAIL read without auto-precharge"); $finish; end end
            3'b100: begin mem[fa({ba, row[ba], a[7:0]})] <= dq;
                      if (!a[10]) begin $display("FAIL write without auto-precharge"); $finish; end end
        endcase
    end
    task run(input integer f, input integer want_errors);
        begin
            FAULT = f; reset = 1; repeat (10) @(posedge clock); reset = 0;
            wait (passes == 16'd2);
            $display("fault=%0d passes=%0d errors A=%0d B=%0d", f, passes, ea, eb);
            if (want_errors == 0 && (ea != 0 || eb != 0)) begin $display("FAIL: errors with a good memory (A)"); $finish; end
            if (want_errors != 0 && (ea == 0 || eb == 0)) begin $display("FAIL: fault not caught"); $finish; end
        end
    endtask
    initial begin
        run(0, 0); run(1, 1); run(2, 1);
        $display("PASS"); $finish;
    end
    initial begin #400_000_000; $display("FAIL timeout"); $finish; end
endmodule
