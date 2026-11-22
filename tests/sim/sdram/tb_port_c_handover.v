// Memory port C shared by the rewind ring and the core's debug slave
// (nexttang_port_c_handover in rtl/platform/nexttang_next_machine.v) in front
// of nexttang_sdr_sdram_service, with no SDRAM behind it (the data is not
// looked at).
//
// A ring-like requester takes the port for one access and lets go a cycle
// after its ack; a core-like requester raises its request while the ring has
// the port and holds it until its own ack, as the debug slave does. Every
// core request must be acked. GATE 0 joins the two request lines as they were
// before the fix, to show that this bench catches the fault: the core's
// request is then never started.
`timescale 1ns/1ps
module tb;
    parameter integer GATE = 1;
    parameter integer ROUNDS = 200;
    reg mclk = 0; always #5.926 mclk = ~mclk;
    reg clk28 = 0; initial begin #5.926; forever #17.778 clk28 = ~clk28; end
    reg reset = 1;
    reg ring_take = 0, ring_request = 0, core_request = 0;
    wire gated, request, c_ack, c_busy, ready;
    nexttang_port_c_handover handover (.clock(clk28), .ring_take(ring_take), .ring_request(ring_request),
                                       .core_request(core_request), .request(gated));
    assign request = GATE != 0 ? gated : (ring_take ? ring_request : core_request);
    wire [31:0] dq;
    nexttang_sdr_sdram_service dut (
        .machine_clock(clk28), .memory_clock(mclk), .reset(reset), .ready(ready),
        .a_request(1'b0), .a_cycle_request(1'b0), .a_read_n(1'b1), .a_address(21'd0), .a_write_data(8'd0),
        .c_request(request), .c_read_n(ring_take), .c_address(23'd0), .c_write_data(8'd0),
        .c_ack(c_ack), .c_busy(c_busy),
        .b_pf_toggle(1'b0), .b_pf_address(21'd0), .b_toggle(1'b0), .b_address(21'd0), .sdram_dq(dq));
    wire ring_ack = c_ack && ring_take, core_ack = c_ack && !ring_take;
    integer round, waited, late;
    initial begin
        repeat (8) @(posedge mclk); reset = 0;
        wait (ready); repeat (4) @(posedge clk28);
        for (round = 0; round < ROUNDS; round = round + 1) begin
            // the ring takes the free port for one access
            @(posedge clk28); #0.1 ring_take = 1; ring_request = 1;
            // the core asks 0 to 5 cycles into it
            late = round % 6;
            fork
                begin
                    while (!ring_ack) begin @(posedge clk28); #0.1; end
                    @(posedge clk28); #0.1 ring_request = 0; ring_take = 0;
                end
                begin
                    repeat (late) @(posedge clk28);
                    #0.1 core_request = 1;
                end
            join
            waited = 0;
            while (!core_ack && waited < 400) begin @(posedge clk28); #0.1; waited = waited + 1; end
            if (!core_ack) begin $display("FAIL round %0d: the core's request was never acked", round); $finish; end
            @(posedge clk28); #0.1 core_request = 0;
            repeat (round % 3) @(posedge clk28);
        end
        $display("PASS %0d handovers", ROUNDS); $finish;
    end
endmodule
