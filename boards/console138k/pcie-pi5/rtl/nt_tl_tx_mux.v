// Packet-locked mux after Sipeed's tl_tx_mux_if. Both inputs use Gowin
// valid/wait: a beat transfers on a rising clock with |valid && !wait.
module nt_tl_tx_mux (
    input wire clk,
    input wire rst,
    input wire demo_sop,
    input wire demo_eop,
    input wire [7:0] demo_valid,
    input wire [255:0] demo_data,
    output wire demo_wait,
    input wire bar_sop,
    input wire bar_eop,
    input wire [7:0] bar_valid,
    input wire [255:0] bar_data,
    output wire bar_wait,
    output wire tx_sop,
    output wire tx_eop,
    output wire [7:0] tx_valid,
    output wire [255:0] tx_data,
    input wire tx_wait
);
    reg locked;
    reg owner_bar;
    wire select_bar = locked ? owner_bar : (|bar_valid);
    assign tx_sop = !rst && (select_bar ? bar_sop : demo_sop);
    assign tx_eop = !rst && (select_bar ? bar_eop : demo_eop);
    assign tx_valid = rst ? 8'd0 : (select_bar ? bar_valid : demo_valid);
    assign tx_data = select_bar ? bar_data : demo_data;
    assign demo_wait = rst || select_bar || tx_wait;
    assign bar_wait = rst || !select_bar || tx_wait;

    always @(posedge clk) begin
        if (rst) begin
            locked <= 1'b0;
            owner_bar <= 1'b0;
        end else if (|tx_valid) begin
            // Lock even an unaccepted SOP. Keep ownership over bubbles
            // and stalls until the EOP beat is actually accepted.
            owner_bar <= select_bar;
            locked <= !(tx_eop && !tx_wait);
        end
    end
endmodule
