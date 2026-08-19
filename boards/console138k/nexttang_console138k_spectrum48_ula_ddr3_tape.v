// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// User-supplied TZX playback on the upper-DDR 48K integration target.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_ula_ddr3_tape
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_DDR3
`define NEXTTANG_SPECTRUM48_USE_TAPE
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_USE_TAPE
`undef NEXTTANG_SPECTRUM48_USE_DDR3
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
