// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

// Bisect instrument. Identical to nexttang_console138k_spec256_loader in every
// respect except that NEXTTANG_SPEC256_DISTRIBUTED_PALETTE is not defined, so
// the palette is the BSRAM-inferred nexttang_spec256_palette rather than the
// 96-cell distributed one.
//
// The distributed palette entered the SD loader builds at 13:55 on 2026-08-29
// and every build since has carried it. The last build without it predates the
// FAT32 directory-restart fix and cannot enumerate the card, so no existing
// bitstream isolates the change. This does.
//
// It sits exactly at the BSRAM cap: the SD loader is 339/340 with the
// distributed palette, and returning the palette to a block costs one more.
`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spec256_loader_bsrampalette
`define NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`define NEXTTANG_SPECTRUM48_USE_SPEC256
`define NEXTTANG_SPEC256_RUNTIME
`define NEXTTANG_SPEC256_SD_PACK
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
`undef NEXTTANG_SPEC256_RUNTIME
`undef NEXTTANG_SPECTRUM48_USE_SPEC256
`undef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`undef NEXTTANG_SPECTRUM48_TOP
