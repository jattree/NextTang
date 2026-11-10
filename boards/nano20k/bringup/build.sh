#!/usr/bin/env bash
# Build the Tang Nano 20K bring-up image: clocks, HDMI test pattern, SDRAM self-test.
# usage: boards/nano20k/bringup/build.sh OUTPUT_DIR
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../../.." && pwd -P)
out=${1:?usage: build.sh OUTPUT_DIR}
mkdir -p "$out"; out=$(cd -- "$out" && pwd -P)
hdmi=(hdmi.sv packet_assembler.sv packet_picker.sv tmds_channel.sv audio_clock_regeneration_packet.sv
      audio_info_frame.sv audio_sample_packet.sv auxiliary_video_information_info_frame.sv
      source_product_description_info_frame.sv)
{
  printf 'set_device -device_version C GW2AR-LV18QN88C8/I7\n'
  printf 'set_option -top_module nexttang_nano20k_bringup\n'
  printf 'set_option -output_base_name nano20k_bringup\n'
  printf 'set_option -verilog_std sysv2017\n'
  printf 'set_option -gen_text_timing_rpt 1\n'
  printf 'add_file {%s}\n' "$here/nexttang_nano20k_bringup.v"
  printf 'add_file {%s}\n' "$here/nexttang_nano20k_sdram_test.v"
  for f in "${hdmi[@]}"; do printf 'add_file {%s}\n' "$repo/rtl/video/hdmi/$f"; done
  printf 'add_file {%s}\n' "$repo/rtl/video/nexttang_gowin_hdmi_serializer.sv"
  printf 'add_file {%s}\n' "$here/nano20k_bringup.cst"
  printf 'add_file {%s}\n' "$here/nano20k_bringup.sdc"
  printf 'run all\n'
} > "$out/build.tcl"
cd "$out" && gw_sh build.tcl
