// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// A real-time clock for boards without the Next's DS1307 chip: an I2C target
// at the DS1307's address (0x68) on the core's bit-banged I2C lines, with the
// seven time registers kept in fabric. Written from the DS1307's register
// description (registers 0 to 6: seconds, minutes, hours in 24-hour form, day
// of the week 1 to 7, date, month, year, each in BCD).
//
// Nothing keeps time while the board is off. The time comes from one of:
//   - the debug UART: C and fourteen decimal digits, the seven registers in
//     order (ss mm hh 0w dd mm yy), e.g. C30451702171126 for 17:45:30 on
//     Tuesday (2) 17 November 2026;
//   - the Next itself writing the registers over I2C (NextZXOS's .date and
//     .time), as on a real machine.
// Until then the clock runs from 00:00:00 on 01/01/00 and `valid` is low.
//
// Registers 0x3E and 0x3F read 5A 58 ("ZX"), the signature NextZXOS's RTC
// driver looks for in the chip's spare memory; the other spare bytes read 0
// and writes to them are dropped.
//
// scl and sda_in are the levels the core drives (1 released, 0 low); sda_out
// is this target's drive in the same sense. The line the core reads back is
// sda_in & sda_out. All in the `clock` domain, as the core's I2C port is.

`default_nettype none

module nexttang_rtc #(
    parameter integer CLOCK_HZ = 28000000,
    // 1: the one-second counter in a Gowin GW2A DSP block (ALU54D), which
    // frees its logic cells; 0: ordinary logic, for simulation and other parts.
    parameter integer DSP_PRESCALER = 0
) (
    input  wire       clock,
    input  wire       reset,
    input  wire       scl,
    input  wire       sda_in,
    output reg        sda_out = 1'b1,
    // debug UART command bytes
    input  wire       command_valid,
    input  wire [7:0] command_byte,
    output reg        valid = 1'b0            // the time has been set
);
    // ------------------------------------------------------------ the time
    reg [6:0] seconds = 7'h00, minutes = 7'h00;
    reg [5:0] hours = 6'h00, date = 6'h01;
    reg [2:0] weekday = 3'd1;
    reg [4:0] month = 5'h01;
    reg [7:0] year = 8'h00;

    reg [24:0] prescale = 25'd0;
    reg        tick_waiting = 1'b0;
    wire       second;
    wire       restart;                  // the seconds register is being written
    generate
    if (DSP_PRESCALER != 0) begin : dsp_prescaler
        // Counts up from PRESET; bit 25 of the sum marks the second, and the
        // count starts again from PRESET then or at a restart: CLOCK_HZ clocks
        // from one mark to the next.
        localparam [25:0] PRESET = 26'd33554432 - CLOCK_HZ + 26'd1;
        wire [53:0] sum;
        wire        again = sum[25] | restart;
        ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
                 .OUT_REG(1'b1), .B_ADD_SUB(1'b0), .C_ADD_SUB(1'b0), .ALUD_MODE(0),
                 .ALU_RESET_MODE("SYNC")) counter (
            .A(again ? {28'd0, PRESET} : 54'd1), .B(54'd0), .ASIGN(1'b0), .BSIGN(1'b0),
            .ACCLOAD(!again), .CASI(55'd0), .CLK(clock), .CE(1'b1), .RESET(1'b0),
            .DOUT(sum), .CASO());
        assign second = sum[25];
    end else begin : logic_prescaler
        assign second = prescale == CLOCK_HZ - 1;
    end
    endgenerate

    // last day of the month, BCD
    wire leap = year[4] ? (year[3:0] == 4'd2 || year[3:0] == 4'd6)
                        : (year[3:0] == 4'd0 || year[3:0] == 4'd4 || year[3:0] == 4'd8);
    reg [5:0] last_day;
    always @* begin
        case (month)
            5'h02: last_day = leap ? 6'h29 : 6'h28;
            5'h04, 5'h06, 5'h09, 5'h11: last_day = 6'h30;
            default: last_day = 6'h31;
        endcase
    end

    // ------------------------------------------------------- I2C target
    reg       scl_was = 1'b1, sda_was = 1'b1;
    reg       active = 1'b0;         // between a START addressed to us and a STOP
    reg       sending = 1'b0;
    reg       addressed = 1'b0;      // the address byte has been taken
    reg       pointed = 1'b0;        // the register pointer has been taken
    reg       master_ack = 1'b0;
    reg       is_read = 1'b0;       // this transfer's address byte asked to read
    reg [3:0] count = 4'd0;          // rising clock edges in this byte
    reg [7:0] shift = 8'd0;
    reg [5:0] pointer = 6'd0;

    reg [7:0] read_byte;
    always @* begin
        case (pointer)
            6'd0: read_byte = {1'b0, seconds};
            6'd1: read_byte = {1'b0, minutes};
            6'd2: read_byte = {2'b00, hours};
            6'd3: read_byte = {5'b00000, weekday};
            6'd4: read_byte = {2'b00, date};
            6'd5: read_byte = {3'b000, month};
            6'd6: read_byte = year;
            6'h3e: read_byte = 8'h5a;
            6'h3f: read_byte = 8'h58;
            default: read_byte = 8'h00;
        endcase
    end

    // a register write, from I2C or from the debug UART
    reg       write = 1'b0;
    reg [2:0] write_index = 3'd0;
    reg [7:0] write_value = 8'd0;
    assign    restart = write && write_index == 3'd0;

    // C and fourteen decimal digits
    reg [3:0] digits_left = 4'd0;
    reg [3:0] high_digit = 4'd0;
    wire      is_digit = command_byte >= "0" && command_byte <= "9";

    wire start = scl && scl_was && sda_was && !sda_in;
    wire stop = scl && scl_was && !sda_was && sda_in;
    wire rising = scl && !scl_was;
    wire falling = !scl && scl_was;

    always @(posedge clock) begin
        scl_was <= scl;
        sda_was <= sda_in;
        write <= 1'b0;

        // ---- time keeping; a tick waits while a transfer is under way
        if (DSP_PRESCALER == 0) prescale <= second ? 25'd0 : prescale + 25'd1;
        if (second) tick_waiting <= 1'b1;
        if (tick_waiting && !active && !write) begin
            tick_waiting <= 1'b0;
            if (seconds != 7'h59) begin
                seconds <= seconds[3:0] == 4'd9 ? {seconds[6:4] + 3'd1, 4'd0} : seconds + 7'd1;
            end else begin
                seconds <= 7'h00;
                if (minutes != 7'h59) begin
                    minutes <= minutes[3:0] == 4'd9 ? {minutes[6:4] + 3'd1, 4'd0} : minutes + 7'd1;
                end else begin
                    minutes <= 7'h00;
                    if (hours != 6'h23) begin
                        hours <= hours[3:0] == 4'd9 ? {hours[5:4] + 2'd1, 4'd0} : hours + 6'd1;
                    end else begin
                        hours <= 6'h00;
                        weekday <= weekday == 3'd7 ? 3'd1 : weekday + 3'd1;
                        if (date != last_day) begin
                            date <= date[3:0] == 4'd9 ? {date[5:4] + 2'd1, 4'd0} : date + 6'd1;
                        end else begin
                            date <= 6'h01;
                            if (month != 5'h12) begin
                                month <= month[3:0] == 4'd9 ? 5'h10 : month + 5'd1;
                            end else begin
                                month <= 5'h01;
                                if (year[3:0] != 4'd9) year <= year + 8'd1;
                                else year <= {year[7:4] == 4'd9 ? 4'd0 : year[7:4] + 4'd1, 4'd0};
                            end
                        end
                    end
                end
            end
        end

        if (write) begin
            valid <= 1'b1;
            case (write_index)
                3'd0: begin
                    seconds <= write_value[6:0];
                    if (DSP_PRESCALER == 0) prescale <= 25'd0;
                    tick_waiting <= 1'b0;
                end
                3'd1: minutes <= write_value[6:0];
                3'd2: hours <= write_value[5:0];
                3'd3: weekday <= write_value[2:0];
                3'd4: date <= write_value[5:0];
                3'd5: month <= write_value[4:0];
                3'd6: year <= write_value;
                default: ;
            endcase
        end

        // ---- debug UART
        if (command_valid) begin
            if (command_byte == "C") begin
                digits_left <= 4'd14;
            end else if (digits_left != 4'd0 && is_digit) begin
                digits_left <= digits_left - 4'd1;
                if (digits_left[0]) begin           // the second digit of a pair
                    write <= 1'b1;
                    write_index <= 3'd7 - digits_left[3:1] - 3'd1;
                    write_value <= {high_digit, command_byte[3:0]};
                end else begin
                    high_digit <= command_byte[3:0];
                end
            end else begin
                digits_left <= 4'd0;
            end
        end

        // ---- I2C
        if (start) begin
            active <= 1'b1;
            sending <= 1'b0;
            addressed <= 1'b0;
            count <= 4'd0;
            sda_out <= 1'b1;
        end else if (stop) begin
            active <= 1'b0;
            sending <= 1'b0;
            sda_out <= 1'b1;
        end else if (active && rising) begin
            count <= count + 4'd1;
            if (count == 4'd8) master_ack <= !sda_in;
            else if (!sending) shift <= {shift[6:0], sda_in};
        end else if (active && falling) begin
            if (!sending) begin
                if (count == 4'd8) begin
                    // a whole byte has arrived
                    if (!addressed) begin
                        if (shift[7:1] == 7'h68) begin
                            addressed <= 1'b1;
                            sda_out <= 1'b0;
                            if (!shift[0]) pointed <= 1'b0;
                        end else begin
                            active <= 1'b0;
                        end
                    end else begin
                        sda_out <= 1'b0;
                        if (!pointed) begin
                            pointed <= 1'b1;
                            pointer <= shift[5:0];
                        end else begin
                            if (pointer < 6'd7) begin
                                write <= 1'b1;
                                write_index <= pointer[2:0];
                                write_value <= shift;
                            end
                            pointer <= pointer + 6'd1;
                        end
                    end
                end else if (count == 4'd9) begin
                    count <= 4'd0;
                    if (is_read) begin
                        // a read: the first data bit goes out now
                        sending <= 1'b1;
                        shift <= read_byte;
                        sda_out <= read_byte[7];
                        pointer <= pointer + 6'd1;
                    end else begin
                        sda_out <= 1'b1;
                    end
                end
            end else begin
                if (count == 4'd8) begin
                    sda_out <= 1'b1;                    // the master's acknowledge slot
                end else if (count == 4'd9) begin
                    count <= 4'd0;
                    if (master_ack) begin
                        shift <= read_byte;
                        sda_out <= read_byte[7];
                        pointer <= pointer + 6'd1;
                    end else begin
                        sending <= 1'b0;
                        active <= 1'b0;
                        sda_out <= 1'b1;
                    end
                end else begin
                    sda_out <= shift[6];
                    shift <= {shift[6:0], 1'b0};
                end
            end
        end

        if (reset) begin
            active <= 1'b0;
            sending <= 1'b0;
            sda_out <= 1'b1;
            digits_left <= 4'd0;
        end
    end

    // The address byte's read bit must outlive the data bytes of a write
    // (which also pass through `shift`): a transfer is a read only when its
    // own address byte said so.
    always @(posedge clock)
        if (active && falling && !sending && count == 4'd8 && !addressed) is_read <= shift[0];
endmodule

`default_nettype wire
