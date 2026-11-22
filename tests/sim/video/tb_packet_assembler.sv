// packet_assembler (shared bit selection) against the original, random
// headers, subpackets, data island periods and resets: packet_data, counter
// and every parity register must match on every clock.
module tb;
    logic clk = 0; always #5 clk = ~clk;
    logic reset = 1, dip = 0;
    logic [23:0] header;
    logic [55:0] sub [3:0];
    logic [8:0] pd, pd_ref; logic [4:0] c, c_ref;
    packet_assembler     dut (.clk_pixel(clk), .reset(reset), .data_island_period(dip), .header(header), .sub(sub), .packet_data(pd), .counter(c));
    packet_assembler_ref ref_(.clk_pixel(clk), .reset(reset), .data_island_period(dip), .header(header), .sub(sub), .packet_data(pd_ref), .counter(c_ref));
    integer n, errors = 0;
    initial begin
        header = 0; for (int k = 0; k < 4; k++) sub[k] = 0;
        repeat (3) @(posedge clk); reset = 0;
        for (n = 0; n < 400000; n++) begin
            @(negedge clk);
            if (pd !== pd_ref || c !== c_ref) begin errors++; if (errors < 5) $display("mismatch at %0d: %h %h", n, pd, pd_ref); end
            // new packet contents now and then; island period mostly on, sometimes off; rare resets
            if ($urandom % 37 == 0) begin header = $urandom; for (int k = 0; k < 4; k++) sub[k] = {$urandom, $urandom}; end
            dip = ($urandom % 8) != 0;
            reset = ($urandom % 5000) == 0;
        end
        if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
        $finish;
    end
endmodule
