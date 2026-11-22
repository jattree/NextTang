// Implementation of HDMI packet ECC calculation.
// By Sameer Puri https://github.com/sameer

module packet_assembler (
    input logic clk_pixel,
    input logic reset,
    input logic data_island_period,
    input logic [23:0] header, // See Table 5-8 Packet Types
    input logic [55:0] sub [3:0],
    output logic [8:0] packet_data, // See Figure 5-4 Data Island Packet and ECC Structure
    output logic [4:0] counter = 5'd0
);

// 32 pixel wrap-around counter. See Section 5.2.3.4 for further information.
always_ff @(posedge clk_pixel)
begin
    if (reset)
        counter <= 5'd0;
    else if (data_island_period)
        counter <= counter + 5'd1;
end
// BCH packets 0 to 3 are transferred two bits at a time, see Section 5.2.3.4 for further information.
wire [5:0] counter_t2 = {counter, 1'b0};
wire [5:0] counter_t2_p1 = {counter, 1'b1};

// Initialize parity bits to 0
logic [7:0] parity [4:0] = '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0};

// NextTang: each subpacket and header bit is selected once and used by both
// the packet output and the ECC below; the parity bits are selected
// separately for the last four counts. Selecting from {parity, sub} for the
// output and from sub for the ECC built two sets of wide multiplexers (about
// 340 LUTs on the Nano 20K). Same output on every clock.
wire [3:0] sub_lo, sub_hi, par_lo, par_hi;
genvar j;
generate
    for (j = 0; j < 4; j++)
    begin: bit_select
        assign sub_lo[j] = sub[j][counter_t2];
        assign sub_hi[j] = sub[j][counter_t2_p1];
        assign par_lo[j] = parity[j][{counter[1:0], 1'b0}];
        assign par_hi[j] = parity[j][{counter[1:0], 1'b1}];
    end
endgenerate
wire header_bit = header[counter];
wire subpacket_period = counter < 5'd28;
wire header_period = counter < 5'd24;
wire [3:0] out_lo = subpacket_period ? sub_lo : par_lo;
wire [3:0] out_hi = subpacket_period ? sub_hi : par_hi;
wire out_header = header_period ? header_bit : parity[4][counter[2:0]];
assign packet_data = {out_hi, out_lo, out_header};

// See Figure 5-5 Error Correction Code generator. Generalization of a CRC with binary BCH.
// See https://web.archive.org/web/20190520020602/http://hamsterworks.co.nz/mediawiki/index.php/Minimal_HDMI#Computing_the_ECC for an explanation of the implementation.
// See https://en.wikipedia.org/wiki/BCH_code#Systematic_encoding:_The_message_as_a_prefix for further information.
function automatic [7:0] next_ecc;
input [7:0] ecc, next_bch_bit;
begin
    next_ecc = (ecc >> 1) ^ ((ecc[0] ^ next_bch_bit) ? 8'b10000011 : 8'd0);
end
endfunction

logic [7:0] parity_next [4:0];

// The parity needs to be calculated 2 bits at a time for blocks 0 to 3.
// There's 56 bits being sent 2 bits at a time over TMDS channels 1 & 2, so the parity bits wouldn't be ready in time otherwise.
logic [7:0] parity_next_next [3:0];

genvar i;
generate
    for(i = 0; i < 5; i++)
    begin: parity_calc
        if (i == 4)
            assign parity_next[i] = next_ecc(parity[i], header_bit);
        else
        begin
            assign parity_next[i] = next_ecc(parity[i], sub_lo[i]);
            assign parity_next_next[i] = next_ecc(parity_next[i], sub_hi[i]);
        end
    end
endgenerate

always_ff @(posedge clk_pixel)
begin
    if (reset)
        parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0};
    else if (data_island_period)
    begin
        if (counter < 5'd28) // Compute ECC only on subpacket data, not on itself
        begin
            parity[3:0] <= parity_next_next;
            if (counter < 5'd24) // Header only has 24 bits, whereas subpackets have 56 and 56 / 2 = 28.
                parity[4] <= parity_next[4];
        end
        else if (counter == 5'd31)
            parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0}; // Reset ECC for next packet
    end
    else
        parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0};
end

endmodule
