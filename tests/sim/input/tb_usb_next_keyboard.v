// nexttang_usb_next_keyboard against the official keymap's default (US)
// table: USB key events in, the Next's 8x7 matrix out, row by row. The test
// supplies `keymaps` as a Verilog model loaded from rtl/input/keymaps.vhd's
// table (tests/test_nano20k_sims.py writes keymap.mem).
`timescale 1ns/1ps
module keymaps (input wire clock_i, input wire [8:0] addr_wr_i, input wire [8:0] data_i, input wire we_i,
                input wire [8:0] addr_rd_i, output reg [8:0] data_o);
    reg [8:0] ram [0:511];
    initial $readmemb("keymap.mem", ram);
    always @(posedge clock_i) begin
        if (we_i) ram[addr_wr_i] <= data_i;
        data_o <= ram[addr_rd_i];
    end
endmodule

module tb;
    reg clk = 0; always #17.778 clk = ~clk;
    reg reset = 1, ev = 0; reg [7:0] eb = 0;
    reg [8:0] ka = 0; reg [7:0] kd = 0; reg kw = 0;
    reg [2:0] row = 0; wire [6:0] cols;
    nexttang_usb_next_keyboard dut (.clock(clk), .reset(reset), .event_valid(ev), .event_byte(eb),
        .keymap_address(ka), .keymap_data(kd), .keymap_write(kw), .membrane_row(row), .membrane_columns(cols));
    integer errors = 0;
    task key(input [7:0] b); begin @(posedge clk); #1 ev = 1; eb = b; @(posedge clk); #1 ev = 0; repeat (4) @(posedge clk); end endtask
    // expect: the given row's seven columns (0 = down)
    task expect_row(input [2:0] r, input [6:0] want, input [8*24-1:0] what);
        begin row = r; #1; if (cols !== want) begin errors = errors + 1; $display("FAIL %0s: row %0d is %b, want %b", what, r, cols, want); end end
    endtask
    task all_up(input [8*24-1:0] what);
        integer k; begin for (k = 0; k < 8; k = k + 1) expect_row(k, 7'h7F, what); end
    endtask
    initial begin
        repeat (3) @(posedge clk); reset = 0; repeat (2) @(posedge clk);
        all_up("idle");
        key(8'h04); expect_row(1, 7'b1111110, "A down");                       // A: row 1 col 0
        key(8'h84); all_up("A up");
        key(8'h69); expect_row(0, 7'b1111110, "LShift = CAPS");                // left shift adds CAPS SHIFT
        key(8'h1F); expect_row(3, 7'b1111101, "2 down");                       // 2: row 3 col 1
        expect_row(0, 7'b1111110, "CAPS still held");
        key(8'hE9); expect_row(0, 7'b1111111, "CAPS released");
        key(8'h9F); all_up("2 up");
        key(8'h68); expect_row(7, 7'b1111101, "LCtrl = SYMBOL");               // left control adds SYMBOL SHIFT
        key(8'h6D); expect_row(0, 7'b1111110, "RShift = CAPS too");
        key(8'hE8); key(8'hED); all_up("modifiers up");
        key(8'h33); expect_row(4, 7'b1011111, "; is the Next's ; key");        // row 4 col 5
        key(8'h34); expect_row(4, 7'b0011111, "' is the Next's \" key");       // row 4 col 6
        key(8'hB3); key(8'hB4); all_up("; and ' up");
        key(8'h39); expect_row(1, 7'b1011111, "Caps Lock");                   // row 1 col 5
        key(8'hB9);
        key(8'h29); expect_row(3, 7'b1011111, "Esc is BREAK");                // row 3 col 5
        key(8'hA9);
        key(8'h4F); expect_row(6, 7'b0111111, "Right");                       // E0 74: row 6 col 6
        key(8'hCF); all_up("all up again");
        key(8'h68); key(8'h69); key(8'hE8); expect_row(0, 7'b1111110, "CAPS counted apart from SYMBOL");
        expect_row(7, 7'b1111111, "SYMBOL gone");
        key(8'hE9); all_up("counts back to zero");
        key(8'h7F); all_up("unknown usage ignored");
        // NextREG 0x28-0x2B: map set 2 code 1C (A) to B (row 7 col 4)
        @(posedge clk); #1 ka = 9'h01C; kd = 8'b00_111_100; kw = 1; @(posedge clk); #1 kw = 0;
        key(8'h04); expect_row(7, 7'b1101111, "remapped A gives B"); expect_row(1, 7'h7F, "not A");
        key(8'h84);
        reset = 1; @(posedge clk); #1 reset = 0;
        key(8'h04); reset = 1; @(posedge clk); #1 reset = 0; all_up("reset clears the matrix");
        if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
        $finish;
    end
endmodule
