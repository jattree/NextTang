#!/usr/bin/env bash
# Build the machine CPU bring-up image for the Console 138K.  The `ula`
# profile is a separate target that replaces only the ad-hoc display path with
# the imported ULA and frame-safe 720p scaler. The tape profile also accepts a
# user-supplied TZX or single-member TZX ZIP outside Git.
#
# This path mixes the imported VHDL T80 and, in the `ula` profile, the imported
# VHDL raster with the original Verilog platform shell.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

toolchain=
profile=
vendor_source=
tape_file=
output_dir=

usage() {
    printf '%s\n' 'usage: boards/console138k/build_spectrum48.sh --toolchain vendor --profile release|ula|ula-tape|ula-ddr-upper|ula-ddr-upper-tape [--vendor-source ABSOLUTE_DIRECTORY] [--tape ABSOLUTE_TZX_OR_ZIP] --output ABSOLUTE_DIRECTORY'
}

while (($#)); do
    case "$1" in
        --toolchain|--profile|--vendor-source|--tape|--output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --toolchain) toolchain=$2 ;;
                --profile) profile=$2 ;;
                --vendor-source) vendor_source=$2 ;;
                --tape) tape_file=$2 ;;
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
if [[ "$profile" != release && "$profile" != ula && \
      "$profile" != ula-tape && \
      "$profile" != ula-ddr-upper && \
      "$profile" != ula-ddr-upper-tape ]]; then
    printf 'console138k spectrum build: profile not implemented: %s\n' "$profile" >&2
    exit 2
fi

