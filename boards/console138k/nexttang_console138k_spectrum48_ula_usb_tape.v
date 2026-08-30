// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// User-supplied TZX playback plus direct FPGA-hosted USB input.  This keeps the
// tape player and USB keyboard as platform services outside the 48K machine.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_ula_usb_tape
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_TAPE
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPECTRUM48_USE_TAPE
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
