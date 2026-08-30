// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

// Experimental read-only SD pack loader.  This deliberately remains separate
// from the hardware-verified UART runtime until exact placement and hardware
// testing establish the combined resource/memory configuration.
`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spec256_loader
`define NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`define NEXTTANG_SPECTRUM48_USE_SPEC256
`define NEXTTANG_SPEC256_RUNTIME
`define NEXTTANG_SPEC256_SD_PACK
`define NEXTTANG_SPEC256_DISTRIBUTED_PALETTE
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`define NEXTTANG_USB_PORT_TWO_ONLY
`define NEXTTANG_HDMI_AUDIO
`define NEXTTANG_CLASSIC_SD_LOADER
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_CLASSIC_SD_LOADER
`undef NEXTTANG_HDMI_AUDIO
`undef NEXTTANG_USB_PORT_TWO_ONLY
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPEC256_SD_PACK
`undef NEXTTANG_SPEC256_DISTRIBUTED_PALETTE
`undef NEXTTANG_SPEC256_RUNTIME
`undef NEXTTANG_SPECTRUM48_USE_SPEC256
`undef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`undef NEXTTANG_SPECTRUM48_TOP
