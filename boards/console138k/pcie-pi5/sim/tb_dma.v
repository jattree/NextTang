`timescale 1ns/1ps
// NextTang DMA: completer + DMA writer + inner TX mux, driven like the Pi
// drives BAR2, with a root-complex model that parses every transmitted TLP.
module tb_dma;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, link_up = 1, cpl_credit = 1, p_credit = 1;
    reg [12:0] busdev = {8'h01, 5'd0};
    reg rx_sop = 0, rx_eop = 0;
    reg [7:0] rx_valid = 0;
    reg [255:0] rx_data = 0;
    wire rx_wait;
    wire [15:0] rejected;
    // completer TX, DMA TX, muxed TX
    wire c_sop, c_eop, c_wait, d_sop, d_eop, d_wait, t_sop, t_eop;
    wire [7:0] c_valid, d_valid, t_valid;
    wire [255:0] c_data, d_data, t_data;
    reg t_wait = 0;
    wire reg_wr;
    wire [5:0] reg_waddr, reg_raddr;
    wire [31:0] reg_wdata, reg_rdata;

    nt_bar_completer cpl (
        .clk(clk), .rst(rst), .link_up(link_up), .cfg_busdev(busdev),
        .cpl_credit_ok(cpl_credit), .rx_sop(rx_sop), .rx_eop(rx_eop),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_bardec(6'b000100),
        .rx_err(8'd0), .rx_wait(rx_wait), .tx_sop(c_sop), .tx_eop(c_eop),
        .tx_valid(c_valid), .tx_data(c_data), .tx_wait(c_wait),
        .rejected(rejected), .reg_wr(reg_wr), .reg_waddr(reg_waddr),
        .reg_wdata(reg_wdata), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata));
    nt_dma_writer dma (
        .clk(clk), .rst_in(rst), .link_up(link_up), .cfg_busdev(busdev),
        .p_credit_ok(p_credit), .reg_wr(reg_wr), .reg_waddr(reg_waddr),
        .reg_wdata(reg_wdata), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
        .tx_sop(d_sop), .tx_eop(d_eop), .tx_valid(d_valid), .tx_data(d_data),
        .tx_wait(d_wait));
    nt_tl_tx_mux mux (
        .clk(clk), .rst(rst),
        .demo_sop(d_sop), .demo_eop(d_eop), .demo_valid(d_valid),
        .demo_data(d_data), .demo_wait(d_wait),
        .bar_sop(c_sop), .bar_eop(c_eop), .bar_valid(c_valid),
        .bar_data(c_data), .bar_wait(c_wait),
        .tx_sop(t_sop), .tx_eop(t_eop), .tx_valid(t_valid), .tx_data(t_data),
        .tx_wait(t_wait));

    integer failures = 0;
    reg debug_hdr = 0;
    task check;
        input ok;
        input [639:0] what;
        begin
            if (ok !== 1'b1) begin
                $display("FAIL: %0s at %0t", what, $time);
                failures = failures + 1;
                if (failures > 20) $finish;
            end
        end
    endtask

    // ---------------- host memory model ----------------
    localparam integer MEMW = (16 * 1024 * 1024) / 4 + 2048; // window + guard
    reg [31:0] mem [0:MEMW-1];
    reg written [0:MEMW-1];
    reg [63:0] win_base;    // what the test programmed
    reg [31:0] win_len;
    reg [31:0] win_seed;
    reg win_mode;
    reg [10:0] win_pay;
    integer tlps_seen, bytes_seen, cpl_seen, outside, crossings, oversize, badhdr;
    integer max_tlp;

    // Independent pattern model (CPU numeric order).
    function [31:0] model_pat;
        input m;
        input [31:0] seed, i;
        reg [31:0] x;
        begin
            x = seed + i;
            if (m) begin
                x = x ^ {x[18:0], 13'd0};
                x = x ^ {17'd0, x[31:17]};
                x = x ^ {x[26:0], 5'd0};
            end
            model_pat = x;
        end
    endfunction

    // ---------------- TX parser (root complex) ----------------
    reg in_tlp = 0;
    reg is_mwr;
    reg [63:0] waddr;      // address of the next payload word
    reg [63:0] tlp_start;
    integer dw_left_rx, lane, k, hdr_dw;
    reg [31:0] dw, h0, h1;
    reg [31:0] last_cpl_data;
    reg [7:0] last_cpl_tag;
    reg got_cpl = 0;

    function [31:0] lane_of;
        input [255:0] d;
        input integer l;
        begin lane_of = d[255 - 32*l -: 32]; end
    endfunction
    function [31:0] sw;
        input [31:0] d;
        begin sw = {d[7:0], d[15:8], d[23:16], d[31:24]}; end
    endfunction

    task store_word;
        input [31:0] cpu_word;
        reg [63:0] off;
        begin
            if (waddr < win_base || waddr >= win_base + win_len) begin
                outside = outside + 1;
                check(0, "MWr payload outside the programmed window");
            end else begin
                off = (waddr - win_base) >> 2;
                check(written[off] === 1'b0, "word written twice");
                written[off] = 1'b1;
                mem[off] = cpu_word;
            end
            waddr = waddr + 4;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && |t_valid && !t_wait) begin
            if (t_sop) begin
                check(!in_tlp, "SOP inside a TLP");
                h0 = lane_of(t_data, 0);
                h1 = lane_of(t_data, 1);
                if (h0[31:24] == 8'h4a) begin
                    // CplD from the completer
                    check(t_eop && t_valid == 8'hf0, "CplD shape");
                    last_cpl_data = sw(lane_of(t_data, 3));
                    last_cpl_tag = lane_of(t_data, 2) >> 8;
                    got_cpl = 1;
                    cpl_seen = cpl_seen + 1;
                end else begin
                    is_mwr = (h0[31:24] == 8'h40) || (h0[31:24] == 8'h60);
                    check(is_mwr, "only MWr or CplD may be sent");
                    if (!is_mwr) badhdr = badhdr + 1;
                    check(h0[23:10] == 14'd0, "MWr DW0 TC/attr/TD/EP zero");
                    check(h1[31:16] == {busdev, 3'b000}, "requester ID");
                    check(h1[3:0] == 4'hf, "first BE");
                    check(h1[7:4] == ((h0[9:0] == 10'd1) ? 4'h0 : 4'hf), "last BE");
                    dw_left_rx = (h0[9:0] == 0) ? 1024 : h0[9:0];
                    if (h0[29]) begin
                        hdr_dw = 4;
                        waddr = {lane_of(t_data, 2), lane_of(t_data, 3)};
                        check(lane_of(t_data, 2) != 0, "4-DW header used below 4 GiB");
                    end else begin
                        hdr_dw = 3;
                        waddr = {32'd0, lane_of(t_data, 2)};
                    end
                    check(waddr[1:0] == 0, "address bits [1:0] zero");
                    if (debug_hdr) $display("  TLP h0=%h h1=%h addr=%h valid=%h", h0, h1, waddr, t_valid);
                    tlp_start = waddr;
                    if (dw_left_rx * 4 > win_pay) begin
                        oversize = oversize + 1;
                        check(0, "TLP longer than programmed payload");
                    end
                    if (dw_left_rx * 4 > max_tlp) max_tlp = dw_left_rx * 4;
                    if ((tlp_start >> 12) != ((tlp_start + dw_left_rx * 4 - 1) >> 12)) begin
                        crossings = crossings + 1;
                        check(0, "TLP crosses a 4 KiB boundary");
                    end
                    tlps_seen = tlps_seen + 1;
                    bytes_seen = bytes_seen + dw_left_rx * 4;
                    for (lane = hdr_dw; lane < 8; lane = lane + 1) begin
                        if (t_valid[7 - lane]) begin
                            check(dw_left_rx > 0, "extra payload DW in first beat");
                            store_word(sw(lane_of(t_data, lane)));
                            dw_left_rx = dw_left_rx - 1;
                        end
                    end
                    check(t_valid == (8'hff << (8 - (hdr_dw + ((h0[9:0] < 8 - hdr_dw) ? h0[9:0] : 8 - hdr_dw)))),
                          "first beat valid mask");
                    in_tlp = !t_eop;
                    check(t_eop == (dw_left_rx == 0), "EOP on first beat matches length");
                end
            end else begin
                check(in_tlp, "data beat outside a TLP");
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (t_valid[7 - lane]) begin
                        check(dw_left_rx > 0, "extra payload DW");
                        store_word(sw(lane_of(t_data, lane)));
                        dw_left_rx = dw_left_rx - 1;
                    end
                end
                check(t_eop == (dw_left_rx == 0), "EOP matches length");
                if (t_eop) in_tlp = 0;
            end
        end
    end

    // ---------------- BAR2 request driver ----------------
    reg [7:0] tag = 0;
    task bar_write;
        input [19:0] off;
        input [31:0] data;
        reg [31:0] dw0, dw1;
        begin
            @(negedge clk);
            while (rx_wait) @(negedge clk);
            dw0 = 32'h60000001;           // MWr64, like the Pi's 0x1b801xxxxx BAR
            dw1 = {16'h0000, 8'h00, 4'h0, 4'hf};
            rx_data = {dw0, dw1, 32'h0000001b, 12'h801, off, sw(data), 96'd0};
            rx_valid = 8'hf8; rx_sop = 1; rx_eop = 1;
            @(negedge clk);
            while (rx_wait) @(negedge clk);
            rx_valid = 0; rx_sop = 0; rx_eop = 0;
        end
    endtask
    task bar_read;
        input [19:0] off;
        output [31:0] data;
        reg [31:0] dw0, dw1;
        integer guard;
        begin
            @(negedge clk);
            while (rx_wait) @(negedge clk);
            tag = tag + 1;
            got_cpl = 0;
            dw0 = 32'h20000001;
            dw1 = {16'h0000, tag, 4'h0, 4'hf};
            rx_data = {dw0, dw1, 32'h0000001b, 12'h801, off, 128'd0};
            rx_valid = 8'hf0; rx_sop = 1; rx_eop = 1;
            @(negedge clk);
            rx_valid = 0; rx_sop = 0; rx_eop = 0;
            guard = 0;
            while (!got_cpl && guard < 100000) begin @(posedge clk); guard = guard + 1; end
            check(got_cpl, "read completed");
            check(last_cpl_tag == tag, "completion tag");
            data = last_cpl_data;
        end
    endtask

    // ---------------- run one transfer ----------------
    reg [31:0] st, v, cyc, nb, nt;
    integer i, errs, polls;
    task run;
        input [63:0] base;
        input [31:0] len;
        input [10:0] pay;
        input mode;
        input [31:0] seed;
        input [7:0] expect_err;  // 0 = expect success
        input poll_busy;         // poll STATUS continuously while running
        begin
            win_base = base; win_len = len; win_pay = pay; win_mode = mode; win_seed = seed;
            for (i = 0; i < len / 4 && i < MEMW; i = i + 1) written[i] = 0;
            tlps_seen = 0; bytes_seen = 0; outside = 0; crossings = 0;
            oversize = 0; badhdr = 0; max_tlp = 0; cpl_seen = 0;
            bar_write(20'h48, base[31:0]);
            bar_write(20'h4c, base[63:32]);
            bar_write(20'h50, len);
            bar_write(20'h54, {21'd0, pay});
            bar_write(20'h58, seed);
            bar_write(20'h44, {23'd0, mode, 8'h01});   // GO
            polls = 0;
            if (poll_busy) begin
                st = 32'h2;
                while (st[1]) begin bar_read(20'h5c, st); polls = polls + 1; end
            end else begin
                st = 32'h2;
                while (st[1]) begin
                    repeat (200) @(posedge clk);
                    bar_read(20'h5c, st); polls = polls + 1;
                end
            end
            bar_read(20'h60, cyc); bar_read(20'h64, nb); bar_read(20'h68, nt);
            if (expect_err != 0) begin
                check(st[2] && st[15:8] == expect_err, "expected GO refusal code");
                check(tlps_seen == 0, "refused GO sent no TLP");
            end else begin
                check(st[0] && !st[2], "DONE without ERROR");
                check(nb == len && bytes_seen == len, "byte count");
                check(nt == tlps_seen, "TLP count register");
                errs = 0;
                for (i = 0; i < len / 4; i = i + 1) begin
                    if (written[i] !== 1'b1 || mem[i] !== model_pat(mode, seed, i)) begin
                        if (errs < 4)
                            $display("  word %0d written=%b got %h want %h", i, written[i],
                                     mem[i], model_pat(mode, seed, i));
                        errs = errs + 1;
                    end
                end
                check(errs == 0, "payload matches pattern for every word");
            end
            $display("run base=%h len=%0d pay=%0d mode=%0d: status=%h tlps=%0d bytes=%0d cycles=%0d maxtlp=%0d outside=%0d cross4k=%0d cplds=%0d polls=%0d",
                     base, len, pay, mode, st, tlps_seen, bytes_seen, cyc, max_tlp, outside,
                     crossings, cpl_seen, polls);
        end
    endtask

    // random backpressure on the hard core's tx_wait and posted credit
    integer seed_rng = 7;
    reg random_wait = 0;
    always @(negedge clk) begin
        if (random_wait) begin
            t_wait <= ($random(seed_rng) & 3) == 0;
            p_credit <= ($random(seed_rng) & 15) != 0;
        end else begin
            t_wait <= 0; p_credit <= 1;
        end
    end

    reg [31:0] id;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);
        bar_read(20'h40, id);
        check(id == 32'h4E54444D, "ID register");
        bar_read(20'h6c, v);
        check(v == 32'h01000000, "MAXLEN register");
        // scratch RAM still works next to the registers, and unmapped reads answer
        bar_write(20'h20, 32'h1234ABCD); bar_read(20'h20, v);
        check(v == 32'h1234ABCD, "scratch RAM round trip");
        bar_read(20'h80, v); check(v == 0, "unmapped register reads 0");
        bar_read(20'hFFFFC, v); check(1, "far offset answered");

        // ladder, 64-bit addresses (Pi: bus = phys + 0x10_0000_0000)
        run(64'h0000_0010_3a00_1000, 64, 11'd128, 0, 32'h1000_0000, 0, 1);
        run(64'h0000_0010_3a00_1000, 4096, 11'd128, 1, 32'hdeadbeef, 0, 1);
        run(64'h0000_0010_3a00_1000, 4096, 11'd256, 1, 32'h01234567, 0, 0);
        run(64'h0000_0010_3a00_1000, 4096, 11'd512, 1, 32'h89abcdef, 0, 0);
        run(64'h0000_0010_3a00_1000, 65536, 11'd512, 0, 32'h0, 0, 1);
        // 32-bit address form, and start not aligned to payload or 4 KiB
        run(64'h0000_0000_0000_1000, 64, 11'd128, 0, 32'h5555_0000, 0, 1);
        run(64'h0000_0010_3a00_0fc0, 8192, 11'd512, 1, 32'h0badf00d, 0, 0);
        run(64'h0000_0010_3a00_0044, 1000, 11'd256, 1, 32'h7, 0, 0);
        run(64'h0000_0010_3a00_0ffc, 4, 11'd64, 0, 32'h77, 0, 1);
        // crossing 4 GiB: MWr32 below, MWr64 above
        run(64'h0000_0000_ffff_f000, 8192, 11'd256, 1, 32'h4242, 0, 0);

        // refusals: none may put a TLP on the wire
        run(64'h0000_0010_3a00_1000, 0, 11'd128, 0, 0, 8'd1, 1);
        run(64'h0000_0010_3a00_1000, 32'h0100_0004, 11'd128, 0, 0, 8'd2, 1);
        run(64'h0000_0010_3a00_1000, 62, 11'd128, 0, 0, 8'd3, 1);
        run(64'h0000_0010_3a00_1002, 64, 11'd128, 0, 0, 8'd4, 1);
        run(64'h0000_0010_3a00_1000, 64, 11'd300, 0, 0, 8'd5, 1);
        run(64'h0000_0010_3a00_1000, 64, 11'd1024, 0, 0, 8'd5, 1);
        run(64'hffff_ffff_ffff_ffc0, 128, 11'd128, 0, 0, 8'd6, 1);

        // backpressure + credit starvation + polling during the transfer
        random_wait = 1;
        run(64'h0000_0010_3a00_0f00, 65536 + 512, 11'd512, 1, 32'h31337, 0, 1);
        run(64'h0000_0010_3a00_1004, 4096 * 3, 11'd128, 0, 32'h99, 0, 1);
        random_wait = 0;

        // GO while busy is refused and the running transfer is unaffected
        win_base = 64'h0000_0010_3a00_1000; win_len = 262144; win_pay = 512;
        for (i = 0; i < 262144 / 4; i = i + 1) written[i] = 0;
        tlps_seen = 0; bytes_seen = 0;
        bar_write(20'h48, 32'h3a00_1000); bar_write(20'h4c, 32'h10);
        bar_write(20'h50, 262144); bar_write(20'h54, 512); bar_write(20'h58, 32'h1);
        bar_write(20'h44, 32'h1);
        bar_write(20'h50, 32'h0100_0000);       // ignored while busy
        bar_write(20'h44, 32'h1);               // GO while busy
        st = 2; while (st[1]) bar_read(20'h5c, st);
        bar_read(20'h64, nb);
        check(st[0] && st[2] && st[15:8] == 8'd7 && nb == 262144 && bytes_seen == 262144,
              "GO while busy flagged, original window unchanged");
        $display("go-while-busy: status=%h bytes=%0d", st, nb);

        // ABORT stops after the current TLP, inside the window
        for (i = 0; i < 1048576 / 4; i = i + 1) written[i] = 0;
        tlps_seen = 0; bytes_seen = 0; win_len = 1048576;
        bar_write(20'h44, 32'h2);               // CLEAR
        bar_write(20'h50, 1048576);
        bar_write(20'h44, 32'h1);
        repeat (2000) @(posedge clk);
        bar_write(20'h44, 32'h4);               // ABORT
        st = 2; while (st[1]) bar_read(20'h5c, st);
        bar_read(20'h64, nb);
        check(st[2] && st[15:8] == 8'd10 && nb < 1048576 && nb == bytes_seen && outside == 0,
              "ABORT stops early inside the window");
        $display("abort: status=%h bytes=%0d", st, nb);

        // full 16 MiB, hashed pattern, with backpressure
        random_wait = 1;
        run(64'h0000_0010_3a00_0000, 32'h0100_0000, 11'd512, 1, 32'hc0ffee, 0, 0);
        random_wait = 0;

        $display("rejected BAR2 requests: %0d", rejected);
        check(rejected == 0, "no rejected requests");
        if (failures == 0) $display("PASS: DMA writer simulation");
        else $display("FAIL: %0d failures", failures);
        $finish;
    end
endmodule
