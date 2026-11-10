#!/usr/bin/env bash
# Build the ZX Spectrum Next core for the Tang Nano 20K (v3923).
#
# Profiles: skeleton (lists sources only) and first (the first buildable
# shell: clocks, SDRAM ports A and C, hdmi_frame DVI, keys over the debug
# UART; see nexttang_nano20k_zxnext.v). Never run on a Nano yet.
#   build_zxnext.sh --profile first --output ABSOLUTE_EMPTY_DIR
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

profile=
output_dir=
place_option=1   # closes 28.125 MHz (worst slack +0.008 ns, 2026-11-11); 0 misses by 0.75 ns
route_option=0
print_sources=0
while (($#)); do
    case "$1" in
        --profile) [[ $# -ge 2 ]] || exit 2; profile=$2; shift 2 ;;
        --output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
        --place) [[ $# -ge 2 ]] || exit 2; place_option=$2; shift 2 ;;
        --route) [[ $# -ge 2 ]] || exit 2; route_option=$2; shift 2 ;;
        --toolchain|--vendor-source|--boot-image) [[ $# -ge 2 ]] || exit 2; shift 2 ;;
        --print-sources) print_sources=1; shift ;;
        -h|--help)
            printf '%s\n' 'usage: boards/nano20k/build_zxnext.sh --profile skeleton|first [--print-sources] [--output DIR]'
            exit 0 ;;
        *) printf 'nano20k zxnext build: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ "$profile" == skeleton || "$profile" == first ]] || {
    printf 'nano20k zxnext build: profile not implemented: %s (skeleton or first)\n' "$profile" >&2
    exit 2
}

# The machine's sources come from the Console driver's list, so the two
# boards cannot drift apart on what the shared machine is.
mapfile -t console_sources < <("$repo_root/boards/console138k/build_zxnext.sh" --profile diagnostic --print-sources)
source_files=()
for source_file in "${console_sources[@]}"; do
    case "$source_file" in
        */boards/*|*/rtl/video/*|*/rtl/memory/nexttang_block_ram.v|*/rtl/audio/nexttang_zxnext_audio_pcm.v|*/rtl/clock/nexttang_machine_clock_enables.v|*/rtl/reset/nexttang_reset_release.v) ;;
        *) source_files+=("$source_file") ;;
    esac
done
# The core's own video files are part of the machine.
for source_file in "${console_sources[@]}"; do
    case "$source_file" in
        */rtl/video/layer2.vhd|*/rtl/video/lores.vhd|*/rtl/video/sprites.vhd|*/rtl/video/tilemap.vhd|*/rtl/video/zxula_timing.vhd|*/rtl/video/zxula.vhd)
            source_files+=("$source_file") ;;
    esac
done
source_files+=(
    "$repo_root/rtl/reset/nexttang_reset_release.v"
    "$repo_root/rtl/clock/nexttang_machine_clock_enables.v"
    "$repo_root/rtl/memory/nexttang_sdr_sdram_service.v"
    "$repo_root/rtl/input/nexttang_keyboard_matrix.v"
    "$repo_root/rtl/video/hdmi_frame.vhd"
    "$repo_root/rtl/video/nexttang_tmds_encoder.v"
    "$repo_root/boards/nano20k/nexttang_nano20k_zxnext.v"
    "$repo_root/boards/nano20k/nano20k_v3923.cst"
    "$repo_root/boards/nano20k/nano20k_zxnext.sdc"
    "$repo_root/boards/nano20k/nano20k_zxnext.gsc"
)
# the Console's list may already carry some of these
mapfile -t source_files < <(printf '%s\n' "${source_files[@]}" | awk '!seen[$0]++')

if ((print_sources)); then
    printf '%s\n' nexttang_nano20k_zxnext "${source_files[@]}"
    exit 0
fi

if [[ "$profile" == skeleton ]]; then
    printf '%s\n' 'nano20k zxnext build: the skeleton profile only lists sources (--print-sources)' >&2
    exit 2
fi
[[ "$output_dir" == /* && -d "$output_dir" ]] || {
    printf '%s\n' 'nano20k zxnext build: --output must be an existing absolute directory' >&2
    exit 2
}
[[ -z $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
    printf 'nano20k zxnext build: output directory is not empty: %s\n' "$output_dir" >&2
    exit 2
}
base_name=nexttang_nano20k_zxnext
sha256sum "${source_files[@]}" >"$output_dir/source-sha256.txt"
{
    printf 'set_device -device_version C GW2AR-LV18QN88C8/I7\n'
    printf 'set_option -top_module %s\n' "$base_name"
    printf 'set_option -output_base_name %s\n' "$base_name"
    printf 'set_option -vhdl_std vhd2008\n'
    printf 'set_option -verilog_std sysv2017\n'
    printf 'set_option -gen_text_timing_rpt 1\n'
    printf 'set_option -use_sspi_as_gpio 1\n'
    printf 'set_option -place_option %s\n' "$place_option"
    printf 'set_option -route_option %s\n' "$route_option"
    for source_file in "${source_files[@]}"; do
        printf 'add_file {%s}\n' "$source_file"
    done
    printf 'run all\n'
} >"$output_dir/$base_name.tcl"
cd -- "$output_dir"
gw_sh "$base_name.tcl" >build.log 2>&1 || { tail -20 build.log >&2; exit 1; }
[[ -s "impl/pnr/$base_name.fs" ]] || { printf '%s\n' 'nano20k zxnext build: no bitstream' >&2; exit 1; }
printf 'nano20k zxnext build: %s\n' "$output_dir/impl/pnr/$base_name.fs"
