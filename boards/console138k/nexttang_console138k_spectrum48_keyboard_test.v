// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

// Hardware diagnostic for the factory BL616 USB-keyboard forwarding path.
// It keeps the normal ULA picture but replaces the automatic typist and tape
// with milestone counters on the debug UART and PMOD probes.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_keyboard_test
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
