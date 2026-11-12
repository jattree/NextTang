#!/usr/bin/env bash
# Build the Tang Nano 20K SDRAM read-data eye scan (nexttang_nano20k_sdram_eye.v).
# usage: boards/nano20k/bringup/build_eye.sh EMPTY_OUTPUT_DIR
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
out=${1:?usage: build_eye.sh OUTPUT_DIR}
mkdir -p "$out"; out=$(cd -- "$out" && pwd -P)
{
  printf 'set_device -device_version C GW2AR-LV18QN88C8/I7\n'
  printf 'set_option -top_module nexttang_nano20k_sdram_eye\n'
  printf 'set_option -output_base_name nano20k_sdram_eye\n'
  printf 'set_option -verilog_std sysv2017\n'
  printf 'set_option -gen_text_timing_rpt 1\n'
  printf 'set_option -use_sspi_as_gpio 1\n'
  # as the Next shell: command, address and capture registers in the I/O cells
  printf 'set_option -ireg_in_iob 1\n'
  printf 'set_option -oreg_in_iob 1\n'
  printf 'set_option -ioreg_in_iob 1\n'
  printf 'add_file {%s}\n' "$here/nexttang_nano20k_sdram_eye.v"
  printf 'add_file {%s}\n' "$here/nano20k_sdram_eye.cst"
  printf 'add_file {%s}\n' "$here/nano20k_sdram_eye.sdc"
  printf 'run all\n'
} > "$out/build.tcl"
cd "$out" && gw_sh build.tcl > build.log 2>&1 || { tail -20 build.log >&2; exit 1; }
printf 'eye build: %s\n' "$out/impl/pnr/nano20k_sdram_eye.fs"
