# hdl-util HDMI transmitter

This directory started as a source import from
[`hdl-util/hdmi`](https://github.com/hdl-util/hdmi) at commit
`83b1c9543a91b776671a44e68e130f81cae437b7`.

The upstream project is dual licensed under MIT or Apache-2.0. Both upstream
license files are retained here. NextTang currently selects the MIT terms for
this import.

`hdmi.sv`, `packet_picker.sv` and `audio_clock_regeneration_packet.sv` replace
the asynchronous audio clock input with a 48 kHz enable in the pixel-clock
domain. This avoids placing a fabric-generated clock on the Console and keeps
the packet transfer synchronous. Serialization is supplied by the separate
project-owned Gowin shim.

`hdmi.sv` and `packet_picker.sv` also gain an optional second mode,
`ALT_VIDEO_ID_CODE`, selected at runtime by a new `alt_mode` input. The
transmitter takes `alt_mode` as a frame ends, so a mode never changes mid-frame.
Only 19 (720p50) with 4 (720p60) is supported: the two share the pixel clock and
differ in the line length (1980 or 1650) and the horizontal sync position (440
or 110), and the AVI InfoFrame announces the VIC of the mode in effect. The
default, 0, keeps the single fixed mode and ignores `alt_mode`. The ZX Next
board uses it to follow the core's 50/60 Hz setting.
