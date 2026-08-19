// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Separate bring-up target for the imported ZX Spectrum Next ULA timing and
// frame-safe 720p scan conversion.  The normal Spectrum48 build remains the
// hardware-verified rollback baseline.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_ula
`define NEXTTANG_SPECTRUM48_USE_ULA
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_SPECTRUM48_USE_ULA
`undef NEXTTANG_SPECTRUM48_TOP
