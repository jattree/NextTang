// nexttang_companion_keyboard with KEY_MATRIX 0 (the Nano 20K, whose keys go
// through the Next keymap): no 40-key matrix, F1-F10 straight from the key
// events, and every key byte still reported on keyboard_message.
`timescale 1ns/1ps
module tb_companion_fkeys;
    reg clock = 1'b0;
    always #17.778 clock = !clock;
    reg reset = 1'b1;
    reg cs_n = 1'b1, sclk = 1'b0, mosi = 1'b0;
    wire miso; wire [39:0] keys; wire [10:1] fkeys; wire seen, kmsg; wire [7:0] kbyte;
    nexttang_companion_keyboard #(.KEY_MATRIX(0)) dut (
        .clock(clock), .reset(reset),
        .spi_cs_n(cs_n), .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(miso),
        .keys(keys), .function_keys(fkeys), .seen(seen), .keyboard_message(kmsg), .message_byte(kbyte),
        .joystick_left(), .joystick_right(), .mouse_x(), .mouse_y(), .mouse_buttons(), .mouse_wheel());
    integer errors = 0, messages = 0;
    reg [7:0] got;
    always @(posedge clock) if (kmsg) messages = messages + 1;
    task xfer(input [7:0] tx, output [7:0] rx);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                #25 sclk = 1'b1; mosi = tx[b];
                #25 sclk = 1'b0; rx[b] = miso;
            end
        end
    endtask
    // NextNano's format: [1][1][usage | release bit]
    task key(input [7:0] b); begin cs_n = 1'b0; #40; xfer(8'd1, got); xfer(8'd1, got); xfer(b, got); #40 cs_n = 1'b1; #800; end endtask
    initial begin
        #200 reset = 1'b0; #200;
        key(8'h3A); if (fkeys !== 10'b0000000001) begin errors = errors + 1; $display("FAIL F1 not held (%b)", fkeys); end
        key(8'h43); if (fkeys !== 10'b1000000001) begin errors = errors + 1; $display("FAIL F10 with F1 (%b)", fkeys); end
        key(8'hBA); if (fkeys !== 10'b1000000000) begin errors = errors + 1; $display("FAIL F1 released (%b)", fkeys); end
        key(8'h04); if (keys !== 40'd0 || fkeys !== 10'b1000000000) begin errors = errors + 1; $display("FAIL A touched keys or F-keys"); end
        key(8'h69); key(8'hC3); if (fkeys !== 10'd0) begin errors = errors + 1; $display("FAIL F10 released (%b)", fkeys); end
        if (messages != 6) begin errors = errors + 1; $display("FAIL %0d key messages, want 6", messages); end
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end
endmodule
