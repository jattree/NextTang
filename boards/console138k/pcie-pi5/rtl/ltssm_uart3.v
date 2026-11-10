// NextTang addition to Sipeed's TangMega-138K pcie_dma_demo (Apache-2.0):
// report the PCIe hard core's LTSSM state and lane-0 SerDes status on the
// Console's status UART. Every 100 ms at 115200 8N1 from a 100 MHz clock:
//   "L=xx U=u P=p S=ssssssss X=xx Y=yy E=eeee F=ffff A=aa T=tttt\r\n"
// L LTSSM state now, U link up, P PERST# from the Pi.
// Sticky since PERST# last rose (kept while PERST# is low, so the last
// attempt stays readable): S bitmap of LTSSM states seen; X flags ever high:
// 0 CMU ok, 1 REFCLK detect, 2 RX-detect result, 3 PMA RX lock, 4 align,
// 5 K lock, 6 RX electrical idle seen low, 7 seen high; E clock cycles with
// a decode error, F cycles with a disparity error (both saturate).
// Live: Y the same flags now (6 = RX electrical idle low now), A lane
// ASTAT, T lane STAT (13 bits).
// ltssm_uart3 appends " Z=zz C=c0,c1,...,c6": Z live probe2 flags
// {refclk_gate_ack, cmu_gate_ack, cmu1_gate_ack, cm1_refclk_det, cmu1_ok,
// elecidle_h, 0, 0}; C the rising edges of each SerDes clock divided by 16
// in the last 100 ms (Hz = C * 160): cmu_ck_ref, cmu1_ck_ref,
// lane0_cmu_ck_ref, lane0 pcs_rx fabric, lane0 pcs_tx fabric, cmu0, cmu1.
// R/TX: four raw DWORD lanes of last accepted RX/TX SOP; V: RX/TX masks;
// I: function-0 completer ID; J: rejected BAR2 requests. Bundled snapshot
// crosses from tlp_clk, so these fields lag by one report (see README.md).
module ltssm_uart3 (
    input         clk,       // 100 MHz
    input  [4:0]  ltssm,
    input         linkup,
    input         perst_n,
    input  [31:0] probe,     // from SerDes_Top nt_probe
    input  [7:0]  probe2,    // from SerDes_Top nt_probe2
    input  [6:0]  meas,      // SerDes clocks to measure
    input  [7:0]  rxn,       // TLP monitor (asynchronous, display only)
    input  [7:0]  txn,
    input  [5:0]  bars,
    input  [31:0] h0,
    input         tlp_clk,  // source clock for coherent TLP snapshot
    input  [127:0] rx4,
    input  [127:0] tx4,
    input  [7:0] rxv,
    input  [7:0] txv,
    input  [15:0] ident,
    input  [15:0] rejected,
    input  [31:0] crp,       // host credits for posted, non-posted, completion TLPs
    input  [31:0] crn,
    input  [31:0] crc,
    output reg    tx = 1'b1
);
    // Bundled-data mailbox: source holds 304 bits stable until the next
    // 100 ms request. Synchronize request/ack; destination captures only
    // after ack crosses two flops. The report uses the previous snapshot.
    reg snap_request = 0;
    reg req1 = 0, req2 = 0, snap_ack = 0;
    reg ack1 = 0, ack2 = 0, ack_seen = 0;
    reg [303:0] snap_hold = 0, snapshot = 0;
    always @(posedge tlp_clk) begin
        req1 <= snap_request; req2 <= req1;
        if (req2 != snap_ack) begin
            snap_hold <= {rx4, tx4, rxv, txv, ident, rejected};
            snap_ack <= req2;
        end
    end
    always @(posedge clk) begin
        ack1 <= snap_ack; ack2 <= ack1;
        if (ack2 != ack_seen) begin
            snapshot <= snap_hold;
            ack_seen <= ack2;
        end
    end
    wire [127:0] report_rx4 = snapshot[303:176];
    wire [127:0] report_tx4 = snapshot[175:48];
    wire [7:0] report_rxv = snapshot[47:40];
    wire [7:0] report_txv = snapshot[39:32];
    wire [15:0] report_ident = snapshot[31:16];
    wire [15:0] report_rejected = snapshot[15:0];

    reg [4:0] l1 = 0, l2 = 0;
    reg [1:0] f1 = 0, f2 = 0;
    reg [31:0] p1 = 0, p2 = 0;
    always @(posedge clk) begin
        l1 <= ltssm; l2 <= l1;
        f1 <= {perst_n, linkup}; f2 <= f1;
        p1 <= probe; p2 <= p1;
    end
    // probe = {stat[12:0], astat[5:0], disp[1:0], dec[1:0], elecidle, klock, align, rxlock, rxdet, refdet, cmuok}
    wire [6:0] flags_now = {p2[6], p2[5], p2[4], p2[3], p2[2], p2[1], p2[0]};
    wire elecidle = p2[6];
    wire dec_err  = |p2[8:7];
    wire disp_err = |p2[10:9];
    wire [5:0]  astat = p2[16:11];
    wire [12:0] stat  = p2[29:17];

    reg perst_d = 0;
    reg [31:0] seen = 0;
    reg [7:0]  ever = 0;
    reg [15:0] decn = 0, dispn = 0;
    always @(posedge clk) begin
        perst_d <= f2[1];
        if (f2[1] && !perst_d) begin
            seen <= 32'd0; ever <= 8'd0; decn <= 0; dispn <= 0;
        end else begin
            seen <= seen | (32'd1 << l2);
            ever <= ever | {elecidle, ~elecidle, flags_now[5:0]};
            if (dec_err  && decn  != 16'hFFFF) decn  <= decn + 1'b1;
            if (disp_err && dispn != 16'hFFFF) dispn <= dispn + 1'b1;
        end
    end


    // clock meters: divide each clock by 16 in its own domain, count the
    // synchronised edges over each 100 ms report period
    reg [7:0] z1 = 0, z2 = 0;
    always @(posedge clk) begin z1 <= probe2; z2 <= z1; end
    genvar g;
    wire [6:0] msb;
    generate for (g = 0; g < 7; g = g + 1) begin : m
        reg [3:0] div = 0;
        always @(posedge meas[g]) div <= div + 1'b1;
        assign msb[g] = div[3];
    end endgenerate
    reg [6:0] ms1 = 0, ms2 = 0, ms3 = 0;
    reg [23:0] cnt [0:6];
    reg [23:0] cap [0:6];
    integer c;
    always @(posedge clk) begin
        ms1 <= msb; ms2 <= ms1; ms3 <= ms2;
        for (c = 0; c < 7; c = c + 1)
            if (tick == 0) begin cap[c] <= cnt[c]; cnt[c] <= {23'd0, ms2[c] & ~ms3[c]}; end
            else if (ms2[c] & ~ms3[c]) cnt[c] <= cnt[c] + 1'b1;
    end

    function [7:0] hex(input [3:0] n);
        hex = n < 10 ? 8'h30 + n : 8'h41 + n - 10;
    endfunction
    localparam N = 271;                // characters before CR LF
    reg [7:0] line [0:N-1];
    reg [8:0] idx = 0;
    reg [23:0] tick = 0;
    reg [9:0]  baud = 0;
    reg [3:0]  bitn = 0;
    reg [9:0]  shift = 10'h3FF;
    reg        busy = 0;
    wire [7:0] ynow = {1'b0, ~elecidle, flags_now[5:0]};
    integer k;
    always @(posedge clk) begin
        tick <= tick == 24'd9_999_999 ? 24'd0 : tick + 1'b1;
        if (tick == 0 && !busy) begin
            if (ack2 == snap_request) snap_request <= ~snap_request;
            line[0] <= "L"; line[1] <= "="; line[2] <= hex({3'b0, l2[4]}); line[3] <= hex(l2[3:0]);
            line[4] <= " "; line[5] <= "U"; line[6] <= "="; line[7] <= hex({3'b0, f2[0]});
            line[8] <= " "; line[9] <= "P"; line[10] <= "="; line[11] <= hex({3'b0, f2[1]});
            line[12] <= " "; line[13] <= "S"; line[14] <= "=";
            for (k = 0; k < 8; k = k + 1) line[15 + k] <= hex(seen[31 - 4*k -: 4]);
            line[23] <= " "; line[24] <= "X"; line[25] <= "="; line[26] <= hex(ever[7:4]); line[27] <= hex(ever[3:0]);
            line[28] <= " "; line[29] <= "Y"; line[30] <= "="; line[31] <= hex(ynow[7:4]); line[32] <= hex(ynow[3:0]);
            line[33] <= " "; line[34] <= "E"; line[35] <= "=";
            for (k = 0; k < 4; k = k + 1) line[36 + k] <= hex(decn[15 - 4*k -: 4]);
            line[40] <= " "; line[41] <= "F"; line[42] <= "=";
            for (k = 0; k < 4; k = k + 1) line[43 + k] <= hex(dispn[15 - 4*k -: 4]);
            line[47] <= " "; line[48] <= "A"; line[49] <= "="; line[50] <= hex({2'b0, astat[5:4]}); line[51] <= hex(astat[3:0]);
            line[52] <= " "; line[53] <= "T"; line[54] <= "=";
            line[55] <= hex({3'b0, stat[12]}); line[56] <= hex(stat[11:8]); line[57] <= hex(stat[7:4]); line[58] <= hex(stat[3:0]);
            line[59] <= " "; line[60] <= "Z"; line[61] <= "="; line[62] <= hex(z2[7:4]); line[63] <= hex(z2[3:0]);
            line[64] <= " "; line[65] <= "C"; line[66] <= "=";
            for (k = 0; k < 7; k = k + 1) begin
                line[67 + 7*k] <= hex(cap[k][23:20]); line[68 + 7*k] <= hex(cap[k][19:16]);
                line[69 + 7*k] <= hex(cap[k][15:12]); line[70 + 7*k] <= hex(cap[k][11:8]);
                line[71 + 7*k] <= hex(cap[k][7:4]);   line[72 + 7*k] <= hex(cap[k][3:0]);
                line[73 + 7*k] <= ",";
            end
            line[116] <= " "; line[117] <= "Q"; line[118] <= "="; line[119] <= hex(rxn[7:4]); line[120] <= hex(rxn[3:0]);
            line[121] <= " "; line[122] <= "W"; line[123] <= "="; line[124] <= hex(txn[7:4]); line[125] <= hex(txn[3:0]);
            line[126] <= " "; line[127] <= "B"; line[128] <= "="; line[129] <= hex({2'b0, bars[5:4]}); line[130] <= hex(bars[3:0]);
            line[131] <= " "; line[132] <= "H"; line[133] <= "="; line[134] <= " ";
            for (k = 0; k < 8; k = k + 1) line[135 + k] <= hex(h0[31 - 4*k -: 4]);
            line[143] <= " "; line[144] <= "K";
            for (k = 0; k < 8; k = k + 1) begin
                line[145 + k] <= hex(crp[31 - 4*k -: 4]); line[154 + k] <= hex(crn[31 - 4*k -: 4]);
                line[163 + k] <= hex(crc[31 - 4*k -: 4]);
            end
            line[153] <= "/"; line[162] <= "/"; line[171] <= ".";
            line[172] <= " "; line[173] <= "R"; line[174] <= "=";
            line[210] <= " "; line[211] <= "T"; line[212] <= "X"; line[213] <= "=";
            for (k = 0; k < 32; k = k + 1) begin
                line[175 + k + k/8] <= hex(report_rx4[127 - 4*k -: 4]);
                line[214 + k + k/8] <= hex(report_tx4[127 - 4*k -: 4]);
            end
            line[183] <= "/"; line[192] <= "/"; line[201] <= "/";
            line[222] <= "/"; line[231] <= "/"; line[240] <= "/";
            line[249] <= " "; line[250] <= "V"; line[251] <= "=";
            line[252] <= hex(report_rxv[7:4]); line[253] <= hex(report_rxv[3:0]);
            line[254] <= "/";
            line[255] <= hex(report_txv[7:4]); line[256] <= hex(report_txv[3:0]);
            line[257] <= " "; line[258] <= "I"; line[259] <= "=";
            line[264] <= " "; line[265] <= "J"; line[266] <= "=";
            for (k = 0; k < 4; k = k + 1) begin
                line[260 + k] <= hex(report_ident[15 - 4*k -: 4]);
                line[267 + k] <= hex(report_rejected[15 - 4*k -: 4]);
            end
            idx <= 0; busy <= 1; bitn <= 0; baud <= 0;
        end else if (busy) begin
            if (bitn == 0 && baud == 0)
                shift <= {1'b1, (idx == N ? 8'h0D : idx == N + 1 ? 8'h0A : line[idx]), 1'b0};
            if (baud == 10'd867) begin
                baud <= 0;
                tx <= shift[0];
                shift <= {1'b1, shift[9:1]};
                if (bitn == 4'd9) begin
                    bitn <= 0;
                    if (idx == N + 1) busy <= 0; else idx <= idx + 1'b1;
                end else bitn <= bitn + 1'b1;
            end else baud <= baud + 1'b1;
        end
    end
endmodule
