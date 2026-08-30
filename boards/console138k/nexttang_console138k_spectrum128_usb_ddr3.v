// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

// First complete 128K machine target: original 128K paging and ROM pair,
// ULA video, direct FPGA USB keyboard input, and bank storage split between
// dual-port screen BSRAM and the verified Console 138K DDR3 service.
`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum128_usb_ddr3
`define NEXTTANG_SPECTRUM128
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_DDR3
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`define NEXTTANG_HDMI_AUDIO
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_HDMI_AUDIO
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPECTRUM48_USE_DDR3
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM128
`undef NEXTTANG_SPECTRUM48_TOP
