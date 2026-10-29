// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Keep the last byte read from each address of one 2 KiB stretch of main
// memory, so code the CPU runs there can be disassembled from the hardware.
//
// Every completed main-memory read whose SRAM address falls in
// [BASE, BASE + 2047] stores the byte returned. A dump request then sends the
// stretch once over the debug UART, one byte per line, labelled with the
// address it has in the CPU's view (CPU_BASE upwards):
//
//     MC aaaa dd
//     ...
//     ME
//
// `sending` is high for the whole dump so the UART can be handed over.

`default_nettype none

module nexttang_memory_capture #(
    parameter integer CLOCK_HZ = 28000000,
    parameter integer BAUD_RATE = 115200,
    parameter [20:0] BASE = 21'h022000,
    parameter [15:0] CPU_BASE = 16'h2000
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        read_done,       // a main-memory read completes now
    input  wire [20:0] read_address,
    input  wire [7:0]  read_data,
    input  wire        dump_request,
    output wire        sending,
    output reg         transmit
);
    // Block RAM starts at zero when the FPGA is configured.
    reg [7:0] stretch [0:2047];

    wire in_stretch = read_address[20:11] == BASE[20:11];

    always @(posedge clock)
        if (read_done && in_stretch)
            stretch[read_address[10:0]] <= read_data;

    // ------------------------------------------------------------- dump
    function [7:0] hex_digit(input [3:0] value);
        hex_digit = (value < 10) ? ("0" + value) : ("a" + value - 10);
    endfunction

    reg [10:0] read_pointer = 0;
    reg [7:0]  entry = 0;
    reg [3:0]  byte_index = 0;
    reg [9:0]  shifter = 10'h3ff;
    reg [3:0]  bit_index = 0;
    reg [31:0] baud_accumulator = 0;
    reg        sending_byte = 1'b0;
    reg [1:0]  phase = 0;          // 0 idle, 1 fetch entry, 2 send line, 3 send end

    always @(posedge clock)
        entry <= stretch[read_pointer];

    wire [15:0] cpu_address = CPU_BASE + {5'b0, read_pointer};

    function [7:0] line_byte(input [3:0] index, input [15:0] address, input [7:0] value);
        case (index)
            4'd0: line_byte = "M";
            4'd1: line_byte = "C";
            4'd2: line_byte = " ";
            4'd3: line_byte = hex_digit(address[15:12]);
            4'd4: line_byte = hex_digit(address[11:8]);
            4'd5: line_byte = hex_digit(address[7:4]);
            4'd6: line_byte = hex_digit(address[3:0]);
            4'd7: line_byte = " ";
            4'd8: line_byte = hex_digit(value[7:4]);
            4'd9: line_byte = hex_digit(value[3:0]);
            4'd10: line_byte = 8'h0d;
            default: line_byte = 8'h0a;
        endcase
    endfunction

    function [7:0] end_byte(input [3:0] index);
        case (index)
            4'd0: end_byte = "M";
            4'd1: end_byte = "E";
            4'd2: end_byte = 8'h0d;
            default: end_byte = 8'h0a;
        endcase
    endfunction

    assign sending = phase != 2'd0 || sending_byte;

    always @(posedge clock) begin
        if (reset) begin
            transmit <= 1'b1;
            phase <= 0;
            sending_byte <= 1'b0;
            bit_index <= 0;
            baud_accumulator <= 0;
        end else if (sending_byte) begin
            baud_accumulator <= baud_accumulator + BAUD_RATE;
            if (baud_accumulator + BAUD_RATE >= CLOCK_HZ) begin
                baud_accumulator <= baud_accumulator + BAUD_RATE - CLOCK_HZ;
                transmit <= shifter[0];
                shifter <= {1'b1, shifter[9:1]};
                if (bit_index == 9) begin
                    bit_index <= 0;
                    sending_byte <= 1'b0;
                end else begin
                    bit_index <= bit_index + 1'b1;
                end
            end
        end else begin
            case (phase)
                2'd0: begin
                    transmit <= 1'b1;
                    if (dump_request) begin
                        read_pointer <= 0;
                        phase <= 2'd1;
                    end
                end
                2'd1: begin
                    // The stretch read has a cycle of latency; wait one here.
                    byte_index <= 0;
                    phase <= 2'd2;
                end
                2'd2: begin
                    shifter <= {1'b1, line_byte(byte_index, cpu_address, entry), 1'b0};
                    sending_byte <= 1'b1;
                    if (byte_index == 4'd11) begin
                        if (read_pointer == 11'h7ff) begin
                            byte_index <= 0;
                            phase <= 2'd3;
                        end else begin
                            read_pointer <= read_pointer + 1'b1;
                            phase <= 2'd1;
                        end
                    end else begin
                        byte_index <= byte_index + 1'b1;
                    end
                end
                default: begin
                    shifter <= {1'b1, end_byte(byte_index), 1'b0};
                    sending_byte <= 1'b1;
                    if (byte_index == 4'd3)
                        phase <= 2'd0;
                    else
                        byte_index <= byte_index + 1'b1;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
