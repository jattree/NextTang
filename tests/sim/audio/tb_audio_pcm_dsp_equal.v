// The DSP-block form of nexttang_zxnext_audio_pcm must give the same samples
// as the ordinary one. Needs Gowin's ALU54D simulation model.
`timescale 1ns/1ps
`default_nettype none
module GSR; wire GSRO = 1'b1; endmodule
module tb_audio_pcm_dsp_equal;
    reg core_clock = 0, clock = 0, reset = 1;
    reg [12:0] core_left = 0, core_right = 0;
    wire ce_a, ce_b;
    wire signed [15:0] left_a, right_a, left_b, right_b;
    nexttang_zxnext_audio_pcm #(.PHASE_INCREMENT(32'd7635497), .DSP(0)) plain (
        .core_clock(core_clock), .core_left(core_left), .core_right(core_right),
        .clock(clock), .reset(reset), .audio_ce(ce_a), .left(left_a), .right(right_a));
    nexttang_zxnext_audio_pcm #(.PHASE_INCREMENT(32'd7635497), .DSP(1)) dsp (
        .core_clock(core_clock), .core_left(core_left), .core_right(core_right),
        .clock(clock), .reset(reset), .audio_ce(ce_b), .left(left_b), .right(right_b));
    always #17.857 core_clock = !core_clock;
    always #18.519 clock = !clock;             // 27 MHz
    // a loud square wave, a quiet one, silence, and a step to full scale
    integer seed = 7;
    always #300000 core_left = (core_left == 13'd6000) ? 13'd200 : 13'd6000;
    always #1100000 core_right = $random(seed) & 13'h1fff;
    reg signed [15:0] kept_l [0:8191], kept_r [0:8191];
    integer wrote = 0, read = 0, errors = 0;
    always @(posedge clock) begin
        if (ce_a) begin kept_l[wrote] = left_a; kept_r[wrote] = right_a; wrote = wrote + 1; end
        if (ce_b) begin
            if (read >= wrote && !(read == wrote && ce_a)) begin
                if (errors < 5) $display("FAIL dsp sample %0d came before the plain one", read);
                errors = errors + 1;
            end else if (kept_l[read] !== left_b || kept_r[read] !== right_b) begin
                if (errors < 5) $display("FAIL sample %0d: plain %0d %0d, dsp %0d %0d", read, kept_l[read], kept_r[read], left_b, right_b);
                errors = errors + 1;
            end
            read = read + 1;
        end
    end
    initial begin
        #2000 reset = 0;
        #60000000;
        if (read < 2500) begin $display("FAIL only %0d samples compared", read); errors = errors + 1; end
        if (wrote - read > 1 || read - wrote > 1) begin $display("FAIL counts differ: %0d plain, %0d dsp", wrote, read); errors = errors + 1; end
        if (errors == 0) $display("PASS %0d samples equal", read); else $display("FAIL (%0d)", errors);
        $finish;
    end
endmodule
`default_nettype wire
