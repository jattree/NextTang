// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

// Diagnostic target: load a pack from SD exactly as the ordinary SD loader
// does, then hold every CPU and put the eight graphical ROM lanes on the
// display instead of the graphical planes.
//
// The frozen-plane capture proved the loaded plane contents and the physical
// display reads are good before execution, because the display reads the
// planes. It could not say anything about the graphical ROM lanes: their
// second port is tied off in every ordinary build, so nothing has ever
// observed them on hardware. They are read by all eight lanes on every ROM
// call and every interrupt vector, which is the remaining unvalidated input
// to gameplay.
//
// Capture this the same way: the CPUs never run, so successive frames must be
// byte-identical, and the image is a direct rendering of the pack's
// graphics_rom section (payload bytes 458752..589823) as the display's own
// address mapping reads it.
//
// The display window is 8 KiB, so this build shows one half of each 16 KiB
// lane. Define NEXTTANG_SPEC256_ROM_LANE_VIEW_HALF as 1'b1 for the upper half.
`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spec256_loader_romview
`define NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`define NEXTTANG_SPECTRUM48_USE_SPEC256
`define NEXTTANG_SPEC256_RUNTIME
`define NEXTTANG_SPEC256_SD_PACK
`define NEXTTANG_SPEC256_DISTRIBUTED_PALETTE
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`define NEXTTANG_USB_PORT_TWO_ONLY
`define NEXTTANG_HDMI_AUDIO
`define NEXTTANG_CLASSIC_SD_LOADER
`define NEXTTANG_SPEC256_ROM_LANE_VIEW
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPEC256_ROM_LANE_VIEW
`undef NEXTTANG_CLASSIC_SD_LOADER
`undef NEXTTANG_HDMI_AUDIO
`undef NEXTTANG_USB_PORT_TWO_ONLY
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPEC256_DISTRIBUTED_PALETTE
`undef NEXTTANG_SPEC256_SD_PACK
`undef NEXTTANG_SPEC256_RUNTIME
`undef NEXTTANG_SPECTRUM48_USE_SPEC256
`undef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`undef NEXTTANG_SPECTRUM48_TOP
