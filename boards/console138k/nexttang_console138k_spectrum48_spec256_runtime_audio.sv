// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// One game-neutral 48K Spec256 core.  A versioned game pack is received over
// PMOD1 IO2 after FPGA configuration; the machine stays reset until its full
// payload has passed CRC32.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_spec256_runtime_audio
`define NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`define NEXTTANG_SPECTRUM48_USE_SPEC256
`define NEXTTANG_SPEC256_RUNTIME
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`define NEXTTANG_USB_PORT_TWO_ONLY
`define NEXTTANG_HDMI_AUDIO
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_HDMI_AUDIO
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_USB_PORT_TWO_ONLY
`undef NEXTTANG_SPEC256_RUNTIME
`undef NEXTTANG_SPECTRUM48_USE_SPEC256
`undef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`undef NEXTTANG_SPECTRUM48_TOP
