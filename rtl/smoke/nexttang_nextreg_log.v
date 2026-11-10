// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Keep a copy of every NextREG and of the main video and paging ports, and send
// it over the debug UART, so it is possible to see what software has asked the
// machine's display to do when the picture is wrong.
//
// The copy follows the core's NextREG write strobe, which covers writes from
// the CPU and the copper. Port writes are taken from I/O write cycles on the
// CPU bus: 0x123b (Layer 2), 0x7ffd, 0xdffd and 0x1ffd (paging), and any port
// with low byte 0xff (Timex). Values are the last written; registers never
// written read 0x00 here whatever their reset value.
//
// About every PERIOD_CLOCKS, and only just after the status reporter sharing
// the UART pin has finished a line, it sends
//
//     NR0 xx xx ... xx        sixteen lines, registers 0x00 to 0xff
//     ...
//     NRf xx xx ... xx
//     NP 123b=xx 7ffd=xx dffd=xx 1ffd=xx 00ff=xx nn=xxxx
//     NW0 rrdd rrdd ... rrdd  sixteen lines, the last 256 NextREG writes,
//     ...                     register and data, oldest first
//     NWf rrdd rrdd ... rrdd
//
// where nn counts NextREG writes. `sending` tells the board to give it the pin.

`default_nettype none

module nexttang_nextreg_log #(
    parameter integer CLOCK_HZ = 28000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer PERIOD_CLOCKS = 56000000,
    // The other transmitter must have been idle this long before a dump starts.
    parameter integer QUIET_CLOCKS = 28000
) (
    input  wire        clock,
    input  wire        reset,

    input  wire        nr_write,
    input  wire [7:0]  nr_register,
    input  wire [7:0]  nr_data,

    input  wire        iorq_n,
    input  wire        wr_n,
    input  wire        m1_n,
    input  wire [15:0] address,
    input  wire [7:0]  data,

    input  wire        other_transmit,
    output reg         sending,
    output reg         transmit
);
    reg [7:0] registers [0:255];
    reg [7:0] port_123b = 8'h00;
    reg [7:0] port_7ffd = 8'h00;
    reg [7:0] port_dffd = 8'h00;
    reg [7:0] port_1ffd = 8'h00;
    reg [7:0] port_00ff = 8'h00;
    reg [15:0] write_count = 16'h0000;
    reg [15:0] history [0:255];
    reg [7:0] history_pointer = 8'h00;

    wire io_write = !iorq_n && !wr_n && m1_n;

    integer clear;
    initial
        for (clear = 0; clear < 256; clear = clear + 1) begin
            registers[clear] = 8'h00;
            history[clear] = 16'h0000;
        end

    always @(posedge clock)
        if (nr_write)
            registers[nr_register] <= nr_data;

    // The core writes a NextREG on every cycle its strobe is high: a copper
    // write and a waiting CPU write can follow each other with the strobe
    // held, so each cycle is one entry.
    always @(posedge clock)
        if (nr_write)
            history[history_pointer] <= {nr_register, nr_data};

    always @(posedge clock) begin
        if (reset) begin
            write_count <= 16'h0000;
        end else begin
            if (nr_write) begin
                write_count <= write_count + 16'h0001;
                history_pointer <= history_pointer + 8'h01;
            end
            if (io_write) begin
                if (address == 16'h123b) port_123b <= data;
                if (address == 16'h7ffd) port_7ffd <= data;
                if (address == 16'hdffd) port_dffd <= data;
                if (address == 16'h1ffd) port_1ffd <= data;
                if (address[7:0] == 8'hff) port_00ff <= data;
            end
        end
    end

    // ------------------------------------------------------------- dump
    function [7:0] hex_digit(input [3:0] value);
        hex_digit = (value < 10) ? ("0" + value) : ("a" + value - 10);
    endfunction

    (* async_reg = "true" *) reg other_meta = 1'b1;
    (* async_reg = "true" *) reg other_sync = 1'b1;
    reg [31:0] quiet = 0;
    reg [31:0] since_dump = 0;

    // Register lines are 16 entries of 3 bytes after "NRx", then CR LF: 53
    // bytes. The port line is built from a fixed template.
    localparam integer REG_LINE = 53;
    localparam integer PORT_LINE = 54;
    // History lines: "NWx", then 16 entries of " rrdd", then CR LF.
    localparam integer HISTORY_LINE = 85;

    reg [5:0] line = 0;             // 0 to 15 registers, 16 ports, 17 to 32 history
    reg [6:0] column = 0;
    reg [7:0] register_value = 0;
    reg [15:0] history_value = 0;
    reg [7:0] history_base = 0;     // the oldest entry when the dump started
    reg [7:0] current_byte = 0;

    // The register a column of a register line shows.
    wire [3:0] entry = (column - 6'd3) / 6'd3;
    always @(posedge clock)
        register_value <= registers[{line[3:0], entry}];

    // The history entry a column of a history line shows, oldest first.
    reg [6:0] history_column;
    always @(*) history_column = {1'b0, column} - 7'd3;
    wire [3:0] history_entry = history_column / 7'd5;
    wire [3:0] history_row = line[3:0] - 4'd1;   // lines 17 to 32 are rows 0 to 15
    always @(posedge clock)
        history_value <= history[history_base + {history_row, history_entry}];

    function [7:0] history_line_byte(input [6:0] index, input [3:0] row, input [15:0] value);
        reg [6:0] slot;
        begin
            slot = (index - 7'd3) % 7'd5;
            if (index == 7'd0) history_line_byte = "N";
            else if (index == 7'd1) history_line_byte = "W";
            else if (index == 7'd2) history_line_byte = hex_digit(row);
            else if (index == HISTORY_LINE - 2) history_line_byte = 8'h0d;
            else if (index == HISTORY_LINE - 1) history_line_byte = 8'h0a;
            else if (slot == 7'd0) history_line_byte = " ";
            else if (slot == 7'd1) history_line_byte = hex_digit(value[15:12]);
            else if (slot == 7'd2) history_line_byte = hex_digit(value[11:8]);
            else if (slot == 7'd3) history_line_byte = hex_digit(value[7:4]);
            else history_line_byte = hex_digit(value[3:0]);
        end
    endfunction

    function [7:0] port_line_byte(input [5:0] index);
        case (index)
            6'd0: port_line_byte = "N";
            6'd1: port_line_byte = "P";
            6'd2: port_line_byte = " ";
            6'd3: port_line_byte = "1";  6'd4: port_line_byte = "2";
            6'd5: port_line_byte = "3";  6'd6: port_line_byte = "b";
            6'd7: port_line_byte = "=";
            6'd8: port_line_byte = hex_digit(port_123b[7:4]);
            6'd9: port_line_byte = hex_digit(port_123b[3:0]);
            6'd10: port_line_byte = " ";
            6'd11: port_line_byte = "7"; 6'd12: port_line_byte = "f";
            6'd13: port_line_byte = "f"; 6'd14: port_line_byte = "d";
            6'd15: port_line_byte = "=";
            6'd16: port_line_byte = hex_digit(port_7ffd[7:4]);
            6'd17: port_line_byte = hex_digit(port_7ffd[3:0]);
            6'd18: port_line_byte = " ";
            6'd19: port_line_byte = "d"; 6'd20: port_line_byte = "f";
            6'd21: port_line_byte = "f"; 6'd22: port_line_byte = "d";
            6'd23: port_line_byte = "=";
            6'd24: port_line_byte = hex_digit(port_dffd[7:4]);
            6'd25: port_line_byte = hex_digit(port_dffd[3:0]);
            6'd26: port_line_byte = " ";
            6'd27: port_line_byte = "1"; 6'd28: port_line_byte = "f";
            6'd29: port_line_byte = "f"; 6'd30: port_line_byte = "d";
            6'd31: port_line_byte = "=";
            6'd32: port_line_byte = hex_digit(port_1ffd[7:4]);
            6'd33: port_line_byte = hex_digit(port_1ffd[3:0]);
            6'd34: port_line_byte = " ";
            6'd35: port_line_byte = "0"; 6'd36: port_line_byte = "0";
            6'd37: port_line_byte = "f"; 6'd38: port_line_byte = "f";
            6'd39: port_line_byte = "=";
            6'd40: port_line_byte = hex_digit(port_00ff[7:4]);
            6'd41: port_line_byte = hex_digit(port_00ff[3:0]);
            6'd42: port_line_byte = " ";
            6'd43: port_line_byte = "n"; 6'd44: port_line_byte = "n";
            6'd45: port_line_byte = "=";
            6'd46: port_line_byte = hex_digit(write_count[15:12]);
            6'd47: port_line_byte = hex_digit(write_count[11:8]);
            6'd48: port_line_byte = hex_digit(write_count[7:4]);
            6'd49: port_line_byte = hex_digit(write_count[3:0]);
            6'd50: port_line_byte = " ";
            6'd51: port_line_byte = " ";
            6'd52: port_line_byte = 8'h0d;
            default: port_line_byte = 8'h0a;
        endcase
    endfunction

    // A register line byte. Column 0 to 2 are "NR" and the line's digit; then
    // each entry is " xx"; then CR LF.
    function [7:0] register_line_byte(input [5:0] index, input [3:0] row, input [7:0] value);
        reg [5:0] slot;
        begin
            slot = (index - 6'd3) % 6'd3;
            if (index == 6'd0) register_line_byte = "N";
            else if (index == 6'd1) register_line_byte = "R";
            else if (index == 6'd2) register_line_byte = hex_digit(row);
            else if (index == REG_LINE - 2) register_line_byte = 8'h0d;
            else if (index == REG_LINE - 1) register_line_byte = 8'h0a;
            else if (slot == 6'd0) register_line_byte = " ";
            else if (slot == 6'd1) register_line_byte = hex_digit(value[7:4]);
            else register_line_byte = hex_digit(value[3:0]);
        end
    endfunction

    reg [9:0] shifter = 10'h3ff;
    reg [3:0] bit_index = 0;
    reg [31:0] baud_accumulator = 0;
    reg sending_byte = 1'b0;
    reg [1:0] phase = 0;            // 0 wait, 1 settle, 2 send

    always @(posedge clock) begin
        other_meta <= other_transmit;
        other_sync <= other_meta;
        if (reset) begin
            sending <= 1'b0;
            transmit <= 1'b1;
            phase <= 0;
            quiet <= 0;
            since_dump <= 0;
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
                    sending <= 1'b0;
                    quiet <= other_sync ? (quiet == 32'hffffffff ? quiet : quiet + 1) : 0;
                    if (since_dump != 32'hffffffff)
                        since_dump <= since_dump + 1;
                    // Start just after the other transmitter goes quiet, so the
                    // whole dump fits before its next line.
                    if (since_dump >= PERIOD_CLOCKS && quiet == QUIET_CLOCKS) begin
                        since_dump <= 0;
                        sending <= 1'b1;
                        line <= 0;
                        column <= 0;
                        history_base <= history_pointer;
                        phase <= 2'd1;
                    end
                end
                2'd1: begin
                    // One cycle for the register read at this column.
                    phase <= 2'd2;
                end
                2'd2: begin
                    if (line == 6'd16)
                        current_byte = port_line_byte(column[5:0]);
                    else if (line > 6'd16)
                        current_byte = history_line_byte(column, history_row, history_value);
                    else
                        current_byte = register_line_byte(column[5:0], line[3:0], register_value);
                    shifter <= {1'b1, current_byte, 1'b0};
                    sending_byte <= 1'b1;
                    if ((line == 6'd16 && column == PORT_LINE - 1) ||
                        (line > 6'd16 && column == HISTORY_LINE - 1) ||
                        (line < 6'd16 && column == REG_LINE - 1)) begin
                        column <= 0;
                        if (line == 6'd32)
                            phase <= 2'd0;
                        else begin
                            line <= line + 1'b1;
                            phase <= 2'd1;
                        end
                    end else begin
                        column <= column + 1'b1;
                        phase <= 2'd1;
                    end
                end
                default: phase <= 2'd0;
            endcase
        end
    end
endmodule

`default_nettype wire
