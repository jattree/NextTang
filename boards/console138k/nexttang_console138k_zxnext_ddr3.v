// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// The ZXNext image with its whole 2 MB main memory in DDR3.

`define NEXTTANG_ZXNEXT_TOP nexttang_console138k_zxnext_ddr3
`define NEXTTANG_ZXNEXT_DDR3
`include "nexttang_console138k_zxnext.v"
`undef NEXTTANG_ZXNEXT_DDR3
`undef NEXTTANG_ZXNEXT_TOP
