#!/usr/bin/env bash
# Build the machine CPU bring-up image for the Console 138K.
#
# This is the project's first synthesis of VHDL: the imported T80 core and the
# diagnostic boot ROM. Everything else in the tree is Verilog, so a failure
# here is most likely mixed-language support rather than the design.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

toolchain=
profile=
output_dir=

usage() {
    printf '%s\n' 'usage: boards/console138k/build_spectrum.sh --toolchain vendor --profile release --output ABSOLUTE_DIRECTORY'
}

while (($#)); do
    case "$1" in
        --toolchain|--profile|--output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --toolchain) toolchain=$2 ;;
                --profile) profile=$2 ;;
                --output) output_dir=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'console138k spectrum build: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$toolchain" != vendor ]]; then
    printf 'console138k spectrum build: toolchain not implemented: %s\n' "$toolchain" >&2
    exit 2
fi
if [[ "$profile" != release ]]; then
    printf 'console138k spectrum build: profile not implemented: %s\n' "$profile" >&2
    exit 2
fi
if [[ "$output_dir" != /* ]]; then
    printf '%s\n' 'console138k spectrum build: --output must be an absolute path' >&2
    exit 2
fi
if [[ ! -d "$output_dir" ]]; then
    printf 'console138k spectrum build: output directory does not exist: %s\n' "$output_dir" >&2
    exit 2
fi
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    printf 'console138k spectrum build: output directory is not empty: %s\n' "$output_dir" >&2
    exit 2
fi

base_name=nexttang_console138k_spectrum
project_tcl="$output_dir/$base_name.tcl"
build_log="$output_dir/vendor-build.log"
bitstream="$output_dir/impl/pnr/$base_name.fs"
timing_report="$output_dir/impl/pnr/${base_name}_tr_content.html"
source_hashes="$output_dir/source-sha256.txt"

source_files=(
    "$repo_root/rtl/cpu/t80n_pack.vhd"
    "$repo_root/rtl/cpu/t80n_alu.vhd"
    "$repo_root/rtl/cpu/t80n_mcode.vhd"
    "$repo_root/rtl/cpu/t80n.vhd"
    "$repo_root/rtl/cpu/t80na.vhd"
    "$repo_root/rtl/core/nexttang_diagnostic_bootrom.vhd"
    "$repo_root/rtl/memory/nexttang_block_ram.v"
    "$repo_root/rtl/smoke/nexttang_debug_status_uart.v"
    "$repo_root/boards/console138k/nexttang_console138k_machine_pll.v"
    "$repo_root/boards/console138k/nexttang_console138k_pll.v"
    "$repo_root/rtl/video/nexttang_video_timing.v"
    "$repo_root/rtl/video/nexttang_spectrum_display.v"
    "$repo_root/rtl/video/nexttang_tmds_encoder.v"
    "$repo_root/boards/console138k/nexttang_console138k_spectrum.v"
    "$repo_root/boards/console138k/console138k_spectrum.cst"
    "$repo_root/boards/console138k/console138k_spectrum.sdc"
)

{
    printf 'set_device -device_version C GW5AST-LV138PG484AC1/I0\n'
    printf 'set_option -top_module %s\n' "$base_name"
    printf 'set_option -output_base_name %s\n' "$base_name"
    printf 'set_option -vhdl_std vhd2008\n'
    # A plain-text timing report. The HTML one has to be tag-stripped before it
    # can be read, which is how a broken check went unnoticed for so long.
    printf 'set_option -gen_text_timing_rpt 1\n'
    for source_file in "${source_files[@]}"; do
        printf 'add_file {%s}\n' "$source_file"
    done
    printf 'run all\n'
} >"$project_tcl"

(
    cd -- "$output_dir"
    gw_sh "$project_tcl"
# Shown as it happens as well as kept. A vendor build takes minutes and a
# silent terminal gives no way to tell slow from stuck, which matters most on
# exactly the runs that are going wrong. pipefail carries gw_sh's status
# through the pipe.
) 2>&1 | tee "$build_log" || {
    printf 'console138k spectrum build: FAIL (see %s)\n' "$build_log" >&2
    exit 1
}

sha256sum "${source_files[@]}" >"$source_hashes"

if [[ ! -f "$bitstream" ]]; then
    printf 'console138k spectrum build: no bitstream produced (see %s)\n' "$build_log" >&2
    exit 1
fi

python3 "$repo_root/scripts/check_timing.py" "$timing_report" || exit 1

printf 'console138k spectrum build: PASS\n'
printf 'bitstream: %s\n' "$bitstream"
