// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Internal-RAM tape target which presses S and then 1 after a successful tape.
// This starts a one-player Chuckie Egg game without physical input hardware.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_ula_tape_s1
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_TAPE
`define NEXTTANG_SPECTRUM48_POST_TAPE_S1
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_POST_TAPE_S1
`undef NEXTTANG_SPECTRUM48_USE_TAPE
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
