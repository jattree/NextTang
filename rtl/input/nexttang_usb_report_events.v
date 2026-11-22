// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Key events from a USB boot keyboard report, for nexttang_usb_next_keyboard.
//
// A boards' own USB host (the Console 138K's usb_hid_host) gives the latest
// report: the modifier byte and up to six held usages. This module compares
// each new report with the last one and sends one event per clock for every
// difference, in the form the BL616's FPGA-Companion uses: the usage in bits
// 6-0 (0x68 + n for modifier bit n) and bit 7 set on release. Releases go
// first, then presses, then the modifiers. Usages from 0x80 up (none on a
// boot keyboard's main keys) and the rollover code 0x01 are ignored.
//
// The report may come from another clock domain: it is sampled twice and
// taken only when two samples in a row agree, so a report caught changing is
// never used.

`default_nettype none

module nexttang_usb_report_events (
    input  wire        clock,
    input  wire        reset,
    input  wire        keyboard,          // the device is a keyboard
    input  wire [7:0]  modifiers,
    input  wire [47:0] keys,              // six usages, key 1 in bits 7-0
    output reg         event_valid = 1'b0,
    output reg  [7:0]  event_byte = 8'd0
);
    reg  [55:0] sample_a = 56'd0, sample_b = 56'd0;
    reg  [55:0] current = 56'd0;          // the report being worked through
    reg  [55:0] previous = 56'd0;         // the report the events have reached
    reg  [4:0]  step = 5'd0;              // 0-5 releases, 6-11 presses, 12-19 modifiers, 20 done
    reg         busy = 1'b0;

    wire [55:0] report = keyboard ? {modifiers, keys} : 56'd0;
    wire [7:0]  cur_mods = current[55:48];
    wire [7:0]  old_mods = previous[55:48];

    function automatic [7:0] usage_at(input [55:0] r, input [2:0] i);
        usage_at = r[8 * i +: 8];
    endfunction
    function automatic in_report(input [55:0] r, input [7:0] u);
        integer j;
        begin
            in_report = 1'b0;
            for (j = 0; j < 6; j = j + 1)
                if (r[8 * j +: 8] == u) in_report = 1'b1;
        end
    endfunction
    function automatic usable(input [7:0] u);
        usable = u > 8'h03 && u < 8'h80;
    endfunction

    wire [7:0] old_usage = usage_at(previous, step[2:0]);

    always @(posedge clock) begin
        sample_a <= report;
        sample_b <= sample_a;
        event_valid <= 1'b0;
        if (reset) begin
            current <= 56'd0; previous <= 56'd0; busy <= 1'b0; step <= 5'd0;
        end else if (!busy) begin
            if (sample_a == sample_b && sample_b != previous) begin
                current <= sample_b;
                busy <= 1'b1;
                step <= 5'd0;
            end
        end else begin
            step <= step + 5'd1;
            if (step < 5'd6) begin
                if (usable(old_usage) && !in_report(current, old_usage)) begin
                    event_valid <= 1'b1; event_byte <= {1'b1, old_usage[6:0]};
                end
            end else if (step < 5'd12) begin
                if (usable(usage_at(current, step - 5'd6)) && !in_report(previous, usage_at(current, step - 5'd6))) begin
                    event_valid <= 1'b1; event_byte <= {1'b0, usage_at(current, step - 5'd6)} & 8'h7F;
                end
            end else if (step < 5'd20) begin
                if (cur_mods[step - 5'd12] != old_mods[step - 5'd12]) begin
                    event_valid <= 1'b1;
                    event_byte <= {!cur_mods[step - 5'd12], 4'b1101, step[2:0] - 3'd4};
                end
            end else begin
                previous <= current;
                busy <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