vendor_files=()
if [[ "$profile" == ula-ddr-upper || \
      "$profile" == ula-ddr-upper-tape ]]; then
    if [[ "$vendor_source" != /* || ! -d "$vendor_source" ]]; then
        printf '%s\n' 'console138k spectrum build: DDR profile requires --vendor-source ABSOLUTE_DIRECTORY' >&2
        exit 2
    fi
    vendor_files=(
        "$vendor_source/ddr3_memory_interface/ddr3_memory_interface.v"
        "$vendor_source/gowin_pll/gowin_pll.v"
        "$vendor_source/gowin_pll/gowin_pll_mod.v"
        "$vendor_source/pll_init.v"
    )
    for vendor_file in "${vendor_files[@]}"; do
        if [[ ! -s "$vendor_file" ]]; then
            printf 'console138k spectrum build: required vendor source missing: %s\n' "$vendor_file" >&2
            exit 2
        fi
    done
fi
if [[ ("$profile" == ula-ddr-upper-tape || "$profile" == ula-tape) && \
      ("$tape_file" != /* || ! -f "$tape_file") ]]; then
    printf '%s\n' 'console138k spectrum build: tape profile requires --tape ABSOLUTE_TZX_OR_ZIP' >&2
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

if [[ "$profile" == ula-ddr-upper-tape ]]; then
    base_name=nexttang_console138k_spectrum48_ula_ddr3_tape
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_ula_ddr3_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula_ddr3.sdc"
elif [[ "$profile" == ula-ddr-upper ]]; then
    base_name=nexttang_console138k_spectrum48_ula_ddr3
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_ula_ddr3_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula_ddr3.sdc"
elif [[ "$profile" == ula-tape ]]; then
    base_name=nexttang_console138k_spectrum48_ula_tape
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula.sdc"
elif [[ "$profile" == ula ]]; then
    base_name=nexttang_console138k_spectrum48_ula
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula.sdc"
else
    base_name=nexttang_console138k_spectrum48
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48.sdc"
fi

if [[ "$profile" == ula-ddr-upper-tape || "$profile" == ula-tape ]]; then
    python3 "$repo_root/scripts/tzx_to_mem.py" \
        "$tape_file" "$output_dir/tape.mem" \
        --manifest "$output_dir/tape-input-sha256.txt" || exit 1
fi

if [[ -n "$pin_constraints_extra" ]]; then
    pin_constraints="$output_dir/$base_name.cst"
    {
        printf '%s\n' '// Generated from the two repository constraint sources below.'
        awk 'FNR == 1 && NR != 1 { print "" } { print }' \
            "$pin_constraints_base" "$pin_constraints_extra"
    } >"$pin_constraints"
else
    pin_constraints=$pin_constraints_base
fi

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
    "$repo_root/rtl/memory/nexttang_block_ram.v"
    "$repo_root/rtl/memory/nexttang_rom.v"
    "$repo_root/rtl/input/nexttang_keyboard_matrix.v"
    "$repo_root/rtl/input/nexttang_key_sequencer.v"
    "$repo_root/rtl/smoke/nexttang_debug_status_uart.v"
    "$repo_root/boards/console138k/nexttang_console138k_machine_pll.v"
    "$repo_root/boards/console138k/nexttang_console138k_pll.v"
    "$repo_root/rtl/video/nexttang_video_timing.v"
    "$repo_root/rtl/video/nexttang_tmds_encoder.v"
)

if [[ "$profile" == ula || "$profile" == ula-tape || \
      "$profile" == ula-ddr-upper || \
      "$profile" == ula-ddr-upper-tape ]]; then
    source_files+=(
        "$repo_root/rtl/video/zxula_timing.vhd"
        "$repo_root/rtl/video/zxula.vhd"
        "$repo_root/rtl/video/nexttang_ula_capture.v"
        "$repo_root/rtl/video/nexttang_framebuffer_scaler.v"
        "$repo_root/rtl/video/nexttang_ula_palette.v"
    )
    if [[ "$profile" == ula-ddr-upper || \
          "$profile" == ula-ddr-upper-tape ]]; then
        source_files+=(
            "$repo_root/rtl/memory/nexttang_cpu_memory_service.v"
            "$repo_root/rtl/memory/nexttang_memory_cdc_bridge.v"
            "$repo_root/rtl/memory/nexttang_byte_line_adapter.v"
            "$repo_root/rtl/memory/nexttang_cpu_memory_path.v"
            "$repo_root/rtl/memory/nexttang_spectrum48_split_memory.v"
            "$repo_root/rtl/memory/nexttang_gowin_ddr3_ui_adapter.v"
            "$repo_root/boards/console138k/nexttang_console138k_ddr3_pll.v"
        )
        if [[ "$profile" == ula-ddr-upper-tape ]]; then
            source_files+=(
                "$repo_root/rtl/input/nexttang_load_key_sequencer.v"
                "$repo_root/rtl/input/nexttang_tzx_player.v"
                "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_ddr3_tape.v"
            )
        else
            source_files+=(
                "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_ddr3.v"
            )
        fi
    elif [[ "$profile" == ula-tape ]]; then
        source_files+=(
            "$repo_root/rtl/input/nexttang_load_key_sequencer.v"
            "$repo_root/rtl/input/nexttang_tzx_player.v"
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_tape.v"
        )
    else
        source_files+=(
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula.v"
        )
    fi
else
    source_files+=(
        "$repo_root/rtl/video/nexttang_spectrum_display.v"
        "$repo_root/boards/console138k/nexttang_console138k_spectrum48.v"
    )
fi

# The ULA wrapper textually includes the established Spectrum 48K top. Gowin
# only receives the wrapper as a source file, but the included top is still a
# build input and must be present in the reproducibility manifest.
hash_files=("${source_files[@]}")
hash_files+=("$pin_constraints_base" "$timing_constraints")
if [[ -n "$pin_constraints_extra" ]]; then
    hash_files+=("$pin_constraints_extra")
fi
if [[ "$profile" == ula || "$profile" == ula-tape || \
      "$profile" == ula-ddr-upper || \
      "$profile" == ula-ddr-upper-tape ]]; then
    hash_files+=(
        "$repo_root/boards/console138k/nexttang_console138k_spectrum48.v"
    )
fi
if [[ "$profile" == ula-ddr-upper-tape || "$profile" == ula-tape ]]; then
    hash_files+=("$repo_root/scripts/tzx_to_mem.py")
fi

if [[ -z "${NEXTTANG_48K_ROM:-}" || ! -f "${NEXTTANG_48K_ROM}" ]]; then
    printf 'console138k spectrum48 build: set NEXTTANG_48K_ROM to a 48K ROM image\n' >&2
    exit 2
fi
rom_image="$output_dir/48k.mem"
python3 "$repo_root/scripts/rom_to_mem.py" "$NEXTTANG_48K_ROM" "$rom_image" \
    --expect-bytes 16384 || exit 1

{
    printf 'set_device -device_version C GW5AST-LV138PG484AC1/I0\n'
    printf 'set_option -top_module %s\n' "$base_name"
    printf 'set_option -verilog_std sysv2017\n'
    printf 'set_option -output_base_name %s\n' "$base_name"
    printf 'set_option -vhdl_std vhd2008\n'
    # A plain-text timing report. The HTML one has to be tag-stripped before it
    # can be read, which is how a broken check went unnoticed for so long.
    printf 'set_option -gen_text_timing_rpt 1\n'
    for vendor_file in "${vendor_files[@]}"; do
        printf 'add_file {%s}\n' "$vendor_file"
    done
    for source_file in "${source_files[@]}"; do
        printf 'add_file {%s}\n' "$source_file"
    done
    printf 'add_file {%s}\n' "$pin_constraints"
    printf 'add_file {%s}\n' "$timing_constraints"
    printf 'run all\n'
} >"$project_tcl"

(
    cd -- "$output_dir"
    QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-offscreen} gw_sh "$project_tcl"
# Shown as it happens as well as kept. A vendor build takes minutes and a
# silent terminal gives no way to tell slow from stuck, which matters most on
# exactly the runs that are going wrong. pipefail carries gw_sh's status
# through the pipe.
) 2>&1 | tee "$build_log" || {
    printf 'console138k spectrum build: FAIL (see %s)\n' "$build_log" >&2
    exit 1
}

sha256sum "${hash_files[@]}" >"$source_hashes"
if ((${#vendor_files[@]})); then
    for vendor_file in "${vendor_files[@]}"; do
        printf '%s  %s\n' \
            "$(sha256sum "$vendor_file" | awk '{print $1}')" \
            "${vendor_file#"$vendor_source/"}"
    done >"$output_dir/vendor-source-sha256.txt"
fi

if [[ ! -f "$bitstream" ]]; then
    printf 'console138k spectrum build: no bitstream produced (see %s)\n' "$build_log" >&2
    exit 1
fi

python3 "$repo_root/scripts/check_timing.py" "$timing_report" || exit 1

printf 'console138k spectrum build: PASS\n'
printf 'bitstream: %s\n' "$bitstream"
