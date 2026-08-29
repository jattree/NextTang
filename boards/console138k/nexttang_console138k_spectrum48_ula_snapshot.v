// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Internal-RAM ULA target which resumes a user-supplied 48K SNA.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_ula_snapshot
`define NEXTTANG_SPECTRUM48_USE_ULA
`define NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
