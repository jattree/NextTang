// BAR2, one-DW MMIO for the Gowin 256-bit transaction-layer interface.
// See README.md for sources and the deliberately limited request subset.
module nt_bar_completer (
    input wire clk,
    input wire rst,
    input wire link_up,
    input wire [12:0] cfg_busdev,
    input wire cpl_credit_ok,
    input wire rx_sop,
    input wire rx_eop,
    input wire [7:0] rx_valid,
    input wire [255:0] rx_data,
    input wire [5:0] rx_bardec,
    input wire [7:0] rx_err,
    output wire rx_wait,
    output wire tx_sop,
    output wire tx_eop,
    output wire [7:0] tx_valid,
    output wire [255:0] tx_data,
    input wire tx_wait,
    output reg [15:0] rejected,
    // NextTang DMA: register window at BAR2 0x40-0xFF (first 256 bytes only).
    // Everything else keeps the 16-word scratch RAM alias, so every 1-DW
    // read anywhere in the BAR is still answered.
    output reg reg_wr,
    output reg [5:0] reg_waddr,
    output reg [31:0] reg_wdata,
    output wire [5:0] reg_raddr,
    input wire [31:0] reg_rdata
);
    // Header words retain PCIe bit numbering. Payload byte 0 is the
    // most-significant byte of its TL DWORD (LitePCIe Gowin "big" PHY).
    wire [31:0] h0 = rx_data[255:224];
    wire [31:0] h1 = rx_data[223:192];
    wire four_dw = h0[29];
    wire is_write = h0[30];
    wire [31:0] addr = four_dw ? rx_data[159:128] : rx_data[191:160];
    wire [31:0] payload = four_dw ? rx_data[127:96] : rx_data[159:128];
    wire [3:0] be = h1[3:0];
    wire [7:0] expected_valid = is_write ?
        (four_dw ? 8'hf8 : 8'hf0) : (four_dw ? 8'hf0 : 8'he0);
    wire supported = !h0[31] &&
        h0[28:24] == 5'b00000 && h0[9:0] == 10'd1 &&
        // No prefixes, 10-bit tags, TPH, digest, poison or address translation.
        !h0[23] && !h0[19] && !h0[16] && !h0[15] && !h0[14] &&
        h0[11:10] == 2'b00 && h1[7:4] == 4'b0000 &&
        rx_eop && rx_valid == expected_valid && rx_err == 8'd0;

    function [31:0] swap_bytes;
        input [31:0] d;
        begin swap_bytes = {d[7:0], d[15:8], d[23:16], d[31:24]}; end
    endfunction
    function [1:0] first_byte;
        input [3:0] b;
        begin
            if (b[0]) first_byte = 2'd0;
            else if (b[1]) first_byte = 2'd1;
            else if (b[2]) first_byte = 2'd2;
            else if (b[3]) first_byte = 2'd3;
            else first_byte = 2'd0;
        end
    endfunction
    function [2:0] byte_count;
        input [3:0] b;
        reg [2:0] last;
        begin
            if (b[3]) last = 3'd3;
            else if (b[2]) last = 3'd2;
            else if (b[1]) last = 3'd1;
            else last = 3'd0;
            // Byte Count is the span, including holes, not popcount(BE).
            // A zero-BE read still completes with 1 DW and Byte Count 1.
            byte_count = last - {1'b0, first_byte(b)} + 3'd1;
        end
    endfunction

    // 16 words (aliased through the BAR) for the smoke test. Registers, not block RAM: the read shares the write's clock edge and
    // Gowin's block RAM cannot do that write mode.
    reg [31:0] ram [0:15] /* synthesis syn_ramstyle = "registers" */;
    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1) ram[i] = 32'd0;
    end
    wire [31:0] write_data = swap_bytes(payload);
    wire reg_sel = addr[19:8] == 12'd0 && addr[7:6] != 2'b00;
    // Read data is fetched one clock after the request (fill), from a
    // registered address, to keep the hard-IP RX pins off the read mux.
    reg fill;
    reg rd_sel_q, rd_zero_be_q;
    reg [5:0] rd_word_q;
    assign reg_raddr = rd_word_q;
    wire [31:0] read_word = rd_sel_q ? reg_rdata : ram[rd_word_q[3:0]];
    reg pending;
    reg offered;
    reg [127:0] completion;
    wire sending = pending && !fill && (offered || (link_up && cpl_credit_ok));

    // One outstanding read. Stop RX until its completion leaves; never
    // overwrite its requester/tag/data. All consumers must obey rx_wait.
    assign rx_wait = rst || pending;
    assign tx_sop = sending;
    assign tx_eop = sending;
    assign tx_valid = sending ? 8'hf0 : 8'h00;
    assign tx_data = {completion, 128'd0};

    always @(posedge clk) begin
        if (rst) begin
            pending <= 1'b0;
            offered <= 1'b0;
            completion <= 128'd0;
            rejected <= 16'd0;
            fill <= 1'b0;
            rd_sel_q <= 1'b0;
            rd_zero_be_q <= 1'b0;
            rd_word_q <= 6'd0;
            reg_wr <= 1'b0;
            reg_waddr <= 6'd0;
            reg_wdata <= 32'd0;
        end else begin
            reg_wr <= 1'b0;
            if (fill) begin
                completion[31:0] <= rd_zero_be_q ? 32'd0 : swap_bytes(read_word);
                fill <= 1'b0;
            end
            if (sending) begin
                offered <= 1'b1;
                if (!tx_wait) begin
                    pending <= 1'b0;
                    offered <= 1'b0;
                end
            end
            if (!rx_wait && rx_sop && rx_valid[7] && rx_bardec[2]) begin
                if (!supported) begin
                    if (rejected != 16'hffff) rejected <= rejected + 1'b1;
                end else if (is_write && reg_sel) begin
                    // Registers take full-word writes only.
                    if (be == 4'hf) begin
                        reg_wr <= 1'b1;
                        reg_waddr <= addr[7:2];
                        reg_wdata <= write_data;
                    end
                end else if (is_write) begin
                    if (be[0]) ram[addr[5:2]][7:0]   <= write_data[7:0];
                    if (be[1]) ram[addr[5:2]][15:8]  <= write_data[15:8];
                    if (be[2]) ram[addr[5:2]][23:16] <= write_data[23:16];
                    if (be[3]) ram[addr[5:2]][31:24] <= write_data[31:24];
                end else begin
                    // DW0: Fmt/Type=4a, copy TC and Attr, Length=1.
                    // DW1: {bus,device,function=0}, SC, BCM=0, Byte Count.
                    // DW2: Requester ID, Tag, reserved, Lower Address.
                    completion[127:32] <= {
                        (32'h4a000001 | (h0 & 32'h00743000)),
                        cfg_busdev, 3'b000, 4'b0000, 9'd0, byte_count(be),
                        h1[31:8], 1'b0, addr[6:2], first_byte(be)
                    };
                    rd_sel_q <= reg_sel;
                    rd_word_q <= addr[7:2];
                    rd_zero_be_q <= be == 4'd0;
                    fill <= 1'b1;
                    pending <= 1'b1;
                    offered <= 1'b0;
                end
            end
        end
    end
endmodule
