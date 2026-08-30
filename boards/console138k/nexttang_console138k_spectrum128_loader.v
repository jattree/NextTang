// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

// Common read-only SD loader plus the hardware-verified classic 128K paths.
`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum128_loader
`define NEXTTANG_SPECTRUM128
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_DDR3
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`define NEXTTANG_HDMI_AUDIO
`define NEXTTANG_CLASSIC_SD_LOADER
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_CLASSIC_SD_LOADER
`undef NEXTTANG_HDMI_AUDIO
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPECTRUM48_USE_DDR3
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM128
`undef NEXTTANG_SPECTRUM48_TOP
