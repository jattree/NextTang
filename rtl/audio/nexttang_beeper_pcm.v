// Convert the one-bit Spectrum speaker level into HDMI-ready signed PCM and
// produce a one-cycle average 48 kHz sample enable in the pixel-clock domain.
module nexttang_beeper_pcm #(
    parameter [31:0] PHASE_INCREMENT = 32'd2771878,
    parameter signed [15:0] AMPLITUDE = 16'sd4096,
    parameter integer BASELINE_SHIFT = 8
) (
    input  wire               clock,
    input  wire               reset,
    input  wire               beeper,
    output reg                audio_ce,
    output reg signed [15:0]  sample
);
    reg [31:0] phase = 32'd0;
    reg beeper_meta = 1'b0;
    reg beeper_sync = 1'b0;
    wire [32:0] phase_sum = {1'b0, phase} + {1'b0, PHASE_INCREMENT};
    wire signed [31:0] amplitude_ext = {{16{AMPLITUDE[15]}}, AMPLITUDE};
    wire signed [31:0] target_q =
        (beeper_sync ? amplitude_ext : -amplitude_ext) <<< 16;
    reg signed [31:0] baseline_q = -(32'sd4096 <<< 16);
    wire signed [31:0] ac_q = target_q - baseline_q;

    always @(posedge clock) begin
        if (reset) begin
            phase <= 32'd0;
            audio_ce <= 1'b0;
            beeper_meta <= 1'b0;
            beeper_sync <= 1'b0;
            baseline_q <= -(amplitude_ext <<< 16);
            sample <= 16'sd0;
        end else begin
            phase <= phase_sum[31:0];
            audio_ce <= phase_sum[32];
            beeper_meta <= beeper;
            beeper_sync <= beeper_meta;
            if (phase_sum[32]) begin
                baseline_q <= baseline_q + (ac_q >>> BASELINE_SHIFT);
                sample <= ac_q >>> 16;
            end
        end
    end
endmodule
