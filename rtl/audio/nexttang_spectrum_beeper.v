// ZX Spectrum one-bit speaker latch.
//
// The original machine updates the speaker from bit 4 of any write to an
// even I/O port.  Keep that machine-facing behaviour separate from whichever
// physical audio transport a board uses.
module nexttang_spectrum_beeper (
    input  wire        clock,
    input  wire        reset,
    input  wire        iorq_n,
    input  wire        wr_n,
    input  wire [15:0] address,
    input  wire [7:0]  data,
    output reg         beeper = 1'b0
);
    always @(posedge clock) begin
        if (reset)
            beeper <= 1'b0;
        else if (!iorq_n && !wr_n && !address[0])
            beeper <= data[4];
    end
endmodule
