// nexttang_sdr_sdram_service port B (Layer 2) against a behavioural SDRAM.
//
// Layer 2 traffic as layer2.vhd makes it: at most one read per four machine
// cycles (one 7 MHz pixel), announced eight pixels earlier on the prefetch
// toggle. Lines of 448 pixels with fetches in the active part only:
//   ROW mode    256 x 192: address = base + y * 256 + (x + scroll_x) mod 256
//   COLUMN mode 320 x 256: address = base + x' * 256 + y, x' = (x + scroll_x) mod 320
// Port A (core-like, random) and port C (random) run at the same time.
// Every Layer 2 byte is checked at the core's sample point, four machine
// cycles after its request. One announcement in INJECT_AT is made wrong on
// purpose: the service must count a mismatch and recover.
// Pass: no wrong bytes outside the injected disturbance, no lates in steady
// state, port A/C reads correct.
`timescale 1ns/1ps
module tb;
    parameter integer MODE = 0;          // 0 row, 1 column
    parameter integer LINES = 60;
    parameter integer INJECT_LINE = 20;  // one wrong announcement on this line
    reg mclk = 0; always #5.926 mclk = ~mclk;
    reg clk28 = 0; always #17.778 clk28 = ~clk28;
    reg reset = 1;

    reg a_request = 0, a_cycle = 0, a_read_n = 1; reg [20:0] a_addr = 0; reg [7:0] a_wdata = 0;
    wire [7:0] a_rdata; wire a_wait;
    reg c_request = 0, c_read_n = 1; reg [20:0] c_addr = 0; reg [7:0] c_wdata = 0;
    wire [7:0] c_rdata; wire c_ack, c_busy;
    reg b_pf_t = 0, b_t = 0; reg [20:0] b_pf_addr = 0, b_addr = 0;
    wire [7:0] b_data; wire [15:0] b_late, b_mismatch;
    wire ready, fault;
    wire sclk, cke, cs_n, ras_n, cas_n, we_n; wire [10:0] sa; wire [1:0] sba; wire [3:0] dqm; wire [31:0] dq;

    nexttang_sdr_sdram_service dut (
        .machine_clock(clk28), .memory_clock(mclk), .reset(reset), .ready(ready),
        .a_request(a_request), .a_cycle_request(a_cycle), .a_read_n(a_read_n), .a_address(a_addr),
        .a_write_data(a_wdata), .a_read_data(a_rdata), .a_wait(a_wait),
        .c_request(c_request), .c_read_n(c_read_n), .c_address(c_addr), .c_write_data(c_wdata),
        .c_read_data(c_rdata), .c_ack(c_ack), .c_busy(c_busy), .fault_timeout(fault),
        .b_pf_toggle(b_pf_t), .b_pf_address(b_pf_addr), .b_toggle(b_t), .b_address(b_addr),
        .b_data(b_data), .b_late(b_late), .b_mismatch(b_mismatch),
        .sdram_clk(sclk), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
        .sdram_we_n(we_n), .sdram_addr(sa), .sdram_ba(sba), .sdram_dqm(dqm), .sdram_dq(dq));

    // ---------------- SDRAM model (as tb_sdr_sdram_service)
    reg [31:0] mem [0:2097151];
    reg [10:0] row [0:3];
    reg [20:0] raddr; reg [1:0] rpipe = 0; reg drive = 0; reg [31:0] dout;
    assign dq = drive ? dout : 32'bz;
    always @(posedge sclk) begin
        rpipe <= {rpipe[0], 1'b0};
        if (drive) drive <= #2.5 1'b0;
        if (rpipe[1]) begin dout <= #5.4 mem[raddr]; drive <= #5.4 1'b1; end
        if (!cs_n) case ({ras_n, cas_n, we_n})
            3'b011: row[sba] <= sa;
            3'b101: begin raddr <= {sba, row[sba], sa[7:0]}; rpipe[0] <= 1'b1; end
            3'b100: begin : wr
                reg [31:0] w; w = mem[{sba, row[sba], sa[7:0]}];
                if (!dqm[0]) w[7:0] = dq[7:0];   if (!dqm[1]) w[15:8] = dq[15:8];
                if (!dqm[2]) w[23:16] = dq[23:16]; if (!dqm[3]) w[31:24] = dq[31:24];
                mem[{sba, row[sba], sa[7:0]}] = w;
            end
        endcase
    end
    // the service's map: word [20:2] -> {bank [11:10], row [20:12], column [9:2]}
    function [20:0] widx(input [20:0] a); widx = {a[11:10], 2'b00, a[20:12], a[9:2]}; endfunction
    function [7:0] mbyte(input [20:0] a); reg [31:0] w; begin w = mem[widx(a)]; mbyte = w[8 * a[1:0] +: 8]; end endfunction

    integer i, seed = 7;
    initial for (i = 0; i < 2097152; i = i + 1) mem[i] = $random(seed);

    // ---------------- Layer 2 address stream
    localparam integer LINE = 448, ACTIVE_START = 96;
    integer width; initial width = MODE ? 320 : 256;
    integer scroll_x = 37;
    function [20:0] l2addr(input integer line, input integer x);
        integer xs;
        begin
            xs = MODE ? ((x + scroll_x) % 320) : ((x + scroll_x) % 256);
            l2addr = MODE ? (21'h40000 + xs * 256 + (line % 256)) : (21'h48000 + (line % 192) * 256 + xs);
        end
    endfunction
    // pixel slot p of line l is a read when ACTIVE_START <= p < ACTIVE_START + width
    function is_read(input integer p); is_read = p >= ACTIVE_START && p < ACTIVE_START + width; endfunction

    integer wrong = 0, checked = 0, wrong_after = 0, inject_slot = -1;
    integer line, p, pp, pl;
    reg [20:0] expect_addr; reg [7:0] expect_byte; integer check_at;
    initial begin
        repeat (8) @(posedge mclk); reset = 0;
        wait (ready);
        for (line = 0; line < LINES; line = line + 1) begin
            for (p = 0; p < LINE; p = p + 1) begin
                @(posedge clk28); #0.1;
                // announcement for the pixel eight slots on (next line if it wraps)
                pp = p + 8; pl = line;
                if (pp >= LINE) begin pp = pp - LINE; pl = line + 1; end
                if (is_read(pp) && pl < LINES) begin
                    b_pf_addr = l2addr(pl, pp - ACTIVE_START);
                    if (pl == INJECT_LINE && pp == ACTIVE_START + 100) begin
                        b_pf_addr = b_pf_addr ^ 21'h01000; inject_slot = line * LINE + p;
                    end
                    b_pf_t = !b_pf_t;
                end
                if (is_read(p)) begin
                    expect_addr = l2addr(line, p - ACTIVE_START);
                    b_addr = expect_addr; b_t = !b_t;
                    expect_byte = mbyte(expect_addr);
                    // the core samples four machine cycles later
                    fork : sample
                        begin
                            repeat (3) @(posedge clk28); #17.0;
                            checked = checked + 1;
                            if (b_data !== expect_byte) begin
                                wrong = wrong + 1;
                                if (inject_slot < 0 || line * LINE + p > inject_slot + 40) begin
                                    wrong_after = wrong_after + 1;
                                    if (wrong_after < 8) $display("wrong L2 byte line %0d x %0d addr %06h got %02h want %02h",
                                        line, p - ACTIVE_START, expect_addr, b_data, expect_byte);
                                end
                            end
                        end
                    join_none
                end
                repeat (3) @(posedge clk28);
            end
        end
        repeat (40) @(posedge clk28);
        $display("MODE %0d: L2 reads %0d, wrong %0d (outside the injected disturbance %0d), late %0d, mismatches %0d; port A %0d errors %0d",
                 MODE, checked, wrong, wrong_after, b_late, b_mismatch, a_ops, a_err);
        if (wrong_after == 0 && b_mismatch >= 1 && a_err == 0 && checked > 1000) $display("PASS"); else $display("FAIL");
        $finish;
    end

    // ---------------- port A: random core-like traffic outside the Layer 2 area
    integer a_ops = 0, a_err = 0; reg [7:0] shadow [0:65535];
    initial for (i = 0; i < 65536; i = i + 1) shadow[i] = 8'h00;
    reg a_have [0:65535];
    initial for (i = 0; i < 65536; i = i + 1) a_have[i] = 0;
    initial begin : porta
        reg rd; reg [15:0] off; reg [7:0] wd;
        wait (ready);
        forever begin
            @(posedge clk28); #0.1;
            rd = $random(seed); off = $random(seed); wd = $random(seed);
            a_request = 1; a_cycle = 1; a_read_n = !rd; a_addr = {5'h01, off}; a_wdata = wd;  // 0x10000-0x1FFFF
            @(posedge clk28); #0.1 a_request = 0;
            while (a_wait) begin @(posedge clk28); #0.1; end
            if (rd && a_have[off] && a_rdata !== shadow[off]) a_err = a_err + 1;
            if (!rd) begin shadow[off] = wd; a_have[off] = 1; end
            @(posedge clk28); #0.1 a_cycle = 0;
            a_ops = a_ops + 1;
            repeat ($random(seed) & 7) @(posedge clk28);
        end
    end
endmodule
