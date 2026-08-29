// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Private-asset Spec256 snapshot target for the Console 138K.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_spec256_snapshot
`define NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`define NEXTTANG_SPECTRUM48_USE_SPEC256
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPECTRUM48_USE_SPEC256
`undef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`undef NEXTTANG_SPECTRUM48_TOP
