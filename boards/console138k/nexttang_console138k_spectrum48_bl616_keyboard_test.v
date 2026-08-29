// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Hardware diagnostic for the factory TangCore BL616 keyboard path. The
// automatic typist is disabled and the direct FPGA USB hosts are absent, so a
// matrix event can only originate in message 0x0c from the MCU-side OTG hub.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_bl616_keyboard_test
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
