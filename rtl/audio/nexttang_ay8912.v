// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// AY-3-8912-compatible register, tone, noise and envelope core for the 128K
// Spectrum personality.  The surrounding machine owns the 0xfffd/0xbffd port
// decode; this module receives one-cycle address/data strobes.
module nexttang_ay8912 (
    input  wire       clock,
    input  wire       reset,
    input  wire       select_write,
    input  wire       data_write,
    input  wire       data_read,
    input  wire [7:0] write_data,
    output reg  [7:0] read_data,
    output wire [7:0] channel_a,
    output wire [7:0] channel_b,
    output wire [7:0] channel_c
);
    reg [3:0] selected = 0;
    reg [7:0] registers [0:15];
    integer index;

    reg ay_phase = 0;
    reg [15:0] tone_count_a = 0, tone_count_b = 0, tone_count_c = 0;
    reg tone_a = 0, tone_b = 0, tone_c = 0;
    reg [7:0] noise_count = 0;
    reg [16:0] noise_lfsr = 17'h1ffff;
    reg noise = 0;
    reg [23:0] envelope_count = 0;
    reg [4:0] envelope_level = 0;
    reg envelope_up = 0;
    reg envelope_holding = 0;

    wire [11:0] period_a = {registers[1][3:0], registers[0]};
    wire [11:0] period_b = {registers[3][3:0], registers[2]};
    wire [11:0] period_c = {registers[5][3:0], registers[4]};
    wire [4:0] noise_period = registers[6][4:0];
    wire [15:0] envelope_period = {registers[12], registers[11]};
    wire [3:0] envelope_shape = registers[13][3:0];

    function [7:0] volume_table;
        input [4:0] level;
        begin
            case (level)
                5'd0:  volume_table = 8'h00;
                5'd1:  volume_table = 8'h01;
                5'd2:  volume_table = 8'h01;
                5'd3:  volume_table = 8'h02;
                5'd4:  volume_table = 8'h02;
                5'd5:  volume_table = 8'h03;
                5'd6:  volume_table = 8'h03;
                5'd7:  volume_table = 8'h04;
                5'd8:  volume_table = 8'h06;
                5'd9:  volume_table = 8'h07;
                5'd10: volume_table = 8'h09;
                5'd11: volume_table = 8'h0a;
                5'd12: volume_table = 8'h0c;
                5'd13: volume_table = 8'h0e;
                5'd14: volume_table = 8'h11;
                5'd15: volume_table = 8'h13;
                5'd16: volume_table = 8'h17;
                5'd17: volume_table = 8'h1b;
                5'd18: volume_table = 8'h20;
                5'd19: volume_table = 8'h25;
                5'd20: volume_table = 8'h2c;
                5'd21: volume_table = 8'h35;
                5'd22: volume_table = 8'h3e;
                5'd23: volume_table = 8'h47;
                5'd24: volume_table = 8'h54;
                5'd25: volume_table = 8'h66;
                5'd26: volume_table = 8'h77;
                5'd27: volume_table = 8'h88;
                5'd28: volume_table = 8'ha1;
                5'd29: volume_table = 8'hc0;
                5'd30: volume_table = 8'he0;
                default: volume_table = 8'hff;
            endcase
        end
    endfunction

    function [4:0] fixed_level;
        input [3:0] level;
        begin fixed_level = level == 0 ? 5'd0 : {level, 1'b1}; end
    endfunction

    wire gate_a = (registers[7][0] | tone_a) & (registers[7][3] | noise);
    wire gate_b = (registers[7][1] | tone_b) & (registers[7][4] | noise);
    wire gate_c = (registers[7][2] | tone_c) & (registers[7][5] | noise);
    wire [4:0] level_a = registers[8][4] ? envelope_level : fixed_level(registers[8][3:0]);
    wire [4:0] level_b = registers[9][4] ? envelope_level : fixed_level(registers[9][3:0]);
    wire [4:0] level_c = registers[10][4] ? envelope_level : fixed_level(registers[10][3:0]);

    assign channel_a = gate_a ? volume_table(level_a) : 8'h00;
    assign channel_b = gate_b ? volume_table(level_b) : 8'h00;
    assign channel_c = gate_c ? volume_table(level_c) : 8'h00;

    always @(*) begin
        if (data_read)
            read_data = registers[selected];
        else
            read_data = 8'hff;
    end

    always @(posedge clock) begin
        if (reset) begin
            selected <= 0;
            for (index = 0; index < 16; index = index + 1)
                registers[index] <= 0;
            registers[7] <= 8'hff;
            ay_phase <= 0;
            tone_count_a <= 0; tone_count_b <= 0; tone_count_c <= 0;
            tone_a <= 0; tone_b <= 0; tone_c <= 0;
            noise_count <= 0; noise_lfsr <= 17'h1ffff; noise <= 0;
            envelope_count <= 0; envelope_level <= 0;
            envelope_up <= 0; envelope_holding <= 0;
        end else begin
            if (select_write)
                selected <= write_data[3:0];
            if (data_write) begin
                registers[selected] <= write_data;
                if (selected == 4'd13) begin
                    envelope_count <= 0;
                    envelope_holding <= 0;
                    envelope_up <= write_data[2];
                    envelope_level <= write_data[2] ? 5'd0 : 5'd31;
                end
            end

            // The Spectrum drives the AY at half the 3.5 MHz CPU clock.
            ay_phase <= !ay_phase;
            if (ay_phase) begin
                if (tone_count_a >= ((period_a == 0 ? 12'd1 : period_a) * 8 - 1)) begin
                    tone_count_a <= 0; tone_a <= !tone_a;
                end else tone_count_a <= tone_count_a + 1'b1;
                if (tone_count_b >= ((period_b == 0 ? 12'd1 : period_b) * 8 - 1)) begin
                    tone_count_b <= 0; tone_b <= !tone_b;
                end else tone_count_b <= tone_count_b + 1'b1;
                if (tone_count_c >= ((period_c == 0 ? 12'd1 : period_c) * 8 - 1)) begin
                    tone_count_c <= 0; tone_c <= !tone_c;
                end else tone_count_c <= tone_count_c + 1'b1;

                if (noise_count >= ((noise_period == 0 ? 5'd1 : noise_period) * 8 - 1)) begin
                    noise_count <= 0;
                    noise_lfsr <= {noise_lfsr[0] ^ noise_lfsr[3], noise_lfsr[16:1]};
                    noise <= noise_lfsr[0];
                end else noise_count <= noise_count + 1'b1;

                if (!envelope_holding) begin
                    if (envelope_count >= ((envelope_period == 0 ? 16'd1 : envelope_period) * 256 - 1)) begin
                        envelope_count <= 0;
                        if ((envelope_up && envelope_level == 31) ||
                            (!envelope_up && envelope_level == 0)) begin
                            if (!envelope_shape[3]) begin
                                envelope_level <= 0;
                                envelope_holding <= 1;
                            end else if (envelope_shape[0]) begin
                                envelope_level <= envelope_shape[1] ?
                                    (envelope_up ? 0 : 31) : envelope_level;
                                envelope_holding <= 1;
                            end else begin
                                if (envelope_shape[1]) envelope_up <= !envelope_up;
                                envelope_level <= envelope_shape[1] ?
                                    envelope_level : (envelope_up ? 0 : 31);
                            end
                        end else if (envelope_up)
                            envelope_level <= envelope_level + 1'b1;
                        else
                            envelope_level <= envelope_level - 1'b1;
                    end else envelope_count <= envelope_count + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
