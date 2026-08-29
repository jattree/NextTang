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
