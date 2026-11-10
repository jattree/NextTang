// nexttang_sdr_sdram_service against a behavioural SDR SDRAM.
//
// Memory clock 84.375 MHz, machine clock a third of it (as on the Nano).
// The model takes commands on the rising edge of sdram_clk (the inverted
// memory clock), honours DQM byte lanes, and drives read data from tAC
// (5.4 ns) after the CL-th edge until tOH (2.5 ns) after the next.
// Random port A (core-like: request pulse, cycle held while wait is high,
// then released) and port C (held until ack) traffic against a shadow copy.
// Checks: every read returns the shadow byte; ACTIVE-to-ACTIVE >= 6 cycles;
// ACTIVE-to-READ/WRITE >= 2; READ/WRITE always auto-precharge; refreshes no
// further apart than 2 x 7.8 us; wait raised in the request's own cycle.
`timescale 1ns/1ps
module tb;
    parameter integer ACCESSES = 40000;
    parameter integer CAPTURE = 1;
    reg mclk = 0; always #5.926 mclk = ~mclk;               // 84.375 MHz
    reg clk28 = 0; always #17.778 clk28 = ~clk28;            // 28.125 MHz, rises with every third mclk
    reg reset = 1;

    reg a_request = 0, a_cycle = 0, a_read_n = 1; reg [20:0] a_addr = 0; reg [7:0] a_wdata = 0;
    wire [7:0] a_rdata; wire a_wait;
    reg c_request = 0, c_read_n = 1; reg [20:0] c_addr = 0; reg [7:0] c_wdata = 0;
    wire [7:0] c_rdata; wire c_ack, c_busy;
    wire ready, fault;
    wire sclk, cke, cs_n, ras_n, cas_n, we_n; wire [10:0] sa; wire [1:0] sba; wire [3:0] dqm; wire [31:0] dq;

    nexttang_sdr_sdram_service #(.CAPTURE(CAPTURE)) dut (
        .machine_clock(clk28), .memory_clock(mclk), .reset(reset), .ready(ready),
        .a_request(a_request), .a_cycle_request(a_cycle), .a_read_n(a_read_n), .a_address(a_addr),
        .a_write_data(a_wdata), .a_read_data(a_rdata), .a_wait(a_wait),
        .c_request(c_request), .c_read_n(c_read_n), .c_address(c_addr), .c_write_data(c_wdata),
        .c_read_data(c_rdata), .c_ack(c_ack), .c_busy(c_busy), .fault_timeout(fault),
        .sdram_clk(sclk), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
        .sdram_we_n(we_n), .sdram_addr(sa), .sdram_ba(sba), .sdram_dqm(dqm), .sdram_dq(dq));

    // ---------------- SDRAM model
    reg [31:0] mem [0:2097151];
    reg [10:0] row [0:3];
    reg [20:0] raddr; reg [1:0] rpipe = 0; reg drive = 0; reg [31:0] dout;
    assign dq = drive ? dout : 32'bz;
    real last_act [0:3]; real last_ref; integer i;
    initial begin for (i = 0; i < 4; i = i + 1) last_act[i] = -1000; last_ref = -1; end
    integer refreshes = 0;
    always @(posedge sclk) begin
        rpipe <= {rpipe[0], 1'b0};
        if (drive) drive <= #2.5 1'b0;
        if (rpipe[1]) begin dout <= #5.4 mem[raddr]; drive <= #5.4 1'b1; end
        if (!cs_n) case ({ras_n, cas_n, we_n})
            3'b011: begin
                if ($realtime - last_act[sba] < 6 * 11.852 - 0.1) begin $display("FAIL tRC bank %0d %0.1f ns", sba, $realtime - last_act[sba]); $finish; end
                row[sba] <= sa; last_act[sba] = $realtime;
            end
            3'b101, 3'b100: begin
                if ($realtime - last_act[sba] < 2 * 11.852 - 0.1) begin $display("FAIL tRCD"); $finish; end
                if (!sa[10]) begin $display("FAIL no auto-precharge"); $finish; end
                if ({ras_n, cas_n, we_n} == 3'b101) begin raddr <= {sba, row[sba], sa[7:0]}; rpipe[0] <= 1'b1; end
                else begin : wr
                    reg [31:0] w; w = mem[{sba, row[sba], sa[7:0]}];
                    if (!dqm[0]) w[7:0] = dq[7:0];   if (!dqm[1]) w[15:8] = dq[15:8];
                    if (!dqm[2]) w[23:16] = dq[23:16]; if (!dqm[3]) w[31:24] = dq[31:24];
                    mem[{sba, row[sba], sa[7:0]}] = w;
                end
            end
            3'b001: begin
                if (last_ref > 0 && $realtime - last_ref > 2 * 7800.0) begin $display("FAIL refresh gap %0.1f ns", $realtime - last_ref); $finish; end
                last_ref = $realtime; refreshes = refreshes + 1;
            end
        endcase
    end

    // ---------------- shadow and traffic
    reg [7:0] shadow [0:2097151];
    // keep traffic inside a small window so reads hit written data often
    function [20:0] pick(input integer r); pick = {r[3:0], 3'b000, r[13:0]} ; endfunction
    integer a_ops = 0, c_ops = 0, errors = 0, seed = 1;
    initial begin
        for (i = 0; i < 2097152; i = i + 1) begin shadow[i] = 8'h00; end
        for (i = 0; i < 2097152; i = i + 1) mem[i] = 32'h0;
    end

    task automatic port_a(input reg rd, input [20:0] ad, input [7:0] wd);
        begin
            @(posedge clk28); #0.1;
            a_request = 1; a_cycle = 1; a_read_n = !rd; a_addr = ad; a_wdata = wd;
            #0.5 if (!a_wait) begin $display("FAIL wait not raised in the request cycle"); $finish; end
            @(posedge clk28); #0.1 a_request = 0;
            while (a_wait) begin @(posedge clk28); #0.1; end
            // the core samples data at the edge where it sees wait low
            if (rd) begin
                if (a_rdata !== shadow[ad]) begin errors = errors + 1;
                    if (errors < 10) $display("port A read %06h got %02h want %02h", ad, a_rdata, shadow[ad]); end
            end else shadow[ad] = wd;
            @(posedge clk28); #0.1 a_cycle = 0;
            a_ops = a_ops + 1;
        end
    endtask

    // port C runs alongside, like the debugger
    reg c_run = 0;
    always begin
        @(posedge clk28);
        if (c_run && ($random(seed) & 7) == 0) begin : cdo
            reg rd; reg [20:0] ad; reg [7:0] wd;
            rd = $random(seed); ad = pick($random(seed)); ad[20:18] = 3'b111;  // port C keeps to its own region
            wd = $random(seed);
            #0.1 c_request = 1; c_read_n = !rd; c_addr = ad; c_wdata = wd;
            #0.1; while (!c_ack) begin @(posedge clk28); #0.1; end
            @(posedge clk28); #0.1 c_request = 0;   // like the core: it sees the ack a cycle later
            if (rd) begin if (c_rdata !== shadow[ad]) begin errors = errors + 1;
                    if (errors < 10) $display("port C read %06h got %02h want %02h", ad, c_rdata, shadow[ad]); end end
            else shadow[ad] = wd;
            c_ops = c_ops + 1;
        end
    end

    integer n; reg rd; reg [20:0] ad;
    initial begin
        repeat (8) @(posedge mclk); reset = 0;
        wait (ready);
        c_run = 1;
        for (n = 0; n < ACCESSES; n = n + 1) begin
            rd = ($random(seed) & 3) != 0;
            ad = pick($random(seed)); ad[20:18] = 3'b000;
            port_a(rd, ad, $random(seed));
            repeat ($random(seed) & 3) @(posedge clk28);
        end
        c_run = 0; repeat (200) @(posedge clk28);
        $display("port A %0d, port C %0d, refreshes %0d, errors %0d, timeout %0d", a_ops, c_ops, refreshes, errors, fault);
        if (errors == 0 && !fault && refreshes > 2) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
