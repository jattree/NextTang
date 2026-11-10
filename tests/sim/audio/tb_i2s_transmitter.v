// nexttang_i2s_transmitter: decode the stream as an I2S receiver would (data
// sampled on BCLK rising, MSB one BCLK after the LRCLK edge) and check every
// word against what was presented at the start of its frame.
`timescale 1ns/1ps
module tb;
    reg clock = 0; always #17.778 clock = ~clock;
    reg reset = 1;
    reg signed [15:0] left = 0, right = 0;
    wire bclk, lrclk, data;
    nexttang_i2s_transmitter dut (.clock(clock), .reset(reset), .left(left), .right(right),
        .bclk(bclk), .lrclk(lrclk), .data(data));
    // stimulus: new values every frame, changed mid-frame so a wrong latch time shows
    integer frames = 0, errors = 0, words = 0;
    reg signed [15:0] sent_left [0:255], sent_right [0:255];
    reg lr_prev = 0;
    always @(negedge lrclk) begin   // a frame starts (left word next)
        frames = frames + 1;
    end
    initial begin
        repeat (5) @(posedge clock); reset = 0;
        forever begin
            @(posedge clock);
            if (dut.divide == 0 && dut.bclk && dut.slot == 5'd31) begin   // just before slot 0 begins
                left = $random; right = $random;
                sent_left[frames % 256] = left; sent_right[frames % 256] = right;
            end
        end
    end
    // receiver
    reg [15:0] shift = 0; integer bits = 0; reg cur_lr = 0; reg first = 1; integer wframe = 0;
    always @(posedge bclk) begin
        if (lrclk != cur_lr) begin
            // the bit after the LRCLK edge is the MSB of the new word; the edge's own bit is the old LSB
            if (!first) begin
                shift = {shift[14:0], data};
                words = words + 1;
                if (frames > 2) begin
                    if (cur_lr == 0 && shift !== sent_left[(frames - 1) % 256]) errors = errors + 1;
                    if (cur_lr == 1 && shift !== sent_right[(frames - 2) % 256]) errors = errors + 1;
                end
            end
            first = 0; cur_lr = lrclk; bits = 0; shift = 0;
        end else begin
            shift = {shift[14:0], data}; bits = bits + 1;
        end
    end
    initial begin
        #4_000_000;
        $display("I2S frames %0d words %0d errors %0d", frames, words, errors);
        if (errors == 0 && words > 100) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
