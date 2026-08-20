// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_console138k_ddr3_spec256 (
    input  wire        sys_clk,
    output wire        status_led,
    output wire [4:0]  probe,
    output wire        debug_uart_tx,
    output wire        debug_uart_tx_alt,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,
    output wire [14:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs,
    output wire        ddr_ras,
    output wire        ddr_cas,
    output wire        ddr_we,
    output wire        ddr_ck,
    output wire        ddr_ck_n,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [3:0]  ddr_dm,
    inout  wire [31:0] ddr_dq,
    inout  wire [3:0]  ddr_dqs,
    inout  wire [3:0]  ddr_dqs_n
);
    nexttang_console138k_ddr3_logo #(
        .IMAGE_FILE("spec256_frame_256x192_rgb332.mem"),
        .IMAGE_BEATS(1536),
        .BEAT_ADDRESS_WIDTH(11),
        .PIXEL_ADDRESS_WIDTH(16),
        .STATIC_SPEC256_FRAME(1)
    ) display (
        .sys_clk(sys_clk),
        .status_led(status_led),
        .probe(probe),
        .debug_uart_tx(debug_uart_tx),
        .debug_uart_tx_alt(debug_uart_tx_alt),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p),
        .tmds_d_n(tmds_d_n),
        .ddr_addr(ddr_addr),
        .ddr_bank(ddr_bank),
        .ddr_cs(ddr_cs),
        .ddr_ras(ddr_ras),
        .ddr_cas(ddr_cas),
        .ddr_we(ddr_we),
        .ddr_ck(ddr_ck),
        .ddr_ck_n(ddr_ck_n),
        .ddr_cke(ddr_cke),
        .ddr_odt(ddr_odt),
        .ddr_reset_n(ddr_reset_n),
        .ddr_dm(ddr_dm),
        .ddr_dq(ddr_dq),
        .ddr_dqs(ddr_dqs),
        .ddr_dqs_n(ddr_dqs_n)
    );
endmodule

`default_nettype wire
