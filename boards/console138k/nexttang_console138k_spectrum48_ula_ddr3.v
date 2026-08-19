// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Deliberately separate from the hardware-verified ULA target. The ULA-visible
// lower 16K stays in dual-port block RAM; only 0x8000-0xffff crosses to DDR3.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_ula_ddr3
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_DDR3
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_USE_DDR3
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
