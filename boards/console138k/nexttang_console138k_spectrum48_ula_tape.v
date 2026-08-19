// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// User-supplied TZX playback with all 48K in internal block RAM. This is the
// control for the DDR-backed tape target: same tape, same ROM, same loader,
// with the external memory taken out of the path.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_ula_tape
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_TAPE
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_USE_TAPE
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
