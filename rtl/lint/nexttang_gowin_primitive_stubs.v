// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

// Lint-only stand-ins for the three Gowin hard primitives the project
// instantiates directly. They exist so `scripts/hdl_lint.sh` can elaborate a
// whole board profile without the vendor toolchain installed; nothing here is
// ever handed to synthesis, and no board build lists this file.
//
// Every port and parameter below is derived from this repository's own
// instantiations, not from a vendor model:
//
//   PLL         boards/console138k/nexttang_console138k_pll.v
//               boards/console138k/nexttang_console138k_machine_pll.v
//               boards/console138k/nexttang_console138k_usb_pll.v
//   OSER10      rtl/video/nexttang_gowin_hdmi_serializer.sv
//   ELVDS_OBUF  rtl/video/nexttang_gowin_hdmi_serializer.sv
//
// The parameter list is the set the board wrappers reach with `defparam`. A
// `defparam` into a black box is rejected by the linter, so the names have to
// be declared here even though the values are ignored. A widened or renamed
// port on a real instantiation shows up as a lint failure, which is the
// intent: the stub is a check on our own usage, not a model of the silicon.
// Behaviour is deliberately absent, so the outputs are constants and nothing
// downstream should read timing or function into a lint run.
//
// Keep every comment line here from starting with the linter's own name: it
// reads `// <toolname> <word>` at the start of a line as a lint pragma and
// fails the file.

`default_nettype none

module PLL (
    output wire       LOCK,
    output wire       CLKOUT0,
    output wire       CLKOUT1,
    output wire       CLKOUT2,
    output wire       CLKOUT3,
    output wire       CLKOUT4,
    output wire       CLKOUT5,
    output wire       CLKOUT6,
    output wire       CLKFBOUT,
    input  wire       CLKIN,
    input  wire       CLKFB,
    input  wire       RESET,
    input  wire       PLLPWD,
    input  wire       RESET_I,
    input  wire       RESET_O,
    input  wire [5:0] FBDSEL,
    input  wire [5:0] IDSEL,
    input  wire [6:0] MDSEL,
    input  wire [2:0] MDSEL_FRAC,
    input  wire [6:0] ODSEL0,
    input  wire [2:0] ODSEL0_FRAC,
    input  wire [6:0] ODSEL1,
    input  wire [6:0] ODSEL2,
    input  wire [6:0] ODSEL3,
    input  wire [6:0] ODSEL4,
    input  wire [6:0] ODSEL5,
    input  wire [6:0] ODSEL6,
    input  wire [3:0] DT0,
    input  wire [3:0] DT1,
    input  wire [3:0] DT2,
    input  wire [3:0] DT3,
    input  wire [5:0] ICPSEL,
    input  wire [2:0] LPFRES,
    input  wire [1:0] LPFCAP,
    input  wire [2:0] PSSEL,
    input  wire       PSDIR,
    input  wire       PSPULSE,
    input  wire       ENCLK0,
    input  wire       ENCLK1,
    input  wire       ENCLK2,
    input  wire       ENCLK3,
    input  wire       ENCLK4,
    input  wire       ENCLK5,
    input  wire       ENCLK6,
    input  wire       SSCPOL,
    input  wire       SSCON,
    input  wire [6:0] SSCMDSEL,
    input  wire [2:0] SSCMDSEL_FRAC
);
    parameter FCLKIN = "100.0";
    parameter IDIV_SEL = 1;
    parameter FBDIV_SEL = 1;
    parameter ODIV0_SEL = 8;
    parameter ODIV1_SEL = 8;
    parameter ODIV2_SEL = 8;
    parameter ODIV3_SEL = 8;
    parameter ODIV4_SEL = 8;
    parameter ODIV5_SEL = 8;
    parameter ODIV6_SEL = 8;
    parameter MDIV_SEL = 8;
    parameter MDIV_FRAC_SEL = 0;
    parameter ODIV0_FRAC_SEL = 0;
    parameter CLKOUT0_EN = "TRUE";
    parameter CLKOUT1_EN = "FALSE";
    parameter CLKOUT2_EN = "FALSE";
    parameter CLKOUT3_EN = "FALSE";
    parameter CLKOUT4_EN = "FALSE";
    parameter CLKOUT5_EN = "FALSE";
    parameter CLKOUT6_EN = "FALSE";
    parameter CLKFB_SEL = "INTERNAL";
    parameter DYN_DPA_EN = "FALSE";
    parameter CLKOUT0_PE_COARSE = 0;
    parameter CLKOUT0_PE_FINE = 0;
    parameter CLKOUT1_PE_COARSE = 0;
    parameter CLKOUT1_PE_FINE = 0;
    parameter CLKOUT2_PE_COARSE = 0;
    parameter CLKOUT2_PE_FINE = 0;
    parameter CLKOUT3_PE_COARSE = 0;
    parameter CLKOUT3_PE_FINE = 0;

    assign LOCK = 1'b0;
    assign CLKOUT0 = 1'b0;
    assign CLKOUT1 = 1'b0;
    assign CLKOUT2 = 1'b0;
    assign CLKOUT3 = 1'b0;
    assign CLKOUT4 = 1'b0;
    assign CLKOUT5 = 1'b0;
    assign CLKOUT6 = 1'b0;
    assign CLKFBOUT = 1'b0;
endmodule

module OSER10 (
    output wire Q,
    input  wire D0,
    input  wire D1,
    input  wire D2,
    input  wire D3,
    input  wire D4,
    input  wire D5,
    input  wire D6,
    input  wire D7,
    input  wire D8,
    input  wire D9,
    input  wire PCLK,
    input  wire FCLK,
    input  wire RESET
);
    parameter GSREN = "false";
    parameter LSREN = "true";

    assign Q = 1'b0;
endmodule

module ELVDS_OBUF (
    output wire O,
    output wire OB,
    input  wire I
);
    assign O = 1'b0;
    assign OB = 1'b1;
endmodule

`default_nettype wire
