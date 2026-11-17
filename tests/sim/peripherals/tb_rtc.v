`timescale 1ns/1ps
`default_nettype none
module tb_rtc;
    reg clock = 0; always #5 clock = !clock;
    reg reset = 1, scl = 1, sda = 1, cv = 0; reg [7:0] cb = 0;
    wire sda_t, valid;
    wire line = sda & sda_t;
    nexttang_rtc #(.CLOCK_HZ(20000)) dut (.clock(clock), .reset(reset), .scl(scl), .sda_in(sda), .sda_out(sda_t),
        .command_valid(cv), .command_byte(cb), .valid(valid));
    integer errors = 0; reg ack; reg [7:0] got; reg [7:0] r [0:7]; integer i;
    task i2c_start; begin sda = 1; #100 scl = 1; #100 sda = 0; #100 scl = 0; #100; end endtask
    task i2c_stop; begin sda = 0; #100 scl = 1; #100 sda = 1; #100; end endtask
    task i2c_write(input [7:0] b); integer k; begin
        for (k = 7; k >= 0; k = k - 1) begin sda = b[k]; #100 scl = 1; #100 scl = 0; #100; end
        sda = 1; #100 scl = 1; #50 ack = !line; #50 scl = 0; #100; end endtask
    task i2c_read(input last); integer k; begin
        sda = 1;
        for (k = 7; k >= 0; k = k - 1) begin #100 scl = 1; #50 got[k] = line; #50 scl = 0; #100; end
        sda = last; #100 scl = 1; #100 scl = 0; #100 sda = 1; end endtask
    task read_time; begin
        i2c_start; i2c_write(8'hd0); if (!ack) begin $display("FAIL no ack on address"); errors = errors + 1; end
        i2c_write(8'h00); i2c_start; i2c_write(8'hd1);
        for (i = 0; i < 7; i = i + 1) begin i2c_read(i == 6); r[i] = got; end
        i2c_stop; end endtask
    task check(input [55:0] want, input [255:0] what); begin
        read_time;
        if ({r[0], r[1], r[2], r[3], r[4], r[5], r[6]} !== want) begin
            $display("FAIL %0s: %h %h %h %h %h %h %h", what, r[0], r[1], r[2], r[3], r[4], r[5], r[6]); errors = errors + 1; end
        end endtask
    task uart(input [7:0] b); begin @(negedge clock); cb = b; cv = 1; @(negedge clock); cv = 0; end endtask
    task uart_time(input [55:0] v); integer k; begin
        uart("C"); for (k = 13; k >= 0; k = k - 1) uart(8'h30 + v[k*4 +: 4]); end endtask
    initial begin
        #100 reset = 0; #100;
        if (valid) begin $display("FAIL valid before set"); errors = errors + 1; end
        // another address is not acknowledged
        i2c_start; i2c_write(8'ha0); if (ack) begin $display("FAIL acked a foreign address"); errors = errors + 1; end i2c_stop;
        // set over I2C: 23:59:58 Monday(1) 28/02/28
        i2c_start; i2c_write(8'hd0); i2c_write(8'h00);
        i2c_write(8'h58); i2c_write(8'h59); i2c_write(8'h23); i2c_write(8'h01); i2c_write(8'h28); i2c_write(8'h02); i2c_write(8'h28);
        if (!ack) begin $display("FAIL no ack on data"); errors = errors + 1; end
        i2c_stop;
        if (!valid) begin $display("FAIL valid not set"); errors = errors + 1; end
        check(56'h58_59_23_01_28_02_28, "read back");
        #(20000*10*2);
        check(56'h00_00_00_02_29_02_28, "leap day rollover");
        // set over the UART: 23:59:59 Friday(5) 31/12/99
        uart_time(56'h59_59_23_05_31_12_99);
        check(56'h59_59_23_05_31_12_99, "UART set");
        #(20000*10);
        check(56'h00_00_00_06_01_01_00, "century rollover");
        uart_time(56'h59_59_09_07_30_09_26);
        #(20000*10);
        check(56'h00_00_10_07_30_09_26, "hour carry");
        uart_time(56'h59_59_23_07_30_09_26);
        #(20000*10);
        check(56'h00_00_00_01_01_10_26, "September to October, Sunday to Monday");
        // signature
        i2c_start; i2c_write(8'hd0); i2c_write(8'h3e); i2c_start; i2c_write(8'hd1);
        i2c_read(0); r[0] = got; i2c_read(1); r[1] = got; i2c_stop;
        if (r[0] !== 8'h5a || r[1] !== 8'h58) begin $display("FAIL signature %h %h", r[0], r[1]); errors = errors + 1; end
        // a write to spare memory changes nothing
        i2c_start; i2c_write(8'hd0); i2c_write(8'h3e); i2c_write(8'h00); i2c_write(8'h00); i2c_stop;
        i2c_start; i2c_write(8'hd0); i2c_write(8'h3e); i2c_start; i2c_write(8'hd1); i2c_read(1); i2c_stop;
        if (got !== 8'h5a) begin $display("FAIL signature after write %h", got); errors = errors + 1; end
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end
endmodule
`default_nettype wire
