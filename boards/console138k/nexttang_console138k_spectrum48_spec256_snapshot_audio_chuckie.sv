// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Private Chuckie Egg Spec256 snapshot target with HDMI beeper audio.

`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48_spec256_snapshot_audio_chuckie
`define NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`define NEXTTANG_SPECTRUM48_USE_SPEC256
`define NEXTTANG_SPECTRUM48_USB_KEYBOARD
`define NEXTTANG_SPEC256_AUTOSTART_CHUCKIE
`define NEXTTANG_HDMI_AUDIO
`include "nexttang_console138k_spectrum48.v"
`undef NEXTTANG_HDMI_AUDIO
`undef NEXTTANG_SPEC256_AUTOSTART_CHUCKIE
`undef NEXTTANG_SPECTRUM48_USB_KEYBOARD
`undef NEXTTANG_SPECTRUM48_USE_SPEC256
`undef NEXTTANG_SPECTRUM48_USE_SNAPSHOT
`undef NEXTTANG_SPECTRUM48_TOP
