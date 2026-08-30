// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

// Combined classic 48K target: ULA, DDR3-backed upper RAM, direct keyboard and
// Kempston controller input, and beeper audio in HDMI.
`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_usb_ddr3_audio
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_DDR3
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`define NEXTTANG_HDMI_AUDIO
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_HDMI_AUDIO
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPECTRUM48_USE_DDR3
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
